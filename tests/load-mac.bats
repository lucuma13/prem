#!/usr/bin/env bats
#
# Tests for load-mac.sh.

setup() {
  DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" >/dev/null 2>&1 && pwd)"
  export BATS_LIB_PATH="$DIR/../node_modules${BATS_LIB_PATH:+:$BATS_LIB_PATH}"
  bats_load_library bats-support
  bats_load_library bats-assert
  LOAD_LIB=1 source "$DIR/../src/load-mac.sh"
  PREFS="$BATS_TEST_TMPDIR/prefs"
  CFG="$BATS_TEST_TMPDIR/audacity.cfg"
  # Discover every captured version; adding a premiere_pro_* fixture dir is enough.
  PREMIERE_VERSIONS=()
  for d in "$DIR"/fixtures/premiere_pro_*/; do
    [ -d "$d" ] && PREMIERE_VERSIONS+=("$(basename "$d")")
  done
  MEDIA_CACHE_DOMAIN="test.load.mediacache"
  defaults delete "$MEDIA_CACHE_DOMAIN" 2>/dev/null || true
}

teardown() {
  defaults delete "$MEDIA_CACHE_DOMAIN" 2>/dev/null || true
}

# Truncation safety: the installer's work is wrapped in main(), invoked on the very
# last line, so bash parses the whole script before running anything - a dropped
# connection can't half-execute it (see the header comment).
@test "main is invoked only on the final line (truncation safety)" {
  run awk 'NF{l=$0} END{print l}' "$DIR/../src/load-mac.sh"
  assert_output 'main "$@"'
}

# The bare (auto) run and --fast execute only run_fast; every privileged step lives
# in run_slow. Guard that run_fast escalates nothing, so the quick pass never blocks
# on a sudo prompt - especially under the unattended auto hand-off. Parses the
# function body from the script text (col-0 '}' closes the function).
@test "run_fast performs no sudo (the fast pass needs no root)" {
  run awk '/^run_fast\(\) \{/{c=1} c{print} c&&/^\}/{exit}' "$DIR/../src/load-mac.sh"
  assert_output --partial 'defaults write com.apple.dock' # guard: body actually captured
  refute_output --partial 'sudo'
}

# Copy the given version's prefs fixture into the per-test temp file.
#
# The prefs fixtures are LF, and that is a faithful capture on BOTH platforms -
# Premiere writes this file LF even on Windows (unlike UserWorkspace*.xml, which
# is CRLF there). Do not "fix" them to CRLF to match the workspace fixtures; the
# two files genuinely differ. See set_pref_node in load-mac.sh.
copy_prefs() { cp "$DIR/fixtures/$1/Adobe Premiere Pro Prefs_truncated" "$PREFS"; }

@test "shortcut set is activated" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    customise_premiere_pro "$PREFS" "LGG_25.1.kys" "LGG - Single monitor" "$v"
    run cat "$PREFS"
    assert_output --partial '<FE.Prefs.Shortcuts.Filename>LGG_25.1.kys</FE.Prefs.Shortcuts.Filename>'
  done
}

@test "workspace is activated, spaces preserved" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    customise_premiere_pro "$PREFS" "LGG_25.1.kys" "LGG - Single monitor" "$v"
    run cat "$PREFS"
    assert_output --partial '<FE.Application.LastWorkspaceName>LGG - Single monitor</FE.Application.LastWorkspaceName>'
  done
}

@test "labels switch to Classic (names + colours + marker)" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    customise_premiere_pro "$PREFS" "x.kys" "WS" "$v"
    run cat "$PREFS"
    assert_output --partial '<BE.Prefs.LabelNames.0>Violet</BE.Prefs.LabelNames.0>'
    assert_output --partial '<BE.Prefs.LabelNames.15>Yellow</BE.Prefs.LabelNames.15>'
    assert_output --partial '<BE.Prefs.LabelColors.0>14717094</BE.Prefs.LabelColors.0>'
    assert_output --partial '<BE.Prefs.LabelColors.15>6611682</BE.Prefs.LabelColors.15>'
    assert_output --partial '"name":"Classic"'
    refute_output --partial 'Vibrant'
  done
}

