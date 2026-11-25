#!/bin/sh
# SessionStart (startup) check. When chargelight is missing or cannot drive
# the LED yet, print a systemMessage telling the user how to set it up, at
# most once a day. Prints nothing when everything works, and nothing on
# machines that are not Apple Silicon Macs. Always exits 0.

[ "$(uname -s)" = Darwin ] || exit 0
[ "$(uname -m)" = arm64 ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || exit 0

# Once a day at most. Without a data directory, stay quiet rather than nag.
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || exit 0
stamp="$CLAUDE_PLUGIN_DATA/setup-notice-day"
today=$(date +%Y-%m-%d)
last=
[ -r "$stamp" ] && read -r last <"$stamp"
[ "$last" = "$today" ] && exit 0

if [ -n "${CHARGELIGHT_BIN:-}" ]; then
  bin=$CHARGELIGHT_BIN
elif command -v chargelight >/dev/null 2>&1; then
  bin=chargelight
else
  for bin in /opt/homebrew/bin/chargelight /usr/local/bin/chargelight "$HOME/.local/bin/chargelight"; do
    [ -x "$bin" ] && break
  done
fi

if command -v "$bin" >/dev/null 2>&1; then
  "$bin" doctor --quiet </dev/null >/dev/null 2>&1 && exit 0
  msg='chargelight: the MagSafe LED helper is not set up yet. Run this once in a terminal: sudo chargelight setup (then chargelight doctor to check).'
else
  msg='chargelight: to use your MagSafe LED as a Claude status light, install the CLI: brew install taraxiot/tap/chargelight, then run: sudo chargelight setup'
fi

mkdir -p "$CLAUDE_PLUGIN_DATA" 2>/dev/null && printf '%s\n' "$today" >"$stamp" 2>/dev/null || exit 0
printf '{"systemMessage": "%s"}\n' "$msg"
exit 0
