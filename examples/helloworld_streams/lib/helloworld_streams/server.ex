defmodule HelloworldStreams.Server do
  @moduledoc """
  gRPC service for streaming data.
  """
  use GRPC.Server, service: Stream.EchoServer.Service

  alias HelloworldStreams.Utils.Transformer
  alias GRPC.Stream, as: GRPCStream

  alias Stream.HelloRequest
  alias Stream.HelloReply

  @spec say_unary_hello(HelloRequest.t(), GRPC.Server.Stream.t()) :: any()
  def say_unary_hello(request, _materializer) do
    error_handler = fn
      {:error, %GRPC.RPCError{message: reason} = error} ->
        %GRPC.RPCError{message: "[Error] #{inspect(reason)}"}

      {:error, ArgumentError = error} ->
        %GRPC.RPCError{message: "[Error] Argument exception: #{inspect(error)}"}

      _ ->
        %GRPC.RPCError{message: "[Error] Unknown error occurred"}
    end

    GRPCStream.unary(request)
    |> GRPCStream.ask(Transformer)
    |> GRPCStream.map(fn %HelloReply{} = reply ->
      %HelloReply{message: "[Reply] #{reply.message}"}
    end)
    |> GRPCStream.run(:on_failure, error_handler, errors_to_telemetry: true)
  end

  @spec say_server_hello(HelloRequest.t(), GRPC.Server.Stream.t()) :: any()
  def say_server_hello(request, materializer) do
    create_output_stream(request)
    |> GRPCStream.from()
    |> GRPCStream.run_with(materializer)
  end

  defp create_output_stream(msg) do
    Stream.repeatedly(fn ->
      index = :rand.uniform(10)
      %HelloReply{message: "[#{index}] I'm the Server for #{msg.name}"}
    end)
    |> Stream.take(10)
    |> Enum.to_list()
  end

  @spec say_bid_stream_hello(Enumerable.t(), GRPC.Server.Stream.t()) :: any()
  def say_bid_stream_hello(request, materializer) do
    # simulate a infinite stream of data
    # this is a simple example, in a real world application
    # you would probably use a GenStage or similar
    # to handle the stream of data
    output_stream =
      Stream.repeatedly(fn ->
        index = :rand.uniform(10)
        %HelloReply{message: "[#{index}] I'm the Server ;)"}
      end)

    GRPCStream.from(request, join_with: output_stream)
    |> GRPCStream.map(fn
      %HelloRequest{} = hello ->
        %HelloReply{message: "Welcome #{hello.name}"}

      output_item ->
        output_item
    end)
    |> GRPCStream.run_with(materializer)
  end
end
