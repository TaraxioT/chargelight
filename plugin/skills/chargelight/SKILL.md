---
name: chargelight
description: Explains and controls chargelight, which turns the MacBook MagSafe charger LED into a Claude Code status light. Use when the user asks about the charger LED or MagSafe light, chargelight setup, why the light is not changing, turning it off, changing its colours, or making it signal their own events such as a finished build or test run.
user-invocable: false
---

# chargelight

The chargelight plugin's hooks send every Claude Code session event to the `chargelight` CLI, which sets the MagSafe LED:

| LED | Meaning | State name |
| --- | --- | --- |
| Amber | Claude is working | `working` |
| Fast blink | Claude needs the user: permission prompt, question, MCP input | `attention` |
| Green | Claude finished and is waiting | `ready` |
| Normal charging light | No active session | idle |

Requires an Apple Silicon Mac with a MagSafe charger connected.

## Commands

| Command | Does |
| --- | --- |
| `chargelight status [--json]` | Shows the current LED state, the active claims and any override |
| `chargelight doctor [--json]` | Checks the install and helper; prints what to fix |
| `chargelight claim <id> <working\|attention\|ready> [--ttl 10m] [--label text]` | Holds the LED in a state under your own id |
| `chargelight release <id>` | Drops that claim |
| `chargelight reset` | Drops all claims and any override |
| `chargelight set <off\|green\|amber\|blink-slow\|blink-fast> [--for 10m]` | Overrides the agents and shows that state until `chargelight set system` |
| `chargelight set system` | Ends the override; the agents decide the LED again |
| `chargelight demo` | Cycles through the states |

If `chargelight` is not on the Bash tool's PATH, try `/opt/homebrew/bin/chargelight`.

## Setup and troubleshooting

When the light does not change, run `chargelight doctor` first and act on what it reports.

- Not installed: the user installs it with `brew tap TaraxioT/chargelight https://github.com/TaraxioT/chargelight && brew install TaraxioT/chargelight/chargelight`.
- Helper missing or not passwordless: the user must run `sudo chargelight setup` once. It asks for their password, so never run it yourself; ask the user to run it in their own terminal.
- `chargelight status` shows which claim or override is driving the LED. A stale claim from a script can be cleared with `chargelight release <id>`; `chargelight reset` clears everything.

## Signal your own events

Scripts can claim the LED with their own id. Always pass `--ttl` so a script that dies does not leave the light stuck:

```sh
chargelight claim build working --label "build" --ttl 30m
if make; then
  chargelight claim build ready --label "build passed" --ttl 10m
else
  chargelight claim build attention --label "build failed" --ttl 10m
fi
```

Run `chargelight release build` to clear it early.

## Change the colours

Remap each state with an environment variable whose value is one of `system`, `off`, `green`, `amber`, `blink-slow`, `blink-fast`: `CHARGELIGHT_LED_WORKING`, `CHARGELIGHT_LED_ATTENTION`, `CHARGELIGHT_LED_READY`, `CHARGELIGHT_LED_IDLE`. Claude Code runs the hooks, so set them where Claude Code's process sees them, such as the `env` block of `~/.claude/settings.json`, then restart Claude Code:

```json
{ "env": { "CHARGELIGHT_LED_READY": "off", "CHARGELIGHT_LED_WORKING": "blink-slow" } }
```

## Turn it off

`chargelight set off` keeps the LED dark, whatever the agents do, until `chargelight set system`. Add `--for 2h` to make it temporary. To stop the plugin using the light at all, disable it with `/plugin`.
