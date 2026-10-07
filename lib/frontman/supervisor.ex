defmodule Frontman.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    unless is_atom(name), do: raise(ArgumentError, "name must be an atom")

    children = [
      {Registry, keys: :duplicate, name: Frontman.registry(name)},
      {Registry, keys: :unique, name: Frontman.states(name)},
      {Finch, name: Frontman.finch(name), pools: %{default: [size: 64]}},
      {Finch, name: Frontman.health_finch(name), pools: %{default: [size: 1]}},
      {Task.Supervisor, name: Frontman.tasks(name)},
      {Frontman.Admission, opts},
      workers(opts)
    ]

    # Rebuild workers if their registry or HTTP client is lost. Individual worker crashes
    # remain isolated inside PoolSupervisor.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  # With `port`, the server runs outside Frontman and only its address is registered.
  defp workers(opts) do
    case Keyword.fetch(opts, :port) do
      {:ok, port} ->
        unless is_integer(port) and port in 1..65_535,
          do: raise(ArgumentError, "port must be an integer from 1 to 65535")

        for key <- [:executable, :args, :directory, :workers], Keyword.has_key?(opts, key) do
          raise ArgumentError, "#{key} can't be combined with port"
        end

        {Frontman.External, opts}

      :error ->
        count = Keyword.get(opts, :workers, 1)

        unless is_integer(count) and count > 0,
          do: raise(ArgumentError, "workers must be a positive integer")

        for key <- [:executable, :args, :directory], do: Keyword.fetch!(opts, key)
        {Frontman.PoolSupervisor, Keyword.put(opts, :workers, count)}
    end
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