@test "auto-save enabled every 5 minutes, keeping 200 project versions" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    customise_premiere_pro "$PREFS" "x.kys" "WS" "$v"
    run cat "$PREFS"
    assert_output --partial '<BE.Prefs.AutoSave.DoSave>true</BE.Prefs.AutoSave.DoSave>'
    assert_output --partial '<BE.Prefs.AutoSave.Interval>5</BE.Prefs.AutoSave.Interval>'
    assert_output --partial '<BE.Prefs.AutoSave.MaxProjectVersions>200</BE.Prefs.AutoSave.MaxProjectVersions>'
  done
}

# Major version of a fixture dir ("premiere_pro_v25.6.6" -> 25).
premiere_major() { [[ "$1" =~ v([0-9]+)\. ]] && printf '%s' "${BASH_REMATCH[1]}"; }

# Read the force-written prefs straight from the `forced=(...)` table in the
# script, one "node|value|min-major" row each (the trailing UI-label comment is
# stripped). Adding a row there automatically adds its checks below - no test
# edit needed.
forced_prefs() {
  awk '
    /^  local forced=\(/ { capture = 1; next }
    capture && /^  \)/ { exit }
    capture {
      sub(/#.*$/, "", $0)
      gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", $0)
      if ($0 != "") print $0
    }
  ' "$DIR/../src/load-mac.sh"
}

# The same table and the same force-write whitelist live in load-win.ps1: each
# installer is invoked as a single downloaded script, so neither can read a shared
# file on the target machine. Guard the two copies against drift here.
forced_prefs_win() {
  awk '/\$forced = @\(/,/^    \)/' "$DIR/../src/load-win.ps1" | grep -oE "'[^']+'" | tr -d "'"
}

@test "the forced pref table matches the one in load-win.ps1" {
  local win
  win="$(forced_prefs_win)"
  [ -n "$win" ] # non-empty, so a silently non-matching parse can't pass vacuously
  assert_equal "$(forced_prefs)" "$win"
}

@test "the force-write version whitelist matches the one in load-win.ps1" {
  local mac win
  mac="$(grep -oE '^ *[0-9]+( \| [0-9]+)*\) force_pref_node' "$DIR/../src/load-mac.sh" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')"
  win="$(grep -oE '\$major -in [0-9, ]+' "$DIR/../src/load-win.ps1" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')"
  [ -n "$mac" ]
  assert_equal "$mac" "$win"
}

# Strip every forced node from $PREFS, simulating a fresh install where Premiere
# has not written any of them yet.
strip_forced() {
  local node rest
  while IFS='|' read -r node rest; do
    sed -i.bak -E "/<${node//./\\.}>/d" "$PREFS"
  done <<<"$1"
}

@test "every forced pref in the script table is written, respecting its version floor" {
  local rows node value min
  rows="$(forced_prefs)"
  [ -n "$rows" ] # guard: parsing must find at least one row
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    run customise_premiere_pro "$PREFS" "x.kys" "WS" "$v"
    assert_success
    refute_output --partial 'not found and skipped'
    run cat "$PREFS"
    assert_output --partial '<TL.PREFLinkedSelectionState>true</TL.PREFLinkedSelectionState>'
    while IFS='|' read -r node value min; do
      if [ -n "$min" ] && [ "$(premiere_major "$v")" -lt "$min" ]; then
        refute_output --partial "$node" # predates the preference: never written
      else
        assert_output --partial "<$node>$value</$node>"
      fi
    done <<<"$rows"
  done
}

# The forced nodes are absent on a fresh install - they must be created, but only
# on the whitelisted versions.
@test "forced prefs are created when absent on a whitelisted version" {
  local rows node value min
  rows="$(forced_prefs)"
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    strip_forced "$rows"
    run customise_premiere_pro "$PREFS" "x.kys" "WS" "$v"
    assert_success
    refute_output --partial 'not found and skipped'
    run cat "$PREFS"
    while IFS='|' read -r node value min; do
      if [ -n "$min" ] && [ "$(premiere_major "$v")" -lt "$min" ]; then
        refute_output --partial "$node"
      else
        assert_output --partial "<$node>$value</$node>"
      fi
    done <<<"$rows"
    run xmllint --noout "$PREFS"
    assert_success
  done
}

# On a non-whitelisted version an absent node is reported and skipped, leaving
# the file untouched for it.
@test "forced prefs are skipped (not created) on a non-whitelisted version" {
  local rows node rest
  rows="$(forced_prefs)"
  copy_prefs "${PREMIERE_VERSIONS[0]}"
  strip_forced "$rows"
  run customise_premiere_pro "$PREFS" "x.kys" "WS" "0.0"
  assert_success
  assert_output --partial 'not found and skipped'
  assert_output --partial 'TL.PREFShowThroughEditsState'
  run cat "$PREFS"
  while IFS='|' read -r node rest; do
    refute_output --partial "<$node>"
  done <<<"$rows"
}

@test "output prefs is valid XML" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    customise_premiere_pro "$PREFS" "x.kys" "WS" "$v"
    run xmllint --noout "$PREFS"
    assert_success
  done
}

