defmodule SymphonyElixir.Dispatch.LocalSessions do
  @moduledoc """
  Observed local task shutdown survives scheduler restarts; remote sessions require explicit recovery.

  Original scheduler lifecycle assertions live in `test/symphony_elixir/core_test.exs`;
  admission and retry composition is exercised by `test/symphony_elixir/dispatch_integration_backpressure_test.exs`.
  """
  use GenServer
  alias SymphonyElixir.Dispatch.Admission.Launch

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec observe(tuple(), term(), String.t(), map(), pid()) :: :ok
  def observe({:ok, config}, owner, id, handle, pid) do
    GenServer.call(__MODULE__, {:observe, {config.path, owner, id}, config, handle, pid})
  end

  @spec stopped_handle(tuple(), term(), String.t()) :: map() | nil
  def stopped_handle({:ok, config}, owner, id) do
    GenServer.call(__MODULE__, {:stopped_handle, {config.path, owner, id}})
  end

  def stopped_handle(_, _, _), do: nil

  @spec forget(tuple(), term(), String.t(), map() | nil) :: :ok
  def forget({:ok, config}, owner, id, handle) do
    GenServer.call(__MODULE__, {:forget, {config.path, owner, id}, handle})
  end

  def forget(_, _, _, _), do: :ok

  @impl true
  def init(_opts), do: {:ok, %{sessions: %{}, refs: %{}}}

  @impl true
  def handle_call({:observe, key, config, handle, pid}, _from, state) do
    state = discard(state, key)
    ref = Process.monitor(pid)
    session = %{config: {:ok, config}, handle: handle, ref: ref, stopped: false}

    {:reply, :ok,
     %{
       state
       | sessions: Map.put(state.sessions, key, session),
         refs: Map.put(state.refs, ref, key)
     }}
  end

  def handle_call({:stopped_handle, key}, _from, state) do
    handle =
      case state.sessions[key] do
        %{stopped: true, handle: handle} -> handle
        _ -> nil
      end

    {:reply, handle, state}
  end

  def handle_call({:forget, key, handle}, _from, state) do
    next =
      case state.sessions[key] do
        %{handle: recorded} when is_map(handle) ->
          if Map.take(recorded, [:token, :session]) == Map.take(handle, [:token, :session]),
            do: discard(state, key),
            else: state

        _ ->
          state
      end

    {:reply, :ok, next}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {key, refs} ->
        session = Map.fetch!(state.sessions, key)
        {_path, _owner, id} = key

        case Launch.stopped(session.config, id, session.handle) do
          {:ok, handle} ->
            {:noreply,
             %{
               state
               | refs: refs,
                 sessions: Map.put(state.sessions, key, %{session | handle: handle, stopped: true})
             }}

          {:error, _} ->
            {:noreply, %{state | refs: refs, sessions: Map.delete(state.sessions, key)}}
        end
    end
  end

  defp discard(state, key) do
    case Map.pop(state.sessions, key) do
      {nil, _} ->
        state

      {%{ref: ref}, sessions} ->
        Process.demonitor(ref, [:flush])
        %{state | sessions: sessions, refs: Map.delete(state.refs, ref)}
    end
  end
end
