defmodule SymphonyElixir.WorkspaceGitSupport do
  @moduledoc false

  def clean_checkout!(path) do
    File.mkdir_p!(Path.dirname(path))
    ensure_empty!(path)
    {seed, origin} = origin_paths(path)
    create_origin!(seed, origin)
    git!(Path.dirname(path), ["clone", origin, path])
    File.rm_rf!(seed)
    path
  end

  def initialize_clean_checkout!(path) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".gitignore"), "*.log\n")
    unless File.exists?(Path.join(path, "README.md")), do: File.write!(Path.join(path, "README.md"), "baseline\n")

    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.name", "Symphony Test"])
    git!(path, ["config", "user.email", "symphony-test@example.com"])
    git!(path, ["add", ".gitignore", "README.md"])
    git!(path, ["commit", "-m", "initial workspace commit"])
    {_seed, origin} = origin_paths(path)
    create_bare_origin!(origin)
    git!(path, ["remote", "add", "origin", origin])
    git!(path, ["push", "--set-upstream", "origin", "main"])
    set_origin_head!(origin)
    path
  end

  defp create_origin!(seed, origin) do
    File.mkdir_p!(seed)
    git!(seed, ["init", "-b", "main"])
    git!(seed, ["config", "user.name", "Symphony Test"])
    git!(seed, ["config", "user.email", "symphony-test@example.com"])
    File.write!(Path.join(seed, ".gitignore"), "*.log\n")
    File.write!(Path.join(seed, "README.md"), "baseline\n")
    git!(seed, ["add", ".gitignore", "README.md"])
    git!(seed, ["commit", "-m", "initial workspace commit"])
    create_bare_origin!(origin)
    git!(seed, ["remote", "add", "origin", origin])
    git!(seed, ["push", "--set-upstream", "origin", "main"])
    set_origin_head!(origin)
  end

  defp create_bare_origin!(origin) do
    File.mkdir_p!(Path.dirname(origin))
    git!(Path.dirname(origin), ["init", "--bare", origin])
  end

  defp set_origin_head!(origin) do
    git!(Path.dirname(origin), ["--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main"])
  end

  defp origin_paths(path) do
    suffix = System.unique_integer([:positive])
    root = Path.dirname(path)
    {Path.join(root, ".workspace-seed-#{suffix}"), Path.join(root, ".workspace-origin-#{suffix}.git")}
  end

  defp ensure_empty!(path) do
    case File.ls(path) do
      {:ok, []} -> :ok
      {:error, :enoent} -> :ok
      {:ok, entries} -> raise "fixture checkout path must be empty: #{path} contains #{inspect(entries)}"
      {:error, reason} -> raise "could not inspect fixture checkout path #{path}: #{inspect(reason)}"
    end
  end

  defp git!(directory, args) do
    case System.cmd("git", ["-C", directory | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed status=#{status}: #{output}"
    end
  end
end
