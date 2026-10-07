defmodule Frontman.External do
  @moduledoc false
  # Stands in for the worker pool when the frontend server runs outside Frontman, such as a
  # Vite dev server. It registers that server as one ready worker and never starts, probes or
  # restarts it. A request to a server that isn't listening fails as it would on a dead worker.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    worker = %{index: 1, port: Keyword.fetch!(opts, :port), node_pid: nil}

    slot =
      Map.merge(worker, %{phase: :external, failures: 0, restart_attempt: 0, next_delay: nil})

    {:ok, _} = Registry.register(Frontman.states(name), worker.index, slot)
    {:ok, _} = Registry.register(Frontman.registry(name), :worker, worker)
    {:ok, nil}
  end
end
