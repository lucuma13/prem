#!/bin/bash
# Mac workstation setup script Copyright (c) 2026 Luis Gómez Gutiérrez
#
# Usage: bash <(curl -fsSL
# https://raw.githubusercontent.com/lucuma13/load/main/src/load-mac.sh)
#
# Process substitution is the recommended form — flags pass straight through,
# e.g. `bash <(curl -fsSL …) --full`. The script's work is wrapped in main() and
# invoked on the last line, so bash reads and parses the whole script before
# running anything: a truncated download can't half-execute, and a piped (`curl
# | bash`) download can't have its tail drained by a child process (e.g. brew's
# ca-certificates keychain step).

# =============================================================================
# Function library
#
# Everything above the LOAD_LIB guard is side-effect-free definitions, so the
# test suite can `source` this file (with LOAD_LIB=1) to exercise individual
# functions without triggering the installer.
# =============================================================================

brew_prefix() {
  if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    echo "$HOMEBREW_PREFIX"
  elif [ -f "/opt/homebrew/bin/brew" ]; then
    echo "/opt/homebrew"
  else
    echo "/usr/local"
  fi
}

# brew_admin_owner — best guess at an admin account to run machine-wide installs
# as: the owner of the Homebrew prefix if brew exists (the admin who set it up),
# else the first non-system member of the admin group. Empty if none found.
brew_admin_owner() {
  local owner=""
  command -v brew &>/dev/null && owner="$(stat -f %Su "$(brew_prefix)" 2>/dev/null || true)"
  case "$owner" in "" | root | _*) owner="" ;; esac
  [ -n "$owner" ] || owner="$(dscl . -read /Groups/admin GroupMembership 2>/dev/null |
    tr ' ' '\n' | grep -v -e '^GroupMembership:$' -e '^root$' -e '^_' | head -1 || true)"
  echo "$owner"
}

# run_machine_via_admin — from a standard (non-admin) account that can't sudo,
# hand the machine-wide install phase to an admin. Prompts on the tty for an
# admin user, then re-invokes this script AS that user with --machine-only. Both
# password prompts belong to the ADMIN account: the first is `su`, the second is
# the `sudo` that a pkg-based cask (e.g. adobe-acrobat-reader) runs internally —
# brew resets the sudo timestamp on every call, so that one can't be
# pre-authenticated away. Exit codes: 2 = no admin to switch to (no tty, none
# found), 3 = the operator declined at the prompt — both are clean skips for the
# caller; any other non-zero = the admin sub-run itself returned an error.
# 0 = success.
run_machine_via_admin() {
  local admin ans hint declined=false
  [ -e /dev/tty ] || return 2
  admin="$(brew_admin_owner)"
  # Enter accepts the detected admin. With no default, blank does skip.
  if [ -n "$admin" ]; then
    hint="[$admin] (enter to accept, Ctrl-C to skip)"
  else
    hint="(blank or Ctrl-C to skip)"
  fi
  # Trap SIGINT so Ctrl-C skips only this phase: untrapped it reaches the whole
  # script and would abandon the per-user config that still has to run.
  trap 'declined=true' INT
  {
    printf '\n  This account is not an administrator; machine-wide software needs one.\n'
    printf '  Install it now via an admin account? Enter admin username %s: ' "$hint"
    read -r ans || true
  } <>/dev/tty >/dev/tty 2>&1
  trap - INT
  if $declined; then
    echo >/dev/tty
    return 3
  fi
  [ -n "$ans" ] && admin="$ans"
  [ -n "$admin" ] || return 2
  echo "  🔑  Switching to '$admin' for the machine-wide install — both password prompts are for THIS admin account:"
  su -l "$admin" -c "curl -fsSL '$SELF_URL' | bash -s -- --machine-only$($FULL && printf ' --full')" <>/dev/tty
}

would_run() { echo "  🚀  $1"; }
would_skip() { echo "  ⏩  $1"; }
checking() { echo "  Checking $1..."; }

# already_done <line> — an item that needs no work.
#
# checklist() is printed twice over a machine's life: as the --dry-run preview and
# as the post-install summary. The same fact reads differently in each — before
# the run it is one more thing that would be skipped, after it, one more thing
# that is done — so the glyph follows the mode while the text stays put.
already_done() {
  if ${DRY_RUN:-false}; then
    echo "  ⏩  $1"
  else
    echo "  ✅  $1"
  fi
}

# quiet_run <cmd…> — run a command fully silent on success: buffer its combined
# output and echo it only if the command fails, then propagate the failure (so
# set -e still aborts). Used to keep brew truly quiet (--quiet only trims "some"
# output and still streams install progress).
quiet_run() {
  local out rc
  out="$("$@" 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || printf '%s\n' "$out"
  return "$rc"
}

# soft_run <brew cmd…> — run a brew op non-fatally so one failure can't abort
# the machine phase (the plugins and ProVideoFormats after it still run).
# quiet_run still surfaces brew's own output on a genuine failure; we just don't
# editorialise. Always returns 0.
soft_run() { quiet_run "$@" || true; }

# install_casks <cask…> — install/adopt casks, bringing any that already exist
# up to the cask's latest version. Fast path: one batched `--adopt` (installs
# what's missing, adopts an already-matching unmanaged app, and keeps pkg-based
# casks to a single sudo prompt). But `--adopt` refuses when an app of a
# DIFFERENT version is already in /Applications (e.g. a hand-installed
# Audacity), so on failure we retry per cask and `--force` only the ones that
# conflict — overwriting the old app with the latest and taking it under brew
# management. Already-installed casks re-adopt as quick no-ops, so the fallback
# stays cheap. Never aborts the run.
install_casks() {
  [ $# -gt 0 ] || return 0
  # Fast path: one batched --adopt. Silent even on failure — a version-mismatch
  # conflict here isn't a real error, it just means "fall through to per-cask".
  brew install --cask --adopt "$@" &>/dev/null && return 0
  local c
  for c in "$@"; do
    # Already-current casks re-adopt as silent no-ops; a different existing
    # version makes --adopt fail (silently), so replace it with the cask's
    # latest via --force. Adopt-and-upgrade is our default, so a conflict
    # resolves quietly; only a genuine --force failure prints (via soft_run's
    # quiet_run).
    brew install --cask --adopt "$c" &>/dev/null && continue
    soft_run brew install --cask --force "$c"
  done
}

formula_installed() { $BREW_OK && brew list --formula "$1" &>/dev/null 2>&1; }
cask_installed() { $BREW_OK && brew list --cask "$1" &>/dev/null 2>&1; }
uv_installed() { command -v uv &>/dev/null && uv tool list 2>/dev/null | grep -q "^$1"; }

# resolve_mode <args…> — echo the setup flags present, normalised and deduped (a
# space-separated subset of "fast full dryrun"); empty when none were given.
resolve_mode() {
  local arg out=""
  for arg in "$@"; do
    case "$arg" in
    --fast) case " $out " in *" fast "*) ;; *) out="$out fast" ;; esac ;;
    --full) case " $out " in *" full "*) ;; *) out="$out full" ;; esac ;;
    --dry-run) case " $out " in *" dryrun "*) ;; *) out="$out dryrun" ;; esac ;;
    esac
  done
  echo "${out# }"
}

usage() {
  echo "Usage: load-mac.sh [--fast | --full | --dry-run]" >&2
  echo "  Run with no flag in a terminal to run Fast, then continue on Full." >&2
}

# premiere_workspace_name <workspace.xml> — echo the workspace display name,
# stored inside the file under the UserName key.
#
# The file's line endings are NOT a platform invariant: Premiere authors these
# LF on macOS but CRLF on Windows. awk's RS strips only the \n, so on a CRLF
# file the \r survives into the returned name. Strip it.
premiere_workspace_name() {
  awk '/<key>UserName<\/key>/{getline; gsub(/\r|<\/?ustring>/,""); print; exit}' "$1"
}

