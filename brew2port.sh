#!/bin/bash
#
# brew2port — move Homebrew formulae to MacPorts on Intel Macs.
#
# Homebrew moved macOS on Intel x86_64 to Tier 3 in September 2026 and no
# longer builds bottles for it. MacPorts still ships binary packages for
# Intel macOS, so this script helps you migrate command-line packages over.
#
# Safe by default: without --apply it only prints a plan and changes nothing.
# It never uninstalls Homebrew itself and never touches casks (GUI apps).
#
# Written for the bash 3.2 that ships with macOS (no associative arrays).

set -u

VERSION="0.5.0"
MACPORTS_FALLBACK="2.12.6"   # used if the latest version can't be detected
APPLY=0
UNINSTALL_BREW=0
ASSUME_YES=0
MAP_FILE=""
SHOW_BANNER=1
CHECKUP=0
OUT_SET=0
OUT_DIR="${HOME}/brew2port-$(date +%Y%m%d-%H%M%S)"

# ---------- output helpers ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

LOG=""
say()  { printf '%s\n' "$*"; [ -n "$LOG" ] && printf '%s\n' "$*" >>"$LOG"; return 0; }
info() { say "${C_BLU}==>${C_OFF} $*"; }
ok()   { say "${C_GRN}✔${C_OFF} $*"; }
warn() { say "${C_YEL}!${C_OFF} $*"; }
err()  { say "${C_RED}✘${C_OFF} $*"; }
die()  { err "$*"; exit 1; }

# ---------- banner ----------
# Original mascot, drawn for this project. Terminal only, never logged.
banner() {
  [ "$SHOW_BANNER" -eq 1 ] && [ -t 1 ] || return 0
  local c1 c2 c3 c4 c5 off
  if [ -n "$C_OFF" ]; then
    c1=$'\033[38;5;213m'; c2=$'\033[38;5;177m'; c3=$'\033[38;5;141m'
    c4=$'\033[38;5;111m'; c5=$'\033[38;5;87m';  off=$'\033[0m'
  else
    c1=""; c2=""; c3=""; c4=""; c5=""; off=""
  fi
  local cheers="yosh, let's move house~!|ikuzo! no more building from source!|ganbatte, little Intel Mac!|packing boxes... sparkle sparkle~|new harbor, same tools (^_^)b"
  local n=$(( RANDOM % 5 + 1 ))
  local cheer; cheer="$(printf '%s' "$cheers" | cut -d'|' -f"$n")"

  printf '\n'
  printf '%s  ✧･ﾟ:* %s ╔╗ ╦═╗╔═╗╦ ╦╔═╗╔═╗╔═╗╦═╗╔╦╗ %s *:･ﾟ✧%s\n' "$c1" "$c2" "$c1" "$off"
  printf '%s         ╠╩╗╠╦╝║╣ ║║║╔═╝╠═╝║ ║╠╦╝ ║ %s\n' "$c3" "$off"
  printf '%s         ╚═╝╩╚═╚═╝╚╩╝╚══╩  ╚═╝╩╚═ ╩  %s v%s%s\n' "$c4" "$C_DIM" "$VERSION" "$off"
  printf '\n'
  printf '%s     ╭─────────────────────────────────────────╮%s\n' "$c2" "$off"
  printf '%s     │%s %-39s %s│%s\n' "$c2" "$off" "$cheer" "$c2" "$off"
  printf '%s     ╰──v──────────────────────────────────────╯%s\n' "$c2" "$off"
  printf '%s   (ﾉ≧∀≦)ﾉ %s⌒[■]%s  ･ﾟ✧          %s|\\%s\n' "$c1" "$c3" "$off" "$c4" "$off"
  printf '%s      Homebrew  %s━━━━━▶%s     %s_____|_\\____%s\n' "$C_DIM" "$c3" "$off" "$c4" "$off"
  printf '%s                         \\__%sMacPorts%s__/ %s~~~%s\n' "$c4" "$c5" "$c4" "$c5" "$off"
  printf '%s                   ~~~~~~~~~~~~~~~~~~~~~~~~~~%s\n' "$c5" "$off"
  printf '\n'
}

