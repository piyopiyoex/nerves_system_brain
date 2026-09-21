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
end
