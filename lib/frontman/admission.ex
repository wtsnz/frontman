defmodule Frontman.Admission do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Frontman.admission(Keyword.fetch!(opts, :name)))
  end

  @impl true
  def init(opts) do
    limit = Keyword.get(opts, :max_concurrency, 16)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "max_concurrency must be positive")

    {:ok,
     %{name: Keyword.fetch!(opts, :name), limit: limit, mode: :ready, leases: %{}, waiters: %{}}}
  end

  @impl true
  def handle_call({:checkout, excluded, deadline}, {owner, _tag}, state) do
    candidates = workers(state) |> Enum.reject(&(&1.pid in excluded))
    available = Enum.filter(candidates, &(&1.in_flight < state.limit))

    cond do
      System.monotonic_time(:millisecond) >= deadline ->
        reject(:unavailable, state)

      state.mode == :draining ->
        reject(:draining, state)

      candidates == [] ->
        reject(:unavailable, state)

      available == [] ->
        reject(:overloaded, state)

      true ->
        least = available |> Enum.map(& &1.in_flight) |> Enum.min()
        worker = available |> Enum.filter(&(&1.in_flight == least)) |> Enum.random()
        ref = Process.monitor(owner)
        state = put_in(state.leases[ref], %{worker: worker.pid, started: System.monotonic_time()})
        emit(:start, state, %{worker: worker.index})
        {:reply, {:ok, Map.put(worker, :lease, {self(), ref})}, state}
    end
  end

  def handle_call({:checkin, ref}, _from, state),
    do: {:reply, :ok, release(state, ref, :complete)}

  def handle_call(:workers, _from, state), do: {:reply, workers(state), state}

  def handle_call(:status, _from, state) do
    workers = workers(state)

    {:reply,
     %{
       mode: state.mode,
       in_flight: map_size(state.leases),
       max_concurrency: state.limit,
       capacity: length(workers) * state.limit,
       workers: workers,
       slots: Frontman.slots(state.name),
       cache: Frontman.Cache.stats(state.name)
     }, state}
  end

  def handle_call({:drain, timeout}, from, state) do
    state = %{state | mode: :draining}

    :telemetry.execute(
      [:frontman, :pool, :drain],
      %{in_flight: map_size(state.leases)},
      %{name: state.name}
    )

    if map_size(state.leases) == 0 do
      {:reply, :ok, state}
    else
      ref = make_ref()
      timer = Process.send_after(self(), {:drain_timeout, ref}, timeout)
      {:noreply, put_in(state.waiters[ref], {from, timer})}
    end
  end

  def handle_call(:resume, _from, state) do
    if map_size(state.waiters) > 0 do
      {:reply, {:error, :drain_in_progress}, state}
    else
      :telemetry.execute([:frontman, :pool, :resume], %{}, %{name: state.name})
      {:reply, :ok, %{state | mode: :ready}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, release(state, ref, :owner_down)}

  def handle_info({:drain_timeout, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _waiters} ->
        {:noreply, state}

      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  defp workers(state) do
    counts = state.leases |> Map.values() |> Enum.frequencies_by(& &1.worker)

    Enum.map(Frontman.registered_workers(state.name), fn worker ->
      Map.merge(worker, %{in_flight: Map.get(counts, worker.pid, 0), state: state.mode})
    end)
  end

  defp release(state, ref, reason) do
    case Map.pop(state.leases, ref) do
      {nil, _leases} ->
        state

      {lease, leases} ->
        Process.demonitor(ref, [:flush])
        state = %{state | leases: leases}

        :telemetry.execute(
          [:frontman, :request, :stop],
          %{in_flight: map_size(leases), duration: System.monotonic_time() - lease.started},
          %{name: state.name, reason: reason}
        )

        if map_size(leases) == 0 do
          for {_ref, {from, timer}} <- state.waiters do
            Process.cancel_timer(timer)
            GenServer.reply(from, :ok)
          end

          %{state | waiters: %{}}
        else
          state
        end
    end
  end

  defp reject(reason, state) do
    emit(:rejected, state, %{reason: reason})
    {:reply, {:error, reason}, state}
  end

  defp emit(event, state, metadata) do
    :telemetry.execute(
      [:frontman, :request, event],
      %{in_flight: map_size(state.leases)},
      Map.put(metadata, :name, state.name)
    )
  end
end
