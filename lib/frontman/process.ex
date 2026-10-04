defmodule Frontman.Process do
  @moduledoc false

  # Keep the wrapper alive until its direct child has exited. A SIGSTOP'd child can leave
  # MuonTrap waiting on SIGCHLD; merely closing the BEAM port does not prove OS cleanup.
  # This handles the owned direct child, not containment of arbitrary descendants.
  def stop(nil), do: :ok

  def stop(daemon) do
    case MuonTrap.Daemon.os_pid(daemon) do
      wrapper when is_integer(wrapper) ->
        with :ok <- stop_children(wrapper) do
          GenServer.stop(daemon, :shutdown, 500)
        end

      :error ->
        GenServer.stop(daemon, :shutdown, 500)
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  defp stop_children(wrapper) do
    {listing, 0} = System.cmd("ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true)

    children =
      for line <- String.split(listing, "\n", trim: true),
          [pid, parent] = String.split(line),
          parent == to_string(wrapper),
          do: String.to_integer(pid)

    Enum.reduce_while(children, :ok, fn child, :ok ->
      case stop_child(wrapper, child) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp stop_child(wrapper, child) do
    with :ok <- signal_owned(wrapper, child, "TERM"),
         :ok <- signal_owned(wrapper, child, "CONT") do
      case wait_for_exit(wrapper, child, now() + 6_000) do
        {:error, :timeout} ->
          with :ok <- signal_owned(wrapper, child, "KILL"),
               do: wait_for_exit(wrapper, child, now() + 1_000)

        result ->
          result
      end
    end
  end

  defp signal_owned(wrapper, child, signal) do
    case ownership(wrapper, child) do
      :gone ->
        :ok

      :owned ->
        System.cmd("kill", ["-" <> signal, to_string(child)], stderr_to_stdout: true)
        :ok

      :unknown ->
        {:error, :lost_process_ownership}
    end
  end

  defp wait_for_exit(wrapper, child, deadline) do
    case ownership(wrapper, child) do
      :gone ->
        :ok

      :unknown ->
        {:error, :lost_process_ownership}

      :owned ->
        if now() >= deadline do
          {:error, :timeout}
        else
          Process.sleep(25)
          wait_for_exit(wrapper, child, deadline)
        end
    end
  end

  defp ownership(wrapper, child) do
    case System.cmd("ps", ["-p", to_string(child), "-o", "ppid="], stderr_to_stdout: true) do
      {"", 1} -> :gone
      {parent, 0} -> if String.trim(parent) == to_string(wrapper), do: :owned, else: :unknown
      _ -> :unknown
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
