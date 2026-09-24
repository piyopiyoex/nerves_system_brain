defmodule HelloKioskBrain.SshAuth do
  @moduledoc """
  PW-SH6-specific lightweight password fallback for NervesSSH.

  The previous OTP `:ssh` implementation showed that `user_passwords` triggers
  expensive PBKDF2 work on this single-core ARMv5 target. Keep the plain
  `pwdfun` callback while the standard NervesSSH path is being validated.
  """

  @doc false
  def check_password(user, password) do
    normalize(user) == "user" and normalize(password) == "brain"
  end

  defp normalize(value) when is_binary(value), do: value
  defp normalize(value) when is_list(value), do: List.to_string(value)
  defp normalize(_value), do: ""
end
