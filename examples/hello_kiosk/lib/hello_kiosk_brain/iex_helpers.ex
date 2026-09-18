defmodule HelloKioskBrain.IExHelpers do
  @moduledoc """
  Helpers imported into SSH IEx sessions.
  """

  @doc false
  def motd do
    app_vsn = :hello_kiosk_brain |> Application.spec(:vsn) |> to_string()
    otp_vsn = :erlang.system_info(:otp_release) |> to_string()

    IO.puts("""

    SHARP Brain PW-SH6
    hello_kiosk_brain #{app_vsn}
    Elixir #{System.version()} / OTP #{otp_vsn}
    """)

    :ok
  end

  @doc """
  Closes the current SSH IEx session without stopping the VM.
  """
  def quit do
    IO.puts("bye")

    group_leader = Process.group_leader()

    spawn(fn ->
      Process.sleep(10)
      Process.exit(group_leader, :kill)
    end)

    IEx.dont_display_result()
  end
end
