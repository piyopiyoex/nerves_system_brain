defmodule HelloKioskBrain.CameraMonitor do
  @moduledoc """
  Brain-side network camera monitor controller.

  The BEAM owns control flow and networking while the external `camera_viewer`
  Port owns JPEG decode, RGB565 conversion, and framebuffer writes.

  One frame is kept in flight at a time:

      HTTP snapshot -> Port.command/2 -> renderer ACK -> next snapshot

  This is deliberate backpressure. If JPEG decode is slow on the ARM926EJ-S,
  frames do not accumulate and camera latency does not grow without bound.
  """

  use GenServer
  require Logger

  @default_interval_ms 500
  @default_retry_ms 1_000
  @default_request_timeout_ms 4_000
  @default_stop_timeout_ms 1_000
  @default_max_jpeg_bytes 2 * 1024 * 1024
  @default_scale 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Enable snapshot fetching and camera rendering."
  def enable, do: GenServer.call(__MODULE__, :enable)

  @doc "Disable camera rendering after the renderer has released the framebuffer."
  def disable, do: GenServer.call(__MODULE__, :disable)

  @doc "Return camera state and the latest timing counters."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Update the snapshot URL used by subsequent fetches."
  def set_snapshot_url(url) when is_binary(url),
    do: GenServer.call(__MODULE__, {:set_snapshot_url, String.trim(url)})

  @doc false
  def validate_snapshot_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host} when is_binary(host) and host != "" -> :ok
      %URI{scheme: "https"} -> {:error, :https_not_supported}
      _ -> {:error, :invalid_camera_url}
    end
  end

  @doc false
  def decode_ack(
        <<0, input_width::unsigned-big-16, input_height::unsigned-big-16,
          output_width::unsigned-big-16, output_height::unsigned-big-16,
          decode_us::unsigned-big-32, write_us::unsigned-big-32>>
      ) do
    {:ok,
     %{
       input_width: input_width,
       input_height: input_height,
       output_width: output_width,
       output_height: output_height,
       decode_ms: decode_us / 1_000,
       framebuffer_ms: write_us / 1_000
     }}
  end

  def decode_ack(<<1, code::unsigned-big-16, message::binary>>) do
    {:error, {:renderer, code, message}}
  end

  def decode_ack(other) when is_binary(other),
    do: {:error, {:invalid_renderer_ack, byte_size(other)}}

  def decode_ack(_other), do: {:error, {:invalid_renderer_ack, :not_binary}}

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:enable, _from, %{enabled: true} = state), do: {:reply, :ok, state}

  def handle_call(:enable, _from, %{state: :stopping} = state) do
    {:reply, {:error, :camera_stopping}, state}
  end

  def handle_call(:enable, _from, %{snapshot_url: nil} = state) do
    {:reply, {:error, :camera_not_configured}, state}
  end

  def handle_call(:enable, _from, state) do
    state =
      state
      |> cancel_timer()
      |> close_port()
      |> reset_session()
      |> Map.put(:enabled, true)
      |> Map.update!(:generation, &(&1 + 1))
      |> start_or_retry_viewer()

    {:reply, :ok, state}
  end

  def handle_call(:disable, from, %{state: :stopping} = state) do
    {:noreply, %{state | disable_waiters: [from | state.disable_waiters]}}
  end

  def handle_call(:disable, from, %{port: port} = state) when is_port(port) do
    state =
      state
      |> cancel_timer()
      |> Map.put(:enabled, false)
      |> Map.put(:state, :stopping)
      |> Map.put(:fetching, false)
      |> Map.put(:cycle_started_ms, nil)
      |> Map.update!(:generation, &(&1 + 1))

    if send_stop(port) do
      timer = Process.send_after(self(), {:stop_timeout, port}, state.stop_timeout_ms)
      {:noreply, %{state | stop_timer: timer, disable_waiters: [from]}}
    else
      {:reply, {:error, :renderer_stop_failed}, state |> close_port() |> disable_without_port()}
    end
  end

  def handle_call(:disable, _from, state), do: {:reply, :ok, disable_without_port(state)}

  def handle_call(:status, _from, state) do
    {:reply,
     Map.take(state, [
       :enabled,
       :state,
       :snapshot_url,
       :interval_ms,
       :frames_received,
       :frames_rendered,
       :failures,
       :download_ms,
       :decode_ms,
       :framebuffer_ms,
       :last_frame_at_ms,
       :last_error
     ]), state}
  end

  def handle_call({:set_snapshot_url, url}, _from, state) do
    case validate_snapshot_url(url) do
      :ok -> {:reply, :ok, %{state | snapshot_url: url}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:fetch, generation},
        %{enabled: true, generation: generation, port: port} = state
      )
      when is_port(port) do
    if state.fetching do
      {:noreply, state}
    else
      parent = self()
      url = state.snapshot_url
      timeout_ms = state.request_timeout_ms
      max_jpeg_bytes = state.max_jpeg_bytes
      started_ms = monotonic_ms()

      {:ok, _task} =
        Task.start(fn ->
          started_us = monotonic_us()
          result = fetch_snapshot(url, timeout_ms, max_jpeg_bytes)
          download_us = monotonic_us() - started_us
          send(parent, {:snapshot_result, generation, result, download_us})
        end)

      {:noreply,
       %{state | timer: nil, fetching: true, state: :connecting, cycle_started_ms: started_ms}}
    end
  end

  def handle_info({:fetch, _generation}, state), do: {:noreply, %{state | timer: nil}}

  def handle_info(
        {:snapshot_result, generation, {:ok, jpeg}, download_us},
        %{enabled: true, generation: generation, port: port} = state
      )
      when is_port(port) do
    case send_frame(port, jpeg) do
      :ok ->
        {:noreply,
         %{
           state
           | fetching: false,
             state: :rendering,
             frames_received: state.frames_received + 1,
             download_ms: download_us / 1_000,
             last_error: nil
         }}

      {:error, reason} ->
        {:noreply, renderer_failed(state, reason)}
    end
  end

  def handle_info(
        {:snapshot_result, generation, {:error, reason}, download_us},
        %{enabled: true, generation: generation} = state
      ) do
    state = %{
      state
      | fetching: false,
        state: :retrying,
        cycle_started_ms: nil,
        failures: state.failures + 1,
        download_ms: download_us / 1_000,
        last_error: reason
    }

    Logger.warning("CameraMonitor: snapshot failed: #{inspect(reason)}")
    {:noreply, schedule(state, :fetch, state.retry_ms)}
  end

  def handle_info({:snapshot_result, _generation, _result, _download_us}, state) do
    {:noreply, state}
  end

  def handle_info({port, {:data, ack}}, %{enabled: true, port: port} = state)
      when is_port(port) do
    case decode_ack(ack) do
      {:ok, metrics} ->
        state =
          state
          |> Map.put(:state, :streaming)
          |> Map.put(:frames_rendered, state.frames_rendered + 1)
          |> Map.put(:decode_ms, metrics.decode_ms)
          |> Map.put(:framebuffer_ms, metrics.framebuffer_ms)
          |> Map.put(:last_frame_at_ms, System.system_time(:millisecond))
          |> Map.put(:last_error, nil)
          |> schedule_next_frame()

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("CameraMonitor: renderer rejected frame: #{inspect(reason)}")

        state = %{
          state
          | state: :retrying,
            cycle_started_ms: nil,
            failures: state.failures + 1,
            last_error: reason
        }

        {:noreply, schedule(state, :fetch, state.retry_ms)}
    end
  end

  def handle_info({port, {:data, _ack}}, %{state: :stopping, port: port} = state) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) when is_port(port) do
    state =
      state
      |> cancel_stop_timer()
      |> Map.put(:port, nil)
      |> Map.put(:fetching, false)
      |> Map.put(:cycle_started_ms, nil)

    cond do
      state.state == :stopping ->
        reply = if status == 0, do: :ok, else: {:error, {:renderer_exit, status}}
        {:noreply, finish_disable(state, reply)}

      state.enabled ->
        reason = {:renderer_exit, status}
        Logger.warning("CameraMonitor: camera_viewer exited: #{status}")

        state = %{
          state
          | state: :retrying,
            failures: state.failures + 1,
            last_error: reason
        }

        {:noreply, schedule(state, :restart_viewer, state.retry_ms)}

      true ->
        {:noreply, %{state | state: :idle}}
    end
  end

  def handle_info({:stop_timeout, port}, %{state: :stopping, port: port} = state) do
    Logger.warning("CameraMonitor: camera_viewer stop timed out")
    state = state |> Map.put(:stop_timer, nil) |> close_port()
    {:noreply, finish_disable(state, {:error, :renderer_stop_timeout})}
  end

  def handle_info({:stop_timeout, _port}, state), do: {:noreply, state}

  def handle_info({:restart_viewer, generation}, %{enabled: true, generation: generation} = state) do
    {:noreply, state |> Map.put(:timer, nil) |> start_or_retry_viewer()}
  end

  def handle_info({:restart_viewer, _generation}, state), do: {:noreply, %{state | timer: nil}}

  def handle_info(message, state) do
    Logger.debug("CameraMonitor: ignoring #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state |> cancel_timer() |> close_port()
    :ok
  end

  defp initial_state do
    config = Application.get_env(:hello_kiosk_brain, :camera_monitor, [])

    %{
      enabled: false,
      state: :idle,
      snapshot_url: Keyword.get(config, :snapshot_url),
      interval_ms: Keyword.get(config, :interval_ms, @default_interval_ms),
      retry_ms: Keyword.get(config, :retry_ms, @default_retry_ms),
      request_timeout_ms: Keyword.get(config, :request_timeout_ms, @default_request_timeout_ms),
      stop_timeout_ms: Keyword.get(config, :stop_timeout_ms, @default_stop_timeout_ms),
      max_jpeg_bytes: Keyword.get(config, :max_jpeg_bytes, @default_max_jpeg_bytes),
      scale: Keyword.get(config, :scale, @default_scale),
      viewer_path: Keyword.get(config, :viewer_path),
      viewer_output: Keyword.get(config, :viewer_output),
      viewer_dry_run: Keyword.get(config, :viewer_dry_run, false),
      generation: 0,
      port: nil,
      timer: nil,
      stop_timer: nil,
      disable_waiters: [],
      fetching: false,
      cycle_started_ms: nil,
      frames_received: 0,
      frames_rendered: 0,
      failures: 0,
      download_ms: nil,
      decode_ms: nil,
      framebuffer_ms: nil,
      last_frame_at_ms: nil,
      last_error: nil
    }
  end

  defp reset_session(state) do
    %{
      state
      | state: :starting,
        fetching: false,
        cycle_started_ms: nil,
        frames_received: 0,
        frames_rendered: 0,
        failures: 0,
        download_ms: nil,
        decode_ms: nil,
        framebuffer_ms: nil,
        last_frame_at_ms: nil,
        last_error: nil
    }
  end

  defp start_or_retry_viewer(state) do
    case open_viewer(state) do
      {:ok, port} ->
        state
        |> Map.put(:port, port)
        |> Map.put(:state, :starting)
        |> Map.put(:last_error, nil)
        |> schedule(:fetch, 0)

      {:error, reason} ->
        Logger.warning("CameraMonitor: camera_viewer start failed: #{inspect(reason)}")

        state
        |> Map.put(:port, nil)
        |> Map.put(:state, :retrying)
        |> Map.put(:last_error, reason)
        |> Map.update!(:failures, &(&1 + 1))
        |> schedule(:restart_viewer, state.retry_ms)
    end
  end

  defp open_viewer(state) do
    path = state.viewer_path || default_viewer_path()

    if File.regular?(path) do
      args =
        [
          "--port",
          "--scale",
          Integer.to_string(state.scale),
          "--max-jpeg-bytes",
          Integer.to_string(state.max_jpeg_bytes)
        ]
        |> maybe_add_output(state.viewer_output)
        |> maybe_add_dry_run(state.viewer_dry_run)
        |> Enum.map(&String.to_charlist/1)

      try do
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(path)},
            [:binary, :exit_status, {:packet, 4}, {:args, args}]
          )

        {:ok, port}
      rescue
        error -> {:error, {:port_open, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:port_open, kind, reason}}
      end
    else
      {:error, {:viewer_not_found, path}}
    end
  end

  defp maybe_add_output(args, nil), do: args
  defp maybe_add_output(args, output), do: args ++ ["--output", output]

  defp maybe_add_dry_run(args, true), do: args ++ ["--dry-run"]
  defp maybe_add_dry_run(args, false), do: args

  defp default_viewer_path do
    :hello_kiosk_brain
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("bin/camera_viewer")
  end

  defp fetch_snapshot(url, timeout_ms, max_jpeg_bytes) do
    request = {String.to_charlist(url), []}
    # OTP 29's :httpc builds default SSL verification options even for http://
    # requests. On this target there are no OS CA certs, so set an explicit SSL
    # policy to avoid an unrelated public_key CA lookup failure.
    http_options = [timeout: timeout_ms, connect_timeout: timeout_ms, ssl: [verify: :verify_none]]
    options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_version, 200, _reason}, _headers, body}} when is_binary(body) ->
        validate_jpeg(body, max_jpeg_bytes)

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http, reason}}
    end
  rescue
    error -> {:error, {:http_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:http_exception, kind, reason}}
  end

  defp validate_jpeg(<<>>, _max_jpeg_bytes), do: {:error, :empty_jpeg}

  defp validate_jpeg(body, max_jpeg_bytes) when byte_size(body) > max_jpeg_bytes,
    do: {:error, {:jpeg_too_large, byte_size(body), max_jpeg_bytes}}

  defp validate_jpeg(<<0xFF, 0xD8, _rest::binary>> = body, _max_jpeg_bytes), do: {:ok, body}
  defp validate_jpeg(_body, _max_jpeg_bytes), do: {:error, :not_jpeg}

  defp send_frame(port, jpeg) do
    try do
      if Port.command(port, jpeg), do: :ok, else: {:error, :port_command_failed}
    rescue
      error -> {:error, {:port_command, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:port_command, kind, reason}}
    end
  end

  defp send_stop(port) do
    try do
      Port.command(port, <<>>)
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp renderer_failed(state, reason) do
    Logger.warning("CameraMonitor: renderer failed: #{inspect(reason)}")

    state
    |> close_port()
    |> Map.put(:fetching, false)
    |> Map.put(:cycle_started_ms, nil)
    |> Map.put(:state, :retrying)
    |> Map.put(:last_error, reason)
    |> Map.update!(:failures, &(&1 + 1))
    |> schedule(:restart_viewer, state.retry_ms)
  end

  defp schedule_next_frame(state) do
    elapsed_ms =
      case state.cycle_started_ms do
        nil -> state.interval_ms
        started -> max(monotonic_ms() - started, 0)
      end

    delay_ms = max(state.interval_ms - elapsed_ms, 0)

    state
    |> Map.put(:cycle_started_ms, nil)
    |> schedule(:fetch, delay_ms)
  end

  defp schedule(state, kind, delay_ms) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), {kind, state.generation}, max(delay_ms, 0))
    %{state | timer: ref}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp cancel_stop_timer(%{stop_timer: nil} = state), do: state

  defp cancel_stop_timer(state) do
    Process.cancel_timer(state.stop_timer)
    %{state | stop_timer: nil}
  end

  defp disable_without_port(state) do
    state
    |> cancel_timer()
    |> cancel_stop_timer()
    |> Map.put(:enabled, false)
    |> Map.put(:state, :idle)
    |> Map.put(:fetching, false)
    |> Map.put(:cycle_started_ms, nil)
    |> Map.update!(:generation, &(&1 + 1))
  end

  defp finish_disable(state, reply) do
    Enum.each(state.disable_waiters, &GenServer.reply(&1, reply))
    %{state | state: :idle, disable_waiters: [], stop_timer: nil}
  end

  defp close_port(%{port: port} = state) when is_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    %{state | port: nil}
  end

  defp close_port(state), do: state

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp monotonic_us, do: System.monotonic_time(:microsecond)
end
