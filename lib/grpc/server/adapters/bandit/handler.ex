defmodule GRPC.Server.Adapters.Bandit.Handler do
  @moduledoc """
  A Bandit Plug handler for gRPC requests.
  """
  use Plug.Router
  require Logger

  alias GRPC.Transport.HTTP2
  alias GRPC.RPCError

  @default_trailers HTTP2.server_trailers()

  def init(%{servers: servers} = opts) do
    Map.put(opts, :routes, build_routes_cache(servers))
  end

  def call(conn, opts) do
    conn
    |> put_private(:plug_opts, opts)
    |> super(opts)
  end

  defp build_routes_cache(servers) do
    Enum.flat_map(servers, fn {_name, server} ->
      server.__meta__(:routes)
      |> Enum.map(fn
        {:grpc, path} ->
          {path, {:grpc, server, path}}

        {:http_transcode, {method, path, _matches}} ->
          {path, {:http_transcode, server, path, method}}
      end)
    end)
    |> Enum.into(%{})
  end

  plug(:match)
  plug(:dispatch)

  # catch-all to gRPC
  match _ do
    handle_grpc_request(conn)
  end

  defp handle_grpc_request(conn) do
    path = conn.request_path
    method = conn.method

    # Find the appropriate handler based on the route
    case Map.get(conn.private.plug_opts.routes, path) do
      {:grpc, server, route} ->
        handle_grpc_call(conn, server, route, :grpc)

      {:http_transcode, server, route, expected_method} when method == expected_method ->
        handle_grpc_call(conn, server, route, :http_transcoding)

      _ ->
        # Try to find more complex route pattern for HTTP transcoding
        case find_http_transcode_route(conn, conn.private.plug_opts.servers) do
          {server, route} ->
            handle_grpc_call(conn, server, route, :http_transcoding)

          nil ->
            send_resp(conn, 404, "Not Found")
        end
    end
  end

  defp find_http_transcode_route(conn, servers) do
    Enum.find_value(servers, fn {_name, server} ->
      routes = server.__meta__(:routes)

      Enum.find_value(routes, fn
        {:http_transcode, {method, _path, matches}} when method == conn.method ->
          if matches_path(matches, conn.request_path) do
            {server, extract_route_from_matches(matches)}
          end

        _ ->
          nil
      end)
    end)
  end

  defp matches_path(_matches, _request_path) do
    # TODO: Implement route matching logic
    true
  end

  defp extract_route_from_matches(_matches) do
    "/grpc/route"
  end

  defp handle_grpc_call(conn, server, route, access_mode) do
    try do
      with {:ok, _content_type, codec} <- find_content_type_and_codec(conn, server),
           {:ok, compressor} <- find_compressor(conn, server) do
        stream_pid = self()

        stream = %GRPC.Server.Stream{
          server: server,
          endpoint: conn.private.plug_opts.endpoint,
          adapter: GRPC.Server.Adapters.Bandit,
          payload: %{pid: stream_pid, conn: conn},
          codec: codec,
          http_method: String.to_atom(conn.method),
          http_request_headers: Map.new(conn.req_headers),
          http_transcode: access_mode == :http_transcoding,
          compressor: compressor,
          is_preflight?: conn.method == "OPTIONS",
          access_mode: access_mode
        }

        # Store connection and stream state in process dictionary for async operations
        Process.put(:grpc_conn, conn)
        Process.put(:grpc_stream, stream)
        Process.put(:resp_headers, [])
        Process.put(:resp_trailers, [])

        method = String.downcase(conn.method) |> String.to_atom()

        # Execute RPC call - this will call adapter functions asynchronously
        case server.__call_rpc__(route, method, stream) do
          {:ok, _stream} ->
            # For streaming responses, wait for completion signal
            wait_for_stream_completion(conn)

          {:ok, _stream, response} ->
            # For unary responses, wait for completion signal  
            stream
            |> GRPC.Server.send_reply(response)
            |> GRPC.Server.send_trailers(@default_trailers)

          {:error, error} ->
            send_grpc_error(conn, error)
        end
      else
        {:error, error} ->
          send_grpc_error(conn, error)
      end
    rescue
      error ->
        Logger.error("GRPC handler error: #{inspect(error)}")
        send_grpc_error(conn, %RPCError{status: :internal, message: "Internal server error"})
    end
  end

  defp wait_for_stream_completion(initial_conn) do
    receive do
      {:stream_complete, conn} ->
        conn
    after
      30_000 ->
        # Timeout - return the last known connection state
        Process.get(:grpc_conn) || initial_conn
    end
  end

  defp find_content_type_and_codec(conn, server) do
    content_type =
      get_req_header(conn, "content-type")
      |> List.first() ||
        get_req_header(conn, "accept")
        |> List.first()

    case extract_subtype(content_type) do
      {:ok, :grpc, subtype} ->
        case find_codec(subtype, server) do
          {:ok, codec} -> {:ok, content_type, codec}
          error -> error
        end

      {:ok, :http_transcoding, "json"} ->
        {:ok, content_type, GRPC.Codec.JSON}

      _ ->
        {:error, RPCError.exception(status: :unimplemented, message: "Unsupported content type")}
    end
  end

  defp extract_subtype("application/grpc"), do: {:ok, :grpc, "proto"}
  defp extract_subtype("application/grpc+proto"), do: {:ok, :grpc, "proto"}
  defp extract_subtype("application/grpc-web"), do: {:ok, :grpc, "proto"}
  defp extract_subtype("application/grpc-web-text"), do: {:ok, :grpc, "text"}
  defp extract_subtype("application/json"), do: {:ok, :http_transcoding, "json"}
  defp extract_subtype(_), do: {:error, :unsupported_content_type}

  defp find_codec(subtype, server) do
    codec = Enum.find(server.__meta__(:codecs), fn c -> c.name() == subtype end)

    if codec do
      {:ok, codec}
    else
      {:error,
       RPCError.exception(
         status: :unimplemented,
         message: "No codec found for subtype #{subtype}"
       )}
    end
  end

  defp find_compressor(conn, server) do
    encoding = get_req_header(conn, "grpc-encoding") |> List.first()

    if encoding do
      compressor = Enum.find(server.__meta__(:compressors), fn c -> c.name() == encoding end)

      if compressor do
        {:ok, compressor}
      else
        {:error,
         RPCError.exception(status: :unimplemented, message: "Unsupported encoding #{encoding}")}
      end
    else
      {:ok, nil}
    end
  end

  defp send_grpc_error(conn, error) do
    status = if error.status == :unimplemented, do: 404, else: 200
    trailers = HTTP2.server_trailers(status, error.message)

    conn
    |> put_resp_headers(trailers)
    |> send_resp(status, "")
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      put_resp_header(conn, key, value)
    end)
  end

  # API functions for GRPC.Server.Stream

  def read_full_body(%{conn: %Plug.Conn{} = conn}) do
    do_read_full_body(conn, <<>>)
  end

  def read_full_body(%{pid: pid}) do
    sync_call(pid, :read_full_body)
  end

  def read_body(%{conn: %Plug.Conn{} = conn}) do
    case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 8_000_000, read_timeout: 5_000) do
      {:ok, body, _conn} -> {:ok, body}
      {:more, part, _conn} -> {:more, part}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_body(%{pid: pid}) do
    sync_call(pid, :read_body)
  end

  defp do_read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn,
           length: 8_000_000,
           read_length: 8_000_000,
           read_timeout: 10_000
         ) do
      {:ok, body, _conn} ->
        {:ok, acc <> body}

      {:more, chunk, _conn} ->
        do_read_full_body(conn, acc <> chunk)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stream_body(pid, data, opts, is_fin, http_transcode? \\ false) do
    send(pid, {:stream_body, data, opts, is_fin, http_transcode?})
    :ok
  end

  def stream_reply(pid, status, headers) do
    send(pid, {:stream_reply, status, headers})
    :ok
  end

  def set_resp_headers(pid, headers) do
    send(pid, {:set_resp_headers, headers})
    :ok
  end

  def set_resp_trailers(pid, trailers) do
    send(pid, {:set_resp_trailers, trailers})
    :ok
  end

  def stream_trailers(pid, trailers) do
    send(pid, {:stream_trailers, trailers})
    :ok
  end

  def set_compressor(pid, compressor) do
    send(pid, {:set_compressor, compressor})
    :ok
  end

  def get_headers(%{pid: pid}) do
    sync_call(pid, :get_headers)
  end

  def get_peer(%{pid: pid}) do
    sync_call(pid, :get_peer)
  end

  def get_cert(%{pid: pid}) do
    sync_call(pid, :get_cert)
  end

  def get_qs(%{pid: pid}) do
    sync_call(pid, :get_qs)
  end

  def get_bindings(%{pid: pid}) do
    sync_call(pid, :get_bindings)
  end

  defp sync_call(pid, key) do
    ref = make_ref()
    send(pid, {key, ref, self()})

    receive do
      {^ref, msg} -> msg
    after
      5000 -> raise "Timeout in sync_call #{key}"
    end
  end

  # Handler for asynchronous messages
  def handle_info({:stream_body, data, opts, is_fin, http_transcode?}, state) do
    conn = Process.get(:grpc_conn)
    stream = Process.get(:grpc_stream)

    if conn do
      conn = send_stream_body(conn, data, opts, is_fin, http_transcode?, stream)
      Process.put(:grpc_conn, conn)
    end

    {:noreply, state}
  end

  def handle_info({:stream_reply, status, headers}, state) do
    conn = Process.get(:grpc_conn)

    if conn do
      conn = send_headers(conn, headers, status)
      Process.put(:grpc_conn, conn)
    end

    {:noreply, state}
  end

  def handle_info({:set_resp_headers, headers}, state) do
    # Store headers to be sent later
    current_headers = Process.get(:resp_headers, [])
    Process.put(:resp_headers, current_headers ++ Enum.to_list(headers))
    {:noreply, state}
  end

  def handle_info({:set_resp_trailers, trailers}, state) do
    # Store trailers to be sent later
    current_trailers = Process.get(:resp_trailers, [])
    Process.put(:resp_trailers, current_trailers ++ Enum.to_list(trailers))
    {:noreply, state}
  end

  def handle_info({:stream_trailers, trailers}, state) do
    conn = Process.get(:grpc_conn)
    current_trailers = Process.get(:resp_trailers, [])
    all_trailers = current_trailers ++ Enum.to_list(trailers)

    if conn do
      conn = send_trailers(conn, all_trailers)
      Process.put(:grpc_conn, conn)

      # Signal that streaming is complete
      send(self(), {:stream_complete, conn})
    end

    {:noreply, state}
  end

  def handle_info({:set_compressor, compressor}, state) do
    Process.put(:compressor, compressor)
    {:noreply, state}
  end

  def handle_info({:read_full_body, ref, pid}, state) do
    conn = Process.get(:grpc_conn)

    if conn do
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      send(pid, {ref, {:ok, body}})
    else
      send(pid, {ref, {:ok, ""}})
    end

    {:noreply, state}
  end

  def handle_info({:read_body, ref, pid}, state) do
    conn = Process.get(:grpc_conn)

    if conn do
      case Plug.Conn.read_body(conn, length: 65_536) do
        {:ok, body, conn} ->
          Process.put(:grpc_conn, conn)
          send(pid, {ref, {:ok, body}})

        {:more, body, conn} ->
          Process.put(:grpc_conn, conn)
          send(pid, {ref, {:more, body}})
      end
    else
      send(pid, {ref, {:ok, ""}})
    end

    {:noreply, state}
  end

  def handle_info({:get_headers, ref, pid}, state) do
    conn = Process.get(:grpc_conn)
    headers = if conn, do: conn.req_headers, else: []
    send(pid, {ref, headers})
    {:noreply, state}
  end

  def handle_info({:get_peer, ref, pid}, state) do
    conn = Process.get(:grpc_conn)
    peer = if conn, do: conn.peer, else: nil
    send(pid, {ref, peer})
    {:noreply, state}
  end

  def handle_info({:get_cert, ref, pid}, state) do
    # Bandit doesn't expose certificate directly
    send(pid, {ref, :undefined})
    {:noreply, state}
  end

  def handle_info({:get_qs, ref, pid}, state) do
    conn = Process.get(:grpc_conn)
    qs = if conn, do: conn.query_string, else: ""
    send(pid, {ref, qs})
    {:noreply, state}
  end

  def handle_info({:get_bindings, ref, pid}, state) do
    # For HTTP transcoding, extract bindings from route
    send(pid, {ref, %{}})
    {:noreply, state}
  end

  def handle_info({:stream_complete, conn}, state) do
    # This is the signal that streaming is complete
    {:noreply, %{state | conn: conn}}
  end

  # Helper functions for streaming processing
  defp send_stream_body(conn, data, opts, is_fin, http_transcode?, stream) do
    if http_transcode? do
      # For HTTP transcoding, send as plain JSON
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_chunked(200)
      |> then(fn {conn, _} ->
        if is_fin == :fin do
          conn
        else
          {conn, _} = chunk(conn, data)
          conn
        end
      end)
    else
      # For pure gRPC, encode the message
      compressor = Process.get(:compressor)

      case GRPC.Message.to_data(data, compressor: compressor, codec: stream.codec) do
        {:ok, encoded_data, _size} ->
          conn
          |> put_resp_header("content-type", "application/grpc+proto")
          |> send_chunked(200)
          |> then(fn {conn, _} ->
            if is_fin == :fin do
              conn
            else
              {conn, _} = chunk(conn, encoded_data)
              conn
            end
          end)

        {:error, msg} ->
          Logger.error("Failed to encode gRPC message: #{msg}")
          conn
      end
    end
  end

  defp send_headers(conn, headers, status) do
    # Apply any previously set response headers
    stored_headers = Process.get(:resp_headers, [])
    all_headers = stored_headers ++ Enum.to_list(headers)

    conn =
      Enum.reduce(all_headers, conn, fn {key, value}, conn ->
        put_resp_header(conn, key, value)
      end)

    # Start chunked response for streaming
    {conn, _} = send_chunked(conn, status)
    conn
  end

  defp send_trailers(conn, trailers) do
    # Apply trailers as headers
    conn
    |> put_resp_headers(trailers)
  end
end
