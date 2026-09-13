defmodule HelloKioskBrain.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello_kiosk_brain,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh],
      mod: {HelloKioskBrain.Application, []}
    ]
  end

  # ERTS は同梱しない: ターゲット(PW-SH6)の /usr/lib/erlang (OTP 29) を使う。
  # BEAM バイトコードはアーキテクチャ非依存なのでクロスコンパイル不要。
  defp releases do
    [
      hello_kiosk_brain: [
        include_erts: false,
        strip_beams: true,
        quiet: true
      ]
    ]
  end
end