# set_pref_node <prefs> <node> <value> — replace an XML leaf node's text in
# place (perl, no BOM). The value is passed via env so it survives spaces and
# regex/JSON specials. Returns 1 WITHOUT touching the file when the node is
# absent, so callers can flag nodes a future Premiere version may have renamed
# (no edit = no corruption).
#
# EOL-preserving: perl -pe substitutes WITHIN a line and rewrites the record
# separator untouched, so the file's endings survive the edit.
set_pref_node() {
  local prefs="$1" node="$2"
  grep -q "<$node>" "$prefs" || return 1
  SPN_VAL="$3" perl -i -pe "s{(<\Q$node\E>).*?(</\Q$node\E>)}{\${1}\$ENV{SPN_VAL}\${2}}" "$prefs"
}

# force_pref_node <prefs> <node> <value> — like set_pref_node, but when the node
# is absent it CREATES it inside the <Properties> block instead of skipping. Use
# only for nodes whose Premiere default is wrong for us, so a fresh install
# (where Premiere hasn't written the node yet) must still be overridden. Returns
# 1 without touching the file only when the <Properties> block can't be found.
# Idempotent: once created, later runs find the node and edit it in place.
#
# The inserted "\n" below is the one place we author a line ending in the prefs,
# and a bare LF is correct: Premiere writes this file LF on BOTH macOS and
# Windows.
force_pref_node() {
  local prefs="$1" node="$2"
  grep -q "<$node>" "$prefs" && {
    set_pref_node "$prefs" "$node" "$3"
    return
  }
  grep -q "<Properties" "$prefs" || return 1
  SPN_NODE="$node" SPN_VAL="$3" perl -i -pe 's{(<Properties\b[^>]*>)}{$1\n\t\t\t<$ENV{SPN_NODE}>$ENV{SPN_VAL}</$ENV{SPN_NODE}>}' "$prefs"
}

# customise_premiere_pro <prefs> <kys_file> <ws_name> <version> — point
# Premiere's prefs at the keyboard set + workspace, apply the Classic label
# preset, enable auto-save every 5 minutes keeping 200 project versions, turn on
# the timeline's Link Selection + Display Settings, turn off Media Analysis'
# "Analyze all imported media", and stop playback returning to the beginning when
# it restarts. Every node is matched exactly; any not found is left untouched and
# collected into a single warning, so the script never crashes or corrupts the
# prefs on a version bump.
#
# A missing-node warning can mean one of two things:
#   a) Fresh Premiere install — Premiere only writes certain nodes to disk after
#       a user first manually changes them. Warning is harmless; the setting is
#       already at the correct value.
#   b) Adobe renamed the node in this Premiere version — the setting was NOT
#       applied and the script needs updating. Either way the file is left
#       untouched for that node.
customise_premiere_pro() {
  local prefs="$1" kys_file="$2" ws_name="$3" version="$4"
  # "Classic" label colour preset: 16 names + 16 colours + a RecentPreset marker
  # (Premiere has no single preset switch, so we write the exact values).
  local label_names=(Violet Iris Caribbean Lavender Cerulean Forest Rose Mango Purple Blue Teal Magenta Tan Green Brown Yellow)
  local label_colors=(14717094 13408882 10016297 14910691 14597935 5814353 10776567 3909357 9896087 16727100 8421376 15151847 9814478 2191389 1262987 6611682)
  local missing=() i

  # Keyboard set
  set_pref_node "$prefs" "FE.Prefs.Shortcuts.Filename" "$kys_file" || missing+=("FE.Prefs.Shortcuts.Filename")

  # Active workspace (skip if the display name couldn't be read from the file)
  if [ -n "$ws_name" ]; then
    set_pref_node "$prefs" "FE.Application.LastWorkspaceName" "$ws_name" || missing+=("FE.Application.LastWorkspaceName")
  fi

  # Classic label preset (names + colours + preset marker)
  for i in "${!label_names[@]}"; do
    set_pref_node "$prefs" "BE.Prefs.LabelNames.$i" "${label_names[$i]}" || missing+=("BE.Prefs.LabelNames.$i")
    set_pref_node "$prefs" "BE.Prefs.LabelColors.$i" "${label_colors[$i]}" || missing+=("BE.Prefs.LabelColors.$i")
  done
  set_pref_node "$prefs" "PPro.LabelColorPresets.RecentPreset" '{"builtIn":true,"name":"Classic"}' || missing+=("PPro.LabelColorPresets.RecentPreset")

  # Auto-save: on, every 5 minutes. "Maximum Project Versions" is force-written
  # further down, with the other nodes whose Premiere default is wrong for us.
  set_pref_node "$prefs" "BE.Prefs.AutoSave.DoSave" "true" || missing+=("BE.Prefs.AutoSave.DoSave")
  set_pref_node "$prefs" "BE.Prefs.AutoSave.Interval" "5" || missing+=("BE.Prefs.AutoSave.Interval")

  # Timeline toggles: Link Selection + Display Settings (wrench menu).
  # The Display Settings nodes below are commented out for now because they are not
  # written to the preference file until the default behaviour has changed:
  #   be.Prefs.Timeline.Show.Video.Thumbnails
  #   be.Prefs.Timeline.Show.Video.Names
  #   be.Prefs.Timeline.Show.Audio.Waveforms
  #   be.Prefs.Timeline.Show.Audio.Names
  #   be.Prefs.Timeline.Show.Proxy.Badges
  #   TL.PREFShowFXBadges
  # Link Selection already defaults to the value we want, so a missing node on a fresh
  # install is fine and simply left untouched.
  set_pref_node "$prefs" "TL.PREFLinkedSelectionState" "true" || missing+=("TL.PREFLinkedSelectionState")

  # Preferences whose Premiere default is NOT the value we want. A fresh install
  # has never written these nodes, so leaving them untouched keeps the wrong
  # default: they are force-written (created when absent) rather than skipped.
  # Fields are node|value|min-major, min-major blank when every version has the
  # node; the trailing comment on each row is the control it is behind in
  # Premiere's UI.
  #
  # Premiere only persists these once the control has been toggled by hand, so
  # finding the node in a real profile is the proof we need: it pins the name AND
  # shows Premiere round-trips a value we write there. Every row below was read
  # off a live profile (25.6.6 on Windows, 26.3.2 on macOS).
  #
  # Force-writing only happens on the majors we have evidence for: 25.x and 26.x
  # seen live, 24.x carried over from the captures in tests/fixtures. When 27.x
  # ships, look at a real prefs file before adding it here. On any other version
  # fall back to the in-place edit (skip + report if absent). $version is normally
  # "24.0"/"26.3" etc; pull the leading major number.
  #
  # Kept in step with the $forced table in load-win.ps1 by a test, not by a shared
  # file: each installer is invoked as a single downloaded script, with no
  # checkout on the target machine to read one from.
  local major=""
  [[ "$version" =~ ([0-9]+)\. ]] && major="${BASH_REMATCH[1]}"
  local forced=(
    "TL.PREFShowThroughEditsState|true|"                              # Show Through Edits
    "MZ.SQShowDuplicateMarkers|true|"                                 # Show Duplicate Frame Markers
    "MZ.Prefs.PlaybackEndReturnToBeginning|false|"                    # At playback end, return to beginning
    "BE.Prefs.AutoSave.MaxProjectVersions|200|"                       # Auto Save: Maximum Project Versions
    "BE.Prefs.MediaIntelligence.AnalyzeImportedMediaForMISO|false|25" # Analyze all imported media
  )
  local entry node value min_major
  for entry in "${forced[@]}"; do
    node="${entry%%|*}"
    value="${entry#*|}"
    min_major="${value#*|}"
    value="${value%%|*}"
    # A preference that postdates this Premiere has no node to write, and its
    # absence is permanent rather than a fresh-install artefact - so skip it
    # silently instead of reporting it.
    if [ -n "$min_major" ] && [ -n "$major" ] && [ "$major" -lt "$min_major" ]; then
      continue
    fi
    case "$major" in
    24 | 25 | 26) force_pref_node "$prefs" "$node" "$value" || missing+=("$node") ;;
    *) set_pref_node "$prefs" "$node" "$value" || missing+=("$node") ;;
    esac
  done

  # A missing node leaves the file untouched for that node (never corrupted).
  # The nodes that can still be reported here are ones Premiere writes on every
  # real machine (shortcuts, workspace, labels, auto-save) or whose default
  # already matches ours — harmless on a fresh profile, suspicious anywhere else.
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "  ⚠️  Premiere prefs on version ${version}: ${#missing[@]} preference node(s) not found and skipped (file untouched for those nodes):"
    printf '        - %s\n' "${missing[@]}"
    echo "      Missing nodes are ones Premiere had never written. Every preference we"
    echo "      know Premiere leaves unwritten until it is changed by hand is created"
    echo "      when absent, so a report here means either a genuinely fresh profile"
    echo "      or, on a machine that has had Premiere used on it, that Adobe renamed"
    echo "      the node — diff a real prefs file around that control and update this"
    echo "      script."
  fi
}

