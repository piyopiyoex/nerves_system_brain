defmodule HelloKioskBrain.Kiosk do
  @moduledoc """
  PW-SH6 KIOSK デモ(LovyanGFX NIF 描画版)。

  画面(下部バーのタップ、または物理キー: タッチ=15 / キー=104 / デモ=109 /
  予備1=110 / 予備2=111):
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

  alias HelloKioskBrain.{Draw, Input, Native, Pswitch, UsbMode}

  @tick_ms 1_000
  @w 854
  @h 480
  @tab_h 40
  # 下部バーの全セル。左から 4 タブ + 予備 2 + 電源を切る。
  #   {label, kind, target, keycode}
  #   kind: :tab(画面切替・選択ハイライトあり) / :spare(未割当のプレースホルダ) /
  #         :power(電源OFF 確認へ)
  #   keycode: 物理キー(evdev コード)。そのキーでこのセルをタップしたのと同じ動作。
  #            nil は割当なし。
  @bar [
    {"ホーム", :tab, :home, nil},
    {"タッチ", :tab, :touch, 15},
    {"キー", :tab, :keys, 104},
    {"デモ", :tab, :demo, 109},
    {"予備1", :tab, :spare1, 110},
    {"予備2", :tab, :spare2, 111},
    {"電源を切る", :power, :confirm_off, nil}
  ]
  @bar_cells length(@bar)
  # 「キー」(index 2)と「デモ」(index 3)の間にこの幅の隙間を空ける。
  # ボタン幅は全セル均等(@cell_w)のまま、デモ以降を右へずらす。
  @bar_gap 10
  @gap_index 3
  @cell_w div(@w - @bar_gap, @bar_cells)

  # 確認画面のボタン(x, y, w, h)
  @confirm_yes {220, 300, 180, 64}
  @confirm_no {460, 300, 180, 64}
  # ヘッダ左端の機種名(DTB から自動認識)の右に置く画面タイトルの開始 x / 読めないときの表示
  @title_x 110
  @model_fallback "Brain"
  # ホーム「USB」行のボタン領域(システム情報 8 行目、値の部分)と、USB 役割切替ダイアログの部品
  @usb_row_btn {196, 384, 300, 36}
  @usb_opt_host {80, 150, 330, 110}
  @usb_opt_ncm {444, 150, 330, 110}
  @usb_go {220, 330, 180, 64}
  @usb_cancel {460, 330, 180, 64}

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

    devmem = resolve_devmem()
    # 起動前の押下ラッチを掃除(いきなり確認画面が出るのを防ぐ)
    Pswitch.clear(devmem)

    st = %{
      screen: :home,
      ticks: 0,
      last_touch: nil,
      last_key: nil,
      devmem: devmem,
      # USB 役割ダイアログ: 選択中(:host | :peripheral)と結果メッセージ
      usb_sel: :host,
      usb_msg: nil
    }

    {:ok, st, {:continue, :first_render}}
  end

  @impl true
  def handle_continue(:first_render, st) do
    paint(st)
    send(self(), :tick)
    {:noreply, st}
  end

  @impl true
  def handle_info(:tick, st) do
    st = %{st | ticks: st.ticks + 1}
    st = maybe_power_button(st)

    # ヘッダの時計を進めるためデモ以外は毎秒再描画
    if st.screen != :demo, do: paint(st)

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, st}
  end

  def handle_info({:touch, x, y}, st), do: on_touch(st, x, y)
  def handle_info({:key, code, :down}, st), do: on_key(st, code)

  def handle_info(_, st), do: {:noreply, st}

  # --- 入力ディスパッチ -------------------------------------------------------

  # デモ中は NIF スレッドが画面を専有: 任意のタッチ/キーでホームへ戻る
  defp on_touch(%{screen: :demo} = st, _x, _y), do: go(st, :home)

  # 電源断中 / 5V案内画面: タップでホームへ戻れる(キャンセル/エスケープ)
  defp on_touch(%{screen: :powering_off} = st, _x, _y), do: go(st, :home)
  defp on_touch(%{screen: :needs_unplug} = st, _x, _y), do: go(st, :home)

  defp on_touch(%{screen: :confirm_off} = st, x, y) do
    cond do
      in_rect?(x, y, @confirm_yes) -> power_off(st)
      in_rect?(x, y, @confirm_no) -> go(st, :home)
      true -> {:noreply, st}
    end
  end

  # USB 役割ダイアログ: HOST / NCM の選択 → 「リブート実行」で DTB 差し替え+再起動、「キャンセル」でホームへ
  defp on_touch(%{screen: :usb_dialog} = st, x, y) do
    cond do
      in_rect?(x, y, @usb_opt_host) -> repaint(%{st | usb_sel: :host})
      in_rect?(x, y, @usb_opt_ncm) -> repaint(%{st | usb_sel: :peripheral})
      in_rect?(x, y, @usb_cancel) -> go(st, :home)
      in_rect?(x, y, @usb_go) -> usb_switch(st)
      true -> {:noreply, st}
    end
  end

  # 切替結果画面(エラー時)はタップでホームへ
  defp on_touch(%{screen: :usb_result} = st, _x, _y), do: go(st, :home)

  defp on_touch(st, x, y) do
    cond do
      y >= @h - @tab_h ->
        case bar_index_at(x) do
          nil -> {:noreply, st}
          idx -> bar_action(st, Enum.at(@bar, idx))
        end

      # ホームの「USB」行(ボタン)→ 役割切替ダイアログ
      st.screen == :home and in_rect?(x, y, @usb_row_btn) ->
        opt(HelloKioskBrain.Audio, :touch)
        cur = UsbMode.current()
        sel = if cur in [:host, :peripheral], do: cur, else: :host
        repaint(%{st | screen: :usb_dialog, usb_sel: sel, usb_msg: nil})

      true ->
        st = %{st | last_touch: {x, y}}
        if st.screen == :touch, do: paint(st)
        {:noreply, st}
    end
  end

  defp on_key(%{screen: :demo} = st, _code), do: go(st, :home)
  defp on_key(%{screen: :powering_off} = st, _code), do: go(st, :home)
  defp on_key(%{screen: :needs_unplug} = st, _code), do: go(st, :home)
  # USB ダイアログ/結果画面ではキー=キャンセル(誤操作で再起動しない)
  defp on_key(%{screen: :usb_dialog} = st, _code), do: go(st, :home)
  defp on_key(%{screen: :usb_result} = st, _code), do: go(st, :home)

  defp on_key(st, code) do
    st = %{st | last_key: code}

    # 物理キー → 下部バーのセルに紐付け(タップと同じ動作)。
    case Enum.find(@bar, fn {_l, _k, _t, kc} -> kc == code end) do
      nil ->
        # 未割当キー: KEYS 画面ならコード表示のため再描画
        if st.screen == :keys, do: paint(st)
        {:noreply, st}

      cell ->
        bar_action(st, cell)
    end
  end

  # 下部バーのセル 1 個に対する動作(タッチ・キー共通)。
  defp bar_action(st, {_label, :tab, scr, _kc}), do: go(st, scr)
  defp bar_action(st, {_label, :power, scr, _kc}), do: go(st, scr)
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
        with {:ok, _} <- File.copy(src, dst),
             :ok <- File.chmod(dst, 0o755),
             do: dst,
             else: (_ -> nil)

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
      System.cmd("/sbin/poweroff", [])
      {:noreply, st}
    end
  rescue
    e ->
      Logger.error("poweroff failed: #{inspect(e)}")
      go(st, :home)
  end

  # USB/充電器の 5V(VBUS)が来ているかを USB ガジェット(UDC)の state で判定する。
  # VBUS 無し(電池駆動)なら UDC state = "not attached"、来ていれば configured/attached 等。
  # ※ HW_POWER bit29(VDD5V_GT_VDDIO)は電池 ~3.7V でも VDDIO(3.3V)超で常に 1 になり
  #   使えない。UDC の VBUS 検出は割込駆動で即時・確実。
  # 読めない場合は 5V 無しとみなす(= poweroff を通す。電池駆動で確実に切れるように)。
  defp on_5v? do
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
    go(%{st | screen: :home}, scr)
  end

  defp go(st, :demo) do
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
    case st.screen do
      :confirm_off ->
        Native.render([Draw.clear(@bg), confirm_off()])

      :powering_off ->
        Native.render([Draw.clear(@bg), powering_off()])

      :needs_unplug ->
        Native.render([Draw.clear(@bg), needs_unplug()])

      :usb_dialog ->
        Native.render([Draw.clear(@bg), usb_dialog(st)])

      :usb_result ->
        Native.render([Draw.clear(@bg), usb_result(st)])

      screen ->
        body =
          case screen do
            :home -> home(st)
            :touch -> touch(st)
            :keys -> keys(st)
            :demo -> []
            :spare1 -> spare_screen("予備1")
            :spare2 -> spare_screen("予備2")
          end

        Native.render([Draw.clear(@bg), body, tabs(st)])
    end
  end

  defp confirm_off do
    {yx, yy, yw, yh} = @confirm_yes
    {nx, ny, nw, nh} = @confirm_no

    [
      Draw.text(div(@w, 2), 180, :mc, :jp32, @fg, "電源を切りますか?"),
      Draw.text(div(@w, 2), 240, :mc, :jp20, @dim, "「切る」を押すと電源が切れます"),
      Draw.rect(yx, yy, yw, yh, @warn),
      Draw.text(yx + div(yw, 2), yy + div(yh, 2), :mc, :jp24, @bg, "切る"),
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

    [
      Draw.rect(0, 0, @w, 40, @panel),
      # 左端: 機種名(DTB から自動認識)→ 画面タイトル
      Draw.text(12, 20, :ml, :jp24, @fg, model_name()),
      Draw.text(@title_x, 20, :ml, :jp24, @accent, title),
      # 上段: 時計(中央)・電池(右)
      Draw.text(div(@w, 2), 12, :mc, :jp16, ccol, clock),
      Draw.text(@w - 12, 12, :mr, :jp16, bcol, bat),
      # 下段: 有線 LAN(eth0、NCM 時は usb0)/ WiFi の取得 IP(取得済=緑・未取得=グレー)
      Draw.text(@w - 200, 28, :mr, :jp16, net_col(wired), "有線 " <> (wired || "なし")),
      Draw.text(@w - 12, 28, :mr, :jp16, net_col(wifi), "WiFi " <> (wifi || "なし"))
    ]
  end

  defp net_col(nil), do: @dim
  defp net_col(_), do: @ok

  # --- 機種の自動認識 ---------------------------------------------------------
  # Brain ファームは自機種名の実行ファイル(例 PW-SH6 → edsh6exe.bin = U-Boot)しか起動せず、その U-Boot が
  # fdt_file=imx28-pwsh6.dtb を内蔵しているため、Linux が受け取る DTB の model 文字列はファーム自身の機種判定の
  # 結果になる。/proc/device-tree/model で確定できる。結果は persistent_term に保持(ヘッダは毎秒描き直す)。

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

      {Calendar.strftime(ndt, "%Y-%m-%d") <> "(#{wd}) " <> Calendar.strftime(ndt, "%H:%M:%S"),
       @fg}
    end
  end

  defp home(_st) do
    {mem, up, load} = sys_dynamic()

    # 左: システム情報 / 右: サブシステム状態。ラベルと値を 2 列で整列。
    sysinfo = [
      {"モデル", dt_model() || "SHARP Brain (不明)", @fg},
      {"SoC", "i.MX283 (ARMv5)", @fg},
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
      {"ディスプレイ", "OK", @ok},
      {"タッチ", "OK", @ok},
      {"キーボード", "OK", @ok},
      {"ネットワーク", "OK", @ok},
      # オーディオ / BLE は本体アプリ(hello_kiosk_brain)のモジュールがあれば実状態、無ければ「未実装」
      audio_status(),
      # ブザー = PWM4→pwm-beeper まで Linux 側は動作するが基板配線未達で無音(worklog 20260904_タッチ音_PWM調査結論)
      {"ブザー", "非対応", @dim},
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
      # 「USB」行はボタン(タップで役割切替ダイアログ)。値の周りに枠と「切替 >」
      usb_row_button(),
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

  # --- 状態行(オプションのモジュールがあれば実状態) -----------------------------

  # 本体アプリにある Audio / BtSpeaker / SwitchBotScanner は本例に含めていない。あれば呼び、無ければ :absent。
  defp opt(mod, fun, args \\ []) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)),
      do: apply(mod, fun, args),
      else: :absent
  end

  defp audio_status do
    cond do
      opt(HelloKioskBrain.BtSpeaker, :ready?) == true -> {"オーディオ", "BT OK", @ok}
      opt(HelloKioskBrain.Audio, :output_label) == :absent -> {"オーディオ", "未実装(本例)", @dim}
      opt(HelloKioskBrain.Audio, :output_label) -> {"オーディオ", "USB OK", @ok}
      true -> {"オーディオ", "USB 未接続", @dim}
    end
  end

  defp ble_status do
    cond do
      opt(HelloKioskBrain.BtSpeaker, :configured?) == true ->
        case opt(HelloKioskBrain.BtSpeaker, :status) do
          :connected -> {"BT", "スピーカー接続", @ok}
          :unpaired -> {"BT", "ペアリング中", @warn}
          :disconnected -> {"BT", "スピーカー未接続", @warn}
          _ -> {"BT", "スタック起動待ち", @dim}
        end

      opt(HelloKioskBrain.SwitchBotScanner, :scanning?) == :absent ->
        {"BLE", "未実装(本例)", @dim}

      opt(HelloKioskBrain.SwitchBotScanner, :scanning?) == true ->
        {"BLE", "受信中", @ok}

      File.exists?("/sys/class/bluetooth/hci0") ->
        {"BLE", "初期化中", @warn}

      true ->
        {"BLE", "ドングルなし", @dim}
    end
  end

  # --- USB 役割(HOST / NCM)の表示と切替 -------------------------------------------

  # USB0 の動作モードを sysfs から判定して 1 行にする。
  #   HOST: /sys/bus/usb/devices/usb1(ルートハブ)がある → ハブ配下の機器数(ハブ自身を除く)を表示
  #   NCM : /sys/class/udc に UDC がある(peripheral DTB)→ usb0 の IP(ガジェット未リンクなら「リンク待ち」)
  defp usb_role_row do
    case UsbMode.current() do
      :host ->
        n = usb_device_count()
        {"USB", "HOST / 機器 #{n}台", if(n > 0, do: @ok, else: @warn)}

      :peripheral ->
        case ip_map()["usb0"] do
          nil -> {"USB", "NCM / リンク待ち", @warn}
          ip -> {"USB", "NCM / usb0 #{ip}", @ok}
        end

      :otg ->
        {"USB", "OTG / HOST #{usb_device_count()}台 + NCM", @ok}

      _ ->
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

  defp usb_row_button do
    {x, y, w, h} = @usb_row_btn

    [
      Draw.rframe(x, y, w, h, 8, @tab_off),
      Draw.text(x + w - 10, y + div(h, 2), :mr, :jp16, @accent, "切替 >")
    ]
  end

  defp repaint(st) do
    paint(st)
    {:noreply, st}
  end

  defp usb_switch(%{usb_sel: sel} = st) do
    opt(HelloKioskBrain.Audio, :touch)

    case UsbMode.switch_and_reboot(sel) do
      :ok -> repaint(%{st | screen: :usb_result, usb_msg: {:ok, sel}})
      {:error, reason} -> repaint(%{st | screen: :usb_result, usb_msg: {:error, reason}})
    end
  end

  defp usb_mode_name(:host), do: "HOST"
  defp usb_mode_name(:peripheral), do: "NCM"
  defp usb_mode_name(:otg), do: "OTG"
  defp usb_mode_name(_), do: "不明"

  defp usb_dialog(st) do
    cur = UsbMode.current()
    supported = UsbMode.supported?()

    [
      Draw.text(div(@w, 2), 60, :mc, :jp32, @fg, "USB の役割を切り替え"),
      Draw.text(
        div(@w, 2),
        104,
        :mc,
        :jp20,
        @dim,
        "現在: #{usb_mode_name(cur)}  (#{if supported, do: "選んで「リブート実行」", else: "この機種は非対応(#{UsbMode.model_code() || "?"})"})"
      ),
      usb_option(
        @usb_opt_host,
        "HOST",
        "ハブ経由: LAN / WiFi / BLE / 音声",
        st.usb_sel == :host,
        cur == :host
      ),
      usb_option(
        @usb_opt_ncm,
        "NCM",
        "母艦と直結: usb0 / VintageNetDirect",
        st.usb_sel == :peripheral,
        cur == :peripheral
      ),
      Draw.text(
        div(@w, 2),
        290,
        :mc,
        :jp16,
        @dim,
        "boot 領域の imx28-pwsh6.dtb を差し替えて再起動します(両方同時には使えません)"
      ),
      usb_button(
        @usb_go,
        "リブート実行",
        if(supported, do: @warn, else: @tab_off),
        if(supported, do: @bg, else: @dim)
      ),
      usb_button(@usb_cancel, "キャンセル", @tab_off, @fg)
    ]
  end

  defp usb_option({x, y, w, h}, title, sub, selected, current) do
    [
      Draw.rrect(x, y, w, h, 12, if(selected, do: @panel, else: @bg)),
      Draw.rframe(x, y, w, h, 12, if(selected, do: @accent, else: @tab_off)),
      Draw.text(
        x + div(w, 2),
        y + 34,
        :mc,
        :jp32,
        if(selected, do: @accent, else: @fg),
        title <> if(current, do: " (現在)", else: "")
      ),
      Draw.text(x + div(w, 2), y + 80, :mc, :jp16, @dim, sub)
    ]
  end

  defp usb_button({x, y, w, h}, label, bg, fg) do
    [
      Draw.rrect(x, y, w, h, 10, bg),
      Draw.text(x + div(w, 2), y + div(h, 2), :mc, :jp24, fg, label)
    ]
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

  # 稼働ごとに変化する情報(/proc から取得)。render 毎(1秒)に読むが軽量。
  defp sys_dynamic do
    {mem_used_mb(), uptime_str(), loadavg_str()}
  end

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

  defp power_status do
    case safe_battery() do
      %{percent: p, on_5v: on} when is_integer(p) ->
        src = if on, do: "充電中", else: "電池"
        {"電源", "#{src} #{p}%", if(on, do: @ok, else: @fg)}

      _ ->
        {"電源", "N/A", @dim}
    end
  end

  # 予備ボタン用の暫定画面(名前を中央に表示するだけ。後で機能を割り当てる)
  defp spare_screen(name) do
    [
      header(name),
      Draw.text(div(@w, 2), div(@h, 2), :mc, :jp40, @accent, name)
    ]
  end

  defp touch(st) do
    readout =
      case st.last_touch do
        {x, y} -> "最終タッチ X:#{x} Y:#{y}"
        nil -> "最終タッチ なし"
      end

    [
      header("タッチデモ"),
      Draw.text(40, 70, :ml, :jp20, @dim, "どこでもタップしてください"),
      Draw.text(40, 110, :ml, :jp24, @accent, readout),
      case st.last_touch do
        {x, y} -> Draw.fcircle(x, y, 6, @accent)
        nil -> []
      end
    ]
  end

  defp keys(st) do
    readout =
      case st.last_key do
        nil -> "最終キー なし"
        c -> "最終キー コード #{c}"
      end

    [
      header("キーボードデモ"),
      Draw.text(40, 80, :ml, :jp20, @dim, "いずれかのキーを押してください"),
      Draw.text(40, 150, :ml, :jp32, @fg, readout),
      Draw.text(40, 220, :ml, :jp20, @dim, "キー タッチ15/キー104/デモ109/予備110・111")
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
      on = kind == :tab and st.screen == target

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

  defp battery_label do
    case safe_battery() do
      %{percent: p, on_5v: on} when is_integer(p) ->
        mark = if on, do: "+", else: ""

        col =
          cond do
            on -> @ok
            p <= 15 -> @warn
            true -> @fg
          end

        {"電池#{mark}#{p}%", col}

      _ ->
        {"電池 N/A", @dim}
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

  # eth0(USB 有線 LAN)/ usb0(USB-NCM)どちらでも拾えるよう、loopback 以外で
  # IPv4 を持つ最初のインタフェースのアドレスを返す。
  # インタフェース名 → IPv4 文字列(lo 以外、最初のアドレス)
  defp ip_map do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        for {name, props} <- ifs,
            name != ~c"lo",
            {a, b, c, d} <-
              Keyword.get_values(props, :addr)
              |> Enum.filter(&match?({_, _, _, _}, &1))
              |> Enum.take(1),
            into: %{},
            do: {List.to_string(name), "#{a}.#{b}.#{c}.#{d}"}

      _ ->
        %{}
    end
  end
end
