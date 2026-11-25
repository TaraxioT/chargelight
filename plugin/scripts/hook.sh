#!/bin/sh
# Forward a Claude Code hook event (JSON on stdin) to `chargelight hook`,
# which maps it to an LED state. Prints nothing and always exits 0, so it
# can never disturb Claude Code. Does nothing when chargelight is missing.

if [ -n "${CHARGELIGHT_BIN:-}" ]; then
  bin=$CHARGELIGHT_BIN
elif command -v chargelight >/dev/null 2>&1; then
  bin=chargelight
else
  # Claude Code launched from the Dock may have a minimal PATH.
  for bin in /opt/homebrew/bin/chargelight /usr/local/bin/chargelight "$HOME/.local/bin/chargelight"; do
    [ -x "$bin" ] && break
  done
fi

command -v "$bin" >/dev/null 2>&1 || exit 0
"$bin" hook >/dev/null 2>&1
exit 0