# premiere_set_media_cache <plist-domain> <cache-dir> — point Premiere's shared
# "Media Cache Files" location (the Adobe Common prefs) at <cache-dir>, stored
# with a trailing slash. -dict-add updates FolderPath in place, preserving the
# sibling DatabasePath (the Media Cache Database location).
premiere_set_media_cache() {
  local domain="$1" cache_dir="$2"
  defaults write "$domain" "Media Cache" -dict-add FolderPath "${cache_dir%/}/"
}

# audacity_set_pref <cfg> <section> <key> <value> — set a key in Audacity's
# audacity.cfg. Not a plist: it's a wxFileConfig INI, so `defaults` can't touch
# it and the org.audacityteam.audacity.plist next to it holds only window state.
#
# Creates whatever is missing — the file, the [section], the key — because a
# freshly installed Audacity has no cfg at all (it writes one on first quit),
# and a cfg it does write omits every key still at its default. Partial files
# are fine: wxFileConfig merges what's there over the built-in defaults.
#
# Section-scoped by design. Keys are only unique within their section, so the
# key is matched between this section's header and the next one, never
# file-wide. Values go through /e so regex specials in them stay literal.
#
# The key match is [^\r\n]* rather than .* because a migrated CRLF cfg might
# keep its CR: perl's `.` matches a bare \r, and `.*$` would eat it.
audacity_set_pref() {
  local cfg="$1"
  mkdir -p "$(dirname "$cfg")" || return 1
  [ -f "$cfg" ] || : >"$cfg"
  ASP_SECTION="$2" ASP_KEY="$3" ASP_VAL="$4" perl -i -0777 -pe '
    my $sec  = quotemeta $ENV{ASP_SECTION};
    my $key  = quotemeta $ENV{ASP_KEY};
    my $line = $ENV{ASP_KEY} . "=" . $ENV{ASP_VAL};
    # Follow the file s own endings for any line we add; default to LF, which is
    # what Audacity writes here on macOS.
    my $nl = /\r\n/ ? "\r\n" : "\n";
    # \r?$ and \r?\n throughout: on a CRLF cfg a bare ^\[GUI\]$ never matches
    # (the \r sits between "]" and the \n), and the section would be appended a
    # second time instead of edited.
    if (/^\[$sec\]\r?$/m) {
      s{(^\[$sec\]\r?\n)((?:(?!^\[).*\n)*)}{
        my ($hdr, $body) = ($1, $2);
        $body =~ s{^$key=[^\r\n]*}{$line}me or $body = $line . $nl . $body;
        $hdr . $body;
      }me;
    } else {
      $_ .= $nl unless $_ eq "" || /\n$/;
      $_ .= "[$ENV{ASP_SECTION}]" . $nl . $line . $nl;
    }
  ' "$cfg"
}

# Audacity's settings file
AUDACITY_CFG="$HOME/Library/Application Support/audacity/audacity.cfg"

# The Audacity settings we enforce:
#   GUI/DefaultViewModeChoiceNew  default track view mode set to spectrogram
#   Spectrum/MaxFreq              set max frequency of that spectogram
AUDACITY_PREFS=(
  "GUI/DefaultViewModeChoiceNew=Spectrogram"
  "Spectrum/MaxFreq=48000"
)

# audacity_present — is Audacity on this machine? A function rather than an
# inline test because preflight and apply_audacity_prefs must agree.
audacity_present() { [ -d "/Applications/Audacity.app" ]; }

# audacity_applied — true once every AUDACITY_PREFS entry is in the cfg. Each
# entry's tail past the section is already the exact "key=value" line, so it
# greps as a whole line with no reformatting.
audacity_applied() {
  [ -f "$AUDACITY_CFG" ] || return 1
  local pref
  for pref in "${AUDACITY_PREFS[@]}"; do
    grep -qx "${pref#*/}" "$AUDACITY_CFG" || return 1
  done
}

# Managed package lists. Kept above the guard so the test suite can source them
# and confirm every formula/cask still resolves (catches
# renames/delisting/typos).
CORE_FORMULAE="media-info exiftool ffmpeg uv"
CORE_CASKS="vlc caffeine mediainfo"
CORE_UV="triplecheck mhl-suite"
FULL_CASKS="google-chrome adobe-acrobat-reader audacity mediahuman-audio-converter appcleaner"
PREMIERE_CASKS="lucuma13/dit/prem-down"

# Friendly display names for the brew/uv ids (used by the checklist). Anything
# without a mapping passes through unchanged (uv tool names are already
# readable).
pkg_alias() {
  case "$1" in
  media-info) echo "MediaInfo CLI" ;;
  mediainfo) echo "MediaInfo GUI" ;;
  exiftool) echo "ExifTool" ;;
  ffmpeg) echo "FFmpeg" ;;
  vlc) echo "VLC" ;;
  caffeine) echo "Caffeine" ;;
  google-chrome) echo "Google Chrome" ;;
  adobe-acrobat-reader) echo "Adobe Acrobat Reader" ;;
  audacity) echo "Audacity" ;;
  appcleaner) echo "AppCleaner" ;;
  lucuma13/dit/prem-down) echo "prem-down" ;;
  *) echo "$1" ;;
  esac
}

# tidy_workdir <dir> — remove the work dir if the run left nothing in it. A
# machine without Premiere never writes to it, and the admin sub-run would
# otherwise strand an empty folder in the admin's Downloads.
tidy_workdir() {
  rmdir "$1" 2>/dev/null || true
}

# Sourced as a library (tests set LOAD_LIB=1): stop here, run nothing below.
[ -n "${LOAD_LIB:-}" ] && return 0 2>/dev/null

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve the setup mode — prompt when run with no flag
# -----------------------------------------------------------------------------

MODES="$(resolve_mode "$@")"

FAST=false
FULL=false
DRY_RUN=false
case " $MODES " in *" fast "*) FAST=true ;; esac
case " $MODES " in *" full "*) FULL=true ;; esac
case " $MODES " in *" dryrun "*) DRY_RUN=true ;; esac

# --machine-only: an internal re-invocation used by run_machine_via_admin. When
# a standard (non-admin) user runs load, it re-invokes this script as an admin
# with this flag to perform ONLY the machine-wide installs (Homebrew packages,
# /Applications apps, ProVideoFormats) — never the per-user config, which must
# stay with the original account. Not advertised in usage(); always paired with
# --full.
MACHINE_ONLY=false
for _arg in "$@"; do [ "$_arg" = "--machine-only" ] && MACHINE_ONLY=true; done

