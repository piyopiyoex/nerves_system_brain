defmodule HelloKioskBrain.Pswitch do
  @moduledoc """
  電源ボタン(i.MX28 PSWITCH)の押下検出。

  電源ボタンはキーボードマトリクス外の PSWITCH(HW_POWER 直結)で、押下は
  `HW_POWER_CTRL`(0x80044000)の PSWITCH_IRQ ビット(bit20)にラッチされる
  (カーネル割込は無効)。ここを devmem で読み、ラッチを検出したら CLR で
  クリアして true を返す。Kiosk が tick 毎に呼ぶ想定。
  """
  import Bitwise

  @ctrl 0x80044000
  @ctrl_clr 0x80044008
  # PSWITCH_IRQ = bit20
  @pswitch_irq 0x0010_0000

  @doc """
  PSWITCH_IRQ を確認し、立っていればクリアして `true`(押下あり)。
  それ以外は `false`。devmem が無い/エラー時も `false`。
  """
  def check_and_clear(devmem) when is_binary(devmem) do
    case read(devmem, @ctrl) do
      {:ok, v} when (v &&& @pswitch_irq) != 0 ->
        write(devmem, @ctrl_clr, @pswitch_irq)
        true

      _ ->
        false
    end
  end

  def check_and_clear(_), do: false

  @doc "起動時などにラッチを掃除する(押下履歴の取りこぼしを避ける)"
  def clear(devmem) when is_binary(devmem), do: write(devmem, @ctrl_clr, @pswitch_irq)
  def clear(_), do: :error

  defp read(devmem, addr) do
    case System.cmd(devmem, ["0x" <> Integer.to_string(addr, 16)], stderr_to_stdout: true) do
      {out, 0} ->
        s = out |> String.trim() |> String.replace_prefix("0x", "")

        case Integer.parse(s, 16) do
          {v, _} -> {:ok, v}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp write(devmem, addr, val) do
    System.cmd(devmem, [
      "0x" <> Integer.to_string(addr, 16),
      "0x" <> Integer.to_string(val, 16)
    ])

    :ok
  rescue
    _ -> :error
  end
end
