#!/bin/bash
# Generate the SSH host key + authorized_keys for the on-device :ssh daemon.
# These files are git-ignored (secrets / PII); run this once after cloning.
set -eu
cd "$(dirname "$0")/.."

mkdir -p priv/ssh

if [ ! -f priv/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -q -t rsa -b 2048 -m PEM -N "" -f priv/ssh/ssh_host_rsa_key
  echo "generated priv/ssh/ssh_host_rsa_key"
else
  echo "priv/ssh/ssh_host_rsa_key already exists — keeping it"
fi

if [ ! -f priv/ssh/authorized_keys ]; then
  if [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    cp "$HOME/.ssh/id_rsa.pub" priv/ssh/authorized_keys
    echo "authorized_keys <- ~/.ssh/id_rsa.pub"
  else
    echo "no ~/.ssh/id_rsa.pub found — put your public key in priv/ssh/authorized_keys"
    echo "(password auth user/brain still works as a fallback)"
    : > priv/ssh/authorized_keys
  fi
fi

chmod 700 priv/ssh
chmod 600 priv/ssh/ssh_host_rsa_key
echo "done."