# No flag given — run the Fast pass inline now (quick config), then pause and
# continue into the Full pass in this same process (see the Dispatch section).
# We need a terminal to prompt for that hand-off; under process substitution
# stdin may be redirected, so probe /dev/tty rather than stdin. Bail if there is
# none (e.g. CI) so we don't run a heavy install unattended.
AUTO=false
if [ -z "$MODES" ] && ! $MACHINE_ONLY; then
  { exec 3<>/dev/tty; } 2>/dev/null || {
    usage
    exit 1
  }
  exec 3>&-
  AUTO=true
  FAST=true
fi

# Phase gates. run_fast applies lightweight config; run_slow does the
# downloads/installs. Both run in this one process: the bare command runs Fast
# inline then continues into Slow; --fast runs Fast only; --full runs both.
RUN_FAST=true
RUN_SLOW=true
$FAST && RUN_SLOW=false
# The admin sub-run does machine-wide installs only: no per-user Fast pass.
$MACHINE_ONLY && {
  RUN_FAST=false
  RUN_SLOW=true
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

PREMIERE_OK=false
[ -d "$HOME/Documents/Adobe/Premiere Pro" ] && PREMIERE_OK=true
# Machine-wide Premiere presence (the app in /Applications), independent of
# whose home holds prefs. The machine-wide plugins (Mister Horse, Flicker Free)
# key off this so they still install when an admin sub-run's own account never
# launched Premiere. Per-user prefs work still keys off PREMIERE_OK.
PREMIERE_MACHINE=false
{ $PREMIERE_OK || ls -d /Applications/Adobe\ Premiere\ Pro* &>/dev/null; } && PREMIERE_MACHINE=true
# Premiere rewrites its prefs on exit — activating a set while it's running
# would get clobbered. Match the process name (version-agnostic) rather than
# full args, which would hit our own perl call.
PREMIERE_RUNNING=false
$PREMIERE_OK && pgrep "Adobe Premiere Pro" &>/dev/null 2>&1 && PREMIERE_RUNNING=true
AUDACITY_OK=false
audacity_present && AUDACITY_OK=true
# Audacity rewrites audacity.cfg wholesale when it quits, so anything we write
# while it's open is discarded on exit.
AUDACITY_RUNNING=false
$AUDACITY_OK && pgrep -x Audacity &>/dev/null 2>&1 && AUDACITY_RUNNING=true
BREW_OK=false
# Homebrew is a single-user tool: its prefix is owned by whoever installed it.
# On a shared Mac a standard user can't write to it (packages are already there
# machine-wide), so track writability separately and gate mutating brew steps on
# it.
BREW_RW=false
if command -v brew &>/dev/null; then
  BREW_OK=true
  [ -w "$(brew_prefix)/Cellar" ] && BREW_RW=true
fi
PVF_OK=false
pkgutil --pkg-info com.apple.pkg.ProVideoFormats &>/dev/null 2>&1 && PVF_OK=true
# Admin accounts can sudo; standard accounts can't, so they hand the machine-wide
# phase to an admin via `su` (see run_machine_via_admin). Membership in the admin
# group is what grants sudo on macOS.
IS_ADMIN=false
id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin && IS_ADMIN=true
# Raw URL of this script, for the admin re-invocation.
SELF_URL="https://raw.githubusercontent.com/lucuma13/load/main/src/load-mac.sh"
# First mounted SCRATCH* volume, or "" if none.
scratch_vols=(/Volumes/SCRATCH*)
SCRATCH=""
[ -d "${scratch_vols[0]}" ] && SCRATCH="${scratch_vols[0]}"

# Work dir — every download (the LUT pack and the plugin installers) goes here, so
# all our temp files live under one folder instead of scattering across ~/Downloads
# (mirrors $WorkDir in load-win.ps1). Created lazily by the phase that
# downloads, so
# a --dry-run leaves the disk untouched.
WORKDIR="$HOME/Downloads/load-mac"

# Premiere shortcut set + workspace we distribute (used by run_fast and the
# "is it applied?" checklist detector).
KYS_FILE="LGG_25.1.kys"
WS_FILE_1="UserWorkspace_LGG_1.xml"
WS_FILE_2="UserWorkspace_LGG_2.xml"

# -----------------------------------------------------------------------------
# Checklist — the live state of every action, derived from the real current
# state plus the run mode. The same call works as a preview (a --dry-run,
# nothing done yet) or as a post-install summary at the end (state reflects what
# ran). Mirrors the sections and merged categories of the checklist in
# load-win.ps1.
# -----------------------------------------------------------------------------

# premiere_applied — true once our shortcut set is active in any Premiere
# profile (the prefs' Shortcuts.Filename points at our .kys).
premiere_applied() {
  $PREMIERE_OK || return 1
  local profile prefs
  for profile in "$HOME/Documents/Adobe/Premiere Pro"/*/Profile-*/; do
    prefs="${profile}Adobe Premiere Pro Prefs"
    [ -f "$prefs" ] || continue
    if grep -qF "<FE.Prefs.Shortcuts.Filename>$KYS_FILE</FE.Prefs.Shortcuts.Filename>" "$prefs"; then
      return 0
    fi
  done
  return 1
}

# luts_present — true once at least one LUT has been downloaded.
luts_present() { ls "$WORKDIR/LUTs/"* >/dev/null 2>&1; }

# apply_audacity_prefs — write every AUDACITY_PREFS entry into audacity.cfg.
#
# Deliberately re-checks for Audacity itself rather than reading the cached
# AUDACITY_OK: it is called twice, and the second call happens after run_slow's
# cask install.
apply_audacity_prefs() {
  audacity_present || return 0
  # Audacity rewrites the whole cfg when it quits, discarding anything we wrote
  # while it was open.
  if pgrep -x Audacity &>/dev/null 2>&1; then
    echo "  ⚠️  Audacity is running — spectrogram settings not changed"
    return 0
  fi
  local pref section entry
  for pref in "${AUDACITY_PREFS[@]}"; do
    section="${pref%%/*}" # e.g. GUI
    entry="${pref#*/}"    # e.g. DefaultViewModeChoiceNew=Spectrogram
    audacity_set_pref "$AUDACITY_CFG" "$section" "${entry%%=*}" "${entry#*=}" ||
      echo "  ⚠️  Audacity settings file could not be written — ${entry%%=*} not changed"
  done
}

# prefs_applied — true once the lightweight System/Finder/TextEdit config is in
# place (probe a representative key, mirroring the Windows keyboard check).
prefs_applied() {
  [ "$(defaults read NSGlobalDomain KeyRepeat 2>/dev/null)" = "2" ] &&
    [ "$(defaults read com.apple.dock autohide 2>/dev/null)" = "1" ]
}

# Premiere plugins already on the machine (detected by install path). Mister
# Horse's Product Manager lands in /Applications; Flicker Free drops its .plugin
# under the shared Adobe MediaCore tree (nested in a "Digital Anarchy/Flicker
# Free AE <ver>" folder), so we search the tree rather than assuming a fixed
# depth.
misterhorse_installed() { ls -d /Applications/*[Mm]ister*[Hh]orse* >/dev/null 2>&1; }
flickerfree_installed() {
  find "/Library/Application Support/Adobe/Common/Plug-ins" -iname "*flicker*free*" -print -quit 2>/dev/null | grep -q .
}

# premdown_pkg_copy — true when prem-down's standalone .pkg build is on the
# machine: it writes a REGULAR FILE to /usr/local/bin/prem-down, whereas the
# cask symlinks into the Homebrew prefix. Deliberately not `command -v` and not
# cask_installed — the regular-file-vs-symlink distinction is the whole point
# (see the adoption step in run_slow), and on an Intel Mac, where the prefix IS
# /usr/local, the two builds land on the very same path.
premdown_pkg_copy() { [ -f /usr/local/bin/prem-down ] && [ ! -L /usr/local/bin/prem-down ]; }

# mediainfo_gui_external — true when a MediaInfo.app is present but NOT managed
# by Homebrew, i.e. installed another way (e.g. the better-integrated Mac App
# Store build; the cask and the App Store build share the same /Applications
# path). We leave that one alone: skip the cask entirely rather than override or
# adopt it.
mediainfo_gui_external() { [ -d "/Applications/MediaInfo.app" ] && ! cask_installed mediainfo; }

checklist() {
  echo ""

  # Premiere Pro — shortcuts, workspace, preferences, media cache and the LUT
  # pack are the editing setup, so they show as one line and all require
  # Premiere installed. (When Premiere is open the files are dropped but not
  # activated.)
  local items="shortcuts, workspace, preferences"
  [ -n "$SCRATCH" ] && items="$items, media cache"
  items="$items, LUTs"
  local premiere_line="Premiere Pro ($items)"
  if ! $PREMIERE_OK; then
    would_skip "$premiere_line — not installed"
  elif $PREMIERE_RUNNING; then
    would_skip "$premiere_line — Premiere Pro is open"
  elif premiere_applied && luts_present; then
    already_done "$premiere_line"
  else
    would_run "$premiere_line"
  fi

  # Audacity — preferences (spectrogram track view).
  local audacity_line="Audacity (preferences)"
  if ! $AUDACITY_OK; then
    would_skip "$audacity_line — not installed"
  elif $AUDACITY_RUNNING; then
    would_skip "$audacity_line — Audacity is open"
  elif audacity_applied; then
    already_done "$audacity_line"
  else
    would_run "$audacity_line"
  fi

  # System, Finder & TextEdit preferences — the lightweight config.
  if prefs_applied; then
    already_done "System, Finder & TextEdit preferences"
  else
    would_run "System, Finder & TextEdit preferences"
  fi

  # Pro Video Formats
  if $PVF_OK; then
    already_done "Pro Video Formats"
  elif $FAST; then
    would_skip "Pro Video Formats (--fast)"
  else
    would_run "Pro Video Formats"
  fi

  # Install or update — Homebrew, managed packages, Premiere plugins and uv
  # tools, each paired with its installed check (mirrors the Windows checklist's
  # one merged line). Friendly names come from pkg_alias.
  local formulae_list="$CORE_FORMULAE" casks_list="$CORE_CASKS"
  $FULL && casks_list="$casks_list $FULL_CASKS"

  local apps_all="" apps_done="" apps_todo="" pkg name

  name="Homebrew"
  apps_all="$apps_all, $name"
  if ! $FAST; then
    if $BREW_OK; then apps_done="$apps_done, $name"; else apps_todo="$apps_todo, $name"; fi
  fi
  for pkg in $formulae_list; do
    name="$(pkg_alias "$pkg")"
    apps_all="$apps_all, $name"
    if ! $FAST; then
      if formula_installed "$pkg"; then apps_done="$apps_done, $name"; else apps_todo="$apps_todo, $name"; fi
    fi
  done
  for pkg in $casks_list; do
    name="$(pkg_alias "$pkg")"
    apps_all="$apps_all, $name"
    if ! $FAST; then
      # MediaInfo GUI counts as done when a MediaInfo.app is already present, even if
      # Homebrew isn't managing it (e.g. an App Store install we deliberately leave alone).
      if cask_installed "$pkg" || { [ "$pkg" = mediainfo ] && mediainfo_gui_external; }; then
        apps_done="$apps_done, $name"
      else
        apps_todo="$apps_todo, $name"
      fi
    fi
  done
  if $PREMIERE_OK; then
    apps_all="$apps_all, Mister Horse"
    if ! $FAST; then
      if misterhorse_installed; then apps_done="$apps_done, Mister Horse"; else apps_todo="$apps_todo, Mister Horse"; fi
    fi
    apps_all="$apps_all, Flicker Free"
    if ! $FAST; then
      if flickerfree_installed; then apps_done="$apps_done, Flicker Free"; else apps_todo="$apps_todo, Flicker Free"; fi
    fi
    for pkg in $PREMIERE_CASKS; do
      name="$(pkg_alias "$pkg")"
      apps_all="$apps_all, $name"
      if ! $FAST; then
        if cask_installed "${pkg##*/}"; then apps_done="$apps_done, $name"; else apps_todo="$apps_todo, $name"; fi
      fi
    done
  fi
  for pkg in $CORE_UV; do
    name="$(pkg_alias "$pkg")"
    apps_all="$apps_all, $name"
    if ! $FAST; then
      if uv_installed "$pkg"; then apps_done="$apps_done, $name"; else apps_todo="$apps_todo, $name"; fi
    fi
  done

  apps_all="${apps_all#, }"
  apps_done="${apps_done#, }"
  apps_todo="${apps_todo#, }"

  if $FAST; then
    would_skip "Install or update (--fast) — $apps_all"
  else
    [ -n "$apps_done" ] && already_done "Install or update: $apps_done"
    [ -n "$apps_todo" ] && would_run "Install or update: $apps_todo"
  fi

  echo ""
}