usage() {
  cat <<EOF
brew2port ${VERSION} — migrate Homebrew formulae to MacPorts (Intel Macs)

Usage: ./brew2port.sh [options]

  (no options)       Dry run: back up your package list and print a plan.
  --apply            Install the matching MacPorts ports.
  --uninstall-brew   With --apply: remove each Homebrew formula after its
                     port installs successfully. Formulae that other
                     formulae still depend on are kept.
  --checkup          Health check for later: update MacPorts, run
                     port diagnose, list outdated ports and offer to
                     upgrade them. Run it every week or two.
  --map FILE         Your own name overrides, one per line:
                       <brew-name> <port-name>
                     Use "-" as the port name to skip a formula.
  --yes              Don't ask for confirmation.
  --no-banner        Skip the banner (NO_COLOR=1 also disables colors).
  --out DIR          Where to write backups and logs
                     (default: ~/brew2port-<timestamp>).
  -h, --help         Show this help.
  -v, --version      Show version.

If MacPorts isn't installed, it offers to download the official .pkg for
your macOS version, verify its SHA256 and Apple signature, and install it.

Casks (GUI apps) are listed but not migrated; apps already in
/Applications keep working. Homebrew itself is never uninstalled.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --uninstall-brew) UNINSTALL_BREW=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --no-banner) SHOW_BANNER=0 ;;
    --checkup) CHECKUP=1 ;;
    --map) shift; [ $# -gt 0 ] || die "--map needs a file"; MAP_FILE="$1" ;;
    --out) shift; [ $# -gt 0 ] || die "--out needs a directory"; OUT_DIR="$1"; OUT_SET=1 ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "brew2port ${VERSION}"; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
  shift
done

if [ "$UNINSTALL_BREW" -eq 1 ] && [ "$APPLY" -eq 0 ]; then
  die "--uninstall-brew only works together with --apply"
fi
if [ "$CHECKUP" -eq 1 ] && [ "$APPLY" -eq 1 ]; then
  die "--checkup and --apply are separate steps; run them one at a time"
fi
if [ "$CHECKUP" -eq 1 ] && [ "$OUT_SET" -eq 0 ]; then
  OUT_DIR="${HOME}/brew2port-checkup-$(date +%Y%m%d-%H%M%S)"
fi
if [ -n "$MAP_FILE" ] && [ ! -r "$MAP_FILE" ]; then
  die "Can't read map file: $MAP_FILE"
fi

# ---------- preflight ----------
[ "$(uname -s)" = "Darwin" ] || die "This script is for macOS only."

banner

mkdir -p "$OUT_DIR" || die "Can't create $OUT_DIR"
LOG="$OUT_DIR/brew2port.log"
: >"$LOG"

# ---------- MacPorts: find it, or offer to install it ----------
install_macports() {
  local major name ver file base pkg chk want got

  major="$(sw_vers -productVersion | cut -d. -f1)"
  case "$major" in
    11) name="11-BigSur" ;;   12) name="12-Monterey" ;; 13) name="13-Ventura" ;;
    14) name="14-Sonoma" ;;   15) name="15-Sequoia" ;;  26) name="26-Tahoe" ;;
    *)  die "No MacPorts installer known for macOS $major. Get one at https://www.macports.org/install.php" ;;
  esac

  if ! xcode-select -p >/dev/null 2>&1; then
    warn "MacPorts needs the Xcode Command Line Tools. Opening Apple's installer…"
    xcode-select --install >/dev/null 2>&1 || true
    die "Finish the Command Line Tools install, then run brew2port again."
  fi

  ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
          https://github.com/macports/macports-base/releases/latest 2>>"$LOG" |
         sed -n 's#.*/tag/v\([0-9][0-9.]*\)$#\1#p')"
  [ -n "$ver" ] || ver="$MACPORTS_FALLBACK"

  file="MacPorts-${ver}-${name}.pkg"
  base="https://github.com/macports/macports-base/releases/download/v${ver}"
  pkg="$OUT_DIR/$file"
  chk="$OUT_DIR/MacPorts-${ver}.chk.txt"

  info "Downloading $file"
  curl -fL --progress-bar -o "$pkg" "$base/$file" || die "Download failed: $base/$file"
  curl -fsSL -o "$chk" "$base/MacPorts-${ver}.chk.txt" 2>>"$LOG" || die "Couldn't download the checksum file"

  # MacPorts labels .pkg hashes "SHA2-256(...)" (tarballs use "SHA256(...)")
  want="$(awk -v a="SHA2-256($file)=" -v b="SHA256($file)=" \
          'index($0, a) == 1 || index($0, b) == 1 { print $2; exit }' "$chk")"
  got="$(shasum -a 256 "$pkg" | awk '{print $1}')"
  [ -n "$want" ] || die "No SHA256 for $file in the checksum file — not installing."
  [ "$want" = "$got" ] || die "SHA256 mismatch for $file — not installing. (expected $want, got $got)"
  ok "Checksum verified"

  if pkgutil --check-signature "$pkg" 2>>"$LOG" | grep -q "signed by a developer certificate issued by Apple"; then
    ok "Apple Developer ID signature verified"
  else
    die "$file is not signed with an Apple Developer ID — not installing."
  fi

  info "Installing MacPorts $ver (asks for your password)…"
  sudo installer -pkg "$pkg" -target / >>"$LOG" 2>&1 || die "MacPorts installer failed (see $LOG)"

  PATH="/opt/local/bin:/opt/local/sbin:$PATH"; export PATH
  hash -r
  command -v port >/dev/null 2>&1 || die "MacPorts installed but 'port' isn't in /opt/local/bin?"

  info "Fetching the MacPorts package index (first time takes a few minutes)…"
  sudo port -N selfupdate >>"$LOG" 2>&1 || warn "port selfupdate failed (see log)"
  ok "MacPorts $ver is ready"
}