@test "no BOM is introduced" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    customise_premiere_pro "$PREFS" "x.kys" "WS" "$v"
    run head -c 3 "$PREFS"
    assert_output '<?x' # would be the UTF-8 BOM bytes if perl had added one
  done
}

@test "idempotent: second run is byte-identical" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    customise_premiere_pro "$PREFS" "LGG_25.1.kys" "LGG - Single monitor" "$v"
    cp "$PREFS" "$PREFS.first"
    customise_premiere_pro "$PREFS" "LGG_25.1.kys" "LGG - Single monitor" "$v"
    run cmp -s "$PREFS.first" "$PREFS"
    assert_success
  done
}

@test "a renamed node is reported and skipped without corrupting others" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    copy_prefs "$v"
    # simulate a future Premiere renaming one node
    sed -i.bak 's/TL.PREFLinkedSelectionState/TL.PREFLinkedSelectionStateRENAMED/g' "$PREFS"
    run customise_premiere_pro "$PREFS" "LGG_25.1.kys" "LGG - Single monitor" "$v"
    assert_success
    assert_output --partial 'not found and skipped'
    assert_output --partial 'Adobe renamed'
    assert_output --partial 'TL.PREFLinkedSelectionState'
    run xmllint --noout "$PREFS"
    assert_success
    run cat "$PREFS"
    assert_output --partial '<BE.Prefs.AutoSave.Interval>5</BE.Prefs.AutoSave.Interval>'                     # others still applied
    assert_output --partial '<TL.PREFLinkedSelectionStateRENAMED>false</TL.PREFLinkedSelectionStateRENAMED>' # renamed node untouched
  done
}

# set_pref_node is the engine under customise_premiere_pro. Its "no edit = no
# corruption" contract - a missing node leaves the file byte-for-byte untouched -
# is the safety guarantee the rest of the prefs handling relies on, so exercise it
# directly (mirrors load-win.ps1's Set-PrefNode tests).
@test "set_pref_node replaces a present node's value and succeeds" {
  printf '<root><x>old</x></root>' >"$PREFS"
  run set_pref_node "$PREFS" "x" "new"
  assert_success
  run cat "$PREFS"
  assert_output --partial '<x>new</x>'
}

# Guards the EOL-preserving contract documented on set_pref_node: the perl edit
# substitutes within a line and must leave the record separators alone. A CRLF file
# is the shape a normalising rewrite would visibly destroy, so it is what we assert
# on - it also shows the installer can't be what re-ended a synced Windows prefs.
@test "set_pref_node preserves the file's line endings" {
  printf '<root>\r\n<x>old</x>\r\n</root>\r\n' >"$PREFS"
  run set_pref_node "$PREFS" "x" "new"
  assert_success
  # Every ending still CRLF, and the value did change.
  run perl -0777 -ne 'my $crlf=()=/\r\n/g; my $bare=()=/(?<!\r)\n/g; print "crlf=$crlf bare=$bare"' "$PREFS"
  assert_output 'crlf=3 bare=0'
  run grep -c '<x>new</x>' "$PREFS"
  assert_success
}

