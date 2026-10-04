# Run with MIX_ENV=test mix run examples/admission.exs from this library's directory.
# Uses an isolated pool of two Node fixtures; no catalogue or database is involved.
Logger.configure(level: :warning)

defmodule AdmissionExample do
  def wait_until(fun, attempts \\ 100)
  def wait_until(_fun, 0), do: raise("demo condition timed out")

  def wait_until(fun, attempts) do
    unless fun.() do
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  def request(path) do
    Plug.Test.conn(:get, path)
    |> Frontman.Proxy.call(Frontman.Proxy.init(name: DemoPool))
  end
end

{:ok, _pid} =
  Frontman.start_link(
    name: DemoPool,
    workers: 2,
    max_concurrency: 1,
    executable: System.find_executable("node") || raise("Node must be on PATH"),
    args: ["server.mjs"],
    directory: Path.expand("../test/support", __DIR__),
    env: [{"APP_LABEL", "demo"}]
  )

try do
  AdmissionExample.wait_until(fn -> length(Frontman.workers(DemoPool)) == 2 end)
  requests = for _ <- 1..2, do: Task.async(fn -> AdmissionExample.request("/stream") end)
  AdmissionExample.wait_until(fn -> Frontman.status(DemoPool).in_flight == 2 end)
  IO.puts("Two slow streams occupy both slots.")
  IO.puts("Extra request: HTTP #{AdmissionExample.request("/").status} (capacity exhausted)")

  drain = Task.async(fn -> Frontman.drain(DemoPool, timeout: 2_000) end)
  AdmissionExample.wait_until(fn -> Frontman.status(DemoPool).mode == :draining end)
  IO.puts("Request during drain: HTTP #{AdmissionExample.request("/").status}")

  for task <- requests do
    response = Task.await(task)
    IO.puts("Existing stream finished: HTTP #{response.status}, #{inspect(response.resp_body)}")
  end

  IO.puts("Drain result: #{inspect(Task.await(drain))}")
  :ok = Frontman.resume(DemoPool)
  IO.puts("After resume: HTTP #{AdmissionExample.request("/").status}")
after
  Frontman.stop(DemoPool)
end
