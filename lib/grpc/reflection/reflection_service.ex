defmodule GRPC.Reflection.Service do
  @moduledoc """
  This module implement gRPC Reflection Service.
  """
  use GRPC.Server, service: Grpc.Reflection.V1alpha.ServerReflection.Service
  require Logger

  alias GRPC.Reflection
  alias Grpc.Reflection.V1alpha.{ServerReflectionRequest, ServerReflectionResponse, ErrorResponse}

  alias GRPC.Server

  @spec server_reflection_info(ServerReflectionRequest.t(), GRPC.Server.Stream.t()) ::
          :ok
  def server_reflection_info(request, stream) do
    Enum.each(request, fn message ->
      Logger.debug("Received reflection request: #{inspect(message)}")

      send_reflection(stream, message.message_request)
    end)
  end

  def send_reflection(stream, {:list_services, _}),
    do: Server.send_reply(stream, Reflection.list_services())

  def send_reflection(stream, {:file_containing_symbol, symbol}),
    do: Server.send_reply(stream, Reflection.find_by_symbol(symbol))

  def send_reflection(stream, {:file_by_filename, filename}),
    do: Server.send_reply(stream, Reflection.find_by_filename(filename))

  def send_reflection(stream, _) do
    Logger.warn("This Reflection Operation is not supported")

    response =
      ServerReflectionResponse.new(
        message_response:
          {:error_response,
           ErrorResponse.new(error_code: 13, error_message: "Operation not supported")}
      )

    Server.send_reply(stream, response)
  end
end