if ! command -v port >/dev/null 2>&1 && [ -x /opt/local/bin/port ]; then
  # Installed, just not on PATH in this shell yet.
  PATH="/opt/local/bin:/opt/local/sbin:$PATH"; export PATH
fi

if ! command -v port >/dev/null 2>&1; then
  warn "MacPorts isn't installed yet."
  if [ "$ASSUME_YES" -eq 1 ]; then
    install_macports
  elif { : </dev/tty; } 2>/dev/null; then
    printf 'Download and install MacPorts now? (checksum + signature are verified first) [y/N] '
    read -r answer </dev/tty || answer=""
    case "$answer" in
      y|Y|yes|YES) install_macports ;;
      *) die "OK. Install it yourself from https://www.macports.org/install.php, then run brew2port again." ;;
    esac
  else
    die "Install MacPorts from https://www.macports.org/install.php (or re-run with --yes)."
  fi
fi

if [ "$(uname -m)" = "arm64" ]; then
  warn "This is an Apple Silicon Mac. Homebrew is fully supported here — you probably don't need to migrate."
fi

# ---------- shared: PATH order check ----------
check_path_order() {
  local pos_port=-1 pos_brew=-1 i=0 d
  local IFS=':'
  for d in $PATH; do
    [ "$d" = "/opt/local/bin" ] && [ $pos_port -lt 0 ] && pos_port=$i
    [ "$d" = "/usr/local/bin" ] && [ $pos_brew -lt 0 ] && pos_brew=$i
    i=$((i+1))
  done
  if [ $pos_port -lt 0 ]; then
    warn "/opt/local/bin is not on your PATH. Add this to ~/.zprofile:"
    say  '   export PATH="/opt/local/bin:/opt/local/sbin:$PATH"'
    return 1
  elif [ $pos_brew -ge 0 ] && [ $pos_brew -lt $pos_port ]; then
    warn "/usr/local/bin (Homebrew) comes before /opt/local/bin (MacPorts) in PATH,"
    say  "   so Homebrew copies still win. Put MacPorts first in ~/.zprofile."
    return 1
  fi
  return 0
}

