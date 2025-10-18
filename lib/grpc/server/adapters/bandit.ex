defmodule GRPC.Server.Adapters.Bandit do
  @moduledoc """
  A server (`b:GRPC.Server.Adapter`) adapter using `Bandit`.
  """
  require Logger

  alias GRPC.Server.Adapters.Bandit.Handler

  @behaviour GRPC.Server.Adapter

  @impl true
  def start(endpoint, servers, port, opts) do
    case Bandit.start_link(server_config(endpoint, servers, port, opts)) do
      {:ok, pid} ->
        {:ok, pid, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Return a child_spec to start server.
  """
  @spec child_spec(atom(), %{String.t() => [module()]}, non_neg_integer(), Keyword.t()) ::
          Supervisor.child_spec()
  def child_spec(endpoint, servers, port, opts) do
    config = server_config(endpoint, servers, port, opts)
    Bandit.child_spec(config)
  end

  @impl true
  def stop(endpoint, servers) do
    # Bandit gerencia automaticamente o shutdown via Supervisão
    :ok
  end

  @impl true
  def send_reply(%{pid: pid}, data, opts) do
    Handler.stream_body(pid, data, opts, :nofin)
  end

  @impl true
  def send_headers(%{pid: pid}, headers) do
    Handler.send_headers(pid, headers)
  end

  def set_headers(%{pid: pid}, headers) do
    Handler.set_resp_headers(pid, headers)
  end

  def set_resp_trailers(%{pid: pid}, trailers) do
    Handler.set_resp_trailers(pid, trailers)
  end

  def send_trailers(%{pid: pid}, trailers) do
    Handler.stream_trailers(pid, trailers)
  end

  def get_headers(%{pid: pid}) do
    Handler.get_headers(pid)
  end

  def get_peer(%{pid: pid}) do
    Handler.get_peer(pid)
  end

  def get_cert(%{pid: pid}) do
    Handler.get_cert(pid)
  end

  def get_qs(%{pid: pid}) do
    Handler.get_qs(pid)
  end

  def get_bindings(%{pid: pid}) do
    Handler.get_bindings(pid)
  end

  def set_compressor(%{pid: pid}, compressor) do
    Handler.set_compressor(pid, compressor)
  end

  @spec read_body(GRPC.Server.Adapter.state()) :: {:ok, binary()}
  def read_body(%{pid: pid} = payload) do
    Handler.read_full_body(payload)
  end

  @spec reading_stream(GRPC.Server.Adapter.state()) :: Enumerable.t()
  def reading_stream(%{pid: pid} = payload) do
    Stream.unfold(%{pid: pid, need_more: true, buffer: <<>>, payload: payload}, fn acc ->
      read_stream(acc)
    end)
  end

  defp read_stream(%{buffer: <<>>, finished: true}), do: nil

  defp read_stream(%{payload: %{pid: pid}, buffer: buffer, need_more: true} = s) do
    case Handler.read_body(%{pid: pid}) do
      {:ok, data} ->
        new_data = buffer <> data
        new_s = %{s | finished: true, need_more: false, buffer: new_data}
        read_stream(new_s)

      {:more, data} ->
        data = buffer <> data
        new_s = %{s | need_more: false, buffer: data}
        read_stream(new_s)
    end
  end

  defp read_stream(%{buffer: buffer} = s) do
    case GRPC.Message.get_message(buffer) do
      {message, rest} ->
        new_s = Map.put(s, :buffer, rest)
        {message, new_s}

      _ ->
        read_stream(Map.put(s, :need_more, true))
    end
  end

  defp server_config(endpoint, servers, port, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    # Configuração base do Bandit
    base_config = [
      port: port,
      scheme: :http,
      plug: {Handler, build_handler_state(endpoint, servers, opts)}
    ]

    # Adicionar configurações SSL se fornecidas
    config =
      case Keyword.get(adapter_opts, :cred) do
        nil ->
          base_config

        cred_opts ->
          ssl_opts = build_ssl_opts(cred_opts)
          Keyword.put(base_config, :transport_options, ssl_opts)
      end

    # Adicionar outras opções específicas do Bandit
    config
    |> add_bandit_options(adapter_opts)
    |> add_network_options(adapter_opts)
  end

  defp build_handler_state(endpoint, servers, opts) do
    %{
      endpoint: endpoint,
      servers: servers,
      opts: Enum.into(opts, %{})
    }
  end

  defp build_ssl_opts(cred_opts) do
    cred_opts.ssl ++
      [
        next_protocols_advertised: ["h2", "http/1.1"],
        alpn_preferred_protocols: ["h2", "http/1.1"]
      ]
  end

  defp add_bandit_options(config, adapter_opts) do
    config
    |> add_if_present(:http_2, adapter_opts)
    |> add_if_present(:http_1, adapter_opts)
    |> add_if_present(:log_requests, adapter_opts)
    |> add_if_present(:log_errors, adapter_opts)
  end

  defp add_network_options(config, adapter_opts) do
    config
    |> add_if_present(:ip, adapter_opts)
    |> add_if_present(:backlog, adapter_opts)
  end

  defp add_if_present(config, key, opts) do
    case Keyword.get(opts, key) do
      nil -> config
      value -> Keyword.put(config, key, value)
    end
  end
end
