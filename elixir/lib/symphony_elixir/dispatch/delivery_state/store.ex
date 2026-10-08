defmodule SymphonyElixir.Dispatch.DeliveryState.Store do
  @moduledoc """
  Atomic JSON delivery observation replacement, retaining prior bytes on errors.

  The same-directory exclusive temporary file is synced before rename. Temporary
  files never become recovery inputs; missing/corrupt canonical state fails closed.
  This provides restart recovery, not a distributed lease or power-loss guarantee
  for filesystems which require directory fsync after rename.
  """
  alias SymphonyElixir.Dispatch.DeliveryState.Model

  @spec load(Path.t()) :: {:ok, map()} | {:error, {:delivery_state, atom()}}
  def load(path) do
    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, state} <- Jason.decode(bytes), :ok <- Model.validate(state) do
          {:ok, state}
        else
          _ -> error(:corrupt)
        end

      {:error, :enoent} ->
        error(:missing)

      {:error, _} ->
        error(:persistence)
    end
  end

  @spec load_or_new(Path.t()) :: {:ok, map()} | {:error, {:delivery_state, atom()}}
  def load_or_new(path) do
    case load(path) do
      {:error, {:delivery_state, :missing}} -> {:ok, Model.new()}
      result -> result
    end
  end

  @spec save(Path.t(), map(), (Path.t(), Path.t() -> :ok | {:error, term()})) :: :ok | {:error, {:delivery_state, :persistence}}
  def save(path, state, rename \\ &File.rename/2) do
    temp = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <> ".tmp"

    try do
      with :ok <- Model.validate(state),
           {:ok, bytes} <- Jason.encode(state),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- write_synced(temp, bytes),
           :ok <- rename.(temp, path) do
        :ok
      else
        _ -> error(:persistence)
      end
    after
      File.rm(temp)
    end
  end

  defp write_synced(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result = with :ok <- IO.binwrite(file, bytes), do: :file.sync(file)
        close = File.close(file)
        if result == :ok and close == :ok, do: :ok, else: error(:persistence)

      {:error, _} ->
        error(:persistence)
    end
  end

  defp error(reason), do: {:error, {:delivery_state, reason}}
end