@test "set_pref_node fails and leaves the file untouched when the node is absent" {
  printf '<root><x>old</x></root>' >"$PREFS"
  cp "$PREFS" "$PREFS.orig"
  run set_pref_node "$PREFS" "missing" "new"
  assert_failure
  run cmp -s "$PREFS.orig" "$PREFS"
  assert_success
}

# The value reaches perl via the SPN_VAL env var precisely so regex/JSON specials
# in it are written literally, not interpreted as substitution metacharacters
# (& = whole match, $1/\1 = capture refs). Guards that escaping contract.
@test "set_pref_node writes a value with regex/JSON specials literally" {
  printf '<root><x>old</x></root>' >"$PREFS"
  local val='R&D $1 \1 {"k":2}'
  run set_pref_node "$PREFS" "x" "$val"
  assert_success
  run cat "$PREFS"
  assert_output --partial "<x>${val}</x>"
}

@test "premiere_workspace_name extracts the UserName" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    run premiere_workspace_name "$DIR/fixtures/$v/UserWorkspace_truncated.xml"
    assert_output 'LGG - Single monitor'
  done
}

# The fixtures are LF because that is what Premiere authors on macOS, but the same
# file is pure CRLF when Premiere authors it on Windows. A surviving \r would be
# written verbatim into the prefs, so the name must come back byte-identical from
# both shapes. Derived from the LF fixture so the two can never drift apart.
@test "premiere_workspace_name is line-ending agnostic (CRLF workspace)" {
  for v in "${PREMIERE_VERSIONS[@]}"; do
    crlf="$BATS_TEST_TMPDIR/ws_crlf_$v.xml"
    perl -pe 's/\n/\r\n/' "$DIR/fixtures/$v/UserWorkspace_truncated.xml" >"$crlf"
    # Guard: the conversion actually produced CRLF, so this can't pass vacuously.
    run grep -c $'\r$' "$crlf"
    assert_success
    run premiere_workspace_name "$crlf"
    assert_output 'LGG - Single monitor'
  done
}

# audacity_set_pref edits a wxFileConfig INI, so it has to do its own
# section/key handling. These cover the four shapes it meets in the wild: the key
# already present, the section present but the key still at its default, no
# section at all, and no file at all (a cask install Audacity has never been
# launched from).
@test "audacity_set_pref replaces an existing key in place" {
  printf 'PrefsVersion=1.1.1r1\n[GUI]\nTheme=classic\nDefaultViewModeChoiceNew=Waveform\n[Tracks]\nAutoScroll=1\n' >"$CFG"
  run audacity_set_pref "$CFG" GUI DefaultViewModeChoiceNew Spectrogram
  assert_success
  run cat "$CFG"
  assert_output 'PrefsVersion=1.1.1r1
[GUI]
Theme=classic
DefaultViewModeChoiceNew=Spectrogram
[Tracks]
AutoScroll=1'
}

@test "audacity_set_pref adds the key when the section exists without it" {
  printf '[GUI]\nTheme=classic\n[Tracks]\nAutoScroll=1\n' >"$CFG"
  run audacity_set_pref "$CFG" GUI DefaultViewModeChoiceNew Spectrogram
  assert_success
  run cat "$CFG"
  assert_output '[GUI]
DefaultViewModeChoiceNew=Spectrogram
Theme=classic
[Tracks]
AutoScroll=1'
}

@test "audacity_set_pref appends the section when it is absent" {
  printf 'PrefsVersion=1.1.1r1\n[Tracks]\nAutoScroll=1\n' >"$CFG"
  run audacity_set_pref "$CFG" GUI DefaultViewModeChoiceNew Spectrogram
  assert_success
  run cat "$CFG"
  assert_output 'PrefsVersion=1.1.1r1
[Tracks]
AutoScroll=1
[GUI]
DefaultViewModeChoiceNew=Spectrogram'
}

