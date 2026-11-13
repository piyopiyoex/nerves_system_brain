defmodule HelloKioskBrain.WifiConfig do
  @moduledoc """
  Wi-Fi profile editor for the Nerves Kiosk, backed by VintageNet.

  Unlike the upstream standalone Kiosk, this implementation does *not* modify
  `/etc/wpa_supplicant.conf`, kill `wpa_supplicant`, or reset the USB bus.
  VintageNet owns persistence and interface life cycle.

  New configurations are applied without persistence first. If a Wi-Fi dongle
  is present, the application verifies association and an IPv4 address for up
  to 90 seconds. Only a verified configuration is persisted; failures revert
  the previous running configuration. If no Wi-Fi interface exists, the new
  profile is saved for when one is plugged in, without claiming verification.

  Passwords are never returned by `list/0` and are never logged. Leaving a
  password blank when editing a saved profile preserves the existing PSK.
  """
  require Logger

  @ifname "wlan0"
  @result_key {__MODULE__, :result}
  @max_networks 6
  @verify_s 90

  @doc "Maximum number of profiles shown in the built-in UI."
  def max_networks, do: @max_networks

  @doc "List profiles with blank passwords so saved credentials are not displayed."
  def list do
    profiles()
    |> Enum.with_index()
    |> Enum.map(fn {n, idx} ->
      %{idx: idx, ssid: Map.get(n, :ssid, ""), psk: "", priority: Map.get(n, :priority, 0)}
    end)
  end

  @doc "Read the currently associated SSID, if available."
  def connected_ssid do
    case System.cmd("/usr/bin/iw", ["dev", @ifname, "link"], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/^\s*SSID: (.+)$/m, out) do
          [_, ssid] -> String.trim(ssid)
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "Last asynchronous validation result for the settings page."
  def result, do: :persistent_term.get(@result_key, nil)

  @doc "Validate WPA2-PSK SSID / passphrase for this on-device editor."
  def validate(ssid, psk) when is_binary(ssid) and is_binary(psk) do
    cond do
      not printable?(ssid) or not printable?(psk) -> {:error, :chars}
      byte_size(ssid) not in 1..32 -> {:error, :ssid}
      byte_size(psk) not in 8..63 -> {:error, :pw}
      true -> :ok
    end
  end

  def validate(_, _), do: {:error, :chars}

  @doc "Add or edit a Wi-Fi profile using VintageNet, with connection rollback."
  def save_and_apply(idx, ssid, psk) do
    with {:ok, old} <- current_config(),
         old_profiles = networks(old),
         :ok <- check_index(idx, old_profiles),
         :ok <- check_capacity(idx, old_profiles),
         {:ok, profile} <- new_profile(idx, old_profiles, ssid, psk),
         updated <- replace_profile(old_profiles, idx, profile),
         :ok <- start_update(old, updated, {:ssid, ssid}) do
      :ok
    end
  end

  @doc "Remove a stored profile, refusing to delete the last profile."
  def delete_and_apply(idx) do
    with {:ok, old} <- current_config(),
         prev = networks(old),
         true <- length(prev) > 1 || {:error, :last},
         :ok <- check_existing_index(idx, prev),
         removed <- Enum.at(prev, idx),
         updated <- List.delete_at(prev, idx),
         :ok <- start_update(old, updated, {:deleted, Map.get(removed, :ssid, "")}) do
      :ok
    end
  end

  defp new_profile(idx, prev, ssid, psk) do
    previous = if is_integer(idx), do: Enum.at(prev, idx), else: nil

    # A blank password means "keep existing credentials". Do not downgrade
    # existing WPA3/EAP profiles or expose their secrets to the UI.
    cond do
      previous != nil and psk == "" ->
        case validate_ssid(ssid) do
          :ok -> {:ok, previous |> Map.put(:ssid, ssid) |> Map.put(:priority, 20)}
          error -> error
        end

      true ->
        with :ok <- validate(ssid, psk) do
          {:ok,
           (previous || %{})
           |> Map.put(:ssid, ssid)
           |> Map.put(:key_mgmt, :wpa_psk)
           |> Map.put(:psk, psk)
           |> Map.put(:priority, 20)
           |> Map.delete(:sae_password)}
        end
    end
  end

  defp validate_ssid(ssid) do
    cond do
      not printable?(ssid) -> {:error, :chars}
      byte_size(ssid) not in 1..32 -> {:error, :ssid}
      true -> :ok
    end
  end

  defp check_index(nil, _prev), do: :ok
  defp check_index(idx, prev), do: check_existing_index(idx, prev)

  defp check_existing_index(idx, prev)
       when is_integer(idx) and idx >= 0 and idx < length(prev), do: :ok
  defp check_existing_index(_, _), do: {:error, :range}

  defp check_capacity(nil, prev) when length(prev) >= @max_networks, do: {:error, :full}
  defp check_capacity(_, _), do: :ok

  defp replace_profile(prev, nil, profile), do: prev ++ [profile]
  defp replace_profile(prev, idx, profile), do: List.replace_at(prev, idx, profile)

  defp profiles do
    case current_config() do
      {:ok, config} -> networks(config)
      _ -> []
    end
  end

  defp networks(config) do
    case Map.get(config, :vintage_net_wifi) do
      %{networks: profiles} when is_list(profiles) -> profiles
      _ -> []
    end
  end

  defp current_config do
    {:ok, VintageNet.get_configuration(@ifname)}
  rescue
    e -> {:error, {:vintage_net_unavailable, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:vintage_net_unavailable, reason}}
  end

  defp start_update(old, profiles, target) do
    # Prevent two UI operations from racing while the first is being checked.
    case result() do
      {:pending, _} -> {:error, :busy}
      _ -> do_start_update(old, profiles, target)
    end
  end

  defp do_start_update(old, profiles, target) do
    config =
      old
      |> Map.put(:type, VintageNetWiFi)
      |> Map.put(:ipv4, %{method: :dhcp})
      |> Map.put(:vintage_net_wifi, Map.put(Map.get(old, :vintage_net_wifi) || %{}, :networks, profiles))

    case VintageNet.configure(@ifname, config, persist: false) do
      :ok ->
        label = case target do
          {:ssid, ssid} -> "Wi-Fi「#{ssid}」を確認しています…"
          {:deleted, ssid} -> "Wi-Fi「#{ssid}」の削除を確認しています…"
        end

        put_result({:pending, label})
        # Do not block the Kiosk GenServer while the radio reassociates.
        case Task.start(fn -> verify_and_commit(config, old, target) end) do
          {:ok, _pid} -> :ok
          {:error, reason} ->
            VintageNet.configure(@ifname, old, persist: false)
            put_result({:error, "接続確認を開始できませんでした"})
            {:error, reason}
        end

      {:error, _} = error ->
        error
    end
  catch
    :exit, reason -> {:error, {:vintage_net_unavailable, reason}}
  end

  defp verify_and_commit(config, old, target) do
    radio_present = File.exists?("/sys/class/net/#{@ifname}")

    verified =
      if radio_present do
        Enum.any?(1..@verify_s, fn _ ->
          if associated?(target) and has_ipv4?() do
            true
          else
            Process.sleep(1_000)
            false
          end
        end)
      else
        :not_checked
      end

    if verified == true or verified == :not_checked do
      case VintageNet.configure(@ifname, config) do
        :ok ->
          suffix = if verified == :not_checked, do: " (Wi-Fi 機器なし・未確認)", else: " (接続確認済み)"
          put_result({:ok, "Wi-Fi の設定を保存しました" <> suffix})

        {:error, error} ->
          Logger.warning("WifiConfig: persistence failed: #{inspect(error)}")
          VintageNet.configure(@ifname, old, persist: false)
          put_result({:error, "保存に失敗したため設定を戻しました"})
      end
    else
      # The previous persisted configuration is still intact.
      VintageNet.configure(@ifname, old, persist: false)
      put_result({:error, "接続を確認できず、元の設定に戻しました"})
    end
  rescue
    e ->
      Logger.warning("WifiConfig: verification failed: #{Exception.message(e)}")
      safe_restore(old)
      put_result({:error, "接続確認に失敗し、設定を戻しました"})
  catch
    :exit, _reason ->
      safe_restore(old)
      put_result({:error, "接続確認が中断され、設定を戻しました"})
  end

  defp associated?({:ssid, ssid}), do: connected_ssid() == ssid
  defp associated?({:deleted, ssid}) do
    connected = connected_ssid()
    connected != nil and connected != ssid
  end

  defp has_ipv4? do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        case List.keyfind(ifaces, String.to_charlist(@ifname), 0) do
          {_, options} ->
            Enum.any?(options, fn
              {:addr, {a, b, c, d}} when a in 1..223 and b in 0..255 and c in 0..255 and d in 0..255 -> true
              _ -> false
            end)

          nil -> false
        end

      _ -> false
    end
  end

  defp safe_restore(old) do
    VintageNet.configure(@ifname, old, persist: false)
  catch
    :exit, _ -> :ok
  end

  defp printable?(s), do: s |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E and &1 != ?"))
  defp put_result(status), do: :persistent_term.put(@result_key, status)
end