# -----------------------------------------------------------------------------
# Phase functions
# -----------------------------------------------------------------------------
# run_fast — lightweight preference changes only (no downloads/installs).
# run_slow — everything that downloads or installs, plus the one Finder tweak
# that needs python3 from Command Line Tools. The bare command runs run_fast
# inline then continues into run_slow; --fast runs run_fast only and --full runs both.

run_fast() {
  # System preferences
  defaults write NSGlobalDomain KeyRepeat -int 2
  defaults write NSGlobalDomain InitialKeyRepeat -int 15
  defaults write NSGlobalDomain com.apple.trackpad.scaling -float 2
  defaults write com.apple.dock autohide -bool true
  defaults write com.apple.dock magnification -bool false
  defaults write com.apple.dock mru-spaces -bool false
  defaults write com.apple.dock orientation -string "bottom"
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock tilesize -int 50
  if pmset -g batt | grep -q "InternalBattery"; then # Laptops only
    defaults write com.apple.controlcenter BatteryShowPercentage -bool true
  fi
  killall Dock

  # Finder preferences — the top-level keys. The nested "Calculate all sizes"
  # toggle needs python3 (Command Line Tools), so it lives in run_slow.
  defaults write NSGlobalDomain AppleShowAllExtensions -bool true
  defaults write com.apple.finder ShowPathbar -bool true
  defaults write com.apple.finder ShowStatusBar -bool true
  defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"
  defaults write com.apple.finder NewWindowTarget -string "PfLo"
  defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}/Downloads/"
  killall Finder 2>/dev/null || true

  # TextEdit preferences
  defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
  defaults write NSGlobalDomain NSAutomaticTextCompletionEnabled -bool false
  defaults write com.apple.TextEdit CorrectSpellingAutomatically -bool false
  defaults write com.apple.TextEdit RichText -int 0
  defaults write com.apple.TextEdit ShowRuler -bool false
  defaults write com.apple.TextEdit SmartDashes -bool false
  defaults write com.apple.TextEdit TextReplacement -bool false
  killall cfprefsd
  killall AppleSpell 2>/dev/null || true
  killall TextEdit 2>/dev/null || true

  # Audacity — spectrogram track view and its frequency range. Catches an
  # Audacity already on the machine (however it was installed), so it applies in
  # every mode, --fast included. A fresh machine where our own --full run is
  # what installs Audacity is handled by the second call in run_slow.
  #
  # Safe on a never-launched Audacity that has no cfg yet: it writes one, and
  # Audacity merges a partial hand-written cfg over its defaults and keeps our
  # keys when it rewrites the file on quit (verified).
  apply_audacity_prefs

  # Premiere Pro shortcuts, workspace & labels
  if $PREMIERE_OK; then
    for profile in "$HOME/Documents/Adobe/Premiere Pro"/*/Profile-*/; do
      [ -d "$profile" ] || continue
      prefs="${profile}Adobe Premiere Pro Prefs"

      # Drop the shortcuts into the Profile's Mac folder (where Premiere reads
      # custom sets). Create it first: it only exists once the user has saved a
      # custom set.
      (mkdir -p "${profile}Mac" && cd "${profile}Mac" && curl -fsSL -O "https://raw.githubusercontent.com/lucuma13/load/main/src/data/$KYS_FILE")

      # Drop the workspaces into Layouts. Premiere auto-registers them on
      # launch.
      (mkdir -p "${profile}Layouts" && cd "${profile}Layouts" && curl -fsSL -O "https://raw.githubusercontent.com/lucuma13/load/main/src/data/$WS_FILE_1")
      (cd "${profile}Layouts" && curl -fsSL -O "https://raw.githubusercontent.com/lucuma13/load/main/src/data/$WS_FILE_2")
      ws_name="$(premiere_workspace_name "${profile}Layouts/$WS_FILE_1")"

      if $PREMIERE_RUNNING; then
        echo "  ⚠️  Premiere Pro is running — files dropped but not activated"
      elif [ -f "$prefs" ]; then
        # Version dir sits above Profile-* (e.g. ".../Premiere
        # Pro/25.0/Profile-foo/"), so the warning can be traced to the right
        # install when several coexist.
        customise_premiere_pro "$prefs" "$KYS_FILE" "$ws_name" "$(basename "$(dirname "$profile")")"
      fi
    done

    # Media cache — relocate the "Media Cache Files" location to a SCRATCH drive
    # when one is attached. The setting lives in the shared Adobe "Common" prefs
    # (com.Adobe.Common <ver>), not the Premiere prefs; skip if no SCRATCH
    # drive.
    if [ -n "$SCRATCH" ]; then
      mkdir -p "$SCRATCH/Cache"
      if $PREMIERE_RUNNING; then
        echo "  ⚠️  Premiere Pro is running — media cache not changed"
      else
        for plist in "$HOME/Library/Preferences/com.Adobe.Common "*.plist; do
          [ -f "$plist" ] || continue
          premiere_set_media_cache "$(basename "$plist" .plist)" "$SCRATCH/Cache"
        done
      fi
    fi

    # LUTs — download LUTs into the work directory. The file list comes from the
    # GitHub contents API (new LUTs are picked up automatically)
    LUT_DIR="$WORKDIR/LUTs"
    LUT_API="https://api.github.com/repos/lucuma13/load/contents/src/data/LUTs?ref=main"
    mkdir -p "$LUT_DIR"
    LUT_URLS="$(curl -fsSL "$LUT_API" | grep -o 'https://raw.githubusercontent.com/[^"]*' || true)"
    for url in $LUT_URLS; do
      (cd "$LUT_DIR" && curl -fsSL -O "$url")
    done
  fi
}