# The fresh-install path: Audacity writes no cfg (and no containing directory)
# until it first quits, so the helper must author both or the setting would only
# ever land on a second run of the installer.
@test "audacity_set_pref creates the file and its directory when neither exists" {
  local fresh="$BATS_TEST_TMPDIR/fresh/audacity/audacity.cfg"
  run audacity_set_pref "$fresh" GUI DefaultViewModeChoiceNew Spectrogram
  assert_success
  run cat "$fresh"
  assert_output '[GUI]
DefaultViewModeChoiceNew=Spectrogram'
}

# Keys are only unique within a section - [Tracks] and [GUI] can both hold a
# DefaultViewModeChoiceNew - so a file-wide match would write the wrong one. The
# decoy in [Tracks] must come back untouched.
@test "audacity_set_pref only edits the named section" {
  printf '[Tracks]\nDefaultViewModeChoiceNew=Waveform\n[GUI]\nDefaultViewModeChoiceNew=Waveform\n' >"$CFG"
  run audacity_set_pref "$CFG" GUI DefaultViewModeChoiceNew Spectrogram
  assert_success
  run cat "$CFG"
  assert_output '[Tracks]
DefaultViewModeChoiceNew=Waveform
[GUI]
DefaultViewModeChoiceNew=Spectrogram'
}

# Both readers slice each AUDACITY_PREFS entry positionally:
# apply_audacity_prefs takes the section from before the first "/" and splits the
# rest on the first "=", and audacity_applied greps that rest as a whole cfg line.
# An entry missing either separator would silently write to the wrong section or
# key, so pin the shape.
@test "every AUDACITY_PREFS entry is a Section/Key=Value triple" {
  [ "${#AUDACITY_PREFS[@]}" -gt 0 ]
  for entry in "${AUDACITY_PREFS[@]}"; do
    assert_regex "$entry" '^[A-Za-z]+/[A-Za-z]+=[^=/]+$'
  done
}

# The two platform scripts must enforce the same Audacity settings - the shared
# "Section/Key=Value" shape exists so the lists can be compared verbatim. Guards
# against one side being edited alone. (The Windows suite asserts the same thing
# from its end.)
@test "AUDACITY_PREFS matches the list in load-win.ps1" {
  run awk '/^\$AUDACITY_PREFS = @\(/{f=1;next} f&&/^\)/{exit} f&&/"/{
             gsub(/^[ \t]*"|",?[ \t\r]*$/,""); print }' "$DIR/../src/load-win.ps1"
  assert_success
  # Non-empty, so a silently non-matching awk can't make this pass vacuously.
  [ "${#lines[@]}" -gt 0 ]
  assert_equal "$(printf '%s\n' "${lines[@]}")" "$(printf '%s\n' "${AUDACITY_PREFS[@]}")"
}

# audacity_applied backs the checklist line. It must be all-or-nothing: a cfg
# carrying only some of the settings is NOT applied, or a partly-configured
# Audacity would report as done and never get the rest.
@test "audacity_applied is true only when every pref is present" {
  AUDACITY_CFG="$CFG"
  # Nothing there at all.
  run audacity_applied
  assert_failure
  # Only the first setting.
  printf '[GUI]\nDefaultViewModeChoiceNew=Spectrogram\n' >"$CFG"
  run audacity_applied
  assert_failure
  # Both.
  audacity_set_pref "$CFG" Spectrum MaxFreq 48000
  run audacity_applied
  assert_success
}

# A value that merely CONTAINS ours must not count - grep without -x would call
# MaxFreq=480000 (or a commented-out line) a match and skip the real write.
@test "audacity_applied does not match a partial line" {
  AUDACITY_CFG="$CFG"
  printf '[GUI]\nDefaultViewModeChoiceNew=Spectrogram\n[Spectrum]\nMaxFreq=480000\n' >"$CFG"
  run audacity_applied
  assert_failure
}

# The real run applies several prefs to one file in sequence, landing in
# different sections. Guards that a later call neither disturbs an earlier one
# nor collapses the sections into each other.
@test "audacity_set_pref applies successive prefs to different sections" {
  printf 'PrefsVersion=1.1.1r1\n[GUI]\nTheme=classic\n' >"$CFG"
  audacity_set_pref "$CFG" GUI DefaultViewModeChoiceNew Spectrogram
  audacity_set_pref "$CFG" Spectrum MaxFreq 48000
  run cat "$CFG"
  assert_output 'PrefsVersion=1.1.1r1
[GUI]
DefaultViewModeChoiceNew=Spectrogram
Theme=classic
[Spectrum]
MaxFreq=48000'
}

