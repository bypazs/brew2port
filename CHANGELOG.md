# Changelog

## PortCat 0.4.0
- Codex updates: PortCat checks the installed Codex CLI against the latest release (OpenAI's release channel, then GitHub) and shows an **Update** button. Copies from the official installer (`~/.local/bin/codex`) update in the background with no password. Homebrew/npm copies open Terminal so the installer can offer to replace them.
- macOS notifications with a button: "Update now" for Codex, "Upgrade all" for MacPorts ports. Each new version is announced once, not on every check.
- Other apps: PortCat also lists outdated **Homebrew** formulae and apps, **npm** global packages and **App Store** apps (needs `mas`), each with an Update button and an "Update all". Homebrew apps update in Terminal because their installers can ask for a password; the rest update in the background.
- The cat waves and the badge counts all of these.
- npm is also found when it comes from nvm (the default Node in `~/.nvm`, else the newest) or Volta.
- A gear menu in the popover: choose which sources to check (Homebrew tools, Homebrew apps, npm, App Store, Codex; only the ones installed on this Mac are listed) and pause notifications for a day or a week. Notifications also have a "Remind me tomorrow" button.

## brew2port 0.5.1
- Codex (formula or cask) is now marked "own installer" instead of "no match", and the official `curl -fsSL https://chatgpt.com/codex/install.sh | sh` command is shown. `--checkup` prints the same tip when `codex` is installed. The script never runs it.
- `port install` / `brew uninstall` no longer read stdin, so they can't swallow the rest of the plan being read in the apply loop.
- The Apple Silicon warning now appears before the MacPorts install prompt.

## brew2port 0.5.0 · PortCat 0.3.0 — first public release

### brew2port.sh
- Migrates Homebrew formulae to MacPorts on Intel Macs: backs up, maps names, shows a plan, installs only with `--apply`.
- `--uninstall-brew` removes each Homebrew copy only after its port installed, then clears orphaned dependencies with `brew autoremove`.
- Installs MacPorts if it's missing, after verifying the official `.pkg` (SHA256 against MacPorts' published checksums + Apple Developer ID signature).
- `--checkup` for regular maintenance: selfupdate, `port diagnose`, outdated ports, PATH check, summary.
- Post-run summary saved as `summary.txt`; friendly message when nothing is left to move.
- `--map` file for name overrides; `--no-banner` and `NO_COLOR` support.

### PortCat (menu bar app)
- Original pixel-art cat whose pose shows your MacPorts state; follows light/dark mode.
- Upgrade one or all outdated ports, diagnose, `port reclaim`, Open at Login.
- Buttons to install MacPorts, move Homebrew formulae, remove old copies, keep tools that have no port in Homebrew, and clean up Homebrew leftovers.
- Admin actions always go through the macOS password dialog; nothing runs as root in the background.