rule() { say ""; say "${C_BLU}━━━━━━━━━━━━━━━━━━━━ $* ━━━━━━━━━━━━━━━━━━━━${C_OFF}"; }

# ---------- --checkup mode ----------
run_checkup() {
  local mp_ver n_ports diag outdated n_out upgraded=0 path_ok="ok" diag_ok="ok" answer

  info "MacPorts needs admin rights; you may be asked for your password."
  sudo -v || die "sudo failed"

  info "Updating MacPorts and its package index…"
  if sudo port -N selfupdate >>"$LOG" 2>&1; then ok "Up to date"
  else warn "selfupdate failed (network?) — results below may be stale"; fi

  info "Running port diagnose…"
  diag="$(port diagnose --quiet </dev/null 2>&1)"
  printf '%s\n' "$diag" >>"$LOG"
  if [ -z "$(printf '%s' "$diag" | tr -d '[:space:]')" ]; then
    ok "No problems found"
  else
    diag_ok="issues"
    warn "port diagnose reported:"
    printf '%s\n' "$diag" | sed 's/^/     /' | tee -a "$LOG"
  fi

  info "Checking for outdated ports…"
  outdated="$(port -q outdated 2>>"$LOG")"
  n_out=0
  [ -n "$outdated" ] && n_out="$(printf '%s\n' "$outdated" | grep -c .)"
  if [ "$n_out" -eq 0 ]; then
    ok "Everything is up to date"
  else
    warn "$n_out outdated port(s):"
    printf '%s\n' "$outdated" | sed 's/^/     /' | tee -a "$LOG"
    answer="n"
    if [ "$ASSUME_YES" -eq 1 ]; then answer="y"
    elif { : </dev/tty; } 2>/dev/null; then
      printf 'Upgrade them now? [y/N] '; read -r answer </dev/tty || answer="n"
    fi
    case "$answer" in
      y|Y|yes|YES)
        info "Upgrading (this can take a while)…"
        if sudo port -N upgrade outdated >>"$LOG" 2>&1; then
          ok "Upgraded"; upgraded="$n_out"; n_out=0
        else
          err "Some upgrades failed (see $LOG)"
          n_out="$(port -q outdated 2>/dev/null | grep -c .)"
          upgraded=0
        fi ;;
      *) say "   Skipped. Upgrade later with:  sudo port upgrade outdated" ;;
    esac
  fi

  check_path_order || path_ok="needs fixing"

  mp_ver="$(port version 2>/dev/null | awk '{print $2}')"
  n_ports="$(port -q installed active 2>/dev/null | grep -c .)"

  rule "Checkup summary"
  {
    printf '  %-22s %s\n' "MacPorts version" "${mp_ver:-?}"
    printf '  %-22s %s\n' "Active ports" "$n_ports"
    printf '  %-22s %s\n' "Upgraded just now" "$upgraded"
    printf '  %-22s %s\n' "Still outdated" "$n_out"
    printf '  %-22s %s\n' "port diagnose" "$diag_ok"
    printf '  %-22s %s\n' "PATH order" "$path_ok"
  } | tee -a "$LOG" | tee "$OUT_DIR/summary.txt"
  say ""
  say "Tip: free disk space from old versions with:  sudo port reclaim"
  say "Security: keeping ports upgraded is how fixes arrive — run --checkup every week or two."
  if [ "$n_out" -eq 0 ] && [ "$diag_ok" = "ok" ] && [ "$path_ok" = "ok" ]; then
    say ""; info "All good!  ٩(◕‿◕)۶"
  fi
  exit 0
}

[ "$CHECKUP" -eq 1 ] && run_checkup

