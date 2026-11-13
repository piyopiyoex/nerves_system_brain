defmodule HelloKioskBrain.Mixer do
  @moduledoc """
  スピーカー音量・マイク感度を 10 段階(0〜10)で扱う。tinymix のコントロールを出力カードごとに引き当て、
  段階 n を `round(max * n / 10)` に写像して書く。設定は `/data/hello_kiosk/kiosk_settings.term`(Erlang term)に保存し、
  カードが現れたとき `apply_saved/1` で復元する。

    * 本体(ROHM BU26154): `Playback Volume`(0〜25)/ `Mic Capture Volume`(0〜7)
    * USB オーディオ(GeneralPlus 等): `Speaker Playback Volume`(0〜30、左右)/ `Mic Capture Volume`(0〜28)
    * BT スピーカー: ミキサなし(スピーカー本体の音量で調整)→ `controls/1` が nil
  """
  alias HelloKioskBrain.Audio

  @tinymix "/usr/bin/tinymix"
  @settings_path "/data/hello_kiosk/kiosk_settings.term"
  @steps 10
  # マイクは本体コーデックの既定 4/7 だと ほぼ無音(-69dBFS)、7/7 で音声レベルになる(実機確認)→ 既定は最大
  @defaults %{vol: 5, mic: 10, route: :speaker}

  @doc "現在の出力カードのコントロール定義。無ければ nil。"
  def controls(card \\ Audio.current_card())

  # 本体は出力先(Speaker / Headphone、`Output Route`)で音量コントロールが別: Speaker=Playback Volume(0〜25)、
  # Headphone=Headphone Playback Volume(ドライバは 0〜120、PDATT の 0x6f+v、0.5dB 刻みで 0=mute、120=-12dB)。ヘッドフォンは段階 1〜10 を 60〜144(-42〜0dB)へ線形に写像し 0 は消音(`hp_value/1`)。ドライバの上限は 0xe7(-12dB)だと小さすぎたため 0xff(0dB、PDATT 最大)まで拡張(カーネルパッチ)。
  def controls(%{id: "BrainBU26154", card: n}) do
    vol = if route() == :headphone, do: {"Headphone Playback Volume", 144, 1}, else: {"Playback Volume", 25, 1}
    %{card: n, vol: vol, mic: {"Mic Capture Volume", 7, 1}, route: true}
  end

  def controls(%{card: n}),
    do: %{card: n, vol: {"Speaker Playback Volume", 30, 2}, mic: {"Mic Capture Volume", 28, 1}}

  def controls(nil), do: nil

  @doc "本体の出力先(:speaker | :headphone)。保存済み、既定は :speaker。"
  def route, do: Map.get(load(), :route, @defaults.route)

  @doc "本体の出力先を切り替えて保存・反映する。音量は切替先のコントロールへ同じ段階で再設定する。"
  def set_route(r) when r in [:speaker, :headphone] do
    save(Map.put(load(), :route, r))
    apply_route(Audio.current_card())
    apply_kind(:vol, level(:vol))
    r
  end

  @doc """
  本体コーデックのアナログ出力段ゲイン(`Playback Volume` 0〜25)の聞き比べ用テスト。現在の出力先で
  「起動しました」をアナログ 2 → 13 → 25 の順に 3 回再生し、終わったら保存済みの設定へ戻す(キー 56 で実行)。
  ヘッドフォンでは経路のアナログ段が -24dB のままだと小さいことがある(実機の調査用)。
  """
  def analog_test do
    with %{id: "BrainBU26154", card: c} <- Audio.current_card(), true <- File.exists?(@tinymix) do
      # テスト前のアナログ値を控えて、終了後に戻す(ヘッドフォン経路ではこの値は段階に連動しないため、apply_saved では戻らない)
      {out, _} = System.cmd(@tinymix, ["-D", Integer.to_string(c), "get", "Playback Volume"], stderr_to_stdout: true)
      before = case Integer.parse(String.trim(out)) do {n, _} -> n; _ -> 2 end

      for v <- [2, 13, 25] do
        System.cmd(@tinymix, ["-D", Integer.to_string(c), "set", "Playback Volume", Integer.to_string(v)], stderr_to_stdout: true)
        Audio.startup()
        Process.sleep(3_300)
      end

      System.cmd(@tinymix, ["-D", Integer.to_string(c), "set", "Playback Volume", Integer.to_string(before)], stderr_to_stdout: true)
      apply_saved()
    end

    :ok
  end

  @doc "段階数(10)。"
  def steps, do: @steps

  @doc "保存済みの段階(0〜10)。kind は :vol | :mic。"
  def level(kind), do: Map.get(load(), kind, @defaults[kind])

  @doc "段階を設定して即反映・保存する。範囲外はクランプ。戻り値 新しい段階。"
  def set(kind, n) when kind in [:vol, :mic] do
    n = n |> max(0) |> min(@steps)
    save(Map.put(load(), kind, n))
    apply_async(kind)
    n
  end

  # tinymix は 1 回約 130 ms(ARM926 の fork+exec)。タップのたびに同期で実行すると画面の反応が重くなるので、
  # 別プロセスで適用する。連打は最後の値だけ反映する(適用中に来た要求は、終わってから最新の保存値で再適用)。
  defp apply_async(kind) do
    name = :"mixer_apply_#{kind}"

    case Process.whereis(name) do
      pid when is_pid(pid) -> send(pid, :again)
      nil -> spawn(fn -> run_worker(kind, name) end)
    end

    :ok
  end

  defp run_worker(kind, name) do
    Process.register(self(), name)
    apply_loop(kind)
    Process.unregister(name)

    # 登録を外す直前に届いた要求を取りこぼさない
    receive do
      :again -> run_worker(kind, name)
    after
      0 -> :ok
    end
  rescue
    # 別の worker が先に登録済み: そちらへ再適用を依頼して終わる
    ArgumentError -> if pid = Process.whereis(name), do: send(pid, :again)
  end

  defp apply_loop(kind) do
    apply_kind(kind, level(kind))

    receive do
      :again ->
        drain()
        apply_loop(kind)
    after
      0 -> :ok
    end
  end

  defp drain do
    receive do
      :again -> drain()
    after
      0 -> :ok
    end
  end

  @doc """
  保存済みの設定を現在のカードへ反映(カード出現時・起動時)。
  本体コーデックは出力先(`Output Route`: Speaker / Headphone)がドライバ既定の **Headphone** で起動するため、
  保存済みの出力先(既定 Speaker)を先に設定する(再起動のたびに Headphone へ戻るのでスピーカーが鳴らない、実機確認)。
  """
  def apply_saved(card \\ Audio.current_card()) do
    apply_route(card)
    for kind <- [:vol, :mic], do: apply_kind(kind, level(kind), card)
    :ok
  end

  defp apply_route(%{id: "BrainBU26154", card: c}) do
    name = if route() == :headphone, do: "Headphone", else: "Speaker"

    if File.exists?(@tinymix),
      do: System.cmd(@tinymix, ["-D", Integer.to_string(c), "set", "Output Route", name], stderr_to_stdout: true)

    :ok
  end

  defp apply_route(_), do: :ok

  defp apply_kind(kind, n, card \\ Audio.current_card()) do
    with %{card: c} = ctl <- controls(card), true <- File.exists?(@tinymix) do
      {name, max, ch} = Map.fetch!(ctl, kind)
      v = Integer.to_string(value_for(name, max, n))
      System.cmd(@tinymix, ["-D", Integer.to_string(c), "set", name | List.duplicate(v, ch)], stderr_to_stdout: true)
    end

    :ok
  end

  # 段階 n(0〜10)→ コントロール値。通常は線形。ヘッドフォンは 1〜10 を 60〜max に写像して 0 だけ消音
  # (線形だと下位段階が -48dB 以下で聞こえない)。
  defp value_for("Headphone Playback Volume", max, n), do: hp_value(max, n)
  defp value_for(_name, max, n), do: round(max * n / @steps)

  defp hp_value(_max, 0), do: 0
  defp hp_value(max, n), do: round(60 + (max - 60) * (n - 1) / (@steps - 1))

  @doc "整数の設定値を 1 つ読む(明るさなど他モジュールが `/data/hello_kiosk/kiosk_settings.term` を共有する)。"
  def get_setting(key, default), do: Map.get(load(), key, default)

  @doc "整数の設定値を 1 つ保存する。"
  def put_setting(key, value) when is_atom(key) and is_integer(value), do: save(Map.put(load(), key, value))

  # 設定はメモリ(:persistent_term)に保持し、ファイル(SD)への保存は別プロセスで行う。SD への書き込みは約 70 ms かかり、
  # 音量の +/- を押すたびに同期で保存すると画面の反応が重くなっていた。読み込みは初回だけファイルから。
  @cache_key {__MODULE__, :settings}

  defp load do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        map = load_file()
        :persistent_term.put(@cache_key, map)
        map

      map ->
        map
    end
  end

  defp load_file do
    case File.read(@settings_path) do
      {:ok, bin} ->
        case Code.string_to_quoted(bin) do
          {:ok, {:%{}, _, kv}} -> for {k, v} <- kv, is_atom(k), is_integer(v) or v in [:speaker, :headphone], into: %{}, do: {k, v}
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save(map) do
    if :persistent_term.get(@cache_key, nil) != map, do: :persistent_term.put(@cache_key, map)
    persist_async()
    :ok
  end

  # ファイルへの保存(最新のメモリの内容を書く)。連打は 1 回にまとめる(apply_async と同じ仕組み)。
  defp persist_async do
    case Process.whereis(:mixer_persist) do
      pid when is_pid(pid) -> send(pid, :again)
      nil -> spawn(&run_persist/0)
    end

    :ok
  end

  defp run_persist do
    Process.register(self(), :mixer_persist)
    persist_loop()
    Process.unregister(:mixer_persist)

    receive do
      :again -> run_persist()
    after
      0 -> :ok
    end
  rescue
    ArgumentError -> if pid = Process.whereis(:mixer_persist), do: send(pid, :again)
  end

  defp persist_loop do
    map = :persistent_term.get(@cache_key, %{})

    try do
      File.mkdir_p!(Path.dirname(@settings_path))
      File.write(@settings_path, inspect(map) <> "\n")
    rescue
      _ -> :ok
    end

    receive do
      :again ->
        drain()
        persist_loop()
    after
      0 -> :ok
    end
  end
end