run_slow() {
  # Privilege split. Machine-wide installs (Homebrew packages, /Applications
  # apps, ProVideoFormats) need admin/root; per-user config (Finder, uv tools,
  # Downloads sort) must run as the current account. An admin does both here. A
  # standard user can't sudo, so it hands the machine-wide phase to an admin via
  # `su` and then does its own per-user phase; if no admin is available it
  # configures the user only.
  local DO_MACHINE=false DO_USER=true
  if $MACHINE_ONLY; then
    DO_MACHINE=true # this is the admin sub-run: machine-wide steps only
    DO_USER=false
  elif $IS_ADMIN; then
    DO_MACHINE=true # admin account: sudo works, do everything in this process
  else
    local machine_rc=0
    run_machine_via_admin || machine_rc=$?
    case "$machine_rc" in
    0) ;;
    2) would_skip "Machine-wide installs skipped — no admin account available (configuring this user only)" ;;
    3) would_skip "Machine-wide installs skipped at your request (configuring this user only)" ;;
    *) echo "  ⚠️  The admin account's machine-wide install didn't finish cleanly (see output above) — some packages may be missing; continuing with per-user config" ;;
    esac
  fi

  # Command Line Tools (provides git/python3; required by Homebrew). Without
  # this, a fresh Mac triggers the Xcode CLT dialog mid-run and aborts; we pop
  # the installer and wait for it to finish.
  if $DO_MACHINE && ! xcode-select -p &>/dev/null; then
    echo "  Installing Command Line Tools… (Accept the dialog - this can take a few minutes)…"
    xcode-select --install &>/dev/null || true
    # The installer window opens behind the terminal, so nudge it to the front
    # while we wait so the user doesn't miss the dialog.
    until xcode-select -p &>/dev/null; do
      osascript -e 'tell application "System Events" to set frontmost of (first process whose name is "Install Command Line Developer Tools") to true' &>/dev/null || true
      sleep 10
    done
  fi

  # Finder "Calculate all sizes" — a nested plist key defaults(1) can't reach,
  # so we edit it with python3. Quit Finder first so it doesn't rewrite the
  # plist on exit and clobber the edit.
  if $DO_USER && command -v python3 &>/dev/null; then
    osascript -e 'tell application "Finder" to quit'
    sleep 2
    plutil -convert xml1 ~/Library/Preferences/com.apple.finder.plist
    python3 -c "
