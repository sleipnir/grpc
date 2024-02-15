defmodule GRPC.Reflection do
  alias Google.Protobuf.{FileDescriptorProto, FileDescriptorSet}

  alias Grpc.Reflection.V1alpha.{
    ErrorResponse,
    FileDescriptorResponse,
    ListServiceResponse,
    ServerReflectionResponse,
    ServiceResponse
  }

  def load_services(path) do
    with {:ok, proto} <- File.read(path),
         descriptor = FileDescriptorSet.decode(proto) do
      _file_descriptors = descriptor.file
    else
      error ->
        {:error, "Error on read descriptor file #{inspect(error)}"}
    end
  end

  def list_services() do
  end

  def find_by_symbol(symbol) do
  end

  def find_by_filename(filename) do
  end

  defp contains_service(state, symbol) do
    description =
      state
      |> Enum.map(&get_service(&1, symbol))
      |> Enum.reduce(fn -> [] end, fn s, acc ->
        acc ++ [s]
      end)
      |> Enum.to_list()
      |> List.flatten()

    if Enum.empty?(description) do
      {:fail, :empty}
    else
      {:ok, description}
    end
  end

  defp contains_message_type(state, symbol) do
    description =
      state
      |> Enum.map(&get_messages(&1, symbol))
      |> Enum.reduce(fn -> [] end, fn s, acc ->
        if s != nil || s != [] do
          acc ++ [s]
        else
          acc
        end
      end)
      |> Enum.to_list()
      |> List.flatten()

    if Enum.empty?(description) do
      {:fail, :empty}
    else
      {:ok, Enum.filter(description, &(!is_nil(&1)))}
    end
  end

  defp get_service(descriptor, symbol) do
    services = extract_services(descriptor)

    svcs =
      services
      |> Enum.filter(fn service -> symbol =~ service.name end)
      |> Enum.map(fn _ -> FileDescriptorProto.encode(descriptor) end)
      |> Enum.reduce(fn -> [] end, fn s, acc ->
        acc ++ [s]
      end)
      |> Enum.to_list()

    svcs
  end

  defp get_messages(descriptor, symbol) do
    message_types = extract_messages(descriptor)

    if !Enum.empty?(message_types) do
      types =
        message_types
        |> Enum.filter(fn message -> symbol =~ message.name end)
        |> Enum.map(fn _ -> FileDescriptorProto.encode(descriptor) end)
        |> Enum.reduce(fn -> [] end, fn s, acc ->
          [s] ++ acc
        end)
        |> Enum.to_list()

      types
    end
  end

  defp extract_info(descriptor) do
    package = descriptor.package
    services = extract_services(descriptor)

    svcs =
      services
      |> Enum.map(fn service -> ServiceResponse.new(name: "#{package}.#{service.name}") end)
      |> Enum.reduce(fn -> [] end, fn s, acc ->
        acc ++ [s]
      end)
      |> Enum.to_list()

    svcs
  end

  defp extract_services(file) do
    file.service
    |> Enum.to_list()
  end

  defp extract_messages(file) do
    file.message_type
    |> Enum.to_list()
  end
end
