defmodule HelloKioskBrainTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  doctest HelloKioskBrain

  test "greets the world" do
    assert HelloKioskBrain.hello() == :world
  end

  test "SSH IEx MOTD describes the target and runtime" do
    output = capture_io(fn -> HelloKioskBrain.IExHelpers.motd() end)

    assert output =~ "SHARP Brain PW-SH6"
    assert output =~ "hello_kiosk_brain 0.1.0"
    assert output =~ "Elixir #{System.version()} / OTP #{:erlang.system_info(:otp_release)}"
  end

  test "SSH IEx dot file imports helper functions" do
    dot_iex = Path.expand("../priv/iex.exs", __DIR__)
    {:ok, quoted} = Code.string_to_quoted(File.read!(dot_iex))

    assert Macro.prewalk(quoted, false, fn
             {:import, _, [{:__aliases__, _, [:HelloKioskBrain, :IExHelpers]}]} = node, _acc ->
               {node, true}

             node, acc ->
               {node, acc}
           end)
           |> elem(1)
  end
end