# Audacity writes audacity.cfg with the platform's native endings, so the Windows
# one is CRLF where ours is LF. A CRLF file is the shape a normalising rewrite (or
# a `.*$` key match, which eats the CR) would visibly destroy, so it is what we
# assert on - the same guarantee set_pref_node carries for the Premiere prefs.
@test "audacity_set_pref preserves CRLF endings" {
  printf '[GUI]\r\nTheme=classic\r\nDefaultViewModeChoiceNew=Waveform\r\n' >"$CFG"
  run audacity_set_pref "$CFG" GUI DefaultViewModeChoiceNew Spectrogram
  assert_success
  # Every ending still CRLF, no bare LF introduced, and the value did change.
  run perl -0777 -ne 'my $crlf=()=/\r\n/g; my $bare=()=/(?<!\r)\n/g; print "crlf=$crlf bare=$bare"' "$CFG"
  assert_output 'crlf=3 bare=0'
  run grep -c $'DefaultViewModeChoiceNew=Spectrogram\r$' "$CFG"
  assert_success
}

@test "audacity_set_pref is idempotent" {
  printf 'PrefsVersion=1.1.1r1\n[GUI]\nTheme=classic\n' >"$CFG"
  audacity_set_pref "$CFG" GUI DefaultViewModeChoiceNew Spectrogram
  cp "$CFG" "$CFG.first"
  audacity_set_pref "$CFG" GUI DefaultViewModeChoiceNew Spectrogram
  run cmp -s "$CFG.first" "$CFG"
  assert_success
}

@test "resolve_mode parses flags" {
  run resolve_mode --fast
  assert_output 'fast'
  run resolve_mode --full
  assert_output 'full'
  run resolve_mode --dry-run
  assert_output 'dryrun'
  run resolve_mode
  assert_output ''
  run resolve_mode --full --dry-run
  assert_output 'full dryrun'
  run resolve_mode foo
  assert_output ''
}

@test "premiere_set_media_cache sets FolderPath, preserves DatabasePath" {
  defaults write "$MEDIA_CACHE_DOMAIN" "Media Cache" -dict DatabasePath "/orig/db/" FolderPath "/orig/folder/"
  premiere_set_media_cache "$MEDIA_CACHE_DOMAIN" "/Volumes/SCRATCH_X/Cache" # no trailing slash on input
  run defaults read "$MEDIA_CACHE_DOMAIN" "Media Cache"
  assert_output --partial 'FolderPath = "/Volumes/SCRATCH_X/Cache/"'
  assert_output --partial 'DatabasePath = "/orig/db/"'
  # cleanup handled by teardown
}

# tidy_workdir clears the work dir only when the run left nothing behind. The
# no-Premiere run is the case that motivates it: the LUT pack is the only thing
# meant to outlive a run, and it's Premiere-gated, so the folder would otherwise
# be created (and left) empty on every machine without Premiere.
@test "tidy_workdir removes a work dir the run left empty" {
  local wd="$BATS_TEST_TMPDIR/load-mac"
  mkdir -p "$wd"
  tidy_workdir "$wd"
  [ ! -d "$wd" ]
}

# A leftover installer is deliberately kept for the next run to reuse (see the
# ProVideoFormats download), so a non-empty work dir must survive untouched.
@test "tidy_workdir keeps a work dir holding a download" {
  local wd="$BATS_TEST_TMPDIR/load-mac"
  mkdir -p "$wd"
  touch "$wd/ProVideoFormats.dmg"
  tidy_workdir "$wd"
  [ -f "$wd/ProVideoFormats.dmg" ]
}

@test "tidy_workdir keeps a work dir holding LUTs" {
  local wd="$BATS_TEST_TMPDIR/load-mac"
  mkdir -p "$wd/LUTs"
  touch "$wd/LUTs/some.cube"
  tidy_workdir "$wd"
  [ -f "$wd/LUTs/some.cube" ]
}

