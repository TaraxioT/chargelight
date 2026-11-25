---
name: doctor
description: Check whether chargelight can drive the MagSafe LED and show what it is doing now.
disable-model-invocation: true
allowed-tools: Bash(chargelight doctor *) Bash(chargelight status *) Bash(/opt/homebrew/bin/chargelight doctor *) Bash(/opt/homebrew/bin/chargelight status *)
---

Run `chargelight doctor --json` and `chargelight status --json`. If `chargelight` is not found, try `/opt/homebrew/bin/chargelight`.

Report in a few lines:

1. Whether the LED can be driven. If not, the single next step from the doctor output. When that step is `sudo chargelight setup`, ask the user to run it in their own terminal, since it needs their password; do not run it yourself.
2. The current LED state and the claims holding it, with their labels and time left.

If the CLI is not installed at all, tell the user to run `brew tap TaraxioT/chargelight https://github.com/TaraxioT/chargelight && brew install TaraxioT/chargelight/chargelight`, then `sudo chargelight setup`.
