defmodule TranscriptorBot.Transcriber do
  @moduledoc """
  Runs the external transcriber as a fresh OS process for every job.

  The process writes plain text to stdout. A timeout is computed from the media
  duration so long recordings get enough time without hanging forever.
  """

  @default_min_timeout 15 * 60 * 1000
  @default_max_timeout 2 * 60 * 60 * 1000

  @type runner ::
          (String.t(), [String.t()], pos_integer() ->
             {:ok, String.t()} | {:error, {:exit, non_neg_integer()}} | {:error, :timeout})

  @doc """
  Adaptive timeout: at least fifteen minutes, twice the media duration, capped
  at two hours.
  """
  @spec timeout_for(non_neg_integer(), keyword()) :: pos_integer()
  def timeout_for(duration_ms, opts \\ []) do
    min_timeout =
      Keyword.get(opts, :min_timeout, config(:min_transcriber_timeout_ms, @default_min_timeout))

    max_timeout =
      Keyword.get(opts, :max_timeout, config(:max_transcriber_timeout_ms, @default_max_timeout))

    duration_ms
    |> Kernel.*(2)
    |> max(min_timeout)
    |> min(max_timeout)
  end

  @spec transcribe(Path.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()}
          | {:error, :not_configured | :command_not_found | :timeout | {:exit, non_neg_integer()}}
  def transcribe(pcm_path, duration_ms, opts \\ []) do
    command = fetch_opt(opts, :command, :transcriber_command)
    args = fetch_opt(opts, :args, :transcriber_args) || []
    term_grace_ms = Keyword.get(opts, :term_grace_ms, 1_000)

    runner =
      Keyword.get(opts, :runner, fn cmd, argv, timeout ->
        run_port(cmd, argv, timeout, term_grace_ms)
      end)

    if is_nil(command) or command == "" do
      {:error, :not_configured}
    else
      timeout = timeout_for(duration_ms, opts)

      case runner.(command, args ++ [pcm_path], timeout) do
        {:ok, output} -> {:ok, String.trim(output)}
        {:error, _} = error -> error
      end
    end
  end

  defp fetch_opt(opts, key, config_key) do
    if Keyword.has_key?(opts, key) do
      Keyword.get(opts, key)
    else
      Application.get_env(:transcriptor_bot, config_key)
    end
  end

  defp config(key, default), do: Application.get_env(:transcriptor_bot, key, default)

  defp run_port(command, args, timeout_ms, term_grace_ms) do
    case System.find_executable(command) do
      nil ->
        {:error, :command_not_found}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            args: args
          ])

        timer = Process.send_after(self(), {:transcriber_timeout, port}, timeout_ms)
        collect(port, "", timer, term_grace_ms)
    end
  end

  defp collect(port, acc, timer, term_grace_ms) do
    receive do
      {^port, {:data, data}} ->
        collect(port, acc <> data, timer, term_grace_ms)

      {^port, {:exit_status, 0}} ->
        Process.cancel_timer(timer)
        {:ok, acc}

      {^port, {:exit_status, status}} ->
        Process.cancel_timer(timer)
        {:error, {:exit, status}}

      {:transcriber_timeout, ^port} ->
        terminate_port_process(port, term_grace_ms)
        close_port(port)
        {:error, :timeout}
    end
  end

  defp terminate_port_process(port, grace_ms) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        signal(pid, "TERM")

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          grace_ms ->
            signal(pid, "KILL")

            receive do
              {^port, {:exit_status, _}} -> :ok
            after
              1_000 -> :ok
            end
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp signal(pid, signal) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
