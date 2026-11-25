---
name: chargelight
description: Explains and controls chargelight, the CLI that makes the MacBook MagSafe charger LED programmable and that this plugin uses as a Claude Code status light. Use when the user asks about the charger LED or MagSafe light, chargelight setup, why the light is not changing, turning it off, changing its colours or patterns, or making it signal their own events such as a finished build, a timer or a failing test run.
user-invocable: false
---

# chargelight

`chargelight` is a CLI that makes the MagSafe charger LED programmable. This plugin's hooks send every Claude Code session event to it, so the LED follows the session:

| LED | Meaning | Preset |
| --- | --- | --- |
| Amber | Claude is working | `working` |
| Fast blink | Claude needs the user: permission prompt, question, plan to approve | `attention` |
| Green | Claude finished and is waiting | `ready` |
| Normal charging light | No active session | idle |

The same CLI serves anything else the user wants the light for. Requires an Apple Silicon Mac with a MagSafe charger connected.

## What can be shown

- States: `amber`, `green`, `blink-slow`, `blink-fast` (both amber), `off`, `system` (macOS decides).
- Patterns: `blink-green`, `blink-green-fast`, `alternate`, `heartbeat`, `heartbeat-green`, `sos`, or one written out as `state:milliseconds,...`, for example `green:300,off:300`.
- Presets: `attention` (priority 30), `working` (20), `ready` (10). `chargelight list` prints everything, including the user's own presets and patterns.

## Commands

| Command | Does |
| --- | --- |
| `chargelight status [--json]` | The LED, the active claims and any override |
| `chargelight doctor [--json]` | Checks the install and helper; prints what to fix |
| `chargelight <state\|pattern> [--for 10m]` | Shows it over every claim until `chargelight system` (same as `chargelight set ...`) |
| `chargelight system` | Ends that override; the claims decide again |
| `chargelight flash [green\|amber\|pattern] [--times 3]` | A short notice, then back to what was showing |
| `chargelight morse <text>` | Spells text once in Morse |
| `chargelight run [--keep 5m] -- <command>` | Light follows a command: working, then ready or attention; exits with its status |
| `chargelight claim <id> <preset\|state\|pattern> [--priority N] [--ttl 10m] [--label text]` | Claims the light under an id |
| `chargelight release <id>` | Drops that claim |
| `chargelight pipe` | Claims whatever each line of stdin says; `release` drops it |
| `chargelight watch [--json]` | Prints a line whenever the light or the claims change |
| `chargelight reset` | Drops all claims and any override |

Every command takes `--json`. If `chargelight` is not on the Bash tool's PATH, try `/opt/homebrew/bin/chargelight`.

## Setup and troubleshooting

When the light does not change, run `chargelight doctor` first and act on what it reports.

- Not installed: the user installs it with `brew install taraxiot/tap/chargelight`.
- Helper missing or not passwordless: the user must run `sudo chargelight setup` once. It asks for their password, so never run it yourself; ask the user to run it in their own terminal.
- `chargelight status` shows which claim or override is driving the LED. Claude Code sessions appear as `claude:<session id>`. A stale claim from a script can be cleared with `chargelight release <id>`; `chargelight reset` clears everything.
- An override (`chargelight off`, `chargelight amber`) hides every claim, including Claude's, until `chargelight system`.

## Signal your own events

The highest-priority claim wins, and claims expire, so always pass `--ttl` (or use `run`, which renews its own claim):

```sh
chargelight run -- make test                      # simplest: follows the command

chargelight claim build working --label "build" --ttl 30m
if make; then
  chargelight flash green --times 5
else
  chargelight claim build attention --label "build failed" --ttl 10m
fi
```

Use `--priority` to rank a claim against Claude's (above 30 beats a session that needs attention, below 10 never hides one).

## Change the colours

Remap what each preset shows with an environment variable whose value is a state or a pattern: `CHARGELIGHT_LED_WORKING`, `CHARGELIGHT_LED_ATTENTION`, `CHARGELIGHT_LED_READY`; `CHARGELIGHT_LED_IDLE` takes a state. Claude Code runs the hooks, so set them where Claude Code's process sees them, such as the `env` block of `~/.claude/settings.json`, then restart Claude Code:

```json
{ "env": { "CHARGELIGHT_LED_READY": "off", "CHARGELIGHT_LED_ATTENTION": "alternate" } }
```

The same can go in `~/Library/Application Support/chargelight/config.json` under `"leds"`, next to the user's own `"presets"` and `"patterns"`, with no restart needed.

## Turn it off

`chargelight off` keeps the LED dark, whatever anything else does, until `chargelight system`. Add `--for 2h` to make it temporary. To stop the plugin using the light at all, disable it with `/plugin`.
