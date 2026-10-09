defmodule SymphonyElixir.Dispatch.DeliveryState do
  @moduledoc """
  Durable, read-only delivery observations for the selected tracker issue set.

  A successful refresh persists the complete observation before returning it.
  Errors never mean an empty backlog. Callers must reject admission after any
  refresh error; `read/3` is restart recovery, not a substitute for revalidation.
  This reader neither reserves writers nor mutates tracker issues or PRs.
  """
  alias SymphonyElixir.Dispatch.DeliveryState.{Model, Snapshot, Source, Store}

  @type result :: {:ok, Snapshot.t()} | {:error, {:delivery_state, atom()}}

  @doc """
  Reloads and refreshes selected issues and all previously known PR identities.

  Required options are `:issue_ids` and the `:repositories` allowlist. An explicit
  empty issue list is valid; known deliveries still require confirmation.
  `:now_ms` defaults to Unix milliseconds and `:max_age_ms` to 60 seconds.
  Read collaborators `:tracker_read` and `:pr_read` are optional contract seams;
  defaults use existing Linear and GitHub clients. See the owner guide.
  """
  @spec refresh(Path.t(), keyword()) :: result()
  def refresh(path, opts) when is_binary(path) and is_list(opts) do
    # Serialize same-path refreshes; this is an observation store, not a lease.
    :global.trans({{__MODULE__, Path.expand(path)}, self()}, fn -> refresh_locked(path, opts) end)
  end

  def refresh(_, _), do: {:error, {:delivery_state, :invalid_options}}

  @doc "Reloads durable state and rejects missing, corrupt, future or stale observations."
  @spec read(Path.t(), non_neg_integer(), non_neg_integer()) :: result()
  def read(path, now_ms, max_age_ms) when is_binary(path) do
    with {:ok, state} <- Store.load(path),
         :ok <- Model.fresh(state, now_ms, max_age_ms) do
      {:ok, Model.snapshot(state)}
    end
  end

  def read(_, _, _), do: {:error, {:delivery_state, :invalid_options}}

  defp refresh_locked(path, opts) do
    with {:ok, settings} <- Source.options(opts),
         {:ok, previous} <- Store.load_or_new(path),
         :ok <- Model.clock(previous, settings.now_ms),
         {:ok, refs, sources} <- Source.discover(settings),
         {:ok, observations} <- Source.observe(refs, previous["entries"], settings),
         {:ok, next} <- Model.reconcile(previous, observations, sources, settings.now_ms),
         :ok <- Store.save(path, next) do
      {:ok, Model.snapshot(next)}
    end
  rescue
    _ -> {:error, {:delivery_state, :unavailable}}
  catch
    :exit, _ -> {:error, {:delivery_state, :unavailable}}
  end
end