command -v brew >/dev/null 2>&1 || die "Homebrew (brew) not found in PATH."

# ---------- name mapping ----------
# Prints candidate MacPorts names for a Homebrew formula, best first.
# The first candidate that exists in MacPorts wins.
candidates_for() {
  local n="$1" v
  case "$n" in
    python)          echo "python313 python312" ;;
    python@3.*)      v="${n#python@}"; echo "python${v//./}" ;;
    node)            echo "nodejs24 nodejs22 nodejs20" ;;
    node@*)          echo "nodejs${n#node@}" ;;
    openssl@3)       echo "openssl3" ;;
    openssl@1.1)     echo "openssl11" ;;
    postgresql@*)    v="${n#postgresql@}"; echo "postgresql${v}-server postgresql${v}" ;;
    mysql|mysql@8*)  echo "mysql8" ;;
    ruby)            echo "ruby34 ruby33" ;;
    ruby@3.*)        v="${n#ruby@}"; echo "ruby${v//./}" ;;
    php)             echo "php84 php83" ;;
    php@8.*)         v="${n#php@}"; echo "php${v//./}" ;;
    openjdk)         echo "openjdk21 openjdk17" ;;
    openjdk@*)       echo "openjdk${n#openjdk@}" ;;
    gcc)             echo "gcc14 gcc13" ;;
    gcc@*)           echo "gcc${n#gcc@}" ;;
    gnu-sed)         echo "gsed" ;;
    gnu-tar)         echo "gnutar" ;;
    gnupg)           echo "gnupg2" ;;
    pkg-config|pkgconf) echo "pkgconfig" ;;
    imagemagick)     echo "ImageMagick7 ImageMagick" ;;
    sqlite)          echo "sqlite3" ;;
    ffmpeg)          echo "ffmpeg ffmpeg7" ;;
    *@*)             # generic versioned formula: foo@1.2 -> foo12, then foo
                     v="${n#*@}"; echo "${n%%@*}${v//./} ${n%%@*}" ;;
    *)               echo "$n" ;;
  esac
}

user_map() {
  # Prints the override for $1 from --map, or nothing.
  [ -n "$MAP_FILE" ] || return 0
  awk -v k="$1" '$0 !~ /^[[:space:]]*#/ && $1 == k { print $2; exit }' "$MAP_FILE"
}

port_exists() {
  port -q info --name "$1" >/dev/null 2>&1
}

# ---------- step 1: back up ----------
info "Backing up your Homebrew package list to $OUT_DIR"
brew list --formula --versions >"$OUT_DIR/brew-formulae.txt" 2>>"$LOG"
brew list --cask --versions >"$OUT_DIR/brew-casks.txt" 2>>"$LOG"
if brew bundle dump --force --file="$OUT_DIR/Brewfile" >>"$LOG" 2>&1; then
  ok "Saved Brewfile"
else
  warn "brew bundle dump failed (see log); plain lists were still saved"
fi

# ---------- step 2: build the plan ----------
info "Finding matching MacPorts ports (this can take a minute)…"
PLAN="$OUT_DIR/plan.tsv"
printf 'brew\tport\tstatus\n' >"$PLAN"

leaves="$(brew leaves --installed-on-request 2>>"$LOG")" || die "brew leaves failed (see $LOG)"
[ -n "$leaves" ] || die "No formulae installed on request — nothing to migrate."

n_ok=0; n_missing=0; n_skip=0
for full in $leaves; do
  short="${full##*/}"          # supabase/tap/supabase -> supabase
  target=""; status=""

  mapped="$(user_map "$full")"
  [ -n "$mapped" ] || mapped="$(user_map "$short")"

  if [ "$mapped" = "-" ]; then
    status="skip"
  elif [ -n "$mapped" ]; then
    if port_exists "$mapped"; then target="$mapped"; status="ok"
    else target="$mapped"; status="missing"; fi
  else
    for c in $(candidates_for "$short"); do
      if port_exists "$c"; then target="$c"; status="ok"; break; fi
    done
    [ -n "$status" ] || { target="$(candidates_for "$short" | awk '{print $1}')"; status="missing"; }
  fi

  printf '%s\t%s\t%s\n' "$full" "${target:--}" "$status" >>"$PLAN"
  case "$status" in
    ok)      n_ok=$((n_ok+1)) ;;
    missing) n_missing=$((n_missing+1)) ;;
    skip)    n_skip=$((n_skip+1)) ;;
  esac