# --fast on a machine without Premiere never creates the dir at all; tidying a
# path that was never there is normal, not an error (main runs under set -e).
@test "tidy_workdir succeeds when the work dir was never created" {
  run tidy_workdir "$BATS_TEST_TMPDIR/never-made"
  assert_success
}

# Placement contract: the admin sub-run returns early from main(), and its work
# dir (in the ADMIN's home, holding only installers we delete) is exactly the one
# that would be stranded - so the tidy must come before that return.
@test "main tidies the work dir before the MACHINE_ONLY early return" {
  run awk '/^main\(\) \{/{c=1} c{print} c&&/^\}/{exit}' "$DIR/../src/load-mac.sh"
  assert_success
  local body="$output"
  local tidy_line machine_line
  tidy_line="$(printf '%s\n' "$body" | grep -n 'tidy_workdir "\$WORKDIR"' | head -1 | cut -d: -f1)"
  machine_line="$(printf '%s\n' "$body" | grep -n 'if \$MACHINE_ONLY; then' | head -1 | cut -d: -f1)"
  [ -n "$tidy_line" ] || fail "main() never calls tidy_workdir"
  [ -n "$machine_line" ] || fail "guard: MACHINE_ONLY return not found in main()"
  [ "$tidy_line" -lt "$machine_line" ] || fail "tidy_workdir runs after the MACHINE_ONLY return"
}

# These hit the network to confirm the hard-coded plugin installer URLs are still
# live. Skip them on an offline run with:  bats --filter-tags '!live' tests/
#
# HEAD first, falling back to a 1-byte ranged GET for servers that reject HEAD;
# redirects are followed and 200/206 are both accepted.
link_status() {
  local url="$1" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -I -L --max-time 30 "$url")"
  if [ "$code" != 200 ] && [ "$code" != 206 ]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-0' -L --max-time 30 "$url")"
  fi
  printf '%s' "$code"
}

# bats test_tags=live
@test "plugin download links are live" {
  run link_status "https://misterhorse.com/downloads/product-manager/osx"
  assert_output --regexp '^(200|206)$' # Mister Horse Product Manager
  run link_status "https://www.digitalanarchy.com/downloads/flickerfree_229_AE.dmg"
  assert_output --regexp '^(200|206)$' # Flicker Free
}

# Confirm every pinned formula/cask still resolves - catches an upstream
# rename/delisting or a local typo before it silently no-ops an install. Uses the
# package lists sourced from load-mac.sh, so the assertion can't drift from what
# the installer actually requests. Hits the network (tagged live); skipped when
# Homebrew is absent.
# bats test_tags=live
@test "all brew formulae resolve (rename/delisting/typo guard)" {
  command -v brew >/dev/null || skip "Homebrew not installed"
  local bad=()
  for f in $CORE_FORMULAE $FULL_FORMULAE; do
    brew info --formula "$f" &>/dev/null || bad+=("$f")
  done
  [ ${#bad[@]} -eq 0 ] || fail "unknown formulae: ${bad[*]}"
}

# bats test_tags=live
@test "all brew casks resolve (rename/delisting/typo guard)" {
  command -v brew >/dev/null || skip "Homebrew not installed"
  local bad=()
  for c in $CORE_CASKS $FULL_CASKS $PREMIERE_CASKS; do
    brew info --cask "$c" &>/dev/null || bad+=("$c")
  done
  [ ${#bad[@]} -eq 0 ] || fail "unknown casks: ${bad[*]}"
}

# The uv tools install from PyPI, so existence is a PyPI lookup (200 = project
# exists, 404 = renamed/delisted/mistyped). Same list the installer uses.
# bats test_tags=live
@test "all uv tools resolve on PyPI (rename/delisting/typo guard)" {
  local bad=()
  for p in $CORE_UV; do
    [ "$(link_status "https://pypi.org/pypi/$p/json")" = 200 ] || bad+=("$p")
  done
  [ ${#bad[@]} -eq 0 ] || fail "unknown PyPI packages: ${bad[*]}"
}
