defmodule HelloKioskBrain.UsbMode do
  @moduledoc """
  USB0 の役割(HOST / NCM ガジェット)の判定と切り替え。

  役割は Device Tree の `dr_mode` で決まり、U-Boot が読む boot パーティションの `imx28-<機種>.dtb` を
  `priv/dtb/<機種>-host.dtb` / `<機種>-peripheral.dtb` で置き換えて再起動することで切り替える
  (`priv/dtb/README.md`)。起動後の役割は sysfs から判定する:

    * `:host`       … `/sys/bus/usb/devices/usb1`(EHCI ルートハブ)あり、UDC なし
    * `:peripheral` … `/sys/class/udc/*`(ci_hdrc UDC)あり、ルートハブなし → System が NCM gadget を作り VintageNetDirect が usb0 を管理
    * `:otg` / `:unknown`

  書き換えは boot FAT を `/tmp/hkb_boot` に mount → 一時名にコピー → rename → umount(FAT 上の rename で差し替え、
  途中で電源が落ちても元の DTB が残る)。書き込み後に読み戻して md5 を照合する。
  """
  require Logger

  @boot_dev "/dev/mmcblk1p1"
  @mnt "/tmp/hkb_boot"

  @type mode :: :host | :peripheral | :otg | :unknown

  @doc "現在動作中の USB0 の役割(sysfs)。"
  @spec current() :: mode
  def current do
    host? = File.exists?("/sys/bus/usb/devices/usb1")
    udc? = match?({:ok, [_ | _]}, File.ls("/sys/class/udc"))

    cond do
      host? and udc? -> :otg
      host? -> :host
      udc? -> :peripheral
      true -> :unknown
    end
  end

  @doc "機種コード(\"pwsh6\" など)。DT の compatible \"sharp,pw-sh6\" から。"
  def model_code do
    case File.read("/proc/device-tree/compatible") do
      {:ok, bin} ->
        bin
        |> String.split(<<0>>, trim: true)
        |> Enum.find_value(fn
          "sharp,pw-" <> rest -> "pw" <> String.replace(rest, "-", "")
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  @doc "この機種の切り替え用 DTB が priv にあるか。"
  def supported?, do: dtb_path(:host) != nil and dtb_path(:peripheral) != nil

  @doc "boot パーティションに今書かれている DTB がどちらか(md5 で判定)。判定不能は :unknown。"
  def staged do
    with_boot(fn boot ->
      target = Path.join(boot, target_name())

      case File.read(target) do
        {:ok, bin} ->
          h = :crypto.hash(:md5, bin)

          Enum.find_value([:host, :peripheral], :unknown, fn m ->
            case dtb_path(m) && File.read(dtb_path(m)) do
              {:ok, ref} -> if :crypto.hash(:md5, ref) == h, do: m
              _ -> nil
            end
          end)

        _ ->
          :unknown
      end
    end)
    |> case do
      {:ok, m} -> m
      _ -> :unknown
    end
  end

  @doc """
  DTB を `mode` 用に差し替える(再起動はしない)。戻り値 `:ok` / `{:error, reason}`。
  """
  @spec switch(:host | :peripheral) :: :ok | {:error, term()}
  def switch(mode) when mode in [:host, :peripheral] do
    case dtb_path(mode) do
      nil ->
        {:error, :unsupported_model}

      src ->
        with_boot(fn boot ->
          target = Path.join(boot, target_name())
          tmp = target <> ".new"
          {:ok, ref} = File.read(src)

          with :ok <- File.write(tmp, ref),
               :ok <- File.rename(tmp, target),
               {:ok, back} <- File.read(target),
               true <- back == ref || {:error, :verify_mismatch} do
            Logger.info("UsbMode: #{target_name()} <- #{Path.basename(src)} (#{mode})")
            :ok
          else
            {:error, _} = e -> e
            other -> {:error, other}
          end
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:ok, other} -> other
          err -> err
        end
    end
  end

  @doc "DTB を差し替えて 1.5 秒後に再起動する。"
  def switch_and_reboot(mode) do
    case switch(mode) do
      :ok ->
        spawn(fn ->
          Process.sleep(1_500)
          System.cmd("/sbin/reboot", [])
        end)

        :ok

      err ->
        err
    end
  end

  # --- helpers ---

  defp target_name, do: "imx28-#{model_code() || "pwsh6"}.dtb"

  defp dtb_path(mode) do
    case model_code() do
      nil ->
        nil

      code ->
        p =
          Path.join([to_string(:code.priv_dir(:hello_kiosk_brain)), "dtb", "#{code}-#{mode}.dtb"])

        if File.exists?(p), do: p
    end
  end

  # boot FAT を rw で mount して fun.(mnt) を実行、必ず umount する。
  defp with_boot(fun) do
    File.mkdir_p!(@mnt)

    case System.cmd("/bin/mount", ["-t", "vfat", "-o", "rw,noatime", @boot_dev, @mnt],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        try do
          {:ok, fun.(@mnt)}
        rescue
          e -> {:error, e}
        after
          System.cmd("/bin/umount", [@mnt], stderr_to_stdout: true)
        end

      {out, rc} ->
        {:error, {:mount, rc, String.trim(out)}}
    end
  end
end
