defmodule HelloKioskBrainTest do
  use ExUnit.Case
  doctest HelloKioskBrain

  test "greets the world" do
    assert HelloKioskBrain.hello() == :world
  end
end