done

# ---------- step 3: show the plan ----------
say ""
printf '%-32s %-24s %s\n' "HOMEBREW" "MACPORTS" "STATUS" | tee -a "$LOG"
printf '%-32s %-24s %s\n' "--------" "--------" "------" | tee -a "$LOG"
tail -n +2 "$PLAN" | while IFS=$'\t' read -r b p s; do
  case "$s" in
    ok)      col="$C_GRN"; label="will install" ;;
    missing) col="$C_YEL"; label="no match — add it to a --map file" ;;
    skip)    col="$C_DIM"; label="skipped (map)" ;;
  esac
  printf '%-32s %-24s %s%s%s\n' "$b" "$p" "$col" "$label" "$C_OFF"
  printf '%-32s %-24s %s\n' "$b" "$p" "$label" >>"$LOG"
done
say ""
say "Matched: $n_ok   No match: $n_missing   Skipped: $n_skip"

casks="$(brew list --cask 2>/dev/null)"
if [ -n "$casks" ]; then
  say ""
  info "Casks (GUI apps) — not migrated, they keep working from /Applications:"
  for c in $casks; do say "   $c"; done
fi

say ""
say "${C_DIM}Plan saved to $PLAN${C_OFF}"

if [ "$APPLY" -eq 0 ]; then
  say ""
  info "Dry run only — nothing was changed.  (・ω・)ゞ"
  say "   Review the plan, then run:  ./brew2port.sh --apply"
  say "   To also remove the Homebrew copies:  ./brew2port.sh --apply --uninstall-brew"
  exit 0
fi

if [ "$n_ok" -eq 0 ]; then
  say ""
  ok "Nothing left to move — everything that has a MacPorts version is already there.  (｀・ω・´)b"
  if [ "$n_missing" -gt 0 ]; then
    say "   What's left has no MacPorts port, so it stays in Homebrew. That's fine:"
    say "   Homebrew keeps working on Intel Macs until at least September 2027."
  fi
  exit 0
fi

# ---------- step 4: apply ----------
if [ "$ASSUME_YES" -eq 0 ]; then
  say ""
  msg="Install $n_ok port(s) with MacPorts"
  [ "$UNINSTALL_BREW" -eq 1 ] && msg="$msg and remove their Homebrew copies"
  printf '%s? [y/N] ' "$msg"
  read -r answer </dev/tty || answer=""
  case "$answer" in y|Y|yes|YES) ;; *) die "Cancelled." ;; esac
fi

info "MacPorts needs admin rights; you may be asked for your password."
sudo -v || die "sudo failed"

info "Updating MacPorts…"
sudo port -N selfupdate >>"$LOG" 2>&1 || warn "port selfupdate failed (continuing; see log)"

done_ok=0; done_fail=0; kept=""
RESULTS="$OUT_DIR/results.tsv"
: >"$RESULTS"
while IFS=$'\t' read -r b p s; do
  [ "$s" = "ok" ] || continue
  pstat=""; bstat="kept"

  if port -q installed "$p" 2>/dev/null | grep -q active; then
    ok "$p already installed"; pstat="already there"
  else
    info "Installing $p  (from brew: $b)"
    if sudo port -N install "$p" >>"$LOG" 2>&1; then
      ok "Installed $p"; pstat="installed"
    else
      err "Failed to install $p — Homebrew copy of $b left untouched (see log)"
      done_fail=$((done_fail+1))
      printf '%s\t%s\t%s\t%s\n' "$b" "$p" "FAILED" "kept" >>"$RESULTS"
      continue
    fi
  fi
  done_ok=$((done_ok+1))

  if [ "$UNINSTALL_BREW" -eq 1 ]; then
    if brew uninstall "$b" >>"$LOG" 2>&1; then
      ok "Removed Homebrew $b"; bstat="removed"
    else
      warn "Kept Homebrew $b (something else still depends on it)"
      kept="$kept $b"; bstat="kept (needed)"
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$b" "$p" "$pstat" "$bstat" >>"$RESULTS"
done < <(tail -n +2 "$PLAN")

