defmodule HelloKioskBrain.Display do
  @moduledoc """
  KIOSK display: dark background, title, IP address top-right (raspad3 style),
  uptime bottom-left. Redraws only the dynamic areas every second.
  """
  use GenServer

  alias HelloKioskBrain.Fb

  @tick_ms 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    unbind_fbcon()
    {:ok, fd} = Fb.open()

    bg = Fb.color(0, 24, 48)
    fg = Fb.color(255, 255, 255)
    accent = Fb.color(255, 160, 0)

    Fb.fill_screen(fd, bg)

    title = "NERVES ON BRAIN"
    tw = Fb.text_width(title, 5)
    Fb.draw_text(fd, div(Fb.width() - tw, 2), 150, title, accent, bg, 5)

    sub = "PW-SH6 / OTP 29 / ELIXIR"
    sw = Fb.text_width(sub, 2)
    Fb.draw_text(fd, div(Fb.width() - sw, 2), 210, sub, fg, bg, 2)

    state = %{fd: fd, bg: bg, fg: fg, accent: accent, ticks: 0, last_ip: nil}
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{fd: fd, bg: bg, fg: fg, accent: accent, ticks: n} = state) do
    # 右上: usb0 の IP（変化したときだけ再描画 = チラつき防止）
    ip = ip_string()

    if ip != state.last_ip do
      iw = Fb.text_width(ip, 2)
      Fb.fill_rect(fd, Fb.width() - 300, 8, 300 - 12, Fb.text_height(2), bg)
      Fb.draw_text(fd, Fb.width() - iw - 16, 8, ip, accent, bg, 2)
    end

    # 左下: 稼働秒数
    up = "UP " <> Integer.to_string(n) <> " S"
    Fb.draw_text(fd, 16, Fb.height() - 24, up, fg, bg, 2)

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | ticks: n + 1, last_ip: ip}}
  end

  # fbcon(カーネルコンソール)を fb0 から切り離す。放置するとログ文字列が
  # KIOSK 画面に上書きされ続ける(実機確認 2026-09-02)。
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
  defp ip_string do
    case first_ipv4() do
      {:ok, addr} -> addr |> :inet.ntoa() |> List.to_string()
      :error -> "NO IP"
    end
  end

  defp first_ipv4 do
    with {:ok, ifs} <- :inet.getifaddrs() do
      ifs
      |> Enum.reject(fn {name, _props} -> name == ~c"lo" end)
      |> Enum.find_value(:error, fn {_name, props} ->
        props
        |> Keyword.get_values(:addr)
        |> Enum.find(&match?({a, _, _, _} when a != 127, &1))
        |> case do
          nil -> nil
          a -> {:ok, a}
        end
      end)
    else
      _ -> :error
    end
  end
end
