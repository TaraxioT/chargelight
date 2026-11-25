# chargelight for Claude Code

Turns the MagSafe charger LED on an Apple Silicon MacBook into a status light for Claude Code:

- **Amber**: Claude is working
- **Fast blink**: Claude needs you (permission prompt, question, MCP input)
- **Green**: Claude has finished and is waiting
- **Normal charging light**: no session is active

## Install

In Claude Code:

```
/plugin install chargelight --marketplace TaraxioT/chargelight
```

The plugin drives the light through the `chargelight` command-line tool, installed separately:

```sh
brew tap TaraxioT/chargelight https://github.com/TaraxioT/chargelight
brew install TaraxioT/chargelight/chargelight
sudo chargelight setup
```

`sudo chargelight setup` is a one-time step that installs the privileged helper allowed to change the LED. Run `/chargelight:doctor` in Claude Code to check that everything works.

## What the plugin runs

- **Hooks** (`hooks/hooks.json`): on session, prompt, tool, permission, notification, compaction and stop events, `scripts/hook.sh` passes the event JSON from stdin to `chargelight hook` on your machine. The hooks run in the background, except at session end, and never print output or block Claude.
- **Startup check** (`scripts/setup-notice.sh`): when a session starts, runs `chargelight doctor --quiet`. If the tool is missing or not set up, it shows you a setup message, at most once a day, and keeps the date in the plugin's data directory. It is silent when everything works and on machines other than Apple Silicon Macs.
- **Skills**: `chargelight` teaches Claude the CLI so it can troubleshoot the light, change colours or signal your own events; `/chargelight:doctor` reports the light's health and state.

The plugin makes no network requests and sends no data anywhere. Set `CHARGELIGHT_BIN` to use a `chargelight` binary outside the usual Homebrew paths.

## License

MIT
