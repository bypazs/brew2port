# Changelog

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