# Removing formulae leaves their dependencies behind (often build tools that
# Homebrew pulled in to compile from source on Intel). Clean up the orphans.
orphans=""
if [ "$UNINSTALL_BREW" -eq 1 ]; then
  orphans="$(brew autoremove --dry-run 2>>"$LOG" | grep -v '^==>' | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
  if [ -n "$orphans" ]; then
    info "Removing leftover Homebrew dependencies nothing needs anymore…"
    if brew autoremove >>"$LOG" 2>&1; then
      ok "Removed: $orphans"
      brew cleanup >>"$LOG" 2>&1 || true
    else
      warn "brew autoremove failed (see log); you can run it yourself later"
      orphans=""
    fi
  fi
fi

# ---------- step 5: summary ----------
SUMMARY="$OUT_DIR/summary.txt"
sum() { printf '%s\n' "$*"; printf '%s\n' "$*" >>"$LOG"; printf '%s\n' "$*" >>"$SUMMARY"; }
: >"$SUMMARY"

rule "Summary"
sum ""
sum "$(printf '  %-28s %-20s %-15s %s' "HOMEBREW" "MACPORTS" "PORT" "HOMEBREW COPY")"
sum "$(printf '  %-28s %-20s %-15s %s' "--------" "--------" "----" "-------------")"
while IFS=$'\t' read -r b p ps bs; do
  sum "$(printf '  %-28s %-20s %-15s %s' "$b" "$p" "$ps" "$bs")"
done <"$RESULTS"

not_moved="$(awk -F'\t' 'NR > 1 && $3 != "ok" { printf "%s%s", sep, $1; sep = ", " }' "$PLAN")"
n_casks="$(brew list --cask 2>/dev/null | grep -c .)"
sum ""
sum "  Moved to MacPorts : $done_ok"
sum "  Failed            : $done_fail"
[ -n "$not_moved" ] && sum "  Left in Homebrew  : $not_moved  (no match or skipped)"
[ -n "$kept" ]      && sum "  Kept in Homebrew  :$kept  (other formulae need them)"
[ -n "$orphans" ]   && sum "  Cleaned up deps   : $orphans"
[ "$n_casks" -gt 0 ] && sum "  GUI apps (casks)  : $n_casks, unchanged"
sum "  Backups & log     : $OUT_DIR"
sum ""

if [ "$done_fail" -eq 0 ]; then
  info "Done!  (๑•̀ㅂ•́)و✧ otsukaresama~"
else
  info "Done, with $done_fail failure(s).  (´；ω；\`) details in $LOG"
fi
check_path_order || true

say ""
say "Next steps:"
say "  1. Open a new Terminal window (or run: hash -r)"
say "  2. Check it worked:  which <tool>   → should show /opt/local/bin/<tool>"
say "  3. Keep things updated & healthy, every week or two:"
say "       ./brew2port.sh --checkup"
if [ -z "${BREW2PORT_FROM_PORTCAT:-}" ]; then
  say "     or let a cat do it from your menu bar:  cd PortCat && ./build-app.sh --install"
else
  say "     or just click the cat in your menu bar ♪"
fi
say ""
say "${C_DIM}This summary is saved in $SUMMARY. Homebrew itself was not removed.${C_OFF}"
say "${C_DIM}Saved you some time? ☕ https://buymeacoffee.com/bypazs${C_OFF}"
