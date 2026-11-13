defmodule HelloKioskBrain.Audio do
  @moduledoc """
  効果音・音声再生(直列キュー付き)。出力先は 2 系統:

  * **USB オーディオ(UAC)** … tinyalsa `tinyplay` を 1 音ごとに同期実行(従来どおり)。
    GeneralPlus 1b3f:2008 のような USB サウンドアダプタも USB オーディオ型 BT トランスミッタも
    同じ `snd-usb-audio` カードに見えるので、**どのカードに出すかを優先順リストで都度解決**する。
  * **BT スピーカー(BlueALSA / A2DP)** … `HelloKioskBrain.BtSpeaker` が接続済みのとき。
    A2DP はストリーム開始時にスピーカー側で **約 1 秒の無音(立ち上がり)** があり、1 音ごとに
    aplay を起動する方式では 70ms のタッチ音が丸ごと消える(実測: 0.5 秒間隔 8 連打で 6 回しか
    聞こえない)。そこで **`aplay` を常駐ポートとして開き、無音 PCM を流し続けてスピーカーを
    起こしたままにし、効果音はその流れに混ぜる**。書込は壁時計に合わせて @bt_tick_ms ごとに
    @bt_lead_ms 分だけ先行させる(出し過ぎると遅延、足りないとアンダーラン)。

  再生は本 GenServer の mailbox で**自然に直列化**される。混雑時は間引く(効果音は待ちがあれば
  捨てる、音声列は @max_pending 超で捨てる)。

  * `play/1`     … `priv/audio/<name>.wav` を 1 本再生(`"touch"`, `"alpha/K"` など)
  * `play_seq/1` … 複数 WAV と無音を **連結して 1 回で** 再生(時報 = h + m)。
    出力は常に S16_LE ステレオ。素材は全て 48kHz/16bit(モノ/ステレオ混在可)。

  優先順は `config :hello_kiosk_brain, audio_prefer: [...]`。各要素は `cardN/usbid`・`cardN/id`・
  `/proc/asound/cards` の長い名前に対する大小無視の部分一致。無ければ再生 PCM を持つ最初のカード。
  """
  use GenServer
  require Logger
  alias HelloKioskBrain.BtSpeaker

  @tinyplay "/usr/bin/tinyplay"
  # BT スピーカー(BlueALSA)経路: alsa-lib の aplay で bluealsa PCM プラグインへ出す(tinyalsa は ALSA プラグイン不可)
  @aplay "/usr/bin/aplay"
  @device "0"
  @default_prefer ["bluetooth", "1b3f:2008"]
  # 音声列(play_seq)の最大待ち件数。超えたら新規投入を捨てる。
  @max_pending 2
  @seq_path "/tmp/hkb_seq.wav"

  # BT 常駐ストリーム: 48kHz S16_LE ステレオ = 192 byte/ms
  @bt_rate 48_000
  @bt_bytes_per_ms div(@bt_rate * 2 * 2, 1000)
  @bt_tick_ms 80
  @bt_lead_ms 260
  # デモ画面(LovyanGFX NIF が CPU を占有し tick が遅れる)中は先行を増やしてアンダーランを防ぐ。
  # 遅延は増えるがデモ中はタッチ音を鳴らさない。ALSA バッファ(@bt_alsa_buffer_us)はこれを収める大きさ。
  @bt_lead_demo_ms 1_000
  @bt_alsa_buffer_us 1_300_000
  @bt_check_ms 2_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # --- 公開 API -----------------------------------------------------------------

  @doc "下部バーのボタン押下などのタッチ効果音。待ち行列があれば捨てる(連打で溜めない)。"
  def touch, do: enqueue({:play, "touch"}, 0)

  @doc "キー音(`priv/audio/key.wav`、タッチ音より高く短い)。キューが混んでいれば捨てる。"
  def key, do: enqueue({:play, "key"}, 0)

  @doc """
  長い WAV(デモの楽曲など)を**ノンブロッキング**で再生し、途中で止められる。再生プロセスは別の OS プロセス
  (Port)で動かすので、BT の常駐ストリームやタッチ音の処理を塞がない。
  `owner` に `{:audio_file_started, monotonic_ms}`(再生プロセスを起動した直後)と
  `{:audio_file_done, 終了コード}`(再生が終わった/止められた)が届く。再生中に呼ぶと前の再生を止める。
  出力先が無ければ `:unavailable`。
  """
  def play_file(path, owner \\ self()) when is_binary(path), do: GenServer.call(__MODULE__, {:play_file, path, owner}, 5_000)

  @doc "`play_file/2` の再生を止める(再生中でなければ何もしない)。"
  def stop_file, do: GenServer.cast(__MODULE__, :stop_file)

  @doc "任意パスの WAV(44.1kHz ステレオ想定、録音の再生など)を現在の出力先で再生する。"
  def play_path(path) when is_binary(path), do: enqueue({:play_path, path}, @max_pending)

  @doc """
  `play_seq/1` と同じ items を**連結済みの WAV ファイルに書き出す**(呼び出し元のプロセスで実行。再生キューは塞がない)。
  連結は ARM926 で約 1 秒かかるので、時刻に厳密な再生(時報のカウントダウン)は事前に作っておき `play_path/1` で鳴らす。
  戻り値 `:ok` / `:error`。
  """
  def render_seq(items, path) when is_list(items) and is_binary(path) do
    case build_seq_data(items) do
      {:ok, rate, data} -> File.write(path, wav_header(rate, 16, 2, byte_size(data)) <> data)
      :error -> :error
    end
  end

  @doc "起動チャイム。"
  def startup, do: enqueue({:play, "startup"}, @max_pending)

  @doc """
  `priv/audio/<name>.wav` を再生(直列キュー投入、非ブロッキング)。
  戻り値: `:ok` / `:unavailable`(アダプタ/ツール無し)/ `:dropped`(混雑)/ `:error`(プロセス未起動)。
  """
  def play(name) when is_binary(name), do: enqueue({:play, name}, @max_pending)

  @doc """
  複数の WAV と無音を連結して 1 回で再生。`items` は WAV 相対名(`"time/h14"`)または
  `{:silence, ミリ秒}` のリスト。全 WAV は同一サンプルレート・16bit であること(ch はモノ/ステレオ混在可、
  出力は常にステレオ)。
  """
  def play_seq(items) when is_list(items), do: enqueue({:play_seq, items}, @max_pending)

  @doc "再生手段が揃っているか(BT スピーカー接続済み、または tinyplay + 再生 PCM を持つカード)。"
  def available?, do: bt_ready?() or ((File.exists?(@tinyplay) or File.exists?(@aplay)) and current_card() != nil)

  # BT スピーカー出力が使えるか(設定あり・接続済み・aplay あり)
  defp bt_ready?, do: File.exists?(@aplay) and BtSpeaker.ready?()

  @cards_ttl_ms 2_000

  @doc """
  再生 PCM を持つサウンドカード一覧。`%{card: n, id: ..., usbid: ... | nil, name: ...}`。
  /proc と /dev を走査して 1 回約 40 ms(ARM926)かかり、1 回の音量操作や再生要求で 4〜5 回呼ばれて画面の反応が
  重くなっていたため、**2 秒間キャッシュ**する(USB オーディオの抜き差しの反映は最大 2 秒遅れる)。
  """
  def cards do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :cards}, nil) do
      {at, list} when now - at < @cards_ttl_ms ->
        list

      _ ->
        list = scan_cards()
        :persistent_term.put({__MODULE__, :cards}, {now, list})
        list
    end
  end

  defp scan_cards do
    longnames = parse_longnames()

    for dir <- Path.wildcard("/proc/asound/card[0-9]*"),
        File.dir?(dir),
        n = card_index(dir),
        File.exists?("/dev/snd/pcmC#{n}D0p") do
      %{card: n, id: read_trim("#{dir}/id"), usbid: read_trim("#{dir}/usbid"), name: Map.get(longnames, n, "")}
    end
    |> Enum.sort_by(& &1.card)
  end

  @doc "現在の出力先カード(優先順リストで解決)。無ければ nil。"
  def current_card do
    prefer = Application.get_env(:hello_kiosk_brain, :audio_prefer, @default_prefer)
    cs = cards()
    Enum.find_value(prefer, fn pat -> Enum.find(cs, &matches?(&1, pat)) end) || List.first(cs)
  end

  @doc "出力先の表示名(画面用)。BT スピーカー接続中は \"BT: 名前\"、次に USB カード名。無ければ nil。"
  def output_label do
    if bt_ready?() do
      BtSpeaker.output_label()
    else
      case current_card() do
        nil -> nil
        %{name: name} when is_binary(name) and name != "" -> name |> String.split(" at ") |> hd()
        %{id: id} -> id
      end
    end
  end

  @doc """
  デモ画面の出入りで Kiosk が呼ぶ。true で BT ストリームの先行量を @bt_lead_demo_ms に増やす
  (NIF 描画中の tick 遅れでアンダーラン → スピーカーが再ミュート → 復帰後しばらくタッチ音が消える、の対策)。
  """
  def demo_mode(on?) when is_boolean(on?), do: GenServer.cast(__MODULE__, {:demo_mode, on?})

  @doc "BT 常駐ストリームの状態(デバッグ用)。nil なら未接続。"
  def bt_stream_info do
    GenServer.call(__MODULE__, :bt_info, 1000)
  catch
    :exit, _ -> nil
  end

  # --- キュー投入 --------------------------------------------------------------

  defp enqueue(msg, max_pending) do
    cond do
      not available?() ->
        :unavailable

      true ->
        case Process.whereis(__MODULE__) do
          nil ->
            :error

          pid ->
            # 待ち件数は再生要求(cast)だけを数える。BT 常駐ストリーム中は :bt_tick が 40ms ごとに
            # 届くため message_queue_len で見るとタッチ音が不規則に捨てられる(実機で「鳴ったり鳴らなかったり」)。
            case Process.info(pid, :messages) do
              {:messages, msgs} ->
                if Enum.count(msgs, &match?({:"$gen_cast", _}, &1)) > max_pending,
                  do: :dropped,
                  else: (GenServer.cast(pid, msg); :ok)

              _ ->
                :error
            end
        end
    end
  end

  # --- GenServer ---------------------------------------------------------------

  @impl true
  def init(_) do
    Process.send_after(self(), :bt_check, @bt_check_ms)
    {:ok, %{bt: nil, lead_ms: @bt_lead_ms}}
  end

  @impl true
  def handle_call({:play_file, path, owner}, _from, state) do
    state = stop_file_player(state, false)

    case file_player_cmd(path) do
      nil ->
        {:reply, :unavailable, state}

      {exe, args} ->
        port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, args: args])
        send(owner, {:audio_file_started, now_ms()})
        {:reply, :ok, Map.put(state, :file, %{port: port, owner: owner})}
    end
  end

  def handle_call(:bt_info, _from, %{bt: nil} = state), do: {:reply, nil, state}

  def handle_call(:bt_info, _from, %{bt: bt} = state) do
    info = %{written_ms: bt.written_ms, elapsed_ms: now_ms() - bt.t0, pending_ms: div(byte_size(bt.pending), @bt_bytes_per_ms)}
    {:reply, Map.merge(info, Map.take(state, [:touch_played, :touch_dropped, :played])), state}
  end

  # 1 音: BT ストリームがあればその待ち行列へ(タッチ音は待ちがあれば捨てる)、無ければ tinyplay を同期実行。
  # UAC アダプタは 2ch 固定で、モノラル WAV は tinyplay が "failed to open for pcm" で失敗する
  # (A-Z 素材は mono)。ステレオならそのまま、モノラルなら play_seq と同じ経路でステレオ化して再生。
  @impl true
  def handle_cast({:play, name}, %{bt: bt} = state) when bt != nil do
    if name == "touch" and byte_size(bt.pending) > 0 do
      {:noreply, count(state, :touch_dropped)}
    else
      {:noreply, state |> bt_queue([name]) |> count(if name == "touch", do: :touch_played, else: :played)}
    end
  end

  def handle_cast({:play, name}, state) do
    path = wav_path(name)

    case File.read(path) do
      {:ok, bin} ->
        case parse_wav(bin) do
          {:wav, _rate, 16, 2, _} ->
            run_tinyplay(path)

          {:wav, _rate, 16, 1, _} ->
            case build_seq_wav([name]) do
              {:ok, seq} -> run_tinyplay(seq)
              :error -> Logger.warning("Audio: stereo conversion failed #{path}")
            end

          other ->
            Logger.warning("Audio: unsupported wav #{path}: #{inspect(other)}")
        end

      _ ->
        Logger.warning("Audio: not found #{path}")
    end

    {:noreply, state}
  end

  def handle_cast(:stop_file, state), do: {:noreply, stop_file_player(state, false)}

  def handle_cast({:play_path, path}, state) do
    if bt_ready?() do
      System.cmd(@aplay, ["-q", "-D", BtSpeaker.alsa_device(), path], stderr_to_stdout: true)
    else
      run_tinyplay(path)
    end

    {:noreply, state}
  end

  def handle_cast({:play_seq, items}, %{bt: bt} = state) when bt != nil do
    {:noreply, bt_queue(state, items)}
  end

  def handle_cast({:play_seq, items}, state) do
    case build_seq_wav(items) do
      {:ok, path} -> run_tinyplay(path)
      :error -> Logger.warning("Audio: play_seq build failed #{inspect(items)}")
    end

    {:noreply, state}
  end

  def handle_cast({:demo_mode, on?}, state) do
    {:noreply, %{state | lead_ms: if(on?, do: @bt_lead_demo_ms, else: @bt_lead_ms)}}
  end

  # 診断用カウンタ(bt_stream_info で読める)
  defp count(state, key), do: Map.update(state, key, 1, &(&1 + 1))

  # --- BT 常駐ストリーム ---------------------------------------------------------

  # 2 秒ごと: BT が使えるのにストリームが無ければ開く / 使えなくなったら閉じる
  @impl true
  def handle_info(:bt_check, state) do
    state =
      case {bt_ready?(), state.bt} do
        {true, nil} -> bt_open(state)
        {false, bt} when bt != nil -> bt_close(state, :not_ready)
        _ -> state
      end

    state = onboard_init(state)

    Process.send_after(self(), :bt_check, @bt_check_ms)
    {:noreply, state}
  end

  # 壁時計に合わせて先行 @bt_lead_ms 分まで書き込む。待ち行列の音 → 足りない分は無音。
  def handle_info(:bt_tick, %{bt: nil} = state), do: {:noreply, state}

  def handle_info(:bt_tick, %{bt: bt, lead_ms: lead} = state) do
    now = now_ms()
    need_ms = now - bt.t0 + lead - bt.written_ms

    # 書込が止まっていた(BT の立ち上がりで aplay が読まず Port.command が塞がった等)後は遅れが溜まる。
    # まとめて書くとパイプ+ALSA バッファが埋まって遅延がその分増えるので、基準時刻を張り直して
    # 遅れを捨てる(無音を流しているだけなので音の時間軸がずれても問題ない)。
    {bt, need_ms} =
      if need_ms > lead + 2 * @bt_tick_ms do
        {%{bt | t0: now + lead - bt.written_ms - @bt_tick_ms}, @bt_tick_ms}
      else
        {bt, need_ms}
      end

    bt =
      if need_ms >= @bt_tick_ms do
        # 1 tick に最大 4 tick 分(遅れ・先行量の増加は数 tick で取り戻す)
        w_ms = min(need_ms, 4 * @bt_tick_ms)
        {chunk, rest} = take_pcm(bt.pending, w_ms * @bt_bytes_per_ms)
        Port.command(bt.port, chunk)
        %{bt | written_ms: bt.written_ms + w_ms, pending: rest}
      else
        bt
      end

    Process.send_after(self(), :bt_tick, @bt_tick_ms)
    {:noreply, %{state | bt: bt}}
  end

  def handle_info({port, {:exit_status, rc}}, %{bt: %{port: port}} = state) do
    Logger.info("Audio: bt stream aplay exited rc=#{rc}")
    {:noreply, %{state | bt: nil}}
  end

  def handle_info({port, {:data, out}}, %{bt: %{port: port}} = state) do
    Logger.warning("Audio: aplay(bluealsa): #{String.trim(to_string(out))}")
    {:noreply, state}
  end

  # 長い WAV(play_file)の再生プロセスの終了と出力
  def handle_info({port, {:exit_status, rc}}, %{file: %{port: port, owner: owner}} = state) do
    send(owner, {:audio_file_done, rc})
    {:noreply, Map.delete(state, :file)}
  end

  def handle_info({port, {:data, out}}, %{file: %{port: port}} = state) do
    Logger.warning("Audio: play_file: #{String.trim(to_string(out))}")
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # 再生中の長い WAV を止める(プロセスを終了させて Port を閉じる)。止めた側は自分で分かっているので、
  # 既定では done を送らない(前のセッションの done が、直後に始めた次のセッションを終わらせるのを防ぐ)。
  defp stop_file_player(%{file: %{port: port, owner: owner}} = state, notify?) do
    with os_pid when is_integer(os_pid) <- port_os_pid(port), do: System.cmd("/bin/sh", ["-c", "kill #{os_pid}"], stderr_to_stdout: true)
    try do: Port.close(port), catch: (_, _ -> :ok)
    if notify?, do: send(owner, {:audio_file_done, :stopped})
    Map.delete(state, :file)
  end

  defp stop_file_player(state, _notify?), do: state

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  # 長い WAV を鳴らすコマンド(出力先は run_tinyplay と同じ判断)。再生手段が無ければ nil。
  defp file_player_cmd(path) do
    cond do
      bt_ready?() ->
        {@aplay, ["-q", "-D", BtSpeaker.alsa_device(), path]}

      true ->
        case current_card() do
          nil -> nil
          %{id: "BrainBU26154"} = card -> {@aplay, ["-q", "-D", "plughw:CARD=#{card.id},DEV=0", path]}
          card -> {@tinyplay, [path, "-D", Integer.to_string(card.card), "-d", @device]}
        end
    end
  end

  # カードが現れたら保存済みの音量・マイク設定(Mixer)を 1 回だけ反映する。
  # 本体コーデックの既定 2/25(-24dB)は小さすぎるので、Mixer の既定段階(5/10 ≒ 12/25)になる。
  defp onboard_init(%{onboard_vol: true} = state), do: state

  defp onboard_init(state) do
    case current_card() do
      nil ->
        state

      _card ->
        HelloKioskBrain.Mixer.apply_saved()
        Map.put(state, :onboard_vol, true)
    end
  end

  defp bt_open(state) do
    dev = BtSpeaker.alsa_device()
    # ALSA バッファはデモ時の先行量(1s)が収まる大きさ。ただし aplay は既定で「バッファ満杯まで再生開始を
    # 待つ」ため、-S(開始閾値)を 100ms にしないとバッファ分(1.3s)がそのまま常時遅延になる(実機で
    # 「タッチから 1.9 秒遅れて鳴る」)。通常時は先行 @bt_lead_ms 分しか溜まらず、遅延 ≈ 0.26s + A2DP 側。
    args = ["-q", "-D", dev, "-t", "raw", "-f", "S16_LE", "-c", "2", "-r", Integer.to_string(@bt_rate),
            "-B", Integer.to_string(@bt_alsa_buffer_us), "-F", "40000", "--start-delay=100000", "-"]

    try do
      port = Port.open({:spawn_executable, @aplay}, [:binary, :exit_status, :stderr_to_stdout, args: args])
      Logger.info("Audio: bt stream opened (#{dev})")
      send(self(), :bt_tick)
      %{state | bt: %{port: port, t0: now_ms(), written_ms: 0, pending: <<>>}}
    rescue
      e ->
        Logger.warning("Audio: bt stream open failed #{inspect(e)}")
        state
    end
  end

  defp bt_close(%{bt: bt} = state, why) do
    Logger.info("Audio: bt stream closed (#{why})")
    try do: Port.close(bt.port), catch: (_, _ -> :ok)
    %{state | bt: nil}
  end

  # WAV 列をステレオ PCM に変換して待ち行列へ追加
  defp bt_queue(%{bt: bt} = state, items) do
    case build_seq_data(items) do
      {:ok, @bt_rate, data} ->
        %{state | bt: %{bt | pending: bt.pending <> data}}

      {:ok, rate, _} ->
        Logger.warning("Audio: bt stream needs #{@bt_rate}Hz sources, got #{rate}Hz #{inspect(items)}")
        state

      :error ->
        Logger.warning("Audio: bt queue build failed #{inspect(items)}")
        state
    end
  end

  # pending の先頭から need バイト取り出し、足りない分は「ほぼ無音」で埋める。
  # 完全なデジタル 0 を流し続けると BT スピーカー側が無音検出でミュートし、次の音の頭(70ms の
  # タッチ音なら全部)を落とすことがあるため、±2 LSB の微小ノイズ(聴感上は無音)で埋める。
  defp take_pcm(pending, need) when byte_size(pending) >= need do
    <<chunk::binary-size(need), rest::binary>> = pending
    {chunk, rest}
  end

  defp take_pcm(pending, need), do: {pending <> keepalive(need - byte_size(pending)), <<>>}

  # 「ほぼ無音」= 25Hz 正弦波(振幅 @keep_amp ≈ -49dBFS、小型スピーカーでは再生されず聴感上無音)+ ±2 LSB ディザ。
  # デジタル 0 や ±2 LSB だけだとスピーカーの無音検出ミュートを外せない機種があるため、検出閾値を超える
  # 信号を流し続ける。1 秒 = 25 周期ちょうどのパターンを作り、位相が途切れないよう読み出し位置を持ち回す。
  @keep_hz 25
  @keep_amp 120
  defp keepalive(bytes) do
    {pat, off} =
      case Process.get(:audio_keep) do
        nil ->
          frames = @bt_rate
          p =
            for i <- 0..(frames - 1), into: <<>> do
              v = round(@keep_amp * :math.sin(2 * :math.pi() * @keep_hz * i / @bt_rate)) + :rand.uniform(5) - 3
              <<v::little-signed-16, v::little-signed-16>>
            end

          {p, 0}

        {p, o} ->
          {p, o}
      end

    size = byte_size(pat)
    {chunk, off2} = roll(pat, size, off, bytes)
    Process.put(:audio_keep, {pat, off2})
    chunk
  end

  defp roll(pat, size, off, bytes) when off + bytes <= size, do: {binary_part(pat, off, bytes), rem(off + bytes, size)}

  defp roll(pat, size, off, bytes) do
    head = binary_part(pat, off, size - off)
    {tail, off2} = roll(pat, size, 0, bytes - byte_size(head))
    {head <> tail, off2}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # --- USB(tinyplay)経路 --------------------------------------------------------

  defp run_tinyplay(path) do
    case current_card() do
      nil -> :unavailable
      # 本体コーデック(ROHM BU26154、44.1kHz 固定)は tinyalsa だと開始閾値 0 で XRUN → 無音になる
      # (実機確認)。alsa-lib の plughw で鳴らす(48kHz 素材・モノラルも plug が変換する)。
      %{id: "BrainBU26154"} = card ->
        t0 = System.monotonic_time(:millisecond)
        {out, rc} = res = System.cmd(@aplay, ["-q", "-D", "plughw:CARD=#{card.id},DEV=0", path], stderr_to_stdout: true)
        play_log(path, rc, out, System.monotonic_time(:millisecond) - t0)
        res

      card ->
        System.cmd(@tinyplay, [path, "-D", Integer.to_string(card.card), "-d", @device], stderr_to_stdout: true)
    end
  end

  # 本体出力の再生結果を /data/hello_kiosk/audio.log に残す(不具合調査用、肥大防止のため 64KB を超えたら作り直す)
  defp play_log(path, rc, out, ms) do
    log = "/data/hello_kiosk/audio.log"
    if match?({:ok, %{size: n}} when n > 65_536, File.stat(log)), do: File.rm(log)
    up = File.read!("/proc/uptime") |> String.split() |> hd()
    File.write(log, "uptime=#{up} #{Path.basename(path)} rc=#{rc} #{ms}ms #{inspect(String.trim(out))}\n", [:append])
  rescue
    _ -> :ok
  end

  # --- WAV 連結(出力は常に S16_LE ステレオ) -----------------------------------

  defp build_seq_wav(items) do
    case build_seq_data(items) do
      {:ok, rate, data} ->
        File.write!(@seq_path, wav_header(rate, 16, 2, byte_size(data)) <> data)
        {:ok, @seq_path}

      :error ->
        :error
    end
  end

  # items(WAV 名 / {:silence, ms})→ {:ok, rate, ステレオ PCM バイナリ}。レートは最初の WAV に合わせる。
  defp build_seq_data(items) do
    parsed =
      Enum.map(items, fn
        {:silence, ms} -> {:silence, ms}
        name when is_binary(name) -> read_wav(name)
      end)

    case Enum.find_value(parsed, fn
           {:wav, rate, 16, _ch, _} -> rate
           _ -> nil
         end) do
      nil ->
        :error

      rate ->
        out_ch = 2
        bpms = div(rate * out_ch * 2, 1000)

        data =
          parsed
          |> Enum.map(fn
            {:silence, ms} -> :binary.copy(<<0>>, max(ms, 0) * bpms)
            {:wav, ^rate, 16, 1, d} -> mono_to_stereo(d)
            {:wav, ^rate, 16, 2, d} -> d
            {:wav, r, b, c, _} ->
              Logger.warning("Audio: play_seq skips incompatible wav (#{r}Hz/#{b}bit/#{c}ch, want #{rate}Hz/16bit)")
              <<>>
            :error -> <<>>
          end)
          |> IO.iodata_to_binary()

        {:ok, rate, data}
    end
  end

  # 16bit モノラル PCM の各サンプルを L/R に複製してステレオ化。
  defp mono_to_stereo(data), do: for(<<s::binary-2 <- data>>, into: <<>>, do: s <> s)

  defp read_wav(name) do
    path = wav_path(name)

    case File.read(path) do
      {:ok, bin} -> parse_wav(bin)
      _ -> Logger.warning("Audio: not found #{path}"); :error
    end
  end

  defp parse_wav(<<"RIFF", _::little-32, "WAVE", rest::binary>>), do: walk(rest, nil, nil)
  defp parse_wav(_), do: :error

  defp walk(_bin, fmt, data) when fmt != nil and data != nil, do: {:wav, fmt.rate, fmt.bits, fmt.ch, data}

  defp walk(<<id::binary-4, sz::little-32, rest::binary>>, fmt, data) when byte_size(rest) >= sz do
    <<body::binary-size(sz), tail::binary>> = rest
    tail = if rem(sz, 2) == 1, do: drop1(tail), else: tail

    case id do
      "fmt " -> walk(tail, parse_fmt(body), data)
      "data" -> walk(tail, fmt, body)
      _ -> walk(tail, fmt, data)
    end
  end

  defp walk(_, _, _), do: :error

  defp drop1(<<_, r::binary>>), do: r
  defp drop1(b), do: b

  defp parse_fmt(<<_afmt::little-16, ch::little-16, rate::little-32, _br::little-32, _ba::little-16, bits::little-16, _::binary>>),
    do: %{ch: ch, rate: rate, bits: bits}

  defp parse_fmt(_), do: nil

  defp wav_header(rate, bits, ch, data_len) do
    byte_rate = rate * ch * div(bits, 8)
    block_align = ch * div(bits, 8)

    <<"RIFF", 36 + data_len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, ch::little-16,
      rate::little-32, byte_rate::little-32, block_align::little-16, bits::little-16, "data",
      data_len::little-32>>
  end

  # --- カード解決ヘルパー --------------------------------------------------------

  defp wav_path(name), do: Path.join([to_string(:code.priv_dir(:hello_kiosk_brain)), "audio", name <> ".wav"])

  defp matches?(c, pat) do
    p = String.downcase(pat)
    Enum.any?([c.usbid, c.id, c.name], fn v -> String.contains?(String.downcase(v || ""), p) end)
  end

  defp card_index(dir), do: dir |> Path.basename() |> String.trim_leading("card") |> String.to_integer()

  defp read_trim(path) do
    case File.read(path) do
      {:ok, s} -> String.trim(s)
      _ -> nil
    end
  end

  # /proc/asound/cards は「 N [id ]: driver - short」の行と、字下げされた長い名前の行が対になる。
  defp parse_longnames do
    case File.read("/proc/asound/cards") do
      {:ok, txt} ->
        txt
        |> String.split("\n")
        |> Enum.reduce({nil, %{}}, fn line, {cur, acc} ->
          case Regex.run(~r/^\s*(\d+)\s+\[/, line) do
            [_, n] -> {String.to_integer(n), acc}
            nil ->
              t = String.trim(line)
              if cur != nil and t != "", do: {cur, Map.update(acc, cur, t, &(&1 <> " " <> t))}, else: {cur, acc}
          end
        end)
        |> elem(1)

      _ ->
        %{}
    end
  end
end
