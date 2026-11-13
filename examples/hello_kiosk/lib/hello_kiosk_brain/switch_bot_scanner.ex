defmodule HelloKioskBrain.SwitchBotScanner do
  @moduledoc """
  SwitchBot BLE 温湿度計のパッシブスキャン(HCI over USB を Erlang `:socket` で直接制御)。

  RasPad3 版(hello_kiosk_raspad3)は RPi4 内蔵 BT を UART で叩くが、Brain は USB ドングル
  (RTL8761BU / btusb → hci0)なので **AF_BLUETOOTH の HCI USER チャネル**でソケットを開く。
  HCI イベント/広告レポートの解析と SwitchBot デコードは RasPad3 版を踏襲(温湿度計のみ)。

  hci0 が未初期化(ファーム未ロード等でコントローラ無応答)でも例外を出さず、
  `get_devices/0` は空マップを返し、周期的に再接続を試みる。画面は「受信待ち」を表示する。
  """
  use GenServer
  import Bitwise
  require Logger

  # AF_BLUETOOTH=31, SOCK_RAW=3(:raw), BTPROTO_HCI=1, HCI_CHANNEL_USER=1
  @af_bluetooth 31
  @btproto_hci 1
  @hci_channel_user 1

  @reconnect_ms 5_000
  @stale_seconds 600

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "受信済みデバイス %{addr_string => map}。未接続時は空。"
  def get_devices do
    GenServer.call(__MODULE__, :get_devices, 2000)
  catch
    :exit, _ -> %{}
  end

  @doc """
  種別ごとに分類したセンサ値。%{meters: [..最大3..], pressure: map|nil,
  contact: map|nil, motion: map|nil}。未接続時は全て空/nil。
  """
  def get_sensors do
    GenServer.call(__MODULE__, :get_sensors, 2000)
  catch
    :exit, _ -> %{meters: [], pressure: nil, contact: nil, motion: nil}
  end

  @doc "現在スキャン中(ソケット接続済み)か。"
  def scanning? do
    GenServer.call(__MODULE__, :scanning?, 1000)
  catch
    :exit, _ -> false
  end

  # --- GenServer ---

  @impl true
  def init(_) do
    send(self(), :connect)
    {:ok, %{socket: nil, reader: nil, devices: %{}}}
  end

  @impl true
  def handle_call(:get_devices, _from, state) do
    {:reply, decode_meters(state.devices), state}
  end

  def handle_call(:get_sensors, _from, state) do
    {:reply, categorize(state.devices), state}
  end

  def handle_call(:scanning?, _from, state), do: {:reply, state.socket != nil, state}

  @impl true
  def handle_info(:connect, %{socket: nil} = state) do
    case try_connect() do
      {:ok, sock} ->
        parent = self()
        reader = spawn_link(fn -> read_loop(sock, parent) end)
        Logger.info("SwitchBotScanner: hci0 scan started")
        {:noreply, %{state | socket: sock, reader: reader}}

      {:error, :bt_speaker_mode} ->
        Process.send_after(self(), :connect, 60_000)
        {:noreply, state}

      {:error, reason} ->
        Logger.info("SwitchBotScanner: connect deferred (#{inspect(reason)})")
        Process.send_after(self(), :connect, @reconnect_ms)
        {:noreply, state}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  # reader からの生 HCI イベント(0x04 ...)
  def handle_info({:hci, bin}, state) do
    {:noreply, %{state | devices: ingest(bin, state.devices)}}
  end

  # reader 終了 → ソケットを畳んで再接続
  def handle_info({:reader_down, reason}, state) do
    Logger.info("SwitchBotScanner: reader down (#{inspect(reason)}); reconnecting")
    if state.socket, do: :socket.close(state.socket)
    Process.send_after(self(), :connect, @reconnect_ms)
    {:noreply, %{state | socket: nil, reader: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # --- 接続 ---

  defp try_connect do
    # BT スピーカー出力モード(/root/bt_speaker.conf あり)では bluetoothd が hci0 を管理するため
    # USER チャネルは取れない(EBUSY)。試さずに諦め、再試行の間隔を長くする。
    with true <- not HelloKioskBrain.BtSpeaker.configured?() or {:error, :bt_speaker_mode},
         true <- File.exists?("/sys/class/bluetooth/hci0") or {:error, :no_hci0},
         {:ok, sock} <- :socket.open(@af_bluetooth, :raw, @btproto_hci),
         :ok <- bind_user(sock, 0) do
      # HCI Reset → Event Mask(LE Meta 有効化)→ LE Event Mask(広告レポート有効化)
      # → LE Scan Params(passive)→ Scan Enable。イベントマスクを設定しないと
      # コントローラは広告レポートを一切上げてこない(要注意)。
      all_ones = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
      hci(sock, 0x03, 0x0c, <<>>)
      drain(sock, 200)
      hci(sock, 0x01, 0x0c, all_ones)
      drain(sock, 100)
      hci(sock, 0x01, 0x20, all_ones)
      drain(sock, 100)
      # アクティブスキャン(type=1)。温湿度計は温湿度を Manufacturer Data(0x0969)で、
      # 種別/電池を Service Data(0xFD3D)を scan response で返すため、両方拾って統合する。
      hci(sock, 0x0b, 0x20, <<1, 0x10, 0, 0x10, 0, 0, 0>>)
      drain(sock, 100)
      hci(sock, 0x0c, 0x20, <<1, 0>>)
      {:ok, sock}
    else
      {:error, _} = e -> e
      false -> {:error, :no_hci0}
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  end

  defp bind_user(sock, dev) do
    :socket.bind(sock, %{family: @af_bluetooth, addr: <<dev::native-16, @hci_channel_user::native-16>>})
  end

  defp hci(sock, op_lo, op_hi, payload) do
    :socket.send(sock, <<1, op_lo, op_hi, byte_size(payload)>> <> payload)
  end

  defp drain(sock, ms) do
    case :socket.recv(sock, 0, ms) do
      {:ok, _} -> drain(sock, ms)
      _ -> :ok
    end
  end

  # reader プロセス: ブロッキング recv でイベントを親へ転送。エラーで終了→親が再接続。
  defp read_loop(sock, parent) do
    case :socket.recv(sock, 0, 2000) do
      {:ok, bin} ->
        send(parent, {:hci, bin})
        read_loop(sock, parent)

      {:error, :timeout} ->
        read_loop(sock, parent)

      {:error, reason} ->
        send(parent, {:reader_down, reason})
    end
  end

  # --- HCI イベント → 広告レポート → SwitchBot デコード ---

  defp ingest(<<0x04, 0x3E, _len, 0x02, num, rest::binary>>, devices),
    do: parse_reports(num, rest, devices)

  defp ingest(_, devices), do: devices

  defp parse_reports(0, _rest, devices), do: devices

  defp parse_reports(k, <<_evt_type, _addr_type, addr::binary-size(6), dlen, rest::binary>>, devices)
       when byte_size(rest) >= dlen + 1 do
    <<ad::binary-size(^dlen), rssi::signed-8, remaining::binary>> = rest
    {svc, mfr} = collect_fields(ad, nil, nil)
    devices = store_raw(svc, mfr, addr, rssi, devices)
    parse_reports(k - 1, remaining, devices)
  end

  defp parse_reports(_k, _rest, devices), do: devices

  defp collect_fields(<<>>, svc, mfr), do: {svc, mfr}

  defp collect_fields(<<len, rest::binary>>, svc, mfr) when len > 0 and byte_size(rest) >= len do
    <<field::binary-size(^len), remaining::binary>> = rest

    {svc2, mfr2} =
      case field do
        <<0x16, 0x3D, 0xFD, d::binary>> -> {d, mfr}
        <<0xFF, 0x69, 0x09, d::binary>> -> {svc, d}
        _ -> {svc, mfr}
      end

    collect_fields(remaining, svc2, mfr2)
  end

  defp collect_fields(_, svc, mfr), do: {svc, mfr}

  # 生の Service/Manufacturer データをデバイス毎に統合保存(svc は scan response、
  # mfr は ADV と別パケットで届くため、非 nil の方を上書きせず前回値と合成)。
  defp store_raw(nil, nil, _addr, _rssi, devices), do: devices

  defp store_raw(svc, mfr, addr, rssi, devices) do
    key = addr_string(addr)
    prev = Map.get(devices, key, %{svc: nil, mfr: nil})

    Map.put(devices, key, %{
      svc: svc || prev.svc,
      mfr: mfr || prev.mfr,
      addr: addr,
      rssi: rssi,
      last_seen: System.monotonic_time(:second)
    })
  end

  # 温湿度計(Service Data の dev_type が 0x54/0x77/0x69)だけを対象に、Manufacturer
  # Data から温度/湿度を、Service Data から電池を得る。他種(開閉0x64/人感0x73 等)は除外。
  defp decode_meters(devices) do
    now = System.monotonic_time(:second)

    devices
    |> Enum.filter(fn {_k, r} ->
      now - r.last_seen <= @stale_seconds and meter?(r.svc) and is_binary(r.mfr) and
        byte_size(r.mfr) >= 11
    end)
    |> Enum.map(fn {k, r} -> {k, decode_meter(r.svc, r.mfr, r.rssi)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp meter?(<<dt, _::binary>>) when dt in [0x54, 0x77, 0x69], do: true
  defp meter?(_), do: false

  defp decode_meter(svc, mfr, rssi) do
    <<_m0, _m1, _m2, _m3, id_hi, id_lo, _b1, _b2, temp_dec, temp_int_sign, humidity, _::binary>> = mfr

    temp_int = temp_int_sign &&& 0x7F
    temp_frac = temp_dec &&& 0x0F
    sign = if (temp_int_sign &&& 0x80) != 0, do: 1, else: -1
    temp = Float.round((temp_int + temp_frac / 10.0) * sign, 1)

    battery =
      case svc do
        <<_dev, _status, batt, _::binary>> -> batt &&& 0x7F
        _ -> nil
      end

    %{id: id_hi * 256 + id_lo, temperature: temp, humidity: humidity &&& 0x7F, battery: battery, rssi: rssi}
  rescue
    _ -> nil
  end

  # 全種を分類。hello_kiosk_raspad3 の categorize を踏襲(温湿度計最大3・気圧piyo2・開閉・人感)。
  defp categorize(devices) do
    now = System.monotonic_time(:second)

    decoded =
      for {key, r} <- devices,
          now - r.last_seen <= @stale_seconds,
          is_binary(r.svc),
          is_binary(r.mfr),
          d = decode_device(r.svc, r.mfr, r.rssi, r.addr),
          not is_nil(d),
          into: %{},
          do: {key, Map.put(d, :label, short_mac(key))}

    meters =
      decoded
      |> Enum.filter(fn {_k, d} -> d.type in [:meter, :meter_outdoor] end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {_k, d} -> d end)
      |> Enum.take(3)

    %{
      meters: meters,
      pressure: find_type(decoded, :meter_pressure),
      contact: find_type(decoded, :contact),
      motion: find_type(decoded, :motion)
    }
  end

  defp find_type(decoded, type) do
    Enum.find_value(decoded, fn {_k, d} -> if d.type == type, do: d end)
  end

  # {dev_type, svc長, mfr長} で種別確定(raspad3 準拠)。addr は piyo2 判定に使用。
  defp decode_device(<<dev_type, _::binary>> = svc, mfr, rssi, addr) do
    case {dev_type, byte_size(svc), byte_size(mfr)} do
      {0x54, 6, 11} ->
        if piyo2_addr_match?(mfr, addr),
          do: decode_pressure(svc, mfr, rssi),
          else: decode_meter(svc, mfr, rssi) |> tag(:meter)

      {0x54, 6, 13} ->
        if piyo2_addr_match?(mfr, addr), do: decode_pressure_longlife(svc, mfr, rssi), else: nil

      {0x77, 3, 12} ->
        decode_meter(svc, mfr, rssi) |> tag(:meter_outdoor)

      {0x69, _, m} when m >= 11 ->
        decode_meter(svc, mfr, rssi) |> tag(:meter)

      {0x64, 9, 13} ->
        decode_contact(svc, mfr, rssi)

      {0x73, 6, 10} ->
        decode_motion(svc, mfr, rssi)

      _ ->
        nil
    end
  end

  defp decode_device(_, _, _, _), do: nil

  defp tag(nil, _type), do: nil
  defp tag(map, type), do: Map.put(map, :type, type)

  defp piyo2_addr_match?(mfr, addr)
       when is_binary(mfr) and is_binary(addr) and byte_size(mfr) >= 6 and byte_size(addr) == 6,
       do: binary_part(mfr, 0, 6) == addr

  defp piyo2_addr_match?(_, _), do: false

  # 気圧計 piyo2(nRF54L15 + BMP280)。mfr に気圧(p_lo,p_hi)を追加保持。
  defp decode_pressure(svc, mfr, rssi) do
    <<_m0, _m1, _m2, _m3, id_hi, id_lo, p_lo, p_hi, temp_dec, temp_int_sign, humidity, _::binary>> = mfr
    base = decode_meter(svc, mfr, rssi)
    _ = {temp_dec, temp_int_sign, humidity}

    base &&
      base
      |> Map.merge(%{type: :meter_pressure, id: id_hi * 256 + id_lo, pressure: p_lo + p_hi * 256})
  rescue
    _ -> nil
  end

  defp decode_pressure_longlife(svc, mfr, rssi) do
    <<_m0, _m1, _m2, _m3, _id_hi, _id_lo, _s0, _s1, _td, _tis, _hum, p_hi, p_lo>> = mfr
    base = decode_meter(svc, mfr, rssi)
    base && Map.merge(base, %{type: :meter_pressure, pressure: div(p_hi * 256 + p_lo, 10)})
  rescue
    _ -> nil
  end

  # 開閉センサ(0x64)。開閉(sw)・人感(pir)・電池。
  defp decode_contact(svc, mfr, rssi) do
    <<_m0, _m1, _m2, _m3, id_hi, id_lo, _::binary>> = mfr

    {pir, sw, battery} =
      case svc do
        <<_dev, flags1, batt, flags2, _pt_hi, _pt_lo, _st_hi, _st_lo, _btn>> ->
          {(flags1 &&& 0x40) != 0, (flags2 &&& 0x02) != 0, batt &&& 0x7F}

        _ ->
          {false, false, nil}
      end

    %{type: :contact, id: id_hi * 256 + id_lo, pir: pir, sw: sw, battery: battery, rssi: rssi}
  rescue
    _ -> nil
  end

  # 人感センサ(0x73)。検知(pir)・明るさ(illuminance)・電池。
  defp decode_motion(svc, mfr, rssi) do
    <<_m0, _m1, _m2, _m3, id_hi, id_lo, _::binary>> = mfr

    {pir, battery, illuminance} =
      case svc do
        <<_dev, flags, batt, _pt_hi, _pt_lo, illum>> ->
          {(flags &&& 0x40) != 0, batt &&& 0x7F, (illum &&& 0x03) - 1}

        _ ->
          {false, nil, nil}
      end

    %{type: :motion, id: id_hi * 256 + id_lo, pir: pir, illuminance: illuminance, battery: battery, rssi: rssi}
  rescue
    _ -> nil
  end

  defp short_mac(key) when is_binary(key),
    do: key |> String.split(":") |> Enum.take(-2) |> Enum.join(":")

  defp short_mac(_), do: "?"

  # BLE アドレスはリトルエンディアン。表示は上位→下位に並べ替えて 16 進コロン区切り。
  defp addr_string(<<a, b, c, d, e, f>>) do
    [f, e, d, c, b, a]
    |> Enum.map(&(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> Enum.join(":")
    |> String.upcase()
  end

end
