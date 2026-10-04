defmodule Frontman do
  @moduledoc "Supervises HTTP frontend processes and manages request admission for named pools."

  @doc false
  def registry(name), do: Module.concat(name, Registry)
  @doc false
  def finch(name), do: Module.concat(name, Finch)

  @doc false
  def health_finch(name), do: Module.concat(name, HealthFinch)
  @doc false
  def tasks(name), do: Module.concat(name, Tasks)

  @doc false
  def states(name), do: Module.concat(name, States)

  @doc false
  def slots(name) do
    states(name)
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$3"]}])
    |> Enum.sort_by(& &1.index)
  rescue
    ArgumentError -> []
  end

  @doc "Starts an independently named worker pool. See the README for the worker protocol."
  def start_link(opts), do: Frontman.Supervisor.start_link(opts)

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def admission(name), do: Module.concat(name, Admission)

  @doc "Ready-registered workers, including in-flight counts and ready/draining state."
  def workers(name), do: call(admission(name), :workers, [])

  @doc "Pool admission state and capacity, or nil while unavailable."
  def status(name), do: call(admission(name), :status, nil)

  @doc "Reserves one request slot, owned by the calling process. No capacity queue is used."
  def checkout(name, excluded \\ []) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    call(admission(name), {:checkout, excluded, deadline}, {:error, :unavailable}, 1_500)
  end

  @doc "Releases a reservation; repeated release is harmless."
  def checkin(%{lease: {pid, ref}}), do: call(pid, {:checkin, ref}, :ok)

  @doc "Closes admission and waits for current requests. Timeout leaves admission closed."
  def drain(name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    unless is_integer(timeout) and timeout >= 0,
      do: raise(ArgumentError, "timeout must be nonnegative")

    call(admission(name), {:drain, timeout}, {:error, :unavailable}, timeout + 1_000)
  end

  @doc "Reopens admission after drain has completed or timed out."
  def resume(name), do: call(admission(name), :resume, {:error, :unavailable})

  @doc "Drains, then stops a directly started runtime, even when draining times out."
  def stop(name, opts \\ []) do
    # Pin the process so a replacement under the same name cannot be stopped accidentally.
    case Process.whereis(name) do
      nil ->
        {:error, :unavailable}

      pid ->
        result = drain(name, opts)
        Supervisor.stop(pid, :normal, :infinity)
        result
    end
  end

  @doc false
  def registered_workers(name) do
    registry(name)
    |> Registry.lookup(:worker)
    |> Enum.map(fn {pid, worker} -> Map.put(worker, :pid, pid) end)
    |> Enum.sort_by(& &1.index)
  rescue
    ArgumentError -> []
  end

  defp call(server, message, fallback, timeout \\ 5_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _reason -> fallback
  end
end