import plistlib, os
path = os.path.expanduser('~/Library/Preferences/com.apple.finder.plist')
p = plistlib.load(open(path,'rb'))
def f(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k=='calculateAllSizes':
                o[k]=True
            else:
                f(v)
    elif isinstance(o,list):
        for i in o:
            f(i)
f(p)
plistlib.dump(p,open(path,'wb'))
"
    sleep 1
    open -a Finder
  elif $DO_USER; then
    echo "  ⚠️  Finder 'Calculate all sizes' skipped — python3 not available"
  fi

  # Homebrew — install it, or refresh it (update + cleanup) when already
  # present.
  if $DO_MACHINE && ! $BREW_OK; then
    # Pre-authenticate so Homebrew's own installer (which needs sudo to set up
    # its prefix) doesn't prompt separately — its own `have_sudo_access` check
    # succeeds silently against an already-valid ticket.
    sudo -v
    would_run "Installing Homebrew…"
    echo | quiet_run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    PREFIX="$(brew_prefix)"
    SHELLENV_LINE="eval \"\$(${PREFIX}/bin/brew shellenv)\""
    echo >>"$HOME/.zprofile"
    echo "$SHELLENV_LINE" >>"$HOME/.zprofile"
    eval "$("${PREFIX}/bin/brew" shellenv)"
    BREW_RW=true # just installed under this user, so its prefix is ours to write
  fi

  # Ensure brew is in PATH even if already installed
  PREFIX="$(brew_prefix)"
  eval "$("${PREFIX}/bin/brew" shellenv)" 2>/dev/null || true

  # Homebrew's prefix belongs to another account (a standard user on a shared
  # Mac): packages are already installed machine-wide, so skip every mutating
  # brew step and carry on with the per-user setup below (defaults, Premiere,
  # per-user uv tools).
  if $DO_MACHINE && $BREW_OK && ! $BREW_RW; then
    would_skip "Homebrew is managed by another account — packages already installed machine-wide"
  elif $DO_MACHINE; then
    # Update a pre-existing Homebrew (but don't upgrade packages that are not
    # ours). A bare `brew cleanup` evaluates EVERY installed package, and
    # Homebrew >=6 refuses to load one from a third-party tap the user hasn't
    # `brew trust`ed — someone else's tap would then fail the run. So we name
    # clean-up only our packages, any we name that aren't installed are a silent
    # no-op (housekeeping, so never fatal).
    if $BREW_OK; then
      checking "Homebrew"
      soft_run brew update
      local cleanup_pkgs="$CORE_FORMULAE $CORE_CASKS $FULL_CASKS"
      cask_installed prem-down && cleanup_pkgs="$cleanup_pkgs $PREMIERE_CASKS"
      soft_run brew cleanup $cleanup_pkgs
    fi

    # Core managed packages. Skip the MediaInfo GUI cask only when a
    # MediaInfo.app is present but NOT brew-managed (e.g. the better-integrated
    # App Store build) — don't override or adopt it.
    checking "core packages"
    quiet_run brew install --adopt $CORE_FORMULAE
    local core_casks="" core_casks_preexisting=""
    for cask in $CORE_CASKS; do
      [ "$cask" = mediainfo ] && mediainfo_gui_external && continue
      core_casks="$core_casks $cask"
      cask_installed "$cask" && core_casks_preexisting="$core_casks_preexisting $cask"
    done
    # install --adopt brings in anything missing; upgrade --greedy then updates
    # only the casks that were ALREADY installed before this run. A cask adopted
    # moments ago above is already at the latest version, so greedy-checking it
    # again is redundant work — and for a pkg-based cask (e.g.
    # adobe-acrobat-reader) it's a second separate `brew` process, which
    # re-authenticates sudo on every invocation and can prompt for the password
    # a second time in a row for no actual gain.
    install_casks $core_casks
    [ -n "$core_casks_preexisting" ] && soft_run brew upgrade --cask --greedy $core_casks_preexisting

    # Premiere Pro add-ons — machine-wide and gated on Premiere being installed,
    # exactly like the plugins further down.
    if $PREMIERE_MACHINE; then
      checking "Premiere Pro utilities"
      if premdown_pkg_copy; then
        would_run "Adopting the standalone prem-down install into Homebrew"
        sudo rm -f /usr/local/bin/prem-down || true
      fi
      local premiere_casks_preexisting=""
      for cask in $PREMIERE_CASKS; do
        cask_installed "${cask##*/}" && premiere_casks_preexisting="$premiere_casks_preexisting $cask"
      done
      install_casks $PREMIERE_CASKS
      [ -n "$premiere_casks_preexisting" ] && soft_run brew upgrade --cask $premiere_casks_preexisting
    fi
  fi
  # --quiet drops uv's resolve/install progress on success but still prints
  # errors. All of this is per-user: the tools install into ~/.local and
  # update-shell writes the current account's shell profile — the admin sub-run
  # must not touch it (it would edit the admin's profile and warn about its
  # PATH).
  if $DO_USER; then
    checking "uv tools"
    for pkg in $CORE_UV; do uv tool install "$pkg" --upgrade --quiet; done
    # Ensure uv-installed CLI tools (~/.local/bin) are on PATH. `uv tool
    # update-shell` detects the active shell and updates the right profile
    # (safer than hardcoding ~/.zprofile). Idempotent. Export covers the current
    # session.
    command -v uv &>/dev/null && uv tool update-shell --quiet || true
    export PATH="$HOME/.local/bin:$PATH"
  fi

  # Downloads sort — put ~/Downloads in list view, sorted by Date Added (newest
  # first). A folder's view/sort has no `defaults` key, and Finder's AppleScript
  # view columns are locked down on recent macOS, so the only route is the
  # binary .DS_Store. It lives in the *parent* (~/.DS_Store) under the
  # "Downloads" record: vstl=Nlsv (list view) + lsvC.sortColumn=dateAdded (that
  # column is already newest-first). We edit it with the `ds_store` library,
  # fetched on demand via uvx (uv is installed above). Finder buffers .DS_Store
  # in memory and rewrites it on quit, so we write while Finder is quit, then
  # relaunch. Fully guarded: missing uv, no network or an unreadable/odd store
  # just prints a note and the run continues.
  if $DO_USER && command -v uvx &>/dev/null; then
    osascript -e 'tell application "Finder" to quit' 2>/dev/null || true
    sleep 2
    uvx --from ds-store python3 - <<'PY' 2>/dev/null || echo "  ⚠️  Downloads sort skipped (couldn't update .DS_Store)"
import os, plistlib
import ds_store

home = os.path.expanduser('~/.DS_Store')
# Standard list-view columns — used only when the Downloads record has no lsvC yet
# (e.g. a fresh Mac where Downloads was never opened in list view); Finder reconciles
# the rest. An existing lsvC is edited in place so the user's columns/widths survive.
TEMPLATE = {
    'viewOptionsVersion': 1, 'sortColumn': 'dateAdded', 'useRelativeDates': True,
    'showIconPreview': True, 'calculateAllSizes': True,
    'iconSize': 16.0, 'textSize': 13.0, 'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
    'columns': [
        {'identifier': 'name',         'visible': True, 'width': 300, 'ascending': True},
        {'identifier': 'dateModified', 'visible': True, 'width': 181, 'ascending': False},
        {'identifier': 'dateAdded',    'visible': True, 'width': 181, 'ascending': False},
        {'identifier': 'size',         'visible': True, 'width': 97,  'ascending': False},
        {'identifier': 'kind',         'visible': True, 'width': 115, 'ascending': True},
    ],
}
def apply_downloads_sort(mode):
    with ds_store.DSStore.open(home, mode) as d:
        ent = {e.code: e for e in d if e.filename == 'Downloads'} if mode == 'r+' else {}
        # View style -> list
        if b'vstl' in ent:
            d.delete('Downloads', b'vstl')
        d.insert(ds_store.DSStoreEntry('Downloads', b'vstl', b'type', b'Nlsv'))
        # Sort -> Date Added, newest first
        pl = plistlib.loads(bytes(ent[b'lsvC'].value)) if b'lsvC' in ent else dict(TEMPLATE)
        pl['sortColumn'] = 'dateAdded'
        for c in pl.get('columns', []):
            if c.get('identifier') == 'dateAdded':
                c['visible'] = True
                c['ascending'] = False   # newest first
        if b'lsvC' in ent:
            d.delete('Downloads', b'lsvC')
        d.insert(ds_store.DSStoreEntry('Downloads', b'lsvC', b'blob',
                                       plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)))

try:
    apply_downloads_sort('r+' if os.path.exists(home) else 'w+')
except Exception:
    # A heavily-used ~/.DS_Store can pack a B-tree node right up to its 4KB page
    # limit; inserting our entry there can overflow a known bug in the ds-store
    # library (store.py _split -> _split2 returns None, unhandled). ~/.DS_Store
    # only caches Finder view state (icon positions, window sizes, per-folder
    # view options) that Finder regenerates on demand, so recover by dropping it
    # and rebuilding fresh rather than trying to repair the existing B-tree.
    try:
        if os.path.exists(home):
            os.remove(home)
        apply_downloads_sort('w+')
        print("  ⚠️  ~/.DS_Store was rebuilt from scratch (existing Finder view state was too bloated to edit in place)")
    except Exception as ex2:
        print("  ⚠️  Downloads sort skipped:", ex2)
