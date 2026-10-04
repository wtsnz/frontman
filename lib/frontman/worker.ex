defmodule Frontman.Worker do
  @moduledoc """
  Owns one frontend process across startup, health checks and delayed restarts.

  Expected frontend failures stay inside this process, preserving backoff history. Probes and
  shutdown run in separate tasks; only responsive workers appear in the ready registry.
  """
  use GenServer
  require Logger

  @defaults [
    health_check_interval: 2_000,
    health_check_timeout: 500,
    health_check_failures: 3,
    startup_timeout: 30_000,
    restart_backoff_min: 250,
    restart_backoff_max: 30_000,
    restart_backoff_reset_after: 30_000
  ]

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.fetch!(opts, :index)},
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 8_000
    }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    settings = Keyword.merge(@defaults, Keyword.take(opts, Keyword.keys(@defaults)))

    for {key, value} <- settings do
      unless is_integer(value) and value > 0, do: raise(ArgumentError, "#{key} must be positive")
    end

    if settings[:restart_backoff_min] > settings[:restart_backoff_max],
      do: raise(ArgumentError, "restart_backoff_min must not exceed restart_backoff_max")

    state = %{
      name: Keyword.fetch!(opts, :name),
      index: Keyword.fetch!(opts, :index),
      opts: opts,
      settings: Map.new(settings),
      phase: :starting,
      daemon: nil,
      probe: nil,
      shutdown_task: nil,
      port: nil,
      token: nil,
      node_pid: nil,
      generation: nil,
      failures: 0,
      restart_attempt: 0,
      ready_since: nil,
      next_delay: nil,
      reason: nil
    }

    {:ok, _} = Registry.register(Frontman.states(state.name), state.index, info(state))
    send(self(), :start)
    {:ok, state}
  end

  @impl true
  def handle_info(:start, state) do
    state = %{
      state
      | phase: :starting,
        generation: make_ref(),
        port: free_port(),
        token: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
        node_pid: nil,
        failures: 0,
        ready_since: nil,
        next_delay: nil
    }

    state = Map.put(state, :deadline, now() + state.settings.startup_timeout)
    publish(state)
    emit(state, :start, %{}, %{attempt: state.restart_attempt})

    case MuonTrap.Daemon.start_link(
           state.opts[:executable],
           state.opts[:args],
           daemon_options(state)
         ) do
      {:ok, daemon} ->
        state = %{state | daemon: daemon}
        schedule_probe(state, 0)
        {:noreply, state}

      {:error, reason} ->
        {:noreply, backoff(state, {:start_failed, reason})}
    end
  end

  def handle_info({:probe, generation}, %{generation: generation, probe: nil} = state)
      when state.phase in [:starting, :ready, :suspect] do
    task = Task.Supervisor.async_nolink(Frontman.tasks(state.name), fn -> probe(state) end)

    timer =
      Process.send_after(self(), {:probe_timeout, task.ref}, state.settings.health_check_timeout)

    {:noreply, %{state | probe: {task, timer}}}
  end

  def handle_info({ref, result}, %{probe: {%Task{ref: ref}, timer}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)
    {:noreply, probe_result(result, %{state | probe: nil})}
  end

  def handle_info({:probe_timeout, ref}, %{probe: {%Task{ref: ref} = task, _timer}} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, probe_result(:not_ready, %{state | probe: nil})}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{probe: {%Task{ref: ref}, timer}} = state
      ) do
    Process.cancel_timer(timer)
    {:noreply, probe_result(:not_ready, %{state | probe: nil})}
  end

  def handle_info({ref, :ok}, %{shutdown_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, backoff(%{state | daemon: nil, shutdown_task: nil}, state.reason)}
  end

  def handle_info({ref, {:error, reason}}, %{shutdown_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, cleanup_failed(state, reason)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{shutdown_task: %Task{ref: ref}} = state) do
    {:noreply, cleanup_failed(state, reason)}
  end

  def handle_info({:EXIT, daemon, _reason}, %{daemon: daemon, phase: phase} = state)
      when phase in [:stopping, :cleanup_failed], do: {:noreply, state}

  def handle_info({:EXIT, daemon, reason}, %{daemon: daemon} = state) when is_pid(daemon) do
    state = state |> withdraw() |> cancel_probe()
    {:noreply, backoff(%{state | daemon: nil}, {:node_exited, reason})}
  end

  # Ignore late messages from cancelled probes and earlier frontend generations.
  def handle_info({:probe, _generation}, state), do: {:noreply, state}
  def handle_info({:probe_timeout, _ref}, state), do: {:noreply, state}
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  # An already retired daemon can deliver its exit after the shutdown task result.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_probe(state)
    stop_daemon(state.daemon)
    if state.shutdown_task, do: Task.shutdown(state.shutdown_task, :brutal_kill)
  end

  defp probe_result({:ok, node_pid}, state) do
    recovering? = state.phase != :ready
    ready_since = if recovering?, do: now(), else: state.ready_since

    attempt =
      if now() - ready_since >= state.settings.restart_backoff_reset_after,
        do: 0,
        else: state.restart_attempt

    state = %{
      state
      | phase: :ready,
        node_pid: node_pid,
        failures: 0,
        ready_since: ready_since,
        restart_attempt: attempt
    }

    if recovering? do
      {:ok, _} =
        Registry.register(Frontman.registry(state.name), :worker, %{
          index: state.index,
          port: state.port,
          node_pid: node_pid
        })

      emit(state, :ready, %{}, %{})
      Logger.info("frontend worker #{state.index} ready on port #{state.port}")
    end

    publish(state)
    schedule_probe(state, state.settings.health_check_interval)
    state
  end

  defp probe_result(:not_ready, %{phase: :starting} = state) do
    if now() >= state.deadline do
      recover(state, :startup_timeout)
    else
      schedule_probe(state, 50)
      state
    end
  end

  defp probe_result(:not_ready, state) do
    state = %{withdraw(state) | phase: :suspect, failures: state.failures + 1, ready_since: nil}
    emit(state, :unhealthy, %{failures: state.failures}, %{})
    publish(state)

    if state.failures >= state.settings.health_check_failures do
      recover(state, :health_check_failed)
    else
      schedule_probe(state, state.settings.health_check_interval)
      state
    end
  end

  defp recover(state, reason) do
    state = %{withdraw(state) | phase: :stopping, reason: reason}

    task =
      Task.Supervisor.async_nolink(Frontman.tasks(state.name), fn ->
        stop_daemon(state.daemon)
      end)

    state = %{state | shutdown_task: task}
    publish(state)
    state
  end

  defp backoff(state, reason) do
    attempt = state.restart_attempt + 1

    ceiling =
      min(
        state.settings.restart_backoff_max,
        state.settings.restart_backoff_min * Integer.pow(2, min(attempt - 1, 30))
      )

    floor = div(ceiling, 2)
    delay = floor + :rand.uniform(ceiling - floor)

    state = %{
      state
      | phase: :backoff,
        restart_attempt: attempt,
        next_delay: delay,
        reason: reason
    }

    emit(state, :restart, %{delay: delay, ceiling: ceiling}, %{reason: reason, attempt: attempt})
    publish(state)
    Process.send_after(self(), :start, delay)
    state
  end

  defp probe(state) do
    request = Finch.build(:get, "http://127.0.0.1:#{state.port}/__frontend/ready")
    timeout = state.settings.health_check_timeout

    with {:ok, %Finch.Response{status: 200, body: body}} <-
           Finch.request(request, Frontman.health_finch(state.name),
             pool_timeout: timeout,
             receive_timeout: timeout
           ),
         {:ok, %{"token" => token, "pid" => pid}}
         when token == state.token and is_integer(pid) and pid > 0 <- Jason.decode(body) do
      {:ok, pid}
    else
      _ -> :not_ready
    end
  end

  defp cancel_probe(%{probe: nil} = state), do: state

  defp cancel_probe(%{probe: {task, timer}} = state) do
    Process.cancel_timer(timer)
    Task.shutdown(task, :brutal_kill)
    %{state | probe: nil}
  end

  defp withdraw(state) do
    Registry.unregister(Frontman.registry(state.name), :worker)
    state
  end

  defp stop_daemon(daemon), do: Frontman.Process.stop(daemon)

  defp cleanup_failed(state, reason) do
    # Do not create another OS process if cleanup could not establish that the old one left.
    state = %{state | phase: :cleanup_failed, shutdown_task: nil, reason: reason}
    emit(state, :cleanup_failed, %{}, %{reason: reason})
    publish(state)
    state
  end

  defp publish(state),
    do:
      Registry.update_value(Frontman.states(state.name), state.index, fn _ ->
        info(state)
      end)

  defp info(state),
    do:
      Map.take(state, [:index, :phase, :port, :node_pid, :restart_attempt, :failures, :next_delay])

  defp emit(state, event, measurements, metadata),
    do:
      :telemetry.execute(
        [:frontman, :worker, event],
        measurements,
        Map.merge(%{name: state.name, index: state.index}, metadata)
      )

  defp schedule_probe(state, delay),
    do: Process.send_after(self(), {:probe, state.generation}, delay)

  defp now, do: System.monotonic_time(:millisecond)

  defp daemon_options(state) do
    [
      cd: state.opts[:directory],
      env:
        Keyword.get(state.opts, :env, []) ++
          [
            {"HOST", "127.0.0.1"},
            {"PORT", Integer.to_string(state.port)},
            {"FRONTEND_WORKER_TOKEN", state.token},
            {"SERVER_SHUTDOWN_TIMEOUT", "4"}
          ],
      log_output: :info,
      log_prefix: "frontend[#{state.index}] ",
      stderr_to_stdout: true,
      delay_to_sigkill: 6_000
    ]
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
