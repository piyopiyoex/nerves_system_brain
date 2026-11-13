defmodule HelloKioskBrain.Kiosk do
  @moduledoc """
  PW-SH6 KIOSK デモ(LovyanGFX NIF 描画版)。

  画面(下部バーのタップ、または物理キー。上段のキーが左から順にバーのボタンに対応する:
  ホーム=1 / タッチ・キー=15 / デモ=104 / BLEセンサ=109 / 音声デモ=110 / 設定=111):
    ホーム : タイトル、稼働秒数、IP、電池、サブシステム状態
    タッチ : タップで点を描画、最終座標表示
    キー   : 最終キーコード表示
    デモ   : LovyanGFX MovingIcons(NIF 背景スレッド)。タッチ/キーでホームへ

  各画面は `HelloKioskBrain.Draw` でコマンド列を組み立て、`Native.render/1` で
  1 フレームとして描画する(NIF 内でオフスクリーン描画 → fb0 へ一括転送)。
  日本語は efont/IPA ゴシック(jp8〜jp40)。
  """
  use GenServer
  require Logger

  alias HelloKioskBrain.{Audio, CameraMonitor, Draw, FlightDemo, Input, LetterSpeaker, Mixer, Native, PapapaDemo, Pswitch, Recorder, TimeSignal, TimeSpeaker, UsbMode}

  @tick_ms 1_000
  @w 854
  @h 480
  # ヘッダ左端の機種名(DTB から自動認識、§model_name/0)の右に置く画面タイトルの開始 x
  @title_x 110
  # DTB の model 文字列("SHARP Brain PW-SH6")が読めないときの表示
  @model_fallback "Brain"
  @tab_h 40
  # 下部バーの全セル。左から 5 タブ + 設定 + 電源を切る。
  #   {label, kind, target, keycode}
  #   kind: :tab(画面切替・選択ハイライトあり) / :spare(未割当のプレースホルダ) /
  #         :power(電源OFF 確認へ)
  #   keycode: 物理キー(evdev コード)。そのキーでこのセルをタップしたのと同じ動作。
  #            nil は割当なし。
  @bar [
    {"ホーム", :tab, :home, 1},
    # タッチとキーを 1 つにまとめた画面。空いた 1 枠は「設定」(時計などの設定)。
    # 物理キーは上段の 6 キー(1/15/104/109/110/111)が左から順にバーの 6 ボタンに対応する(電源は PSWITCH)。
    {"タッチ/キー", :tab, :touch, 15},
    {"デモ", :tab, :demo_menu, 104},
    {"BLEセンサ", :tab, :spare1, 109},
    {"音声デモ", :tab, :spare2, 110},
    {"設定", :tab, :settings, 111},
    {"電源を切る", :power, :confirm_off, nil}
  ]
  @bar_cells length(@bar)
  # 「デモ」(index 2)と「BLEセンサ」(index 3)の間にこの幅の隙間(境界)を空ける。
  # ボタン幅は全セル均等(@cell_w)のまま、BLEセンサ以降を右へずらす。
  @bar_gap 10
  @gap_index 3
  @cell_w div(@w - @bar_gap, @bar_cells)

  # 確認画面のボタン(x, y, w, h)
  @confirm_yes {220, 300, 180, 64}
  @confirm_no {460, 300, 180, 64}
  # 電源メニュー(「電源を切る」): 切る / 再起動 / キャンセル。再起動はもう 1 段の確認(@confirm_yes/@confirm_no)
  @off_yes {120, 300, 180, 64}
  @off_reboot {337, 300, 180, 64}
  @off_no {554, 300, 180, 64}
  # ホーム「USB」行のボタン領域(システム情報 8 行目、値の部分)と、USB ダイアログの部品
  @usb_row_btn {196, 384, 300, 36}
  @usb_opt_host {80, 150, 330, 110}
  @usb_opt_ncm {444, 150, 330, 110}
  @usb_go {220, 330, 180, 64}
  @usb_cancel {460, 330, 180, 64}
  # ホーム「オーディオ」状態行のボタン領域と、音量ダイアログの部品(各行: [−] ゲージ [+])
  @vol_row_btn {510, 258, 344, 36}
  @vol_minus {70, 150, 90, 70}
  @vol_plus {694, 150, 90, 70}
  @mic_minus {70, 270, 90, 70}
  @mic_plus {694, 270, 90, 70}
  @vol_close {327, 390, 200, 60}
  # ホーム「ディスプレイ」行のボタン(明るさ 5 段階ダイアログ)
  @bl_row_btn {510, 90, 344, 36}
  # 設定画面の「時計」行(ボタン)と、時計ダイアログの部品。5 つの欄(年/月/日/時/分)それぞれに [+] 値 [-]
  @set_clock_btn {196, 90, 600, 36}
  @clk_fields [:year, :month, :day, :hour, :minute]
  @clk_cx [120, 270, 410, 570, 710]
  @clk_up_y 130
  @clk_dn_y 290
  @clk_btn_w 100
  @clk_btn_h 64
  @clk_apply {220, 392, 180, 60}
  @clk_cancel {460, 392, 180, 60}
  # 設定画面の「Wi-Fi」行(ボタン)と、Wi-Fi ダイアログの部品(2 つの入力欄 + 画面キーボード 5 行 + ボタン 3 つ)
  @set_wifi_btn {196, 138, 600, 36}
  @wf_ssid_box {17, 36, 820, 46}
  @wf_pw_box {17, 88, 820, 46}
  @wf_kb_x 17
  @wf_kb_y 142
  @wf_pitch_x 82
  @wf_pitch_y 54
  @wf_key_h 50
  @wf_show {17, 418, 195, 52}
  @wf_save {222, 418, 195, 52}
  @wf_del {427, 418, 195, 52}
  @wf_cancel {632, 418, 205, 52}
  # Wi-Fi 接続先の一覧画面: 行は縦に並べてタップで編集、下に「追加」「閉じる」
  @wl_y0 52
  @wl_pitch 54
  @wl_row_h 48
  @wl_add {17, 418, 240, 52}
  @wl_close {597, 418, 240, 52}
  @wf_ssid_max 32
  @wf_pw_max 63
  # 出力先の切替ボタン(本体コーデックのみ表示): スピーカー / ヘッドフォン
  @route_spk {24, 30, 190, 48}
  @route_hp {640, 30, 190, 48}

  # 配色(RGB888)
  @bg 0x081020
  @panel 0x142038
  @fg 0xEBEBF5
  @dim 0x788CAA
  @accent 0xFFA500
  @ok 0x50DC78
  @warn 0xFF5A5A
  @tab_off 0x283854

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    unbind_fbcon()

    case Native.init_display() do
      :ok -> :ok
      other -> Logger.error("Kiosk: init_display => #{inspect(other)}")
    end

    Input.subscribe(self())
    # 保存済みの明るさ(5 段階)を反映
    HelloKioskBrain.Backlight.apply_saved()

    devmem = resolve_devmem()
    # 起動前の押下ラッチを掃除(いきなり確認画面が出るのを防ぐ)
    Pswitch.clear(devmem)

    st = %{
      screen: :home,
      ticks: 0,
      last_touch: nil,
      last_key: nil,
      devmem: devmem,
      # 音声デモ画面: A-Z 読み上げ ON/OFF と直近の発声内容(表示用)
      voice_az: false,
      voice_last: nil,
      rec_busy: false,
      # USB 役割ダイアログ: 選択中(:host | :ncm)と結果メッセージ
      usb_sel: :host,
      usb_msg: nil,
      # 時計ダイアログ: 編集中の JST 日時 %{year:, month:, day:, hour:, minute:} と、設定画面に出す結果メッセージ
      clock_edit: nil,
      set_msg: nil,
      # Wi-Fi ダイアログ: %{ssid:, pw:, field: :ssid | :pw, shift:, sym:, show:, err:}
      wf: nil,
      # パパパの二重唱デモ: %{tl:, t0:(音の開始時刻、ms)| nil, started:, sig:}
      papa: nil,
      # フライトデモ: %{sim: FlightDemo の状態}
      flight: nil,
      # 汎用ランナーのデモ: %{mod: モジュール, s: そのデモの状態}
      anim: nil
    }

    {:ok, st, {:continue, :first_render}}
  end

  # 起動チャイム: USB オーディオの enumerate(起動 ~4s)と Kiosk 起動が近接するため、
  # 少し待ってから鳴らし、アダプタ未認識なら @chime_retry_ms おきに最大 @chime_tries 回リトライ。
  @chime_delay_ms 2_000
  @chime_retry_ms 2_000

  # 毎秒の再描画でヘッダだけ描き直す画面と、本体まで全面再描画する間隔(秒)
  @header_only_screens [:home, :touch, :spare2, :settings, :demo_menu]
  # 毎秒の再描画をしない画面(入力中の画面を勝手に描き直さない / デモは自前で更新する)
  @no_tick_screens [:wifi_dialog, :papapa, :credits, :flight, :anim, :camera]
  # 「デモ」の選択画面のカード(増やすときはここに足す)。id は開始時の動作: :moving_icons / :papapa
  @demo_cards [
    %{id: :moving_icons, title: "Moving Icons", desc: ["LovyanGFX の動くアイコン"], color: 0x50DC78},
    %{id: :papapa, title: "パパパの二重唱", desc: ["魔笛より 男女の二重唱"], color: 0xFFA500},
    %{id: :flight, title: "フライト", desc: ["フライトシミュレータの計器"], color: 0x5AB0FF},
    %{id: :fireworks, title: "花火", desc: ["夜の街に打ち上げ花火"], color: 0xFF6A8A},
    %{id: :talk, title: "おしゃべり時計", desc: ["キャラが時刻を話す"], color: 0xFFB0C8},
    %{id: :world, title: "世界時計", desc: ["昼と夜の世界地図"], color: 0x6AD0A0},
    %{id: :stars, title: "プラネタリウム", desc: ["東京の星空を早回し"], color: 0xA08CFF},
    %{id: :memo, title: "お絵描きメモ", desc: ["ペンで手書き・自動で保存"], color: 0xF0E68C},
    %{id: :camera, title: "ネットワークカメラ", desc: ["HTTP JPEG スナップショット"], color: 0x5AB0FF}
  ]
  # 汎用ランナー(:anim 画面)で動くデモ。モジュールは init/1・full/1・frame/2(と任意で event/2・stop/1)を持つ
  @anim_mods %{fireworks: HelloKioskBrain.FireworksDemo, talk: HelloKioskBrain.TalkDemo, world: HelloKioskBrain.WorldDemo,
               stars: HelloKioskBrain.StarDemo, memo: HelloKioskBrain.MemoDemo}
  # 「デモ」の選択画面の「クレジット」ボタン(歌声 CC BY 3.0 などの表示)
  @credit_btn {664, 388, 168, 40}
  @demo_card_w 262
  @demo_card_h 100
  @body_every 5
  @chime_tries 5

  @impl true
  def handle_continue(:first_render, st) do
    paint(st)
    send(self(), :tick)
    Process.send_after(self(), {:startup_chime, @chime_tries}, @chime_delay_ms)
    {:noreply, st}
  end

  @impl true
  def handle_info(:tick, st) do
    st = %{st | ticks: st.ticks + 1}
    st = maybe_power_button(st)

    # 時報デモが始まったら 5 Hz で再描画(秒の小数まで表示して音と見比べられるように)
    if Process.get(:demo_ticking) != true and HelloKioskBrain.TimeSignal.demo_clock() != nil do
      Process.put(:demo_ticking, true)
      send(self(), :demo_tick)
    end

    # ヘッダの時計を進めるためデモ以外は毎秒更新。全面の再描画は ARM926 で 250〜400 ms かかり、その間タッチの処理が
    # 待たされて「反応が重い」ので、ホーム/タッチ/音声デモは通常ヘッダだけ描き直し、本体は @body_every 秒ごとに全面再描画する。
    cond do
      st.screen == :demo -> :ok
      st.screen in @no_tick_screens -> :ok
      st.screen in @header_only_screens and rem(st.ticks, @body_every) != 0 -> paint_header_only(st)
      true -> paint(st)
    end

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, st}
  end

  def handle_info(:demo_tick, st) do
    if HelloKioskBrain.TimeSignal.demo_clock() != nil do
      paint(st)
      Process.send_after(self(), :demo_tick, 200)
    else
      Process.put(:demo_ticking, false)
      paint(st)
    end

    {:noreply, st}
  end

  # 録音ボタンの進行表示(Recorder から)。完了/失敗で rec_busy を戻す。
  def handle_info({:rec_state, text}, st) do
    st = %{st | voice_last: text, rec_busy: not String.starts_with?(text, ["録音 5", "録音失敗", "録音デバイス", "arecord"])}
    if st.screen == :spare2, do: paint(st)
    {:noreply, st}
  end

  # 時報デモ中のタッチはデモを終了して元の画面に戻る
  def handle_info({:touch, x, y}, st) do
    if HelloKioskBrain.TimeSignal.demo_clock() != nil do
      HelloKioskBrain.TimeSignal.demo_stop()
      repaint(st)
    else
      on_touch(st, x, y)
    end
  end
  def handle_info({:key, code, :down}, st), do: on_key(st, code)

  def handle_info({:startup_chime, tries_left}, st) do
    # 保存済みの音量を確実に反映してから鳴らす(Audio の初回反映より先にチャイムが来る場合に備える)
    if tries_left == @chime_tries, do: HelloKioskBrain.Mixer.apply_saved()
    res = HelloKioskBrain.Audio.startup()
    chime_log(tries_left, res)

    case res do
      :ok ->
        :ok

      # :unavailable(アダプタ/tinyplay 未検出)/:error(WAV 無し)。残回数があれば再試行。
      _ when tries_left > 1 ->
        Process.send_after(self(), {:startup_chime, tries_left - 1}, @chime_retry_ms)

      _ ->
        :ok
    end

    {:noreply, st}
  end

  # パパパの二重唱: 音の開始(基準時刻)・口パクの更新・曲の終わり
  def handle_info({:audio_file_started, ms}, %{screen: :papapa, papa: p} = st), do: {:noreply, %{st | papa: %{p | t0: ms}}}
  def handle_info(:papa_tick, %{screen: :papapa} = st), do: {:noreply, papa_tick(st)}
  # 曲が最後まで流れたら、クレジットを見せてから選択画面へ(タッチ/キーで戻る)
  def handle_info({:audio_file_done, _rc}, %{screen: :papapa} = st), do: go(st, :credits)

  # 汎用ランナーのデモ: 描画ループと、音の開始/終了の通知(おしゃべり時計など)
  def handle_info(:anim_tick, %{screen: :anim} = st), do: {:noreply, anim_tick(st)}

  def handle_info({tag, _} = msg, %{screen: :anim, anim: %{mod: m, s: s}} = st) when tag in [:audio_file_started, :audio_file_done] do
    s = if function_exported?(m, :event, 2), do: m.event(msg, s), else: s
    {:noreply, %{st | anim: %{mod: m, s: s}}}
  end

  # 手書きの入力(Input の {:pen, ...})を、pen/4 を持つデモへ
  def handle_info({:pen, phase, x, y}, %{screen: :anim, anim: %{mod: m, s: s}} = st) do
    if function_exported?(m, :pen, 4), do: {:noreply, %{st | anim: %{mod: m, s: m.pen(s, phase, x, y)}}}, else: {:noreply, st}
  end

  # フライトデモの描画ループ
  def handle_info(:flight_tick, %{screen: :flight} = st), do: {:noreply, flight_tick(st)}

  def handle_info(_, st), do: {:noreply, st}

  # 起動チャイムの結果を /root/chime.log に残す(不具合調査用。1 行 = 1 試行)
  defp chime_log(tries_left, res) do
    up = File.read!("/proc/uptime") |> String.split() |> hd()
    File.write("/root/chime.log", "uptime=#{up} tries_left=#{tries_left} result=#{inspect(res)} card=#{inspect(HelloKioskBrain.Audio.output_label())}\n", [:append])
  rescue
    _ -> :ok
  end

  # --- 入力ディスパッチ -------------------------------------------------------

  # デモ中は NIF スレッドが画面を専有: 任意のタッチ/キーでホームへ戻る
  defp on_touch(%{screen: :demo} = st, _x, _y), do: go(st, :demo_menu)
  # パパパの二重唱: どこをタッチしても止めて選択画面へ
  defp on_touch(%{screen: :papapa} = st, _x, _y), do: go(st, :demo_menu)
  defp on_touch(%{screen: :credits} = st, _x, _y), do: go(st, :demo_menu)
  defp on_touch(%{screen: :flight} = st, _x, _y), do: go(st, :demo_menu)
  defp on_touch(%{screen: :camera} = st, _x, _y), do: go(st, :demo_menu)
  # 汎用ランナーのデモ: touch/3 を持つデモ(お絵描きメモ)はタップをデモへ渡す。それ以外はタッチで戻る
  defp on_touch(%{screen: :anim, anim: %{mod: m, s: s}} = st, x, y) do
    if function_exported?(m, :touch, 3) do
      case m.touch(s, x, y) do
        {:ok, s, cmds} ->
          if cmds != [], do: Native.render(cmds)
          {:noreply, %{st | anim: %{mod: m, s: s}}}

        :exit ->
          go(st, :demo_menu)
      end
    else
      go(st, :demo_menu)
    end
  end

  # 電源断中 / 5V案内画面: タップでホームへ戻れる(キャンセル/エスケープ)
  defp on_touch(%{screen: :powering_off} = st, _x, _y), do: go(st, :home)
  defp on_touch(%{screen: :needs_unplug} = st, _x, _y), do: go(st, :home)

  defp on_touch(%{screen: :confirm_off} = st, x, y) do
    cond do
      in_rect?(x, y, @off_yes) -> power_off(st)
      in_rect?(x, y, @off_reboot) -> (Audio.touch(); go(st, :confirm_reboot))
      in_rect?(x, y, @off_no) -> go(st, :home)
      true -> {:noreply, st}
    end
  end

  # 再起動の確認: 「再起動する」で再起動、「キャンセル」でホームへ
  defp on_touch(%{screen: :confirm_reboot} = st, x, y) do
    cond do
      in_rect?(x, y, @confirm_yes) -> reboot(st)
      in_rect?(x, y, @confirm_no) -> go(st, :home)
      true -> {:noreply, st}
    end
  end

  defp on_touch(%{screen: :rebooting} = st, _x, _y), do: {:noreply, st}

  # USB 役割ダイアログ: HOST / NCM の選択 → 「リブート実行」で DTB 差し替え+再起動、「キャンセル」でホームへ
  defp on_touch(%{screen: :usb_dialog} = st, x, y) do
    cond do
      in_rect?(x, y, @usb_opt_host) -> repaint(%{st | usb_sel: :host})
      in_rect?(x, y, @usb_opt_ncm) -> repaint(%{st | usb_sel: :ncm})
      in_rect?(x, y, @usb_cancel) -> go(st, :home)
      in_rect?(x, y, @usb_go) -> usb_switch(st)
      true -> {:noreply, st}
    end
  end

  # 音量ダイアログ: スピーカー/マイクを 10 段階で調整(即反映・保存)。スピーカーは変更時にタッチ音で確認
  defp on_touch(%{screen: :vol_dialog} = st, x, y) do
    cond do
      in_rect?(x, y, @vol_minus) -> vol_step(st, :vol, -1)
      in_rect?(x, y, @vol_plus) -> vol_step(st, :vol, 1)
      in_rect?(x, y, @mic_minus) -> vol_step(st, :mic, -1)
      in_rect?(x, y, @mic_plus) -> vol_step(st, :mic, 1)
      in_rect?(x, y, @vol_close) -> go(st, :home)
      in_rect?(x, y, @route_spk) -> route_set(st, :speaker)
      in_rect?(x, y, @route_hp) -> route_set(st, :headphone)
      true -> {:noreply, st}
    end
  end

  # 明るさダイアログ: 5 段階(即反映・保存)
  defp on_touch(%{screen: :bl_dialog} = st, x, y) do
    cond do
      in_rect?(x, y, @vol_minus) -> bl_step(st, -1)
      in_rect?(x, y, @vol_plus) -> bl_step(st, 1)
      in_rect?(x, y, @vol_close) -> go(st, :home)
      true -> {:noreply, st}
    end
  end

  # 切替結果画面(エラー時)はタップでホームへ
  # 時計ダイアログ: 年月日時分を [+]/[-] で調整 →「設定する」で適用(Linux 時刻 + RTC)、「キャンセル」で戻る
  defp on_touch(%{screen: :clock_dialog} = st, x, y) do
    field_hit =
      Enum.find_value(Enum.zip(@clk_fields, @clk_cx), fn {f, cx} ->
        cond do
          in_rect?(x, y, {cx - div(@clk_btn_w, 2), @clk_up_y, @clk_btn_w, @clk_btn_h}) -> {f, 1}
          in_rect?(x, y, {cx - div(@clk_btn_w, 2), @clk_dn_y, @clk_btn_w, @clk_btn_h}) -> {f, -1}
          true -> nil
        end
      end)

    cond do
      field_hit != nil ->
        {f, d} = field_hit
        Audio.touch()
        repaint(%{st | clock_edit: clock_step(st.clock_edit, f, d)})

      in_rect?(x, y, @clk_apply) ->
        clock_apply(st)

      in_rect?(x, y, @clk_cancel) ->
        Audio.touch()
        go(%{st | set_msg: nil}, :settings)

      true ->
        {:noreply, st}
    end
  end

  # Wi-Fi 接続先の一覧: 行をタップで編集、「追加」で新規、「閉じる」で設定へ
  defp on_touch(%{screen: :wifi_list} = st, x, y) do
    nets = HelloKioskBrain.WifiConfig.list()

    row =
      Enum.find(Enum.with_index(nets), fn {_n, i} ->
        in_rect?(x, y, {17, @wl_y0 + i * @wl_pitch, 820, @wl_row_h})
      end)

    cond do
      row != nil ->
        {n, _} = row
        Audio.touch()
        wifi_open(st, n.idx, n.ssid, n.psk)

      in_rect?(x, y, @wl_add) ->
        Audio.touch()

        if length(nets) >= HelloKioskBrain.WifiConfig.max_networks() do
          repaint(%{st | set_msg: {:error, "登録は #{HelloKioskBrain.WifiConfig.max_networks()} 件までです"}})
        else
          wifi_open(st, nil, "", "")
        end

      in_rect?(x, y, @wl_close) ->
        go(%{st | set_msg: nil}, :settings)

      true ->
        {:noreply, st}
    end
  end

  # Wi-Fi 接続先の削除の確認: 「削除する」で削除、「キャンセル」で編集画面へ戻る(入力内容はそのまま)
  defp on_touch(%{screen: :wifi_del_confirm} = st, x, y) do
    cond do
      in_rect?(x, y, @confirm_yes) -> wifi_delete(st)
      in_rect?(x, y, @confirm_no) -> go(st, :wifi_dialog)
      true -> {:noreply, st}
    end
  end

  # Wi-Fi ダイアログ: 入力欄をタップで選択、画面キーボードで入力、「保存」で適用(つながらなければ自動で元に戻る)
  defp on_touch(%{screen: :wifi_dialog, wf: wf} = st, x, y) do
    cond do
      in_rect?(x, y, @wf_ssid_box) -> wf_repaint_fields(%{st | wf: %{wf | field: :ssid}})
      in_rect?(x, y, @wf_pw_box) -> wf_repaint_fields(%{st | wf: %{wf | field: :pw}})
      in_rect?(x, y, @wf_show) -> wf_repaint_fields(%{st | wf: %{wf | show: not wf.show}}, true)
      in_rect?(x, y, @wf_save) -> wifi_save(st)
      wf.idx != nil and in_rect?(x, y, @wf_del) ->
        Audio.touch()
        repaint(%{st | screen: :wifi_del_confirm})
      in_rect?(x, y, @wf_cancel) -> go(%{st | wf: nil, set_msg: nil}, :wifi_list)
      action = wf_key_at(st, x, y) -> wf_press(st, action)
      true -> {:noreply, st}
    end
  end

  defp on_touch(%{screen: :usb_result} = st, _x, _y), do: go(st, :home)

  defp on_touch(st, x, y) do
    cond do
      y >= @h - @tab_h ->
        case bar_index_at(x) do
          nil -> {:noreply, st}
          idx -> bar_action(st, Enum.at(@bar, idx))
        end

      # ホームの「ディスプレイ」行(ボタン)→ 明るさダイアログ
      st.screen == :home and in_rect?(x, y, @bl_row_btn) ->
        Audio.touch()
        repaint(%{st | screen: :bl_dialog})

      # ホームの「オーディオ」行(ボタン)→ 音量ダイアログ
      st.screen == :home and in_rect?(x, y, @vol_row_btn) ->
        Audio.touch()
        repaint(%{st | screen: :vol_dialog})

      # ホームの「USB」行(ボタン)→ 役割切替ダイアログ
      st.screen == :home and in_rect?(x, y, @usb_row_btn) ->
        Audio.touch()
        cur = UsbMode.current()
        sel = if cur in [:host, :ncm], do: cur, else: :host
        repaint(%{st | screen: :usb_dialog, usb_sel: sel, usb_msg: nil})

      # 「デモ」の選択画面: カードをタップでその出し物を開始
      st.screen == :demo_menu and in_rect?(x, y, @credit_btn) ->
        Audio.touch()
        go(st, :credits)

      st.screen == :demo_menu ->
        card = @demo_cards |> Enum.with_index() |> Enum.find(fn {_c, i} -> in_rect?(x, y, demo_card_rect(i)) end)

        case card do
          {%{id: id}, _} -> demo_start(st, id)
          nil -> {:noreply, st}
        end

      # 設定画面の「時計」行(ボタン)→ 日時の設定ダイアログ
      st.screen == :settings and in_rect?(x, y, @set_clock_btn) ->
        Audio.touch()
        repaint(%{st | screen: :clock_dialog, clock_edit: clock_edit_now(), set_msg: nil})

      # 設定画面の「Wi-Fi」行(ボタン)→ SSID・パスワードの入力ダイアログ
      st.screen == :settings and in_rect?(x, y, @set_wifi_btn) ->
        Audio.touch()
        repaint(%{st | screen: :wifi_list, set_msg: nil})

      st.screen == :settings ->
        {:noreply, st}

      # 音声デモ画面のボタン(バー以外のタップ)
      st.screen == :spare2 ->
        voice_touch(%{st | last_touch: {x, y}}, x, y)

      true ->
        st = %{st | last_touch: {x, y}}

        if st.screen == :touch do
          Audio.touch()
          paint(st)
        end

        {:noreply, st}
    end
  end

  # デモ画面(全画面アニメ)のキー: 下部バーに対応するキーならその画面へ直接移る(以前は常にホームへ戻り、
  # 目的の画面へは 2 回押す必要があった)。デモのキー自体と、対応のないキーはホームへ戻る。
  defp on_key(%{screen: :demo} = st, code) do
    case Enum.find(@bar, fn {_l, kind, _t, kc} -> kc == code and kind == :tab end) do
      {_l, :tab, target, _kc} when target != :demo -> bar_action(st, Enum.find(@bar, fn {_l, _k, t, _kc} -> t == target end))
      _ -> go(st, :demo_menu)
    end
  end

  # パパパの二重唱: 音量キー(29/114)以外のキーで止めて選択画面へ(音量キーは曲の途中でも効く)
  defp on_key(%{screen: :papapa} = st, code) when code not in [29, 114], do: go(st, :demo_menu)
  defp on_key(%{screen: :credits} = st, _code), do: go(st, :demo_menu)
  defp on_key(%{screen: :flight} = st, _code), do: go(st, :demo_menu)
  defp on_key(%{screen: :camera} = st, _code), do: go(st, :demo_menu)
  defp on_key(%{screen: :anim} = st, code) when code not in [29, 114], do: go(st, :demo_menu)
  # 「デモ」の選択画面: 上下左右(103/108/105/106)で選択を動かし、決定(Enter=28)で開始、戻る(158)でホームへ。
  # 選択は state の :demo_sel(後から足した項目なので Map.get/put。ホットロードでも落ちない)。最後の位置は「クレジット」
  defp on_key(%{screen: :demo_menu} = st, code) when code in [103, 108, 105, 106, 28, 158] do
    n = length(@demo_cards)
    i = Map.get(st, :demo_sel, 0) |> min(n)

    case code do
      28 when i < n -> demo_start(st, Enum.at(@demo_cards, i).id)
      28 -> (Audio.touch(); go(st, :credits))
      158 -> (Audio.touch(); go(st, :home))
      _ ->
        j = demo_move(i, n, code)
        if j != i, do: Audio.key()
        repaint(Map.put(st, :demo_sel, j))
    end
  end

  defp on_key(%{screen: :powering_off} = st, _code), do: go(st, :home)
  # 再起動の確認中のキー = キャンセル(誤操作で再起動しない)
  defp on_key(%{screen: :confirm_reboot} = st, _code), do: go(st, :home)
  defp on_key(%{screen: :rebooting} = st, _code), do: {:noreply, st}
  defp on_key(%{screen: :needs_unplug} = st, _code), do: go(st, :home)
  # USB ダイアログ/結果画面ではキー=キャンセル(誤操作で再起動しない)
  defp on_key(%{screen: :usb_dialog} = st, _code), do: go(st, :home)
  defp on_key(%{screen: :usb_result} = st, _code), do: go(st, :home)
  # 時計ダイアログのキー=キャンセル(設定画面へ戻る。誤操作で時刻を変えない)
  defp on_key(%{screen: :clock_dialog} = st, _code), do: go(%{st | set_msg: nil}, :settings)
  # 削除の確認画面のキー=キャンセル(編集画面へ戻る。誤操作で削除しない)
  defp on_key(%{screen: :wifi_del_confirm} = st, _code), do: go(st, :wifi_dialog)

  # Wi-Fi 一覧画面のキー=閉じて設定へ
  defp on_key(%{screen: :wifi_list} = st, _code), do: go(%{st | set_msg: nil}, :settings)

  # Wi-Fi ダイアログの物理キー: 英字・数字・「-」「.」・空白・削除(14)・Enter(28、入力欄の切替)。他のキーは無視
  defp on_key(%{screen: :wifi_dialog, wf: wf} = st, code) do
    ch =
      cond do
        (l = LetterSpeaker.letter_for(code)) != nil -> if wf.shift, do: l, else: String.downcase(l)
        code in 2..11 -> Enum.at(~w(1 2 3 4 5 6 7 8 9 0), code - 2)
        code == 12 -> "-"
        code == 52 -> "."
        code == 57 -> " "
        true -> nil
      end

    cond do
      ch != nil -> wf_press(st, {:char, ch})
      code == 14 -> wf_press(st, :bs)
      code == 28 -> wf_repaint_fields(%{st | wf: %{wf | field: if(wf.field == :ssid, do: :pw, else: :ssid)}})
      true -> {:noreply, st}
    end
  end

  defp on_key(%{screen: :vol_dialog} = st, code) when code not in [29, 114], do: go(st, :home)
  # 明るさダイアログ: 音量キー(29/114)で 5 段階の増減、他のキーで閉じる
  defp on_key(%{screen: :bl_dialog} = st, code) when code in [29, 114], do: bl_step(%{st | last_key: code}, if(code == 29, do: 1, else: -1))
  defp on_key(%{screen: :bl_dialog} = st, _code), do: go(st, :home)

  # 本体の音量キー: 「音量+」(印字 Page Up)= KEY_LEFTCTRL(29)、「音量−」= KEY_VOLUMEDOWN(114)。
  # 後者は DTB のキーマップに <3 4 KEY_VOLUMEDOWN> を足して初めてイベントが出る(priv/dtb の変種)。
  # どの画面でも 10 段階で増減し、変更後にタッチ音で確認する(「キー」画面ではコード表示のため再描画)。
  # 「戻る」(KEY_BACK=158)と「記号」(KEY_COMPOSE=127)は現時点では機能を割り当てず、コードを返すだけ
  # (画面「キー」で表示。DTB で追加したキー。記号は修飾キーとして記号レイヤも開く)。→ 汎用の on_key で last_key のみ更新。

  # キー 56(KEY_LEFTALT): 音量の聞き比べテスト(アナログ出力段 2 → 13 → 25 で起動チャイムを 3 回、終了後に設定を復元)。
  # 実行中の連打は無視する。「キー」画面ではコード表示のため再描画。
  defp on_key(st, 56) do
    st = %{st | last_key: 56}

    unless Process.get(:analog_test) && Process.alive?(Process.get(:analog_test)) do
      Process.put(:analog_test, spawn(fn -> Mixer.analog_test() end))
    end

    if st.screen == :touch, do: paint(st)
    {:noreply, st}
  end

  defp on_key(st, code) when code in [29, 114] do
    st = %{st | last_key: code}
    n = Mixer.set(:vol, Mixer.level(:vol) + if(code == 29, do: 1, else: -1))
    if n > 0, do: Audio.touch()
    if st.screen in [:touch, :vol_dialog], do: paint(st)
    {:noreply, st}
  end

  defp on_key(st, code) do
    st = %{st | last_key: code}

    # 音声デモ画面で A-Z 読み上げが ON なら、文字キーは発声に使う(バー割当キーは別コード)。
    letter = if st.screen == :spare2 and st.voice_az, do: LetterSpeaker.letter_for(code), else: nil

    if letter do
      LetterSpeaker.speak(letter)
      st = %{st | voice_last: LetterSpeaker.label(letter)}
      paint(st)
      {:noreply, st}
    else
      on_key_bar(st, code)
    end
  end

  defp on_key_bar(st, code) do

    # 物理キー → 下部バーのセルに紐付け(タップと同じ動作)。
    case Enum.find(@bar, fn {_l, _k, _t, kc} -> kc == code end) do
      # 未割当キー、または機能の無い「予備」のキー
      cell when cell == nil or elem(cell, 1) == :spare ->
        # 未割当キー: 「タッチ/キー」画面ならキー音とコード表示(再描画)
        if st.screen == :touch do
          Audio.key()
          paint(st)
        end

        {:noreply, st}

      {_l, :tab, :touch, _kc} when st.screen == :touch ->
        # 今の画面を開くキー(15): 画面遷移せず、キー音とコード表示だけ
        Audio.key()
        paint(st)
        {:noreply, st}

      cell ->
        bar_action(st, cell)
    end
  end

  # 下部バーのセル 1 個に対する動作(タッチ・キー共通)。
  # 有効なボタンは USB オーディオでタッチ音を鳴らす(アダプタ無しなら Audio 側で no-op)。
  defp bar_action(st, {_label, :tab, scr, _kc}) do
    HelloKioskBrain.Audio.touch()
    go(st, scr)
  end

  defp bar_action(st, {_label, :power, scr, _kc}) do
    HelloKioskBrain.Audio.touch()
    go(st, scr)
  end
  # 予備セルは未割当。今は無反応(後で機能を割り当てる)。
  defp bar_action(st, _cell), do: {:noreply, st}

  # セル i の左端 x(@gap_index 以降は隙間ぶん右へ)
  defp cell_x(i), do: i * @cell_w + if(i >= @gap_index, do: @bar_gap, else: 0)

  # タップ x 座標 → セル index。隙間(デッドゾーン)に落ちたら nil。
  defp bar_index_at(x) do
    gap_start = @gap_index * @cell_w

    cond do
      x < gap_start -> min(div(x, @cell_w), @gap_index - 1)
      x < gap_start + @bar_gap -> nil
      true -> min(div(x - @bar_gap, @cell_w), @bar_cells - 1)
    end
  end

  # 電源ボタン(PSWITCH)短押しを tick 毎にポーリング。押下 → 電源OFF確認画面。
  defp maybe_power_button(st) do
    if Pswitch.check_and_clear(st.devmem) do
      if st.screen == :confirm_off, do: st, else: open_confirm_off(st)
    else
      st
    end
  end

  defp open_confirm_off(%{screen: :demo} = st) do
    Native.stop_moving_icons()
    open_confirm_off(%{st | screen: :home})
  end

  defp open_confirm_off(%{screen: :papapa} = st) do
    Audio.stop_file()
    Audio.demo_mode(false)
    open_confirm_off(%{st | screen: :home, papa: nil})
  end

  defp open_confirm_off(%{screen: :camera} = st) do
    CameraMonitor.disable()
    open_confirm_off(%{st | screen: :home})
  end

  defp open_confirm_off(%{screen: :flight} = st), do: open_confirm_off(%{st | screen: :home, flight: nil})

  defp open_confirm_off(%{screen: :anim, anim: %{mod: m, s: s}} = st) do
    if function_exported?(m, :stop, 1), do: m.stop(s)
    open_confirm_off(%{st | screen: :home, anim: nil})
  end

  defp open_confirm_off(st) do
    st = %{st | screen: :confirm_off}
    paint(st)
    st
  end

  # devmem ヘルパーのパス解決(Battery と同経路。/root にあれば流用)
  defp resolve_devmem do
    dst = "/root/devmem"
    src = Path.join([to_string(:code.priv_dir(:hello_kiosk_brain)), "bin", "devmem"])

    cond do
      File.exists?(dst) ->
        dst

      File.exists?(src) ->
        with {:ok, _} <- File.copy(src, dst), :ok <- File.chmod(dst, 0o755), do: dst, else: (_ -> nil)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  # 「切る」押下時の電源断処理。
  #   - 5V 給電中(USB/充電器): poweroff すると i.MX28 は電源断できず「再起動」になる。
  #     それは望ましくないので poweroff せず、案内画面(戻る付き)を出して切らない。
  #   - 電池駆動(5V 無し): poweroff を実行(数秒後に電源が切れる。poweroff は非同期で即戻る)。
  # ※ on_5v = HW_POWER_STS bit29(VDD5V_GT_VDDIO)。USB/充電器を抜くと 5V ラインの
  #   放電に数秒かかり、その間は on_5v=true のまま(抜いた直後に切れない=正常。数秒待つ)。
  defp power_off(st) do
    if on_5v?() do
      go(st, :needs_unplug)
    else
      Logger.info("Kiosk: poweroff")
      st = %{st | screen: :powering_off}
      paint(st)
      Process.sleep(200)
      HelloKioskBrain.Power.poweroff()
      {:noreply, st}
    end
  rescue
    e ->
      Logger.error("poweroff failed: #{inspect(e)}")
      go(st, :home)
  end

  defp reboot(st) do
    Logger.info("Kiosk: reboot")
    st = %{st | screen: :rebooting}
    paint(st)
    Process.sleep(200)
    HelloKioskBrain.Power.reboot()
    {:noreply, st}
  rescue
    e ->
      Logger.error("reboot failed: #{inspect(e)}")
      go(st, :home)
  end

  # USB/充電器の 5V(VBUS)が来ているかを USB ガジェット(UDC)の state で判定する。
  # VBUS 無し(電池駆動)なら UDC state = "not attached"、来ていれば configured/attached 等。
  # ※ HW_POWER bit29(VDD5V_GT_VDDIO)は電池 ~3.7V でも VDDIO(3.3V)超で常に 1 になり
  #   使えない。UDC の VBUS 検出は割込駆動で即時・確実。
  # 読めない場合は 5V 無しとみなす(= poweroff を通す。電池駆動で確実に切れるように)。
  defp on_5v? do
    # 5V の有無は Battery(VDD5V の ADC)で判定する。USB ホスト構成(HOST)では UDC が無く、従来の UDC 方式は
    # 常に「5V なし」になり、5V 給電中でも poweroff を実行して再起動になっていた。
    case safe_battery() do
      %{on_5v: on} when is_boolean(on) -> on
      _ -> on_5v_udc?()
    end
  end

  defp on_5v_udc? do
    case Path.wildcard("/sys/class/udc/*/state") do
      [path | _] ->
        case File.read(path) do
          {:ok, s} -> String.trim(s) != "not attached"
          _ -> false
        end

      _ ->
        false
    end
  end

  # 5V 給電中の案内(電源を切らない。戻る or 任意入力でホームへ)。
  defp needs_unplug do
    {x, y, w, h} = {div(@w - 200, 2), 320, 200, 60}

    [
      Draw.text(div(@w, 2), 160, :mc, :jp32, @warn, "USB・充電器を抜いてください"),
      Draw.text(div(@w, 2), 220, :mc, :jp20, @fg, "給電中は電源を切れません(再起動になります)"),
      Draw.text(div(@w, 2), 256, :mc, :jp16, @dim, "抜いて数秒待ってから もう一度「電源を切る」"),
      Draw.rect(x, y, w, h, @tab_off),
      Draw.text(div(@w, 2), y + div(h, 2), :mc, :jp24, @fg, "戻る")
    ]
  end

  # 電池駆動で poweroff 実行中の表示(数秒後に電源が切れる)。
  defp powering_off do
    [Draw.text(div(@w, 2), div(@h, 2), :mc, :jp32, @fg, "電源を切ります…")]
  end

  defp in_rect?(px, py, {x, y, w, h}), do: px >= x and px < x + w and py >= y and py < y + h

  defp go(%{screen: :demo} = st, scr) when scr != :demo do
    Native.stop_moving_icons()
    # デモ(NIF が CPU を占有)の間は BT ストリームの先行量を増やしていたので戻す
    Audio.demo_mode(false)
    go(%{st | screen: :home}, scr)
  end

  defp go(%{screen: :camera} = st, scr) when scr != :camera do
    CameraMonitor.disable()
    go(%{st | screen: :home}, scr)
  end

  # パパパの二重唱から出るときは、音を止めて先行量を戻す
  defp go(%{screen: :papapa} = st, scr) when scr != :papapa do
    Audio.stop_file()
    Audio.demo_mode(false)
    go(%{st | screen: :home, papa: nil}, scr)
  end

  # フライトデモから出る(描画ループは :flight_tick が screen を見て止まる)
  defp go(%{screen: :flight} = st, scr) when scr != :flight, do: go(%{st | screen: :home, flight: nil}, scr)

  defp go(%{screen: :anim, anim: %{mod: m, s: s}} = st, scr) when scr != :anim do
    if function_exported?(m, :stop, 1), do: m.stop(s)
    go(%{st | screen: :home, anim: nil}, scr)
  end

  defp go(st, :camera) do
    # Display notice before the external JPEG renderer takes framebuffer ownership.
    st = %{st | screen: :camera}
    paint(st)
    CameraMonitor.enable()
    {:noreply, st}
  end

  defp go(st, :demo) do
    Audio.demo_mode(true)
    Native.start_moving_icons()
    {:noreply, %{st | screen: :demo}}
  end

  defp go(st, scr) do
    st = %{st | screen: scr}
    paint(st)
    {:noreply, st}
  end

  # 画面全体を 1 コマンド列に組み立てて 1 回で描画
  defp paint(st) do
    # 時報デモ中(TimeSignal.demo/2)は、どの画面でもずらした時計を大きく表示して、音との同期を見て判断できるようにする
    case HelloKioskBrain.TimeSignal.demo_clock() do
      {:ok, d} -> Native.render([Draw.clear(@bg), demo_clock_screen(d)])
      _ -> paint_screen(st)
    end
  end

  defp paint_header_only(st) do
    if HelloKioskBrain.TimeSignal.demo_clock() != nil do
      paint(st)
    else
      title =
        case st.screen do
          :home -> "Nerves on Brain"
          :spare2 -> "音声デモ"
          :touch -> "タッチ/キー"
          :settings -> "設定"
          :demo_menu -> "デモ"
        end

      Native.render(header(title))
    end
  end

  defp paint_screen(st) do
    case st.screen do
      :confirm_off ->
        Native.render([Draw.clear(@bg), confirm_off()])

      :confirm_reboot ->
        Native.render([Draw.clear(@bg), confirm_reboot()])

      :rebooting ->
        Native.render([Draw.clear(@bg), Draw.text(div(@w, 2), div(@h, 2), :mc, :jp32, @fg, "再起動します…")])

      :powering_off ->
        Native.render([Draw.clear(@bg), powering_off()])

      :needs_unplug ->
        Native.render([Draw.clear(@bg), needs_unplug()])

      :usb_dialog ->
        Native.render([Draw.clear(@bg), usb_dialog(st)])

      :usb_result ->
        Native.render([Draw.clear(@bg), usb_result(st)])

      :vol_dialog ->
        Native.render([Draw.clear(@bg), vol_dialog()])

      :bl_dialog ->
        Native.render([Draw.clear(@bg), bl_dialog()])

      :clock_dialog ->
        Native.render([Draw.clear(@bg), clock_dialog(st)])

      :wifi_dialog ->
        Native.render([Draw.clear(@bg), wifi_dialog(st)])

      :wifi_list ->
        Native.render([Draw.clear(@bg), wifi_list(st)])

      :wifi_del_confirm ->
        Native.render([Draw.clear(@bg), wifi_del_confirm(st)])

      :papapa ->
        Native.render(PapapaDemo.full(PapapaDemo.idle_parts(), %{nervous: true, wob: 0}))

      :credits ->
        Native.render([Draw.clear(@bg), credits_screen()])

      :flight ->
        Native.render(FlightDemo.full(st.flight.sim))

      :anim ->
        Native.render(st.anim.mod.full(st.anim.s))

      :camera ->
        Native.render([Draw.clear(@bg), camera_screen()])

      screen ->
        body =
          case screen do
            :home -> home(st)
            :touch -> touch(st)
            :demo -> []
            :spare1 -> sensor_screen()
            :spare2 -> voice_screen(st)
            :settings -> settings_screen(st)
            :demo_menu -> demo_menu(st)
          end

        Native.render([Draw.clear(@bg), body, tabs(st)])
    end
  end

  defp camera_screen do
    if CameraMonitor.status().snapshot_url do
      [
        header("ネットワークカメラ"),
        Draw.text(div(@w, 2), 190, :mc, :jp32, @accent, "カメラに接続中…"),
        Draw.text(div(@w, 2), 245, :mc, :jp20, @fg, "HTTP JPEG snapshot を取得して表示します"),
        Draw.text(div(@w, 2), 290, :mc, :jp16, @dim, "タッチまたはキー入力でデモに戻ります")
      ]
    else
      [
        header("ネットワークカメラ"),
        Draw.text(div(@w, 2), 190, :mc, :jp28, @accent, "カメラが設定されていません"),
        Draw.text(div(@w, 2), 245, :mc, :jp20, @fg, "IEx から snapshot URL を設定してください"),
        Draw.text(div(@w, 2), 290, :mc, :jp16, @dim, "タッチまたはキー入力でデモに戻ります")
      ]
    end
  end

  defp confirm_off do
    {yx, yy, yw, yh} = @off_yes
    {rx, ry, rw, rh} = @off_reboot
    {nx, ny, nw, nh} = @off_no

    [
      Draw.text(div(@w, 2), 180, :mc, :jp32, @fg, "電源を切りますか?"),
      Draw.text(div(@w, 2), 240, :mc, :jp20, @dim, "「切る」で電源が切れます。「再起動」は確認のあと再起動します"),
      Draw.rect(yx, yy, yw, yh, @warn),
      Draw.text(yx + div(yw, 2), yy + div(yh, 2), :mc, :jp24, @bg, "切る"),
      Draw.rect(rx, ry, rw, rh, @accent),
      Draw.text(rx + div(rw, 2), ry + div(rh, 2), :mc, :jp24, @bg, "再起動"),
      Draw.rect(nx, ny, nw, nh, @tab_off),
      Draw.text(nx + div(nw, 2), ny + div(nh, 2), :mc, :jp24, @fg, "キャンセル")
    ]
  end

  defp confirm_reboot do
    {yx, yy, yw, yh} = @confirm_yes
    {nx, ny, nw, nh} = @confirm_no

    [
      Draw.text(div(@w, 2), 180, :mc, :jp32, @fg, "再起動しますか?"),
      Draw.text(div(@w, 2), 240, :mc, :jp20, @dim, "「再起動する」を押すと再起動します(約 1 分)"),
      Draw.rect(yx, yy, yw, yh, @accent),
      Draw.text(yx + div(yw, 2), yy + div(yh, 2), :mc, :jp24, @bg, "再起動する"),
      Draw.rect(nx, ny, nw, nh, @tab_off),
      Draw.text(nx + div(nw, 2), ny + div(nh, 2), :mc, :jp24, @fg, "キャンセル")
    ]
  end

  defp header(title) do
    {bat, bcol} = battery_label()
    {clock, ccol} = clock_label()
    m = ip_map()
    wired = m["eth0"] || m["usb0"]
    wifi = m["wlan0"]
    {wifi_txt, wifi_col} = wifi_label(wifi)

    [
      Draw.rect(0, 0, @w, 40, @panel),
      # 左端: 機種名(固定)→ 画面タイトル
      Draw.text(12, 20, :ml, :jp24, @fg, model_name()),
      Draw.text(@title_x, 20, :ml, :jp24, @accent, title),
      # 上段: 時計(中央)・電池(右)
      Draw.text(div(@w, 2), 12, :mc, :jp16, ccol, clock),
      Draw.text(@w - 12, 12, :mr, :jp16, bcol, bat),
      # 下段: 有線 LAN / WiFi の取得 IP(取得済=緑・未取得=グレー)
      Draw.text(@w - 285, 28, :mr, :jp16, net_col(wired), "有線 " <> (wired || "なし")),
      Draw.text(@w - 12, 28, :mr, :jp16, wifi_col, "WiFi " <> wifi_txt)
    ]
  end

  # WiFi の表示: 「IP (RSSI dBm)」。RSSI は /proc/net/wireless の signal level(dBm)。未取得なら IP のみ。
  # ヘッダの Wi-Fi 表示: IP があれば「IP (RSSI dBm)」(緑)。無いときは WifiWatch の状態(警告色)
  #   起動中… / IP取得中… / 未接続 / 復旧中(試行 N) / ドングルなし / なし(Wi-Fi 未設定・機器なし=グレー)
  defp wifi_label(nil) do
    case HelloKioskBrain.WifiWatch.display() do
      {:starting, _} -> {"起動中…", @warn}
      {:no_ip, _} -> {"IP取得中…", @warn}
      {:no_link, _} -> {"未接続", @warn}
      {:recovering, n} -> {"復旧中" <> if(n > 0, do: "(試行 #{n})", else: ""), @warn}
      {:no_dongle, _} -> {"ドングルなし", @warn}
      # IP が消えた直後で、監視の判断がまだ「正常」のままの間(最大 5 秒)
      {:ok, _} -> {"確認中…", @warn}
      _ -> {"なし", @dim}
    end
  end

  defp wifi_label(ip), do: {wifi_text(ip), @ok}

  defp wifi_text(nil), do: "なし"

  defp wifi_text(ip) do
    case wifi_rssi() do
      nil -> ip
      dbm -> "#{ip} (#{dbm}dBm)"
    end
  end

  # /proc/net/wireless: "wlan0: 0000   58.  -52.  -256 ..." → 3 つ目の数値(level)が dBm。
  # 毎秒の再描画で読んでも軽量だが、フォーマット違い・未関連付けでは nil。
  defp wifi_rssi do
    with {:ok, txt} <- File.read("/proc/net/wireless"),
         [line | _] <- txt |> String.split("\n") |> Enum.filter(&String.contains?(&1, "wlan0:")),
         [_, _status, _link, level | _] <- line |> String.split(~r/[\s:]+/, trim: true),
         {v, _} <- level |> String.trim_trailing(".") |> Integer.parse() do
      if v < 0, do: v, else: v - 256
    else
      _ -> nil
    end
  end

  defp net_col(nil), do: @dim
  defp net_col(_), do: @ok

  # --- 機種の自動認識 ---------------------------------------------------------
  # Brain ファームは自機種名の実行ファイル(例 PW-SH6 → edsh6exe.bin)しか起動しない。その中身は
  # U-Boot で `fdt_file=imx28-pwsh6.dtb` を内蔵しているため、Linux が受け取る DTB の model 文字列
  # ("SHARP Brain PW-SH6")は Brain ファーム自身の機種判定の結果になる。→ /proc/device-tree/model で確定できる。
  # 読取結果は persistent_term に保持(ヘッダは毎秒描き直すため)。

  @doc "DTB の model 文字列(例 \"SHARP Brain PW-SH6\")。読めなければ nil。"
  def dt_model do
    case :persistent_term.get({__MODULE__, :dt_model}, :unset) do
      :unset ->
        m =
          case File.read("/proc/device-tree/model") do
            {:ok, s} -> s |> String.trim_trailing(<<0>>) |> String.trim()
            _ -> nil
          end

        m = if m in [nil, ""], do: nil, else: m
        :persistent_term.put({__MODULE__, :dt_model}, m)
        m

      m ->
        m
    end
  end

  @doc "ヘッダ用の短い機種名(例 \"PW-SH6\")。DTB の model から末尾の語を取る。"
  def model_name do
    case dt_model() do
      nil -> @model_fallback
      m -> m |> String.split() |> List.last()
    end
  end

  # JST(UTC+9)の日付・時刻。時計が未設定(1970 年起点など)ならグレー表示。
  defp clock_label do
    jst =
      :calendar.universal_time()
      |> :calendar.datetime_to_gregorian_seconds()
      |> Kernel.+(9 * 3600)
      |> :calendar.gregorian_seconds_to_datetime()

    {{y, _, _} = date, _time} = jst

    if y < 2024 do
      {"時刻未設定", @dim}
    else
      wd = Enum.at(~w(月 火 水 木 金 土 日), :calendar.day_of_the_week(date) - 1)
      ndt = NaiveDateTime.from_erl!(jst)
      {Calendar.strftime(ndt, "%Y-%m-%d") <> "(#{wd}) " <> Calendar.strftime(ndt, "%H:%M:%S"), @fg}
    end
  end

  defp home(_st) do
    {mem, up, load} = sys_dynamic()

    # 左: システム情報 / 右: サブシステム状態。ラベルと値を 2 列で整列。
    sysinfo = [
      {"モデル", dt_model() || "SHARP Brain (不明)", @fg},
      soc_row(),
      {"カーネル", kernel_str(), @fg},
      {"ランタイム", "OTP #{:erlang.system_info(:otp_release)} / Elixir #{System.version()}", @fg},
      {"メモリ", mem, @fg},
      {"稼働", up, @fg},
      {"負荷", load, @fg},
      # USB0 の役割(DTB で決まる): HOST=ハブ経由で LAN/WiFi/BT/オーディオ、NCM=母艦と USB ガジェット直結
      usb_role_row()
    ]

    {psrc, pval, pcol} = power_status()

    status = [
      # 値は明るさの段階(行全体がボタン: 枠は bl_row_button、タップで明るさダイアログ)
      {"ディスプレイ", "明るさ #{HelloKioskBrain.Backlight.level()}/#{HelloKioskBrain.Backlight.max()}", @ok},
      {"タッチ", "OK", @ok},
      {"キーボード", "OK", @ok},
      {"ネットワーク", "OK", @ok},
      # オーディオ = USB オーディオ(UAC)の有無で判定。本体スピーカー経路は保留(提案書 20260909)。
      audio_status(),
      # BLE = USB ドングル(hci0)の有無 → スキャン開始済みなら受信センサ数
      ble_status(),
      {psrc, pval, pcol}
    ]

    [
      header("Nerves on Brain"),
      Draw.text(50, 62, :ml, :jp24, @accent, "システム情報"),
      Draw.line(50, 84, @w - 50, 84, @panel),
      Draw.text(520, 62, :ml, :jp24, @accent, "状態"),
      sysinfo
      |> Enum.with_index()
      |> Enum.map(fn {{label, value, col}, i} ->
        y = 108 + i * 42

        [
          Draw.text(50, y, :ml, :jp20, @dim, label),
          Draw.text(210, y, :ml, :jp20, col, value)
        ]
      end),
      # 右欄の最下段: ファームのバージョン(アプリ version + ビルド時の Git コミット)。値は長いので小さめの字で
      Draw.text(520, 108 + 7 * 42, :ml, :jp20, @dim, "ファーム"),
      Draw.text(720, 108 + 7 * 42, :ml, :jp16, @fg, HelloKioskBrain.Version.short()),
      # 「USB」行はボタン(タップで役割切替ダイアログ)。値の周りに枠と「▶」
      usb_row_button(),
      # 「オーディオ」行もボタン(タップで音量ダイアログ)
      vol_row_button(),
      # 「ディスプレイ」行もボタン(タップで明るさダイアログ)
      bl_row_button(),
      status
      |> Enum.with_index()
      |> Enum.map(fn {{label, value, col}, i} ->
        y = 108 + i * 42

        [
          Draw.text(520, y, :ml, :jp20, @dim, label),
          Draw.text(720, y, :ml, :jp20, col, value)
        ]
      end)
    ]
  end

  defp audio_status do
    cond do
      HelloKioskBrain.BtSpeaker.ready?() -> {"オーディオ", "BT OK", @ok}
      # 本体コーデック(ROHM BU26154)/ USB オーディオを出力先カードの種別で区別して表示
      match?(%{id: "BrainBU26154"}, Audio.current_card()) -> {"オーディオ", "本体 OK", @ok}
      Audio.output_label() -> {"オーディオ", "USB OK", @ok}
      true -> {"オーディオ", "なし", @dim}
    end
  end

  defp ble_status do
    cond do
      # BT スピーカー出力モードの機体: hci0 は bluetoothd 用(SwitchBot 受信はしない)
      HelloKioskBrain.BtSpeaker.configured?() ->
        case HelloKioskBrain.BtSpeaker.status() do
          :connected -> {"BT", "スピーカー接続", @ok}
          :unpaired -> {"BT", "ペアリング中", @warn}
          :disconnected -> {"BT", "スピーカー未接続", @warn}
          _ -> {"BT", "スタック起動待ち", @dim}
        end

      HelloKioskBrain.SwitchBotScanner.scanning?() ->
        s = HelloKioskBrain.SwitchBotScanner.get_sensors()
        n = length(s.meters) + Enum.count([s.pressure, s.contact, s.motion], &(not is_nil(&1)))
        {"BLE", "受信中 #{n}台", @ok}

      File.exists?("/sys/class/bluetooth/hci0") ->
        {"BLE", "初期化中", @warn}

      true ->
        {"BLE", "ドングルなし", @dim}
    end
  end

  # 稼働ごとに変化する情報(/proc から取得)。render 毎(1秒)に読むが軽量。
  defp sys_dynamic do
    {mem_used_mb(), uptime_str(), loadavg_str()}
  end

  # USB0 の動作モードを sysfs から判定して 1 行にする。
  #   HOST: /sys/bus/usb/devices/usb1(ルートハブ)がある → ハブ配下の機器数(ハブ自身を除く)を表示
  #   NCM : /sys/class/udc に UDC がある(peripheral DTB)→ usb0 の IP(ガジェット未リンクなら「リンク待ち」)
  #   両方あれば OTG。どちらも無ければ不明。
  defp usb_role_row do
    host? = File.exists?("/sys/bus/usb/devices/usb1")
    udc? = match?({:ok, [_ | _]}, File.ls("/sys/class/udc"))

    cond do
      host? and not udc? ->
        n = usb_device_count()
        {"USB", "HOST / 機器 #{n}台", if(n > 0, do: @ok, else: @warn)}

      udc? and not host? ->
        case ip_map()["usb0"] do
          nil -> {"USB", "NCM / リンク待ち", @warn}
          ip -> {"USB", "NCM / usb0 #{ip}", @ok}
        end

      host? and udc? ->
        {"USB", "OTG / HOST #{usb_device_count()}台 + NCM", @ok}

      true ->
        {"USB", "不明", @dim}
    end
  end

  # ルートハブ(usb1)配下の機器数。外付けハブ(bDeviceClass 09)は数えない。
  defp usb_device_count do
    Path.wildcard("/sys/bus/usb/devices/1-*/bDeviceClass")
    |> Enum.reject(fn p -> String.contains?(p, ":") end)
    |> Enum.count(fn p -> String.trim(File.read!(p)) != "09" end)
  rescue
    _ -> 0
  end

  # --- USB 役割(HOST / NCM)切替 ------------------------------------------------

  defp usb_row_button do
    {x, y, w, h} = @usb_row_btn

    [
      Draw.rframe(x, y, w, h, 8, @tab_off),
      Draw.text(x + w - 10, y + div(h, 2), :mr, :jp16, @accent, "切替 >")
    ]
  end

  defp bl_row_button do
    {x, y, w, h} = @bl_row_btn
    [Draw.rframe(x, y, w, h, 8, @tab_off)]
  end

  defp bl_step(st, d) do
    HelloKioskBrain.Backlight.set_level(HelloKioskBrain.Backlight.level() + d)
    Audio.touch()
    repaint(st)
  end

  defp bl_dialog do
    n = HelloKioskBrain.Backlight.level()

    [
      Draw.text(div(@w, 2), 54, :mc, :jp32, @fg, "画面の明るさ"),
      vol_gauge("明るさ", 134, @vol_minus, @vol_plus, n, true, HelloKioskBrain.Backlight.max()),
      Draw.text(div(@w, 2), 280, :mc, :jp16, @dim, "音量キー(+/-)でも調整できます"),
      Draw.rrect(elem(@vol_close, 0), elem(@vol_close, 1), elem(@vol_close, 2), elem(@vol_close, 3), 10, @tab_off),
      Draw.text(elem(@vol_close, 0) + div(elem(@vol_close, 2), 2), elem(@vol_close, 1) + div(elem(@vol_close, 3), 2), :mc, :jp24, @fg, "閉じる")
    ]
  end

  defp vol_row_button do
    {x, y, w, h} = @vol_row_btn
    [Draw.rframe(x, y, w, h, 8, @tab_off)]
  end

  # 出力先の切替(本体コーデックのみ)。切替後にタッチ音を鳴らして新しい出力先で聞こえることを確認できる。
  defp route_set(st, r) do
    if Mixer.controls() |> then(&(&1 != nil and Map.get(&1, :route, false))) do
      Mixer.set_route(r)
      Audio.touch()
    end

    repaint(st)
  end

  defp route_button({x, y, w, h}, label, selected) do
    [
      Draw.rrect(x, y, w, h, 10, if(selected, do: @panel, else: @bg)),
      Draw.rframe(x, y, w, h, 10, if(selected, do: @accent, else: @tab_off)),
      Draw.text(x + div(w, 2), y + div(h, 2), :mc, :jp20, if(selected, do: @accent, else: @dim), label)
    ]
  end

  defp vol_step(st, kind, d) do
    n = Mixer.set(kind, Mixer.level(kind) + d)
    # 音量・マイク感度の変更時もタッチ音を鳴らす(スピーカー音量は聴感で確認できる。0 のときは鳴らさない)
    if kind == :mic or n > 0, do: Audio.touch()
    repaint(st)
  end

  defp vol_dialog do
    ctl = Mixer.controls()

    [
      Draw.text(div(@w, 2), 54, :mc, :jp32, @fg, "音量・マイク"),
      if(ctl != nil and Map.get(ctl, :route, false),
        do: [route_button(@route_spk, "スピーカー", Mixer.route() == :speaker), route_button(@route_hp, "ヘッドフォン", Mixer.route() == :headphone)],
        else: []
      ),
      Draw.text(div(@w, 2), 100, :mc, :jp16, @dim,
        "出力: #{Audio.output_label() || "なし"}" <>
          if(ctl == nil, do: "(音量は BT スピーカー本体で調整)", else: "")),
      vol_gauge("スピーカー", 134, @vol_minus, @vol_plus, Mixer.level(:vol), ctl != nil),
      vol_gauge("マイク", 254, @mic_minus, @mic_plus, Mixer.level(:mic), ctl != nil),
      Draw.rrect(elem(@vol_close, 0), elem(@vol_close, 1), elem(@vol_close, 2), elem(@vol_close, 3), 10, @tab_off),
      Draw.text(elem(@vol_close, 0) + div(elem(@vol_close, 2), 2), elem(@vol_close, 1) + div(elem(@vol_close, 3), 2), :mc, :jp24, @fg, "閉じる")
    ]
  end

  # [-] ■■■■■□□□□□ [+] と段階表示
  defp vol_gauge(label, ty, {mx, my, mw, mh}, {px, py, pw, ph}, n, enabled, total \\ 10) do
    col = if enabled, do: @accent, else: @dim
    gx = mx + mw + 24
    gw = px - 24 - gx
    cell = div(gw, total)

    [
      Draw.text(div(@w, 2), ty, :mc, :jp20, @fg, "#{label}  #{n} / #{total}"),
      Draw.rrect(mx, my, mw, mh, 10, @tab_off),
      Draw.text(mx + div(mw, 2), my + div(mh, 2), :mc, :jp32, @fg, "-"),
      Draw.rrect(px, py, pw, ph, 10, @tab_off),
      Draw.text(px + div(pw, 2), py + div(ph, 2), :mc, :jp32, @fg, "+"),
      for i <- 0..(total - 1) do
        Draw.rrect(gx + i * cell, my + 10, cell - 6, mh - 20, 4, if(i < n, do: col, else: @panel))
      end
    ]
  end

  defp repaint(st) do
    paint(st)
    {:noreply, st}
  end

  defp usb_switch(%{usb_sel: sel} = st) do
    Audio.touch()

    case UsbMode.switch_and_reboot(sel) do
      :ok ->
        repaint(%{st | screen: :usb_result, usb_msg: {:ok, sel}})

      {:error, reason} ->
        repaint(%{st | screen: :usb_result, usb_msg: {:error, reason}})
    end
  end

  defp usb_mode_name(:host), do: "HOST"
  defp usb_mode_name(:ncm), do: "NCM"
  defp usb_mode_name(:otg), do: "OTG"
  defp usb_mode_name(_), do: "不明"

  defp usb_dialog(st) do
    cur = UsbMode.current()
    supported = UsbMode.supported?()

    [
      Draw.text(div(@w, 2), 60, :mc, :jp32, @fg, "USB の役割を切り替え"),
      Draw.text(div(@w, 2), 104, :mc, :jp20, @dim,
        "現在: #{usb_mode_name(cur)}  (#{if supported, do: "選んで「リブート実行」", else: "USB モード変更は未対応"})"),
      usb_option(@usb_opt_host, "HOST", "ハブ経由: LAN / WiFi / BLE / 音声", st.usb_sel == :host, cur == :host),
      usb_option(@usb_opt_ncm, "NCM", "母艦と直結: usb0 10.42.0.2", st.usb_sel == :ncm, cur == :ncm),
      Draw.text(div(@w, 2), 290, :mc, :jp16, @dim, "Nerves System の brain-usb-mode で切り替えて再起動します"),
      usb_button(@usb_go, "リブート実行", if(supported, do: @warn, else: @tab_off), if(supported, do: @bg, else: @dim)),
      usb_button(@usb_cancel, "キャンセル", @tab_off, @fg)
    ]
  end

  defp usb_option({x, y, w, h}, title, sub, selected, current) do
    [
      Draw.rrect(x, y, w, h, 12, if(selected, do: @panel, else: @bg)),
      Draw.rframe(x, y, w, h, 12, if(selected, do: @accent, else: @tab_off)),
      Draw.text(x + div(w, 2), y + 34, :mc, :jp32, if(selected, do: @accent, else: @fg), title <> if(current, do: " (現在)", else: "")),
      Draw.text(x + div(w, 2), y + 80, :mc, :jp16, @dim, sub)
    ]
  end

  defp usb_button({x, y, w, h}, label, bg, fg) do
    [Draw.rrect(x, y, w, h, 10, bg), Draw.text(x + div(w, 2), y + div(h, 2), :mc, :jp24, fg, label)]
  end

  defp usb_result(%{usb_msg: {:ok, sel}}) do
    [
      Draw.text(div(@w, 2), 200, :mc, :jp32, @ok, "#{usb_mode_name(sel)} に切り替えました"),
      Draw.text(div(@w, 2), 250, :mc, :jp20, @fg, "再起動します…")
    ]
  end

  defp usb_result(%{usb_msg: {:error, reason}}) do
    [
      Draw.text(div(@w, 2), 190, :mc, :jp32, @warn, "切り替えに失敗しました"),
      Draw.text(div(@w, 2), 240, :mc, :jp16, @fg, String.slice(inspect(reason), 0, 70)),
      Draw.text(div(@w, 2), 300, :mc, :jp20, @dim, "タップでホームへ戻る(DTB は変更されていません)")
    ]
  end

  defp usb_result(_), do: []

  defp kernel_str do
    case File.read("/proc/version") do
      {:ok, s} ->
        case Regex.run(~r/Linux version (\S+)/, s) do
          [_, v] -> "Linux " <> (v |> String.split("-") |> hd())
          _ -> "Linux"
        end

      _ ->
        "Linux"
    end
  end

  # ホーム画面の「メモリ」表示。書式は "使用量 / 総量 MB"。
  # 左 = MemTotal - MemAvailable(実使用、MemAvailable 基準の空きを差し引いた値)、
  # 右 = MemTotal(カーネル予約後の総 RAM。128MiB 機で約 112MB)。
  # 例: "38 / 112 MB" は「38MB 使用・空き約 74MB」。左は空きではなく使用量。
  defp mem_used_mb do
    with {:ok, s} <- File.read("/proc/meminfo"),
         %{"MemTotal" => total, "MemAvailable" => avail} <- parse_meminfo(s) do
      "#{div(total - avail, 1024)} / #{div(total, 1024)} MB"
    else
      _ -> "N/A"
    end
  end

  defp parse_meminfo(s) do
    for line <- String.split(s, "\n"), into: %{} do
      case Regex.run(~r/^(\w+):\s+(\d+)/, line) do
        [_, k, v] -> {k, String.to_integer(v)}
        _ -> {"", 0}
      end
    end
  end

  defp uptime_str do
    case File.read("/proc/uptime") do
      {:ok, s} ->
        secs = s |> String.split() |> hd() |> String.to_float() |> trunc()
        h = div(secs, 3600)
        m = div(rem(secs, 3600), 60)
        if h > 0, do: "#{h}時間#{m}分", else: "#{m}分#{rem(secs, 60)}秒"

      _ ->
        "N/A"
    end
  end

  defp loadavg_str do
    case File.read("/proc/loadavg") do
      {:ok, s} -> s |> String.split() |> Enum.take(3) |> Enum.join(" ")
      _ -> "N/A"
    end
  end

  # 電源の状態(ホームの「電源」行とヘッダの電池表示で共通):
  #   :battery 電池駆動(5V なし)/ :charging 充電中 / :full 満充電 / :supply 5V 給電のみ
  # 充電中 = Charger が実際に充電を有効にしているとき。満充電 = Charger が満充電で止めている間(5V あり・充電停止・
  # 電池 4.10 V 超。停止電圧 4.15 V は残量 100% の 4.20 V に届かないため、残量の % ではなく Charger の状態で判定)。
  # 残量(%)は、充電中は内部抵抗ぶんの電圧降下を引いた休止電圧相当で出す(引かないと約 5% 多く見える)。
  defp power_state do
    case safe_battery() do
      %{mv: mv, on_5v: on} when is_integer(mv) ->
        charging = on and HelloKioskBrain.Charger.charging?()
        adj = if charging, do: mv - HelloKioskBrain.Charger.ir_drop_mv(), else: mv
        p = HelloKioskBrain.Battery.percent_for(adj)

        state =
          cond do
            not on -> :battery
            charging -> :charging
            HelloKioskBrain.Charger.full?() -> :full
            true -> :supply
          end

        {state, p}

      _ ->
        nil
    end
  end

  # SoC の行: チップ名 + CPU(ダイ)温度。80 ℃ 以上は警告色(i.MX28 の動作上限は 85 ℃ 前後)。
  defp soc_row do
    case HelloKioskBrain.Battery.cpu_temp_c() do
      t when is_float(t) -> {"SoC", "i.MX283 (ARMv5)  #{round(t)}℃", if(t >= 80, do: @warn, else: @fg)}
      _ -> {"SoC", "i.MX283 (ARMv5)", @fg}
    end
  end

  defp power_status do
    case power_state() do
      {state, p} ->
        text =
          case state do
            :battery -> "電池 #{p}%"
            :charging -> "充電中 #{p}%"
            :full -> "満充電"
            :supply -> "給電 #{p}%"
          end

        {"電源", text, if(state == :battery, do: @fg, else: @ok)}

      _ ->
        {"電源", "N/A", @dim}
    end
  end

  # --- 設定画面と時計ダイアログ ---

  # 設定画面: ホームの「ディスプレイ」行と同じ見た目のボタン行(今は「時計」だけ。設定項目はここに足していく)
  defp settings_screen(st) do
    {x, y, w, h} = @set_clock_btn
    {clock, _col} = clock_label()

    [
      header("設定"),
      Draw.text(50, 62, :ml, :jp24, @accent, "設定"),
      Draw.line(50, 84, @w - 50, 84, @panel),
      Draw.text(50, y + div(h, 2), :ml, :jp20, @dim, "時計"),
      Draw.rframe(x, y, w, h, 8, @tab_off),
      Draw.text(x + 14, y + div(h, 2), :ml, :jp20, @ok, clock),
      Draw.text(x + w - 10, y + div(h, 2), :mr, :jp16, @accent, "設定 >"),
      Draw.text(50, 138 + div(h, 2), :ml, :jp20, @dim, "Wi-Fi"),
      Draw.rframe(elem(@set_wifi_btn, 0), elem(@set_wifi_btn, 1), elem(@set_wifi_btn, 2), elem(@set_wifi_btn, 3), 8, @tab_off),
      Draw.text(elem(@set_wifi_btn, 0) + 14, 138 + div(h, 2), :ml, :jp20, @ok, wifi_row_text()),
      Draw.text(elem(@set_wifi_btn, 0) + elem(@set_wifi_btn, 2) - 10, 138 + div(h, 2), :mr, :jp16, @accent, "設定 >"),
      Draw.text(50, 206, :ml, :jp16, @dim, "時計: ネットにつながらなくても、日付・時刻を手動で合わせられます(日本時間)。"),
      Draw.text(50, 232, :ml, :jp16, @dim, "Wi-Fi: 接続先(SSID・パスワード)を追加・変更・削除できます。つながらなければ元に自動で戻ります。"),
      settings_msgs(st)
    ]
  end

  defp wifi_row_text do
    case HelloKioskBrain.WifiConfig.list() do
      [] -> "未設定"
      nets -> "登録 #{length(nets)} 件: " <> Enum.map_join(nets, " / ", & &1.ssid)
    end
  end

  # 設定画面の下部に出す結果(時計の設定結果、Wi-Fi の保存・接続確認の結果)
  defp settings_msgs(st) do
    [
      case st.set_msg do
        {:ok, text} -> Draw.text(50, 290, :ml, :jp20, @ok, text)
        {:error, text} -> Draw.text(50, 290, :ml, :jp20, @warn, text)
        _ -> []
      end,
      case HelloKioskBrain.WifiConfig.result() do
        {:ok, text} -> Draw.text(50, 330, :ml, :jp20, @ok, text)
        {:pending, text} -> Draw.text(50, 330, :ml, :jp20, @accent, text)
        {:error, text} -> Draw.text(50, 330, :ml, :jp20, @warn, text)
        _ -> []
      end
    ]
  end

  # --- Wi-Fi ダイアログ(画面キーボード) ---

  # キー定義 {開始列, 列数, 行, 動作, ラベル}。0 行目=数字、1〜3 行目=英字(Shift で大文字)または記号、4 行目=モード・空白・「.-_」
  defp wf_keys(%{wf: wf}) do
    [r1, r2, r3] =
      cond do
        wf.sym -> ["!@#$%^&*()", "=+[]{}\\;:", "',?~|<>`/"]
        wf.shift -> ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM@/"]
        true -> ["qwertyuiop", "asdfghjkl", "zxcvbnm@/"]
      end

    chars = fn str, row, col0 ->
      for {c, i} <- Enum.with_index(String.graphemes(str)), do: {col0 + i, 1, row, {:char, c}, c}
    end

    chars.("1234567890", 0, 0) ++
      chars.(r1, 1, 0) ++
      chars.(r2, 2, 0) ++
      [{9, 1, 2, :bs, "削除"}, {0, 1, 3, :shift, "A/a"}] ++
      chars.(r3, 3, 1) ++
      [
        {0, 2, 4, :mode, if(wf.sym, do: "ABC", else: "記号")},
        {2, 5, 4, {:char, " "}, "空白"},
        {7, 1, 4, {:char, "."}, "."},
        {8, 1, 4, {:char, "-"}, "-"},
        {9, 1, 4, {:char, "_"}, "下線"}
      ]
  end

  defp wf_key_rect(col, n, row), do: {@wf_kb_x + col * @wf_pitch_x, @wf_kb_y + row * @wf_pitch_y, n * @wf_pitch_x - 4, @wf_key_h}

  defp wf_key_at(st, x, y) do
    Enum.find_value(wf_keys(st), fn {col, n, row, action, _l} ->
      if in_rect?(x, y, wf_key_rect(col, n, row)), do: action
    end)
  end

  defp wf_press(%{wf: wf} = st, action) do
    Audio.key()

    case action do
      {:char, c} ->
        wf = wf_append(wf, c)
        # 大文字(Shift)は 1 文字だけ有効。キーの表示が変わるので全面を描き直す
        if wf.shift, do: repaint(%{st | wf: %{wf | shift: false}}), else: wf_repaint_fields(%{st | wf: wf})

      :bs ->
        v = wf_value(wf)
        wf_repaint_fields(%{st | wf: wf_put(wf, String.slice(v, 0, max(String.length(v) - 1, 0)))})

      :shift ->
        if wf.sym, do: {:noreply, st}, else: repaint(%{st | wf: %{wf | shift: not wf.shift}})

      :mode ->
        repaint(%{st | wf: %{wf | sym: not wf.sym, shift: false}})
    end
  end

  defp wf_value(%{field: :ssid, ssid: v}), do: v
  defp wf_value(%{pw: v}), do: v
  defp wf_put(%{field: :ssid} = wf, v), do: %{wf | ssid: v, err: nil}
  defp wf_put(wf, v), do: %{wf | pw: v, err: nil}

  defp wf_append(wf, c) do
    max = if wf.field == :ssid, do: @wf_ssid_max, else: @wf_pw_max
    v = wf_value(wf)
    if String.length(v) >= max, do: wf, else: wf_put(wf, v <> c)
  end

  # 入力欄だけを描き直す(キーを押すたびに画面全体を描くと重いので)。`full`=true なら全面
  defp wf_repaint_fields(st, full \\ false) do
    if full do
      repaint(st)
    else
      Native.render([wf_top(st), wf_fields(st)])
      {:noreply, st}
    end
  end

  # 下部バーのタブの選択表示。「デモ」は、選択画面・Moving Icons・パパパのどれでも選択中
  defp tab_on?(:demo_menu, screen), do: screen in [:demo_menu, :demo, :papapa, :flight, :anim]
  defp tab_on?(target, screen), do: target == screen

  # --- 「デモ」の選択画面 ---

  # 選択の移動(3 列の格子。i == n は「クレジット」ボタン)
  defp demo_move(i, n, 103) when i == n, do: n - 1
  defp demo_move(i, _n, 103), do: if(i >= 3, do: i - 3, else: i)
  defp demo_move(i, n, 108) when i < n, do: if(i + 3 < n, do: i + 3, else: n)
  defp demo_move(i, n, 105) when i == n, do: n - 1
  defp demo_move(i, _n, 105), do: if(rem(i, 3) > 0, do: i - 1, else: i)
  defp demo_move(i, n, 106) when i < n - 1 and rem(i, 3) < 2, do: i + 1
  defp demo_move(i, n, 106) when i == n - 1, do: n
  defp demo_move(i, _n, _), do: i

  defp demo_card_rect(i), do: {16 + rem(i, 3) * (@demo_card_w + 15), 50 + div(i, 3) * (@demo_card_h + 12), @demo_card_w, @demo_card_h}

  defp demo_menu(st) do
    sel = Map.get(st, :demo_sel, 0)

    cards =
      for {c, i} <- Enum.with_index(@demo_cards) do
        {x, y, w, h} = demo_card_rect(i)
        ok = demo_available?(c.id)

        [
          # 物理キーで選んでいるカード: 白い太枠
          if(i == sel, do: [Draw.rframe(x - 4, y - 4, w + 8, h + 8, 14, @fg), Draw.rframe(x - 3, y - 3, w + 6, h + 6, 13, @fg)], else: []),
          Draw.rrect(x, y, w, h, 12, @panel),
          Draw.rframe(x, y, w, h, 12, if(ok, do: c.color, else: @tab_off)),
          Draw.text(x + 16, y + 30, :ml, :jp24, if(ok, do: c.color, else: @dim), c.title),
          for {line, j} <- Enum.with_index(c.desc) do
            Draw.text(x + 16, y + 64 + j * 20, :ml, :jp16, if(ok, do: @fg, else: @dim), line)
          end,
          if(ok,
            do: Draw.text(x + w - 12, y + h - 14, :mr, :jp16, @accent, ">"),
            else: Draw.text(x + w - 12, y + h - 14, :mr, :jp12, @warn, "素材なし")
          )
        ]
      end

    [
      header("デモ"),
      cards,
      Draw.text(div(@w, 2) - 60, @h - @tab_h - 16, :mc, :jp16, @dim, "矢印キーで選んで決定 / 戻るでホーム ・ 再生中はタッチ/キーで終了"),
      if(sel == length(@demo_cards),
        do: Draw.rframe(elem(@credit_btn, 0) - 4, elem(@credit_btn, 1) - 4, elem(@credit_btn, 2) + 8, elem(@credit_btn, 3) + 8, 10, @fg),
        else: []
      ),
      Draw.rrect(elem(@credit_btn, 0), elem(@credit_btn, 1), elem(@credit_btn, 2), elem(@credit_btn, 3), 8, @tab_off),
      Draw.text(elem(@credit_btn, 0) + div(elem(@credit_btn, 2), 2), elem(@credit_btn, 1) + div(elem(@credit_btn, 3), 2), :mc, :jp16, @fg, "クレジット")
    ]
  end

  # クレジット(CC BY 3.0 の表示を含む。内容は NOTICE と同じ)
  defp credits_screen do
    lines = [
      {:h, "パパパの二重唱"},
      {:l, "曲: W. A. モーツァルト《魔笛》K.620 より「パ・パ・パ」(パブリックドメイン)"},
      {:l, "伴奏: flutetunes.com 公開の編曲(MIDI)を元に作成(個人・非営利の利用に限る)"},
      {:l, "歌声(パパゲーノ): HTS Voice \"NIT ATR503 M001\""},
      {:s, "  © 2003-2012 Nagoya Institute of Technology  /  CC BY 3.0"},
      {:l, "歌声(パパゲーナ): MMDAgent Example「Mei」(mei_normal)"},
      {:s, "  © Nagoya Institute of Technology  /  CC BY 3.0"},
      {:l, "音声合成: Open JTalk(Modified BSD)"},
      {:s, "  CC BY 3.0: https://creativecommons.org/licenses/by/3.0/"},
      {:h, "そのほか"},
      {:l, "描画: LovyanGFX / キャラクター: オリジナル(スタックチャン風)"}
    ]

    {rows, _} =
      Enum.map_reduce(lines, 78, fn
        {:h, t}, y -> {Draw.text(30, y, :ml, :jp24, @accent, t), y + 36}
        {:l, t}, y -> {Draw.text(30, y, :ml, :jp16, @fg, t), y + 26}
        {:s, t}, y -> {Draw.text(30, y, :ml, :jp12, @dim, t), y + 26}
      end)

    [
      Draw.text(div(@w, 2), 30, :mc, :jp32, @fg, "クレジット"),
      Draw.line(30, 52, @w - 30, 52, @panel),
      rows,
      Draw.text(div(@w, 2), @h - 22, :mc, :jp16, @dim, "タッチ/キーで戻ります")
    ]
  end

  defp demo_available?(:papapa), do: PapapaDemo.available?()
  defp demo_available?(_), do: true

  defp demo_start(st, :camera) do
    Audio.touch()
    go(st, :camera)
  end

  defp demo_start(st, :moving_icons) do
    Audio.touch()
    go(st, :demo)
  end

  defp demo_start(st, :papapa) do
    if PapapaDemo.available?() and PapapaDemo.timeline() != nil do
      papa_start(st)
    else
      {:noreply, st}
    end
  end

  # フライトデモ: 描画ループ(:flight_tick)は 1 コマ描いたらすぐ次を予約する(送る先はメールボックスの末尾なので、
  # タッチなど先に届いたメッセージは 1 コマごとに処理される)
  defp demo_start(st, :flight) do
    Audio.touch()
    st = %{st | screen: :flight, flight: %{sim: FlightDemo.new(System.monotonic_time(:millisecond))}}
    paint(st)
    send(self(), :flight_tick)
    {:noreply, st}
  end

  defp demo_start(st, id) when is_map_key(@anim_mods, id) do
    Audio.touch()
    m = Map.fetch!(@anim_mods, id)
    Code.ensure_loaded(m)
    st = %{st | screen: :anim, anim: %{mod: m, s: m.init(System.monotonic_time(:millisecond))}}
    paint(st)
    send(self(), :anim_tick)
    {:noreply, st}
  end

  defp demo_start(st, _), do: {:noreply, st}

  # 汎用ランナーの 1 コマ: デモが返した描画と、次のコマまでの待ち(ms)
  defp anim_tick(%{anim: %{mod: m, s: s}} = st) do
    {cmds, s, delay} = m.frame(s, System.monotonic_time(:millisecond))
    if cmds != [], do: Native.render(cmds)
    if delay > 0, do: Process.send_after(self(), :anim_tick, delay), else: send(self(), :anim_tick)
    %{st | anim: %{mod: m, s: s}}
  end

  defp flight_tick(%{flight: %{sim: sim}} = st) do
    now = System.monotonic_time(:millisecond)
    sim = sim |> FlightDemo.step(now) |> FlightDemo.tick_frame(now)

    {cmds, sim} =
      if FlightDemo.instruments_due?(sim, now),
        do: {[FlightDemo.attitude(sim), FlightDemo.instruments(sim)], %{sim | inst_at: now}},
        else: {FlightDemo.attitude(sim), sim}

    Native.render(cmds)
    send(self(), :flight_tick)
    %{st | flight: %{sim: sim}}
  end

  # パパパの二重唱を始める。音は別プロセスで鳴らし(Audio.play_file)、起動の通知 `:audio_file_started` の時刻を
  # 基準に、口パク・字幕を :papa_tick で更新する(状態が変わったときだけ部分描画)。
  defp papa_start(st) do
    tl = PapapaDemo.timeline()
    Audio.demo_mode(true)
    st = %{st | screen: :papapa, papa: %{tl: tl, t0: nil, started: System.monotonic_time(:millisecond), sig: nil}}
    paint(st)

    case safe_play_file() do
      :ok ->
        Process.send_after(self(), :papa_tick, 30)
        {:noreply, st}

      _ ->
        # 出力先が無い(音が出せない)ときは始めない
        Audio.demo_mode(false)
        go(%{st | papa: nil}, :demo_menu)
    end
  end

  defp safe_play_file do
    Audio.play_file(PapapaDemo.wav_path(), self())
  catch
    :exit, _ -> :error
  end

  defp papa_tick(%{papa: p} = st) do
    now = System.monotonic_time(:millisecond)
    t = if p.t0, do: now - p.t0 - PapapaDemo.sync_offset_ms(), else: 0
    nervous = p.t0 == nil or PapapaDemo.nervous?(p.tl, t)
    parts = if p.t0, do: PapapaDemo.at(p.tl, t), else: PapapaDemo.idle_parts()
    wob = PapapaDemo.wob(now - p.started)
    sig = PapapaDemo.sig(parts, nervous, wob)

    if sig != p.sig, do: Native.render(PapapaDemo.update(parts, %{nervous: nervous, wob: wob}))

    Process.send_after(self(), :papa_tick, 20)
    %{st | papa: %{p | sig: sig}}
  end

  defp wifi_del_confirm(%{wf: wf}) do
    {yx, yy, yw, yh} = @confirm_yes
    {nx, ny, nw, nh} = @confirm_no

    [
      Draw.text(div(@w, 2), 150, :mc, :jp32, @fg, "この接続先を削除しますか?"),
      Draw.text(div(@w, 2), 210, :mc, :jp24, @accent, wf.ssid),
      Draw.text(div(@w, 2), 256, :mc, :jp16, @dim, "削除後、残りの接続先で接続し直します(つながらなければ元に戻ります)"),
      Draw.rect(yx, yy, yw, yh, @warn),
      Draw.text(yx + div(yw, 2), yy + div(yh, 2), :mc, :jp24, @bg, "削除する"),
      Draw.rect(nx, ny, nw, nh, @tab_off),
      Draw.text(nx + div(nw, 2), ny + div(nh, 2), :mc, :jp24, @fg, "キャンセル")
    ]
  end

  defp wifi_open(st, idx, ssid, pw) do
    wf = %{idx: idx, ssid: ssid, pw: pw, field: if(idx == nil, do: :ssid, else: :pw), shift: false, sym: false, show: false, err: nil}
    repaint(%{st | screen: :wifi_dialog, wf: wf, set_msg: nil})
  end

  defp wifi_save(%{wf: wf} = st) do
    case HelloKioskBrain.WifiConfig.save_and_apply(wf.idx, wf.ssid, wf.pw) do
      :ok ->
        Audio.touch()
        # 経過と結果は WifiConfig.result/0(一覧画面に表示)が持つので、ここでは別のメッセージを出さない
        go(%{st | wf: nil, set_msg: nil}, :wifi_list)

      {:error, reason} ->
        repaint(%{st | wf: %{wf | err: wifi_error(reason)}})
    end
  end

  defp wifi_delete(%{wf: wf} = st) do
    case HelloKioskBrain.WifiConfig.delete_and_apply(wf.idx) do
      :ok ->
        Audio.touch()
        go(%{st | wf: nil, set_msg: nil}, :wifi_list)

      {:error, reason} ->
        repaint(%{st | wf: %{wf | err: wifi_error(reason)}})
    end
  end

  defp wifi_error(reason) do
    case reason do
      :ssid -> "SSID は 1〜32 文字で入力してください"
      :pw -> "パスワードは 8〜63 文字で入力してください"
      :chars -> "使えない文字があります(英数字と記号。「\"」は不可)"
      :last -> "最後の 1 件は削除できません"
      :full -> "登録は #{HelloKioskBrain.WifiConfig.max_networks()} 件までです"
      other -> "保存できませんでした: #{inspect(other)}"
    end
  end

  # 登録済みの接続先の一覧(行をタップで編集)。接続中の SSID は緑で「接続中」。保存・削除の経過と結果も出す。
  defp wifi_list(st) do
    nets = HelloKioskBrain.WifiConfig.list()
    conn = HelloKioskBrain.WifiConfig.connected_ssid()
    {ax, ay, aw, ah} = @wl_add
    {cx, cy, cw, ch} = @wl_close

    rows =
      for {n, i} <- Enum.with_index(nets) do
        y = @wl_y0 + i * @wl_pitch
        on = n.ssid == conn

        [
          Draw.rrect(17, y, 820, @wl_row_h, 8, @panel),
          Draw.rframe(17, y, 820, @wl_row_h, 8, if(on, do: @ok, else: @tab_off)),
          Draw.text(31, y + div(@wl_row_h, 2), :ml, :jp24, if(on, do: @ok, else: @fg), n.ssid),
          Draw.text(820, y + div(@wl_row_h, 2), :mr, :jp16, if(on, do: @ok, else: @dim), if(on, do: "接続中 ・ 編集 >", else: "編集 >"))
        ]
      end

    [
      Draw.text(17, 28, :ml, :jp24, @accent, "Wi-Fi の接続先"),
      Draw.text(@w - 17, 28, :mr, :jp16, @dim, "登録 #{length(nets)} / #{HelloKioskBrain.WifiConfig.max_networks()} 件(タップで編集)"),
      rows,
      case st.set_msg do
        {:error, text} -> Draw.text(17, 392, :ml, :jp20, @warn, text)
        _ -> []
      end,
      case HelloKioskBrain.WifiConfig.result() do
        {:ok, text} -> Draw.text(17, 392, :ml, :jp20, @ok, text)
        {:pending, text} -> Draw.text(17, 392, :ml, :jp20, @accent, text)
        {:error, text} -> Draw.text(17, 392, :ml, :jp20, @warn, text)
        _ -> []
      end,
      Draw.rrect(ax, ay, aw, ah, 10, @tab_off),
      Draw.text(ax + div(aw, 2), ay + div(ah, 2), :mc, :jp24, @fg, "追加"),
      Draw.rrect(cx, cy, cw, ch, 10, @tab_off),
      Draw.text(cx + div(cw, 2), cy + div(ch, 2), :mc, :jp24, @fg, "閉じる")
    ]
  end

  defp wf_top(%{wf: wf}) do
    [
      Draw.rect(0, 0, @w, 34, @bg),
      Draw.text(17, 17, :ml, :jp20, @accent, if(wf.idx == nil, do: "Wi-Fi の追加", else: "Wi-Fi の編集")),
      if(wf.err, do: Draw.text(@w - 17, 17, :mr, :jp16, @warn, wf.err), else: [])
    ]
  end

  defp wf_fields(%{wf: wf}) do
    pw = if wf.show, do: wf.pw, else: String.duplicate("*", String.length(wf.pw))
    [wf_field(@wf_ssid_box, "SSID", wf.ssid, wf.field == :ssid), wf_field(@wf_pw_box, "パスワード", pw, wf.field == :pw)]
  end

  defp wf_field({x, y, w, h}, label, value, selected) do
    [
      Draw.rrect(x, y, w, h, 8, @panel),
      Draw.rframe(x, y, w, h, 8, if(selected, do: @accent, else: @tab_off)),
      Draw.text(x + 12, y + div(h, 2), :ml, :jp16, @dim, label),
      Draw.text(x + 130, y + div(h, 2), :ml, :jp20, @fg, value <> if(selected, do: "|", else: ""))
    ]
  end

  defp wifi_dialog(%{wf: wf} = st) do
    keys =
      for {col, n, row, action, label} <- wf_keys(st) do
        {x, y, w, h} = wf_key_rect(col, n, row)
        on = (action == :shift and wf.shift) or (action == :mode and wf.sym)
        dim = action == :shift and wf.sym

        [
          Draw.rrect(x, y, w, h, 8, if(on, do: @accent, else: @tab_off)),
          Draw.text(x + div(w, 2), y + div(h, 2), :mc, :jp20, cond do
            on -> @bg
            dim -> @dim
            true -> @fg
          end, label)
        ]
      end

    {sx, sy, sw, sh} = @wf_show
    {ax, ay, aw, ah} = @wf_save
    {dx, dy, dw, dh} = @wf_del
    {cx, cy, cw, ch} = @wf_cancel

    [
      wf_top(st),
      wf_fields(st),
      keys,
      Draw.rrect(sx, sy, sw, sh, 10, @tab_off),
      Draw.text(sx + div(sw, 2), sy + div(sh, 2), :mc, :jp16, @fg, if(wf.show, do: "パスワードを隠す", else: "パスワードを表示")),
      Draw.rrect(ax, ay, aw, ah, 10, @accent),
      Draw.text(ax + div(aw, 2), ay + div(ah, 2), :mc, :jp24, @bg, "保存"),
      if(wf.idx != nil,
        do: [
          Draw.rrect(dx, dy, dw, dh, 10, @tab_off),
          Draw.text(dx + div(dw, 2), dy + div(dh, 2), :mc, :jp24, @warn, "削除")
        ],
        else: []
      ),
      Draw.rrect(cx, cy, cw, ch, 10, @tab_off),
      Draw.text(cx + div(cw, 2), cy + div(ch, 2), :mc, :jp24, @fg, "キャンセル")
    ]
  end

  # 現在の日本時間(JST)から編集の初期値を作る。時刻が未設定(2024 年より前)なら 2026-01-01 09:00。
  defp clock_edit_now do
    {{y, mo, d}, {h, mi, _s}} =
      :calendar.universal_time()
      |> :calendar.datetime_to_gregorian_seconds()
      |> Kernel.+(9 * 3600)
      |> :calendar.gregorian_seconds_to_datetime()

    if y < 2024,
      do: %{year: 2026, month: 1, day: 1, hour: 9, minute: 0},
      else: %{year: y, month: mo, day: d, hour: h, minute: mi}
  end

  # 欄を 1 つ増減する。月・日・時・分は端で回り込み(日はその月の日数)、年は 2024〜2099 で止める。
  # 年/月を変えて日が月末を超えたら月末に丸める。
  defp clock_step(e, field, d) do
    e =
      case field do
        :year -> %{e | year: min(max(e.year + d, 2024), 2099)}
        :month -> %{e | month: rem(e.month - 1 + d + 12, 12) + 1}
        :day -> %{e | day: rem(e.day - 1 + d + days_in(e), days_in(e)) + 1}
        :hour -> %{e | hour: rem(e.hour + d + 24, 24)}
        :minute -> %{e | minute: rem(e.minute + d + 60, 60)}
      end

    %{e | day: min(e.day, days_in(e))}
  end

  defp days_in(%{year: y, month: m}), do: :calendar.last_day_of_the_month(y, m)

  # 編集した日本時間を UTC の UNIX 秒に直して適用(Linux 時刻 + RTC)。結果は設定画面に出す。
  defp clock_apply(st) do
    e = st.clock_edit

    epoch =
      :calendar.datetime_to_gregorian_seconds({{e.year, e.month, e.day}, {e.hour, e.minute, 0}}) -
        62_167_219_200 - 9 * 3600

    stamp = :io_lib.format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w", [e.year, e.month, e.day, e.hour, e.minute]) |> IO.iodata_to_binary()

    msg =
      case HelloKioskBrain.BrainClock.set_time(epoch) do
        :ok -> {:ok, "時計を #{stamp} に設定しました"}
        {:error, {:rtc, _}} -> {:error, "#{stamp} に設定しました(本体の時計への書き込みは失敗)"}
        {:error, reason} -> {:error, "設定できませんでした: #{inspect(reason)}"}
      end

    Audio.touch()
    go(%{st | set_msg: msg, clock_edit: nil}, :settings)
  end

  defp clock_dialog(st) do
    e = st.clock_edit
    {ax, ay, aw, ah} = @clk_apply
    {cx0, cy, cw, ch} = @clk_cancel
    labels = %{year: "年", month: "月", day: "日", hour: "時", minute: "分"}

    fields =
      for {f, cx} <- Enum.zip(@clk_fields, @clk_cx) do
        v = Map.fetch!(e, f)
        txt = if f == :year, do: Integer.to_string(v), else: v |> Integer.to_string() |> String.pad_leading(2, "0")

        [
          Draw.text(cx, 112, :mc, :jp16, @dim, labels[f]),
          Draw.rrect(cx - div(@clk_btn_w, 2), @clk_up_y, @clk_btn_w, @clk_btn_h, 10, @tab_off),
          Draw.text(cx, @clk_up_y + div(@clk_btn_h, 2), :mc, :jp32, @fg, "+"),
          Draw.text(cx, 254, :mc, :jp40, @accent, txt),
          Draw.rrect(cx - div(@clk_btn_w, 2), @clk_dn_y, @clk_btn_w, @clk_btn_h, 10, @tab_off),
          Draw.text(cx, @clk_dn_y + div(@clk_btn_h, 2), :mc, :jp32, @fg, "-")
        ]
      end

    [
      Draw.text(div(@w, 2), 54, :mc, :jp32, @fg, "日付・時刻の設定(日本時間)"),
      fields,
      Draw.text(div(@w, 2), 372, :mc, :jp16, @dim, "「設定する」を押すと秒は 0 から始まります"),
      Draw.rrect(ax, ay, aw, ah, 10, @accent),
      Draw.text(ax + div(aw, 2), ay + div(ah, 2), :mc, :jp24, @bg, "設定する"),
      Draw.rrect(cx0, cy, cw, ch, 10, @tab_off),
      Draw.text(cx0 + div(cw, 2), cy + div(ch, 2), :mc, :jp24, @fg, "キャンセル")
    ]
  end

  # 予備ボタン用の暫定画面(名前を中央に表示するだけ。後で機能を割り当てる)
  defp spare_screen(name) do
    [
      header(name),
      Draw.text(div(@w, 2), div(@h, 2), :mc, :jp40, @accent, name)
    ]
  end

  # 音声デモ(旧 予備2): 「音声時計」(タップで現在時刻)「読み上げ A-Z」「録音 5秒」「時報発声」(毎正時の時報トグル)+ 直近の発声 + 出力先。
  # 音声は USB オーディオ(Audio の直列キュー)。出力先が無いときはボタンをグレー表示し no-op。
  @vbtn_time {40, 84, 360, 110}
  @vbtn_az {454, 84, 360, 110}
  @vbtn_rec {40, 208, 360, 110}
  @vbtn_clock {454, 208, 360, 110}

  defp demo_clock_screen(%{time: t, hour: h, round: r, total: n}) do
    [
      Draw.text(div(@w, 2), 70, :mc, :jp24, @accent, "時報デモ(時計をずらしています)"),
      Draw.text(div(@w, 2), 190, :mc, :jp40, @fg, t),
      Draw.text(div(@w, 2), 280, :mc, :jp24, @dim, "#{h}:00:00.0 にチャイムの立ち上がり"),
      Draw.text(div(@w, 2), 340, :mc, :jp24, @dim, "#{r} / #{n} 回目"),
      Draw.text(div(@w, 2), 420, :mc, :jp16, @dim, "タッチで終了")
    ]
  end

  defp voice_screen(st) do
    out = Audio.output_label()
    enabled = out != nil
    {ocol, otxt} = if enabled, do: {@ok, "出力: " <> out}, else: {@warn, "出力先なし(USB オーディオ未接続)"}

    az_sub = if st.voice_az, do: "ON: キーを押すと発声", else: "OFF: タップで ON"
    clock_on = TimeSignal.enabled?()
    clock_sub = if clock_on, do: "ON: 毎正時にお知らせ", else: "OFF: タップで ON"

    [
      header("音声デモ"),
      Draw.text(40, 62, :ml, :jp24, @accent, "音声発声デモ"),
      Draw.text(@w - 40, 62, :mr, :jp16, ocol, otxt),
      voice_button(@vbtn_time, "音声時計", "「ただいま N時 M分です」", enabled, false),
      voice_button(@vbtn_az, "読み上げ A-Z", az_sub, enabled, st.voice_az),
      voice_button(@vbtn_rec, "録音 5秒", "ビープ後に話す → 再生", Recorder.available?(), st.rec_busy),
      voice_button(@vbtn_clock, "時報発声", clock_sub, enabled, clock_on),
      Draw.text(40, 350, :ml, :jp20, @dim, "最終:"),
      Draw.text(120, 350, :ml, :jp24, @fg, st.voice_last || "--"),
      Draw.text(40, 392, :ml, :jp16, @dim, "音声時計はタップで現在時刻、時報発声は ON で毎正時に「只今より N時をお知らせします」。"),
      Draw.text(40, 416, :ml, :jp16, @dim, "音声: Open JTalk(Mei)で事前生成、実機は連結再生のみ。")
    ]
  end

  defp voice_button({x, y, w, h}, title, sub, enabled, active) do
    bg = if enabled, do: @panel, else: @tab_off
    frame = cond do
      not enabled -> @dim
      active -> @ok
      true -> @tab_off
    end

    tcol = if enabled, do: @accent, else: @dim

    [
      Draw.rrect(x, y, w, h, 12, bg),
      Draw.rframe(x, y, w, h, 12, frame),
      Draw.text(x + div(w, 2), y + div(h * 36, 100), :mc, :jp32, tcol, title),
      Draw.text(x + div(w, 2), y + div(h * 76, 100), :mc, :jp16, @dim, sub)
    ]
  end

  defp voice_touch(st, x, y) do
    cond do
      in_rect?(x, y, @vbtn_time) ->
        last =
          case TimeSpeaker.speak_now() do
            {:ok, hm} -> "音声時計 " <> TimeSpeaker.label(hm)
            {:error, :clock_unset} -> "時刻未設定(NTP 未同期)"
            {:error, :unavailable} -> "出力先なし"
            {:error, other} -> "再生不可 #{inspect(other)}"
          end

        st = %{st | voice_last: last}
        paint(st)
        {:noreply, st}

      # 音声時計: 毎正時の時報の ON/OFF トグル(読み上げはしない。ON/OFF はタッチ音で確認)
      in_rect?(x, y, @vbtn_clock) ->
        on? = TimeSignal.toggle()
        Audio.touch()
        st = %{st | voice_last: if(on?, do: "時報発声 ON(毎正時にお知らせ)", else: "時報発声 OFF")}
        paint(st)
        {:noreply, st}

      in_rect?(x, y, @vbtn_rec) ->
        if Recorder.available?() and not st.rec_busy do
          Recorder.start(self())
          st = %{st | rec_busy: true, voice_last: "録音の準備…"}
          paint(st)
          {:noreply, st}
        else
          st = %{st | voice_last: if(st.rec_busy, do: "録音中です", else: "録音デバイスなし")}
          paint(st)
          {:noreply, st}
        end

      in_rect?(x, y, @vbtn_az) ->
        st = %{st | voice_az: not st.voice_az}
        paint(st)
        {:noreply, st}

      true ->
        {:noreply, st}
    end
  end

  # 予備1: SwitchBot BLE センサ画面。hello_kiosk_raspad3 の F10(SensorScreen)を参考に、
  # USB ドングル(hci0)から受信した 温湿度計(最大3)/ 気圧計piyo2 / 開閉 / 人感 を
  # 3列×2行のカードで表示。未受信/未初期化時は「受信待ち」。毎秒再描画で更新。
  @sw_cardw 266
  @sw_cardh 175
  @sw_cols [16, 294, 572]

  defp sensor_screen do
    s = HelloKioskBrain.SwitchBotScanner.get_sensors()

    {stxt, scol} =
      if HelloKioskBrain.SwitchBotScanner.scanning?(),
        do: {"BLE受信 ON", @ok},
        else: {"BLE初期化待ち", @warn}

    none? = s.meters == [] and is_nil(s.pressure) and is_nil(s.contact) and is_nil(s.motion)

    body =
      if none? do
        [
          Draw.text(div(@w, 2), 240, :mc, :jp32, @dim, "SwitchBot 受信待ち…"),
          Draw.text(div(@w, 2), 290, :mc, :jp20, @dim, "(BLEドングルの初期化を確認中)")
        ]
      else
        m = fn i -> Enum.at(s.meters, i) end

        [
          meter_card(col(0), 78, m.(0), "温湿度計1"),
          meter_card(col(1), 78, m.(1), "温湿度計2"),
          meter_card(col(2), 78, m.(2), "温湿度計3"),
          pressure_card(col(0), 260, s.pressure),
          contact_card(col(1), 260, s.contact),
          motion_card(col(2), 260, s.motion)
        ]
      end

    [
      header("BLEセンサ"),
      Draw.text(40, 60, :ml, :jp24, @accent, "SwitchBot センサ"),
      Draw.text(@w - 40, 60, :mr, :jp20, scol, stxt),
      body
    ]
  end

  defp col(i), do: Enum.at(@sw_cols, i)

  defp card_base(x, y, title) do
    [
      Draw.rrect(x, y, @sw_cardw, @sw_cardh, 10, @panel),
      Draw.rframe(x, y, @sw_cardw, @sw_cardh, 10, @tab_off),
      Draw.text(x + 14, y + 22, :ml, :jp20, @accent, title)
    ]
  end

  defp empty_card(x, y, title),
    do: [card_base(x, y, title), Draw.text(x + div(@sw_cardw, 2), y + 105, :mc, :jp32, @dim, "--")]

  defp meter_card(x, y, nil, title), do: empty_card(x, y, title)

  defp meter_card(x, y, d, title) do
    [
      card_base(x, y, title),
      Draw.text(x + @sw_cardw - 14, y + 22, :mr, :jp12, @dim, d.label),
      Draw.text(x + 14, y + 74, :ml, :jp32, @fg, "#{fmt(d.temperature)} 度"),
      Draw.text(x + 14, y + 116, :ml, :jp24, @ok, "湿度 #{fmt(d.humidity)} %"),
      Draw.text(x + 14, y + 154, :ml, :jp12, @dim, "電池 #{fmt(d.battery)}%  RSSI #{fmt(d.rssi)}")
    ]
  end

  defp pressure_card(x, y, nil), do: empty_card(x, y, "気圧 piyo2")

  defp pressure_card(x, y, d) do
    [
      card_base(x, y, "気圧 piyo2"),
      Draw.text(x + 14, y + 66, :ml, :jp20, @fg, "#{fmt(d.temperature)}度 #{fmt(d.humidity)}%"),
      Draw.text(x + 14, y + 108, :ml, :jp28, @accent, "#{fmt(d.pressure)} hPa"),
      Draw.text(x + 14, y + 154, :ml, :jp12, @dim, "電池 #{fmt(d.battery)}%  RSSI #{fmt(d.rssi)}")
    ]
  end

  defp contact_card(x, y, nil), do: empty_card(x, y, "開閉センサ")

  defp contact_card(x, y, d) do
    {c, txt} = if d.sw, do: {@warn, "開"}, else: {@ok, "閉"}

    [
      card_base(x, y, "開閉センサ"),
      Draw.text(x + 20, y + 88, :ml, :jp40, c, txt),
      Draw.text(x + 96, y + 80, :ml, :jp20, @fg, "人感 #{onoff(d.pir)}"),
      Draw.text(x + 14, y + 154, :ml, :jp12, @dim, "電池 #{fmt(d.battery)}%  RSSI #{fmt(d.rssi)}")
    ]
  end

  defp motion_card(x, y, nil), do: empty_card(x, y, "人感センサ")

  defp motion_card(x, y, d) do
    {c, txt} = if d.pir, do: {@accent, "検知"}, else: {@dim, "静止"}

    [
      card_base(x, y, "人感センサ"),
      Draw.text(x + 20, y + 88, :ml, :jp40, c, txt),
      Draw.text(x + 120, y + 80, :ml, :jp20, @fg, "明るさ #{light(d.illuminance)}"),
      Draw.text(x + 14, y + 154, :ml, :jp12, @dim, "電池 #{fmt(d.battery)}%  RSSI #{fmt(d.rssi)}")
    ]
  end

  defp onoff(true), do: "あり"
  defp onoff(_), do: "なし"

  defp light(1), do: "明"
  defp light(0), do: "暗"
  defp light(_), do: "--"

  defp fmt(nil), do: "--"
  defp fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp fmt(v), do: to_string(v)

  # タッチとキーを合わせたデモ画面: タップでタッチ音、キーでキー音(いずれも最終位置/コードを表示)。
  defp touch(st) do
    t =
      case st.last_touch do
        {x, y} -> "最終タッチ X:#{x} Y:#{y}"
        nil -> "最終タッチ なし"
      end

    k =
      case st.last_key do
        nil -> "最終キー なし"
        c -> "最終キー コード #{c}"
      end

    [
      header("タッチ/キー"),
      Draw.text(40, 70, :ml, :jp20, @dim, "どこでもタップ(タッチ音)/ キーを押す(キー音)"),
      Draw.text(40, 118, :ml, :jp24, @accent, t),
      Draw.text(40, 168, :ml, :jp24, @fg, k),
      Draw.text(40, 222, :ml, :jp16, @dim, "上段キー: ホーム1 / タッチ・キー15 / デモ104 / BLE109 / 音声110 / 設定111(左から下部バーと同順)"),
      case st.last_touch do
        {x, y} -> Draw.fcircle(x, y, 6, @accent)
        nil -> []
      end
    ]
  end

  defp tabs(st) do
    y = @h - @tab_h
    last = @bar_cells - 1

    @bar
    |> Enum.with_index()
    |> Enum.map(fn {{label, kind, target, _kc}, i} ->
      x = cell_x(i)
      # 端セルは端数ぶん右まで塗る(合計幅が @w にぴったり合わないため)
      cw = if i == last, do: @w - x, else: @cell_w - 2
      on = kind == :tab and tab_on?(target, st.screen)

      bg = if on, do: @accent, else: @tab_off

      fg =
        cond do
          on -> @bg
          kind == :power -> @warn
          kind == :spare -> @dim
          true -> @fg
        end

      [
        Draw.rect(x, y, cw, @tab_h, bg),
        Draw.text(x + div(@cell_w, 2), y + div(@tab_h, 2), :mc, :jp20, fg, label)
      ]
    end)
  end

  # ヘッダの電池表示(状態は power_state/0 で電源行と共通)。電池駆動で 15% 以下は警告色。
  defp battery_label do
    case power_state() do
      {:battery, p} -> {"電池 #{p}%", if(p <= 15, do: @warn, else: @fg)}
      {:charging, p} -> {"充電中 #{p}%", @ok}
      {:full, _p} -> {"満充電", @ok}
      {:supply, p} -> {"給電 #{p}%", @ok}
      _ -> {"電池 N/A", @dim}
    end
  end

  defp safe_battery do
    HelloKioskBrain.Battery.status()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp unbind_fbcon do
    for dir <- Path.wildcard("/sys/class/vtconsole/vtcon*"),
        File.read!(dir <> "/name") =~ "frame buffer" do
      File.write!(dir <> "/bind", "0")
    end
  rescue
    _ -> :ok
  end

  # loopback 以外の各インタフェースについて、最初の IPv4 アドレスを
  # %{"eth0" => "192.168.x.y", "wlan0" => ...} の形で返す(未取得は含めない)。
  defp ip_map do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        for {name, props} <- ifs, name != ~c"lo", into: %{} do
          v4 =
            props
            |> Keyword.get_values(:addr)
            |> Enum.find(&match?({a, _, _, _} when a != 127, &1))

          {List.to_string(name), v4 && v4 |> :inet.ntoa() |> List.to_string()}
        end
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      _ ->
        %{}
    end
  end
end