PY
    sleep 1
    open -a Finder 2>/dev/null || true
  fi

  # Full-only managed packages
  if $DO_MACHINE && $FULL && $BREW_RW; then
    checking "extra packages"
    local full_casks_preexisting=""
    for cask in $FULL_CASKS; do
      cask_installed "$cask" && full_casks_preexisting="$full_casks_preexisting $cask"
    done
    # See the core-casks block above: skip the greedy upgrade for casks just
    # adopted in the `install` call right above it — already at the latest
    # version, and re-checking them is a second `brew` process that can
    # re-prompt for sudo on pkg-based casks like adobe-acrobat-reader.
    install_casks $FULL_CASKS
    [ -n "$full_casks_preexisting" ] && soft_run brew upgrade --cask --greedy $full_casks_preexisting
  fi

  # Audacity preferences, second pass. run_fast already covered an Audacity that
  # was on the machine before this run; this catches the one the --full block
  # just installed. Kept in the per-user phase because it writes into $HOME —
  # the admin sub-run must not run it or the settings would land in the admin's
  # home.
  if $DO_USER; then apply_audacity_prefs; fi

  # Cache sudo credentials right here — not at the top of this function —
  # because `brew` resets any cached sudo timestamp on every single invocation
  # as a deliberate security measure (see brew.sh: "Reset sudo timestamp to
  # avoid running unauthorized sudo commands"), so authenticating before the
  # Homebrew/uv work above would just get silently wiped before we ever needed
  # it. Nothing below this point calls `brew` again, so one prompt here covers
  # every privileged step below it (kept alive across slow downloads just in
  # case).
  if $DO_MACHINE && { $PREMIERE_MACHINE || ! $PVF_OK; }; then
    sudo -v
    while true; do
      sudo -n true || true
      sleep 60
      kill -0 "$$" || exit
    done 2>/dev/null &
  fi

  # Every installer below downloads into the work dir; create it once up front.
  $DO_MACHINE && mkdir -p "$WORKDIR"

  # Premiere plugins — Mister Horse's Product Manager installs & updates
  # Animation Composer (and the other Mister Horse plugins) into Premiere/After
  # Effects. We download the Product Manager installer and run it; Animation
  # Composer itself is then installed from within the app on first launch.
  if $DO_MACHINE && $PREMIERE_MACHINE; then
    checking "plugins"
    PM_DMG="$WORKDIR/MisterHorseProductManager.dmg"
    curl -fsSL -o "$PM_DMG" "https://misterhorse.com/downloads/product-manager/osx"
    VOL="$(hdiutil attach "$PM_DMG" -nobrowse | grep -o '/Volumes/.*' | head -1 || true)"
    PM_APP="$(find "$VOL" -maxdepth 1 -name '*.app' 2>/dev/null | head -1 || true)"
    [ -n "$PM_APP" ] && quiet_run sudo cp -R "$PM_APP" /Applications/
    [ -n "$VOL" ] && hdiutil detach "$VOL" -quiet
    rm -f "$PM_DMG"

    # Flicker Free — Digital Anarchy's deflicker plugin. The DMG holds a .pkg we
    # install straight to the system; the plugin then shows up in Premiere/AE.
    FF_DMG="$WORKDIR/flickerfree_229_AE.dmg"
    curl -fsSL -o "$FF_DMG" "https://www.digitalanarchy.com/downloads/flickerfree_229_AE.dmg"
    FF_VOL="$(hdiutil attach "$FF_DMG" -nobrowse | grep -o '/Volumes/.*' | head -1 || true)"
    FF_PKG="$(find "$FF_VOL" -maxdepth 1 -name '*.pkg' 2>/dev/null | head -1 || true)"
    # The pkg's preinstall script unconditionally runs `open <registration
    # URL>`, popping Digital Anarchy's sign-up page in the default browser —
    # pure noise on an unattended run. Close the tab that lands on that URL — in
    # Safari and Chrome - and clean up if that leaves an empty window behind.
    # The app name must be a literal in the AppleScript (interpolated per call
    # from bash) — `tell application appName` with appName as an AppleScript
    # variable breaks Safari/Chrome's `tabs of window` coercion (-1700,
    # confirmed by hand).
    [ -n "$FF_PKG" ] && quiet_run sudo installer -pkg "$FF_PKG" -target /
    sleep 3
    for ff_browser_app in "Safari" "Google Chrome"; do
      osascript <<APPLESCRIPT &>/dev/null || true
if application "$ff_browser_app" is running then
  tell application "$ff_browser_app"
    set matchingTabs to {}
    repeat with w in windows
      repeat with t in tabs of w
        if (URL of t contains "digitalanarchy.com") and (URL of t contains "registration") then
          set end of matchingTabs to t
        end if
      end repeat
    end repeat
    repeat with t in matchingTabs
      close t
    end repeat
    set emptyWindows to {}
    repeat with w in windows
      if (count of tabs of w) = 0 then set end of emptyWindows to w
    end repeat
    repeat with w in emptyWindows
      close w
    end repeat
  end tell
end if
APPLESCRIPT
    done
    [ -n "$FF_VOL" ] && hdiutil detach "$FF_VOL" -quiet
    rm -f "$FF_DMG"
  fi

  # Pro Video Formats
  if $DO_MACHINE && ! $PVF_OK; then
    DMG_URL="https://updates.cdn-apple.com/2026/macos/072-84099-20260127-5022F0FE-82CF-44E9-B96D-430E73501EBA/ProVideoFormats.dmg"
    DMG_PATH="$WORKDIR/ProVideoFormats.dmg"

    if [ ! -f "$DMG_PATH" ]; then
      curl -fsSL -o "$DMG_PATH" "$DMG_URL"
    fi

    hdiutil attach "$DMG_PATH" -nobrowse -quiet
    quiet_run sudo installer -pkg "/Volumes/Pro Video Formats/ProVideoFormats.pkg" -target /
    hdiutil detach "/Volumes/Pro Video Formats" -quiet
    rm -f "$DMG_PATH"
  fi
}

# -----------------------------------------------------------------------------
# Dispatch — run_fast inline; the bare command then continues into the Full
# pass, and run_slow does the downloads/installs.
#
# Wrapped in main() and invoked only on the very last line. Under `bash <(curl
# …)` the script is read from the stream as it runs, so bash must parse this
# whole function (through its closing brace) before it can call it: a truncated
# download fails to parse and runs nothing that touches the system. Everything
# above main is read-only detection, so it's safe even if a partial read aborts
# before main. Keep the call bare (`main "$@"`) — invoking it in a conditional
# would disable `set -e` inside main.
# -----------------------------------------------------------------------------

main() {
  # --dry-run just prints the checklist, then stops.
  if $DRY_RUN; then
    echo ""
    echo "  🔍  Dry run — nothing will be changed."
    checklist
    echo "  🔍  Nothing was changed. Re-run without --dry-run to do the above."
    echo ""
    exit 0
  fi

  if $RUN_FAST; then run_fast; fi

  if $AUTO; then
    # Fast pass finished. Prompt, then continue into the Full pass in this same
    # process — flip the mode flags so run_slow and the summary below behave as
    # a full run. The single post-install summary at the end covers this Fast
    # pass too.
    exec 3<>/dev/tty
    printf ""
    printf '%s' "

  ▶️  Fast loading is complete. Press (y) or Enter to continue on FULL mode " >&3
    # A single keypress: y/Y continues without enter, and enter alone (an empty
    # read) continues too. Anything else is ignored so a stray key can't skip
    # the Full pass. A failed read (no tty) falls through rather than spinning.
    while read -rsn1 key <&3; do
      case "$key" in
      "" | y | Y) break ;;
      esac
    done
    echo ""
    exec 3>&-
    FAST=false
    FULL=true
    RUN_SLOW=true
  fi

  if $RUN_SLOW; then run_slow; fi

  # Both passes are done, so anything still in the work dir is a keeper. Runs
  # before the MACHINE_ONLY return below so the admin sub-run tidies up after
  # itself too.
  tidy_workdir "$WORKDIR"

  # The admin sub-run is one phase of the caller's run — it prints its own
  # progress; the caller shows the summary. Don't print a second
  # checklist/restart notice here.
  if $MACHINE_ONLY; then
    echo "  ✅  Machine-wide install complete."
    return 0
  fi

  # Summary
  checklist
  echo "  🛼  You're ready to roll!"
  echo ""
  echo "  ⚠️  Please restart the computer for all changes to take effect"
  echo ""
}

main "$@"
