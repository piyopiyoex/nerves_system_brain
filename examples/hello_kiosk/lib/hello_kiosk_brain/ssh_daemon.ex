defmodule HelloKioskBrain.SshDaemon do
  @moduledoc """
  SSH daemon on port 22 using OTP's built-in :ssh (no external deps).

  Startup cost matters here: the whole box is one ARMv5 core and the render
  NIF shares the single dirty-CPU scheduler with crypto's dirty NIFs, so any
  heavy crypto at daemon start directly stalls touch/paint.

  Two measures keep startup cheap (2026-09-05, measured on device):
  - password auth uses `pwdfun` (plain compare), NOT `user_passwords`.
    With `user_passwords`, OTP hashes the password (and a decoy checker) with
    PBKDF2 inside :ssh.daemon — 35 s of dirty-CPU on this hardware, which
    queued ahead of the render NIF and made touch lag for ~40 s after boot.
    With `pwdfun` the same call is ~0.1 s.
  - the lazily-loaded crypto/public_key/ssh modules (~6 s of SD reads) are
    preloaded one by one with small sleeps in between, so no single burst
    blocks the touch path; :ssh.daemon then starts instantly.

  The daemon start is still delayed a little (@boot_delay_ms) and off the
  init path (send_after), so the UI paints first; it retries on a timer if
  crypto isn't ready yet (crng is up ~3 s after power on kernel 6.1, so in
  practice the first try succeeds).

  - host keys / authorized_keys are shipped in priv/ssh
  - public key auth (host machine's key) + password fallback (user/brain)
  - IEx shell, direct exec (`ssh user@host '<expr>'`), and SFTP subsystem
  """
  use GenServer
  require Logger

  @retry_ms 3_000

  # UI(初回描画 ~1 秒)が立ってから SSH を準備する。重い処理は pwdfun 化と
  # モジュール分散ロードで解消済みなので、遅延は「起動直後の描画を邪魔しない」
  # ための短いマージンで足りる(旧 25s は PBKDF2 問題への対症療法だった)。
  @boot_delay_ms 10_000

  # SD からの遅延ロード1件ごとに挟む小休止。ロード自体は 0.1-0.5 秒/件の
  # 塊になるため、間を空けてタッチイベント処理に CPU を譲る。
  @preload_gap_ms 15

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :try_start_delayed, @boot_delay_ms)
    {:ok, %{daemon: nil}}
  end

  @impl true
  def handle_info(:try_start_delayed, state), do: {:noreply, try_start(state)}
  def handle_info(:retry, state), do: {:noreply, try_start(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp try_start(%{daemon: pid} = state) when is_pid(pid), do: state

  defp try_start(state) do
    preload_modules()

    priv = :code.priv_dir(:hello_kiosk_brain)
    system_dir = priv |> Path.join("ssh") |> String.to_charlist()

    opts = [
      system_dir: system_dir,
      user_dir: system_dir,
      # user_passwords は使わない(PBKDF2 で起動が 35 秒止まる。@moduledoc 参照)
      pwdfun: &check_password/2,
      # the shell fun must return the pid that owns the channel lifetime;
      # {IEx, :start, []} returns immediately and the channel closes.
      shell: fn _user, _peer -> spawn(fn -> IEx.Server.run([]) end) end,
      exec: {:direct, &exec_elixir/1},
      subsystems: [:ssh_sftpd.subsystem_spec(cwd: ~c"/", root: ~c"/")]
    ]

    try do
      case :ssh.daemon(22, opts) do
        {:ok, pid} ->
          Logger.info("SSH daemon up on 22")
          %{state | daemon: pid}

        {:error, reason} ->
          Logger.warning("SSH daemon start failed: #{inspect(reason)}; retrying")
          Process.send_after(self(), :retry, @retry_ms)
          state
      end
    catch
      kind, reason ->
        Logger.warning("SSH daemon crashed: #{inspect({kind, reason})}; retrying")
        Process.send_after(self(), :retry, @retry_ms)
        state
    end
  end

  defp check_password(user, password) do
    user == ~c"user" and password == ~c"brain"
  end

  defp preload_modules do
    for app <- [:crypto, :asn1, :public_key, :ssh],
        {:ok, mods} = :application.get_key(app, :modules),
        mod <- mods do
      :code.ensure_loaded(mod)
      Process.sleep(@preload_gap_ms)
    end

    :ok
  rescue
    e -> Logger.warning("ssh module preload: #{inspect(e)}")
  end

  defp exec_elixir(cmd) do
    {result, _binding} = Code.eval_string(to_string(cmd))
    {:ok, inspect(result) <> "\n"}
  rescue
    e -> {:error, inspect(e) <> "\n"}
  end
end
