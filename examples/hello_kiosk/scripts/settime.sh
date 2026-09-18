#!/bin/bash
# Set the Brain's clock from the host over SSH (UTC), then store it to the RTC
# if one exists. The KIOSK header shows JST derived from UTC, and treats a
# pre-2024 clock as "unset" — run this after boot if the device has no
# battery-backed RTC.
set -eu
HOST=user@10.42.0.2
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

NOW=$(date -u '+%Y-%m-%d %H:%M:%S')
ssh $SSH_OPTS $HOST "{out, rc} = System.cmd(\"date\", [\"-u\", \"-s\", \"$NOW\"], stderr_to_stdout: true); IO.puts(\"date rc=#{rc} #{String.trim(out)}\"); if File.exists?(\"/dev/rtc0\") do {o2, r2} = System.cmd(\"hwclock\", [\"-w\", \"-u\"], stderr_to_stdout: true); IO.puts(\"hwclock rc=#{r2} #{String.trim(o2)}\") else IO.puts(\"no rtc\") end"
