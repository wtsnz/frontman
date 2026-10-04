defmodule Frontman.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    count = Keyword.get(opts, :workers, 1)

    unless is_atom(name) and is_integer(count) and count > 0 do
      raise ArgumentError, "name must be an atom and workers must be a positive integer"
    end

    for key <- [:executable, :args, :directory], do: Keyword.fetch!(opts, key)

    children = [
      {Registry, keys: :duplicate, name: Frontman.registry(name)},
      {Registry, keys: :unique, name: Frontman.states(name)},
      {Finch, name: Frontman.finch(name), pools: %{default: [size: 64]}},
      {Finch, name: Frontman.health_finch(name), pools: %{default: [size: 1]}},
      {Task.Supervisor, name: Frontman.tasks(name)},
      {Frontman.Admission, opts},
      {Frontman.PoolSupervisor, Keyword.put(opts, :workers, count)}
    ]

    # Rebuild workers if their registry or HTTP client is lost. Individual worker crashes
    # remain isolated inside PoolSupervisor.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule Frontman.PoolSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    count = Keyword.fetch!(opts, :workers)

    children =
      for index <- 1..count, do: {Frontman.Worker, Keyword.put(opts, :index, index)}

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5 * count, max_seconds: 10)
  end
end
