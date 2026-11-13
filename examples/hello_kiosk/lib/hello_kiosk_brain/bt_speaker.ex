defmodule HelloKioskBrain.BtSpeaker do
  @moduledoc """
  Bluetooth スピーカー(A2DP シンク)への接続管理。BlueZ(bluetoothd)+ BlueALSA を使う「案B」
  (docs/20260911_ブルートゥーススピーカー_接続提案書.md)。

  * 設定ファイル `/root/bt_speaker.conf`(機体ごと。`MAC=AA:BB:..` 必須、`NAME=表示名` 任意)が
    **あるときだけ**動く。無ければ何もしない(BT ドングルは SwitchBot BLE スキャナが使う)。
    デーモン群(dbus-daemon / bluetoothd / bluealsa)は erlinit の `enable_net` → `enable_bt_speaker`
    が起動済み。本モジュールは `bluetoothctl` を非対話で叩いて **ペアリング → trust → connect** を
    面倒見て、`bluealsa-cli list-pcms` で **再生可能(A2DP PCM が出現)** を判定する。
  * 状態: `:off`(未設定)/ `:no_stack`(デーモン未起動・hci0 なし)/ `:unpaired` / `:disconnected` /
    `:connected`(PCM あり=再生可)。`ready?/0` が true のとき `Audio` は aplay(bluealsa)へ出力する。
  * スピーカーの電源 OFF→ON 時は bluetoothd の自動再接続(trusted)に加え、本モジュールが
    @poll_ms ごとに `connect` を試みる。
  """
  use GenServer
  require Logger

  @conf "/root/bt_speaker.conf"
  @bluetoothctl "/usr/bin/bluetoothctl"
  @bluealsa_cli "/usr/bin/bluealsa-cli"
  @poll_ms 10_000
  @connect_interval_s 20
  @pair_interval_s 60
  @scan_s 8

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "設定ファイルがあるか(=この機体は BT スピーカー出力モード)。"
  def configured?, do: File.exists?(@conf)

  @doc "設定(%{mac: .., name: ..})。未設定なら nil。"
  def config do
    case File.read(@conf) do
      {:ok, txt} ->
        kv =
          for line <- String.split(txt, "\n"),
              [k, v] <- [String.split(line, "=", parts: 2)],
              into: %{},
              do: {String.trim(k), String.trim(v)}

        case kv do
          %{"MAC" => mac} when byte_size(mac) == 17 -> %{mac: String.upcase(mac), name: Map.get(kv, "NAME", mac)}
          # MAC 未記入・NAME のみ: スキャンで名前一致のデバイスを探し、見つけたら MAC を書き足す(§discover)
          %{"NAME" => name} when name != "" -> %{mac: nil, name: name}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  現在の状態(上記 @moduledoc)。GenServer には問い合わせず persistent_term から読む
  (GenServer は bluetoothctl/bluealsa-cli を同期実行して数秒〜数十秒塞がることがあり、Audio の
  再生判定(毎回呼ばれる)を巻き込まないため)。
  """
  def status, do: :persistent_term.get({__MODULE__, :status}, :off)

  @doc "A2DP PCM が使える(=aplay で鳴らせる)か。"
  def ready?, do: status() == :connected

  @doc "画面用の出力名(\"BT: ZoeeTree S1+\")。未接続なら nil。"
  def output_label do
    case {ready?(), config()} do
      {true, %{name: n}} -> "BT: " <> n
      _ -> nil
    end
  end

  @doc "aplay 用の ALSA デバイス名。"
  def alsa_device do
    case config() do
      %{mac: mac} when is_binary(mac) -> "bluealsa:DEV=#{mac},PROFILE=a2dp"
      _ -> nil
    end
  end

  @doc """
  周囲の BT デバイスをスキャンして [{mac, name}] を返す(#{@scan_s} 秒)。MAC 不明のスピーカー探しに使う:
  `HelloKioskBrain.BtSpeaker.discover()` → 該当 MAC を `/root/bt_speaker.conf` に書く。
  """
  def discover(scan_s \\ @scan_s) do
    ctl(["--timeout", Integer.to_string(scan_s), "scan", "on"], (scan_s + 5) * 1000)

    ctl(["devices"])
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/Device ([0-9A-F:]{17}) (.*)$/, String.trim(line)) do
        [_, mac, name] -> [{mac, name}]
        _ -> []
      end
    end)
  end

  @doc "手動ペアリング(スキャン #{@scan_s}s → pair → trust → connect)。結果はログと状態に出る。"
  def pair_now, do: GenServer.cast(__MODULE__, :pair)

  @doc "手動接続。"
  def connect_now, do: GenServer.cast(__MODULE__, :connect)

  # --- GenServer ---

  @impl true
  def init(_) do
    state = %{status: :off, last_connect: 0, last_pair: 0}

    if configured?() do
      Process.send_after(self(), :poll, 5_000)
    end

    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast(:pair, state), do: {:noreply, publish(do_pair(state))}
  def handle_cast(:connect, state), do: {:noreply, publish(do_connect(state))}

  @impl true
  def handle_info(:poll, state) do
    state = publish(refresh(state))
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  # 状態を persistent_term に反映(status/0 用)。変化時だけ書く(persistent_term の更新は GC を伴うため)。
  defp publish(state) do
    if :persistent_term.get({__MODULE__, :status}, :off) != state.status do
      :persistent_term.put({__MODULE__, :status}, state.status)
    end

    state
  end

  def handle_info(_, state), do: {:noreply, state}

  # 状態を観測し、必要なら pair / connect を(間隔を空けて)試みる
  defp refresh(state) do
    now = System.os_time(:second)

    case config() do
      nil ->
        %{state | status: :off}

      %{mac: nil, name: name} ->
        # NAME だけ設定された機体: スタックが上がっていればスキャンして名前一致の MAC を探し、設定に書き足す
        if stack_up?() and now - state.last_pair >= @pair_interval_s do
          found = discover() |> Enum.find(fn {_m, n} -> String.contains?(String.downcase(n), String.downcase(name)) end)

          case found do
            {mac, n} ->
              Logger.info("BtSpeaker: discovered #{n} at #{mac}; saving to #{@conf}")
              File.write!(@conf, "MAC=#{mac}\nNAME=#{n}\n")
              refresh(%{state | last_pair: now})

            nil ->
              Logger.info("BtSpeaker: '#{name}' not found in scan (speaker in pairing mode?)")
              %{state | status: :unpaired, last_pair: now}
          end
        else
          %{state | status: if(stack_up?(), do: :unpaired, else: :no_stack)}
        end

      %{mac: mac} ->
        cond do
          not stack_up?() ->
            %{state | status: :no_stack}

          pcm_present?(mac) ->
            %{state | status: :connected}

          true ->
            info = ctl(["info", mac])

            cond do
              not String.contains?(info, "Paired: yes") ->
                st = %{state | status: :unpaired}
                if now - state.last_pair >= @pair_interval_s, do: do_pair(st), else: st

              now - state.last_connect >= @connect_interval_s ->
                do_connect(%{state | status: :disconnected})

              true ->
                %{state | status: :disconnected}
            end
        end
    end
  end

  defp do_pair(state) do
    case config() do
      %{mac: mac, name: name} when is_binary(mac) ->
        Logger.info("BtSpeaker: pairing #{name} (#{mac}) — scan #{@scan_s}s")
        ctl(["--timeout", Integer.to_string(@scan_s), "scan", "on"], (@scan_s + 5) * 1000)
        ctl(["trust", mac])
        out = ctl(["pair", mac], 30_000)
        Logger.info("BtSpeaker: pair => #{String.slice(out, -160, 160) |> String.trim()}")
        ctl(["trust", mac])
        do_connect(%{state | last_pair: System.os_time(:second)})

      _ ->
        state
    end
  end

  defp do_connect(state) do
    case config() do
      %{mac: mac} when is_binary(mac) ->
        out = ctl(["connect", mac], 20_000)
        ok? = String.contains?(out, "Connection successful")
        Logger.info("BtSpeaker: connect #{mac} => #{if ok?, do: "ok", else: String.slice(out, -120, 120) |> String.trim()}")
        # PCM が立つまで少し待つ(A2DP の SEP 設定)
        if ok?, do: Process.sleep(1_500)
        %{state | last_connect: System.os_time(:second), status: if(pcm_present?(mac), do: :connected, else: :disconnected)}

      _ ->
        state
    end
  end

  # --- 観測ヘルパー ---

  defp stack_up? do
    File.exists?("/run/dbus/system_bus_socket") and File.exists?("/sys/class/bluetooth/hci0") and
      File.exists?(@bluetoothctl)
  end

  # bluealsa-cli list-pcms は接続済みデバイスの PCM パス(/org/bluealsa/hci0/dev_AA_BB_.../a2dpsrc/sink)を列挙する
  defp pcm_present?(mac) do
    dev = "dev_" <> String.replace(mac, ":", "_")

    case cmd(@bluealsa_cli, ["list-pcms"], 5_000) do
      {out, 0} -> String.contains?(out, dev) and String.contains?(out, "a2dp")
      _ -> false
    end
  end

  defp ctl(args, timeout \\ 10_000) do
    {out, _} = cmd(@bluetoothctl, args, timeout)
    out
  end

  # System.cmd にはタイムアウトが無いので Task 経由で打ち切る(bluetoothctl が固まっても Audio を巻き込まない)
  defp cmd(exe, args, timeout) do
    if File.exists?(exe) do
      task = Task.async(fn -> System.cmd(exe, args, stderr_to_stdout: true) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, res} -> res
        _ -> {"timeout", 124}
      end
    else
      {"missing #{exe}", 127}
    end
  end
end
