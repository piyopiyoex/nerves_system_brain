defmodule HelloKioskBrainTest do
  use ExUnit.Case

  doctest HelloKioskBrain

  test "greets the world" do
    assert HelloKioskBrain.hello() == :world
  end

  test "SSH password fallback keeps the PW-SH6 lightweight credentials" do
    assert HelloKioskBrain.SshAuth.check_password("user", "brain")
    assert HelloKioskBrain.SshAuth.check_password(~c"user", ~c"brain")
    refute HelloKioskBrain.SshAuth.check_password("user", "wrong")
    refute HelloKioskBrain.SshAuth.check_password("other", "brain")
  end

  test "SSH IEx dot file enables the standard Nerves helpers" do
    dot_iex = Path.expand("../rootfs_overlay/etc/iex.exs", __DIR__)
    {:ok, quoted} = Code.string_to_quoted(File.read!(dot_iex))

    {_quoted, helpers} =
      Macro.prewalk(quoted, %{motd: false, toolshed: false}, fn
        {{:., _, [{:__aliases__, _, [:NervesMOTD]}, :print]}, _, []} = node, acc ->
          {node, %{acc | motd: true}}

        {:use, _, [{:__aliases__, _, [:Toolshed]}]} = node, acc ->
          {node, %{acc | toolshed: true}}

        node, acc ->
          {node, acc}
      end)

    assert helpers == %{motd: true, toolshed: true}
  end

  test "Draw preserves the KIOSK API while producing LovyanGFX commands" do
    assert HelloKioskBrain.Draw.clear(0x00182F) == {:fill_screen, {:rgb888, 0x00182F}}

    assert HelloKioskBrain.Draw.rect(1, 2, 3, 4, "50dc78") ==
             {:fill_rect, 1, 2, 3, 4, {:rgb888, 0x50DC78}}

    assert HelloKioskBrain.Draw.text(10, 20, :mc, :jp24, 0xFFFFFF, "日本語") == [
             {:set_text_datum, :middle_center},
             {:set_text_color, {:rgb888, 0xFFFFFF}},
             {:draw_string, "日本語", 10, 20, :japan_gothic_24}
           ]
  end

  test "all Draw commands are accepted by LovyanGFX" do
    commands = [
      HelloKioskBrain.Draw.clear(0),
      HelloKioskBrain.Draw.rect(1, 2, 3, 4, 0x112233),
      HelloKioskBrain.Draw.frame(1, 2, 3, 4, 0x112233),
      HelloKioskBrain.Draw.rrect(1, 2, 3, 4, 1, 0x112233),
      HelloKioskBrain.Draw.rframe(1, 2, 3, 4, 1, 0x112233),
      HelloKioskBrain.Draw.line(1, 2, 3, 4, 0x112233),
      HelloKioskBrain.Draw.circle(1, 2, 3, 0x112233),
      HelloKioskBrain.Draw.fcircle(1, 2, 3, 0x112233),
      HelloKioskBrain.Draw.text(1, 2, "tl", "jp8", 0x112233, "Brain")
    ]

    assert {:ok, normalized} = commands |> List.flatten() |> LovyanGFX.Command.normalize()
    assert length(normalized) == 11
  end
end
