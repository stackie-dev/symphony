defmodule SymphonyElixir.Workspace.Paths do
  @moduledoc """
  Owns issue workspace names, path validation, and shell-safe remote path encoding.

  Local paths must remain below the configured root; shell arguments are always quoted.
  """

  alias SymphonyElixir.{Config, PathSafety}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @spec workspace_path_for_issue(String.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.local_workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  def workspace_path_for_issue(safe_id, worker_host)
      when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

    if safe_identifier == identifier do
      safe_identifier
    else
      hash = :crypto.hash(:sha256, identifier) |> Base.encode16(case: :lower) |> binary_part(0, 16)
      "#{safe_identifier}--#{hash}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  @spec validate_workspace_path(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  def validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  def validate_workspace_path(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  @spec validate_recorded_workspace_path(Path.t()) :: :ok | {:error, term()}
  def validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
  end

  @spec remote_shell_assign(String.t(), String.t()) :: String.t()
  def remote_shell_assign(variable_name, raw_path)
      when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(value) when is_binary(value),
    do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  @spec parse_remote_workspace_output(String.t()) ::
          {:ok, Path.t(), boolean()} | {:error, term()}
  def parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end
end
