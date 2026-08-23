<#
.SYNOPSIS
Windows workstation setup script

.NOTES
Copyright (c) 2026 Luis Gomez Gutierrez

.EXAMPLE
# Stream and run in memory (avoids MOTW / blocking GPO). Flags: --fast/--full/--dry-run/--mse.
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/lucuma13/load/main/src/load-win.ps1").Content))

.EXAMPLE
# Alternative for Constrained Language Mode (download and run, gracefully downgrade under $CLM). Flags: --fast/--full/--dry-run/--mse.
$f="$env:TEMP\load-win.ps1"; Invoke-WebRequest -Uri "https://raw.githubusercontent.com/lucuma13/load/main/src/load-win.ps1" -UseBasicParsing -OutFile $f -ErrorAction Stop; if(-not ((Get-Content $f -Raw).TrimEnd().EndsWith('# === END load-win.ps1 ==='))){throw "download incomplete - try again"}; powershell -ExecutionPolicy Bypass -File $f
#>

$ErrorActionPreference = "Continue"

Set-StrictMode -Version Latest

# Constrained Language Mode (enforced by WDAC/AppLocker) blocks Add-Type,
# P/Invoke, crypto and most .NET method calls. Steps that need those degrade to
# a clean "skipped (CLM)".
$CLM = $ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'

# Get-ProgramFiles64 - the 64-bit Program Files, named correctly from a host of
# either bitness. $env:ProgramFiles reads as the x86 directory under a 32-bit
# PowerShell (the SysWOW64 host), where a machine-scope 64-bit install would never be
# found; ProgramW6432 names the real one from both. It's empty on 32-bit Windows,
# hence the fallback. A function rather than a constant so it re-reads the
# environment at each call.
function Get-ProgramFiles64 {
    if ($env:ProgramW6432) { return $env:ProgramW6432 }
    return $env:ProgramFiles
}

# Get-RegValue <path> <name> - the value, or $null when the key or the value is absent.
#
# -ErrorAction on Get-ItemProperty is not enough by itself. Under
# Set-StrictMode -Version Latest, dotting a property that isn't there is ITSELF an
# error, so `(Get-ItemProperty ... -Name X -EA SilentlyContinue).X` still fails on a
# missing value - and because it fails mid-assignment the variable is left UNDEFINED,
# so the next read of it throws a second time. Two red errors per lookup, on exactly
# the fresh profile this script exists to set up: no Keyboard Layout\Toggle yet, and
# no shellbag for a folder nobody has opened. Select-Object does the lookup
# inside the cmdlet, where a missing property is an ordinary error it can swallow.
function Get-RegValue($path, $name) {
    Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty $name -ErrorAction SilentlyContinue
}

# Get-UserFolder <name> <fallback> - resolve a Windows known folder from the registry.
#
# "$HOME\Documents" is a macOS habit that does not survive the trip. Windows lets
# Documents and Downloads live anywhere, and OneDrive's "Back up this PC's folders" -
# offered on by default through Windows 11 setup - relocates them under
# %USERPROFILE%\OneDrive without changing $HOME. Premiere writes its profile into the
# REAL Documents folder, so guessing wrong makes the whole Premiere step silently
# no-op on a machine that looks completely ordinary. $HOME is doubly unsafe on a
# domain PC, where PowerShell builds it from HOMEDRIVE/HOMEPATH and it can resolve to
# a mapped network drive.
#
# User Shell Folders is the authority. PowerShell expands its REG_EXPAND_SZ values on
# read, and unlike [Environment]::GetFolderPath the read still works under CLM.
#
# $key is injectable so the resolution and both fallbacks can be unit-tested against a
# probe key, the way Remove-SelfTemp takes its path/temp.
function Get-UserFolder {
    param(
        $name,
        $fallback,
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    )
    $path = Get-RegValue $key $name
    # A recorded folder that no longer exists (a detached OneDrive, an unmapped drive)
    # is worse than the profile-relative guess, so it falls back too.
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    return $fallback
}

$DocumentsDir = Get-UserFolder 'Personal' "$HOME\Documents"
$DownloadsDir = Get-UserFolder '{374DE290-123F-4565-9164-39C4925E467B}' "$HOME\Downloads"
$PremiereDir = Join-Path $DocumentsDir "Adobe\Premiere Pro"

# Created by the dispatch block rather than here: this file is also sourced as a
# library by the tests, and --dry-run is a preview that must not touch the disk.
$WorkDir = Join-Path $DownloadsDir "load-win"

# AHK macros live in the work dir - the user double-clicks the script after
# rebooting to activate it.
$AhkScript = Join-Path $WorkDir "MacKeyboard_LGG.ahk"

# Find-AhkExe - locate an installed AutoHotkey interpreter, or return $null.
# Used both to preview (is AutoHotkey present?) and to run the macros.
#
# The name filter matters as much as the sort. An AutoHotkey v2 install ships
# several executables next to the interpreter, and a bare "AutoHotkey*.exe"
# match picks up two kinds we must not launch scripts with: AutoHotkey64_UIA.exe
# the UI Access build, which exists precisely to drive ELEVATED windows - the
# opposite of the non-elevated launch Install-AhkScript documents, and it sorted
# first here AutoHotkeyUX.exe      the launcher/dash GUI, not an interpreter at
# all So match the interpreter names exactly, then prefer the 64-bit build
# ($false sorts before $true, so "contains 64" comes first).
#
# AutoHotkey is in $USER_SCOPE_PKGS - installed with "winget --scope user" so
# a standard user doesn't need admin rights - which lands in the vendor
# installer's own non-elevated default, %LocalAppData%\Programs\AutoHotkey,
# not Program Files. Search both so discovery works for either scope.
function Find-AhkExe {
    $exe = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $exe) {
        $exe = Get-ChildItem `
            "$(Get-ProgramFiles64)\AutoHotkey", `
            "${env:ProgramFiles(x86)}\AutoHotkey", `
            "$env:LOCALAPPDATA\Programs\AutoHotkey" `
            -Recurse -Filter "AutoHotkey*.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^AutoHotkey(32|64)?\.exe$' } |
            Sort-Object { $_.Name -notmatch '64' } |
            Select-Object -First 1 -ExpandProperty FullName
    }
    return $exe
}

# Find-UvExe - locate the uv executable, or return $null. We invoke uv by full
# path so the uv-tool installs don't depend on the session PATH having refreshed
# after winget installed it - which is unreliable under CLM, where %vars% in the
# registry PATH can't be expanded. Checks PATH first, then winget's usual
# install/shim locations.
#
# Get-Command returns one result per PATH directory holding uv.exe, so -First 1
# (PATH order - the copy the shell itself would run) keeps a second install,
# from pip/scoop or from "uv self update" seeding ~\.local\bin, out of $exe as
# an array: that array is truthy, so it would skip the fallbacks below, and it
# can't be invoked with & either. The machine-scope candidate is built on
# Get-ProgramFiles64 (see above) so a 32-bit host still names the 64-bit Program
# Files.
function Find-UvExe {
    $exe = Get-Command uv.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $exe) {
        $exe = Get-ChildItem `
            "$env:LOCALAPPDATA\Microsoft\WinGet\Links\uv.exe", `
            "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\astral-sh.uv*\uv.exe", `
            "$(Get-ProgramFiles64)\WinGet\Links\uv.exe", `
            "$env:USERPROFILE\.local\bin\uv.exe" `
            -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    return $exe
}

# Get-WorkspaceName <ws_file> - return the workspace display name from the XML file,
# stored under the UserName key.
#
# -Encoding UTF8 is required, not decorative: Premiere writes these files UTF-8
# without a BOM, and Windows PowerShell 5.1 - the shell the documented entrypoint
# actually uses - falls back to the ANSI code page for a file with no BOM. A
# workspace named "Edicion Camara" then comes back mojibaked and gets copied into the
# prefs as LastWorkspaceName, naming a workspace that does not exist. (The cmdlet's
# -Encoding is also CLM-safe, unlike the byte-level .NET read in Set-PrefNode.)
function Get-WorkspaceName {
    param($wsFile)
    $content = Get-Content -LiteralPath $wsFile -Raw -Encoding UTF8
    if ($content -match '<key>UserName</key>\s*<ustring>(.*?)</ustring>') { return $Matches[1] }
    return ""
}

# ConvertTo-CrlfFile <path> - rewrite a file with CRLF endings, no BOM.
#
# WORKSPACES ONLY. Premiere does not use one line-ending convention per
# platform: two serialisers inside the same app disagree, writing into the same
# profile dir.
#
#   Adobe Premiere Pro Prefs   LF on BOTH platforms (pure LF, no CR anywhere)
#   UserWorkspace*.xml         platform-native: LF on macOS, CRLF on Windows
#
# So "Windows means CRLF" is false for this profile as a whole, and converting
# the prefs would move them AWAY from what Premiere writes. Only the workspaces
# get converted; Set-PrefNode is EOL-preserving and leaves the prefs alone.
#
# We ship ONE workspace payload (LF, byte-pinned by .gitattributes) so the repo
# has a single source of truth. Dropped as-is on Windows it is the only LF file
# in a Layouts folder Premiere wrote entirely in CRLF, and its first save
# rewrites every line. Convert on delivery instead, so the platform's own
# convention lands on disk.
#
function ConvertTo-CrlfFile {
    param($path)
    $enc = New-Object System.Text.UTF8Encoding $false
    $text = [System.IO.File]::ReadAllText($path, $enc)
    [System.IO.File]::WriteAllText($path, ($text -replace "`r?`n", "`r`n"), $enc)
}

# Set-PrefNode <prefs> <node> <value> - replace an XML leaf node's text in
# place. Returns $false WITHOUT touching the file when the node is absent, so
# callers can flag nodes a future Premiere version may have renamed (no edit =
# no corruption).
#
# EOL-preserving by construction, and deliberately so: it splices between the
# tags (ReadAllBytes -> string -> Substring join -> WriteAllBytes) and never
# goes near a newline, so whatever endings the file arrived with survive the
# edit. Do NOT reimplement this with Get-Content/Set-Content or Out-File, which
# would normalise the whole file as a side effect of changing one value.
#
# Note this file wants LF, unlike the workspaces next to it - see the serialiser
# split documented on ConvertTo-CrlfFile. That is why nothing here converts.
function Set-PrefNode {
    param($prefs, $node, $value)
    $bytes = [System.IO.File]::ReadAllBytes($prefs)
    $enc = [System.Text.Encoding]::UTF8
    $content = $enc.GetString($bytes)
    $open = "<$node>"
    $close = "</$node>"
    $idx = $content.IndexOf($open)
    if ($idx -lt 0) { return $false }
    $closeIdx = $content.IndexOf($close, $idx + $open.Length)
    $new = $content.Substring(0, $idx + $open.Length) + $value + $content.Substring($closeIdx)
    [System.IO.File]::WriteAllBytes($prefs, $enc.GetBytes($new))
    return $true
}

# Set-ForcedPrefNode <prefs> <node> <value> - like Set-PrefNode, but when the
# node is absent it CREATES it inside the <Properties> block instead of
# skipping. Use only for nodes whose Premiere default is wrong for us, so a
# fresh install (where Premiere has not written the node yet) is still
# overridden. Returns $false without touching the file only when the
# <Properties> block cannot be found.
#
# Idempotent: once created, later runs find the node and edit it in place.
#
# The inserted "`n" is the one line ending this script authors in the prefs, and
# a bare LF is correct: Premiere writes this file LF on BOTH Windows and macOS
# (unlike UserWorkspace*.xml, which is CRLF here). Mirrors force_pref_node in
# load-mac.sh.
#
# Byte-level read/write for the same reason as Set-PrefNode: it guarantees no
# BOM is introduced.
function Set-ForcedPrefNode {
    param($prefs, $node, $value)
    if (Set-PrefNode -Prefs $prefs -Node $node -Value $value) { return $true }
    $enc = [System.Text.Encoding]::UTF8
    $content = $enc.GetString([System.IO.File]::ReadAllBytes($prefs))
    $open = [regex]::Match($content, '<Properties\b[^>]*>')
    if (-not $open.Success) { return $false }
    $at = $open.Index + $open.Length
    $new = $content.Substring(0, $at) + "`n`t`t`t<$node>$value</$node>" + $content.Substring($at)
    [System.IO.File]::WriteAllBytes($prefs, $enc.GetBytes($new))
    return $true
}

# Set-AudacityPref <cfg> <section> <key> <value> - set a key in Audacity's
# audacity.cfg.
#
# Creates whatever is missing - the file, the [section], the key - because a
# freshly installed Audacity has no cfg at all (it writes one on first quit),
# and a cfg it does write omits every key still at its default. Partial files
# are fine: wxFileConfig merges what's there over the built-in defaults.
#
# EOL-preserving (this file is CRLF): wxFileConfig writes it through wxTextFile,
# which uses the platform's native endings. The file's own first ending is
# detected and reused for any line this function adds, and the match is `\r?\n`
# throughout so a hand-edited mixed file still parses.
#
# Byte-level read/write for the same reason as Set-PrefNode: it guarantees no
# BOM is introduced. Windows PowerShell 5.1's `-Encoding UTF8` would add one,
# and a BOM would glue itself to the first key name in the file. That makes it
# unavailable under CLM, so callers skip it there.
function Set-AudacityPref {
    param($cfg, $section, $key, $value)
    $enc = [System.Text.Encoding]::UTF8
    $dir = Split-Path -Parent $cfg
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $content = if (Test-Path $cfg) { $enc.GetString([System.IO.File]::ReadAllBytes($cfg)) } else { "" }

    $nl = if ($content -match "\r\n") { "`r`n" } elseif ($content -match "\n") { "`n" } else { "`r`n" }
    $line = "$key=$value"
    $secPat = "(?m)^\[" + [regex]::Escape($section) + "\]\r?\n"
    $keyPat = "(?m)^" + [regex]::Escape($key) + "=[^\r\n]*"

    if ($content -match $secPat) {
        $start = $content.IndexOf($Matches[0]) + $Matches[0].Length
        $rest = $content.Substring($start)
        $nextHdr = [regex]::Match($rest, "(?m)^\[")
        $bodyLen = if ($nextHdr.Success) { $nextHdr.Index } else { $rest.Length }
        $body = $rest.Substring(0, $bodyLen)
        $body = if ($body -match $keyPat) {
            [regex]::Replace($body, $keyPat, { $line })
        }
        else { $line + $nl + $body }
        $content = $content.Substring(0, $start) + $body + $rest.Substring($bodyLen)
    }
    else {
        if ($content -ne "" -and $content -notmatch "\n$") { $content += $nl }
        $content += "[$section]" + $nl + $line + $nl
    }

    try { [System.IO.File]::WriteAllBytes($cfg, $enc.GetBytes($content)); return $true }
    catch { return $false }
}

# Set-PremierePro <prefs> <kys_file> <ws_name> <version> - point Premiere Pro's
# keyboard shortcuts preset and active workspace at our files, use  Classic label
# colour preset, enable auto-save every 5 minutes keeping 200 project versions,
# toggle on the Timeline's Linked Selection button and some Timeline Display
# Settings, turn off Media Analysis' "Analyze all imported media", and stop
# playback returning to the beginning when it restarts.
#
# A missing-node warning can mean one of two things:
#   (a) Fresh Premiere install - Premiere only writes certain nodes to disk after
#       a user first manually changes them. Warning is harmless; the setting is
#       already at the correct value.
#   (b) Adobe renamed the node in this Premiere version - the setting was NOT
#       applied and the script needs updating.
# Either way the file is left untouched for that node.
function Set-PremierePro {
    param($prefs, $kysFile, $wsName, $version)
    $labelNames = @('Violet', 'Iris', 'Caribbean', 'Lavender', 'Cerulean', 'Forest', 'Rose', 'Mango', 'Purple', 'Blue', 'Teal', 'Magenta', 'Tan', 'Green', 'Brown', 'Yellow')
    $labelColors = @('14717094', '13408882', '10016297', '14910691', '14597935', '5814353', '10776567', '3909357', '9896087', '16727100', '8421376', '15151847', '9814478', '2191389', '1262987', '6611682')
    $missing = @()

    # Keyboard shortcuts preset
    if (-not (Set-PrefNode -Prefs $prefs -Node "FE.Prefs.Shortcuts.Filename" -Value $kysFile)) { $missing += "FE.Prefs.Shortcuts.Filename" }

    # Active workspace
    if ($wsName) {
        if (-not (Set-PrefNode -Prefs $prefs -Node "FE.Application.LastWorkspaceName" -Value $wsName)) { $missing += "FE.Application.LastWorkspaceName" }
    }

    # Classic label colour preset
    for ($i = 0; $i -lt $labelNames.Count; $i++) {
        if (-not (Set-PrefNode -Prefs $prefs -Node "BE.Prefs.LabelNames.$i"  -Value $labelNames[$i])) { $missing += "BE.Prefs.LabelNames.$i" }
        if (-not (Set-PrefNode -Prefs $prefs -Node "BE.Prefs.LabelColors.$i" -Value $labelColors[$i])) { $missing += "BE.Prefs.LabelColors.$i" }
    }
    if (-not (Set-PrefNode -Prefs $prefs -Node "PPro.LabelColorPresets.RecentPreset" -Value '{"builtIn":true,"name":"Classic"}')) { $missing += "PPro.LabelColorPresets.RecentPreset" }

    # Auto-save every 5 minutes
    if (-not (Set-PrefNode -Prefs $prefs -Node "BE.Prefs.AutoSave.DoSave"   -Value "true")) { $missing += "BE.Prefs.AutoSave.DoSave" }
    if (-not (Set-PrefNode -Prefs $prefs -Node "BE.Prefs.AutoSave.Interval" -Value "5")) { $missing += "BE.Prefs.AutoSave.Interval" }

    # Timeline toggles: Linked Selection + Timeline Display Settings (wrench menu).
    # Linked Selection already defaults to the value we want, so a missing node on a
    # fresh install is fine and simply left untouched.
    #
    # The preferences below are commented out for now because they are not written to the preference file until the default behaviour has changed:
    # 'be.Prefs.Timeline.Show.Video.Thumbnails',
    # 'be.Prefs.Timeline.Show.Video.Names',
    # 'be.Prefs.Timeline.Show.Audio.Waveforms',
    # 'be.Prefs.Timeline.Show.Audio.Names',
    # 'be.Prefs.Timeline.Show.Proxy.Badges',
    # 'TL.PREFShowFXBadges',
    if (-not (Set-PrefNode -Prefs $prefs -Node "TL.PREFLinkedSelectionState" -Value "true")) { $missing += "TL.PREFLinkedSelectionState" }

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
    # ships, look at a real prefs file before adding it here; on any other version
    # fall back to the in-place edit (skip + report if absent). $version is normally
    # "24.0"/"26.3" etc; pull the leading major number, or -1 when the caller passed
    # no version.
    #
    # Mirrors customise_premiere_pro in load-mac.sh, kept in step by a test rather
    # than a shared file: each installer is invoked as a single downloaded script,
    # with no checkout on the target machine to read one from.
    $major = if ("$version" -match '(\d+)\.') { [int]$Matches[1] } else { -1 }
    $forced = @(
        'TL.PREFShowThroughEditsState|true|'                              # Show Through Edits
        'MZ.SQShowDuplicateMarkers|true|'                                 # Show Duplicate Frame Markers
        'MZ.Prefs.PlaybackEndReturnToBeginning|false|'                    # At playback end, return to beginning
        'BE.Prefs.AutoSave.MaxProjectVersions|200|'                       # Auto Save: Maximum Project Versions
        'BE.Prefs.MediaIntelligence.AnalyzeImportedMediaForMISO|false|25' # Analyze all imported media
    )
    foreach ($row in $forced) {
        $node, $value, $minMajor = $row -split '\|'
        # A preference that postdates this Premiere has no node to write, and its
        # absence is permanent rather than a fresh-install artefact - so skip it
        # silently instead of reporting it.
        if ($minMajor -and $major -ge 0 -and $major -lt [int]$minMajor) { continue }
        $ok = if ($major -in 24, 25, 26) { Set-ForcedPrefNode -Prefs $prefs -Node $node -Value $value }
        else { Set-PrefNode -Prefs $prefs -Node $node -Value $value }
        if (-not $ok) { $missing += $node }
    }

    if ($missing.Count -gt 0) {
        Write-Host "  [warn] Premiere prefs on version ${version}: $($missing.Count) node(s) not found and skipped (file untouched for those nodes):"
        $missing | ForEach-Object { Write-Host "        - $_" }
        Write-Host "      Missing nodes are ones Premiere had never written. Every preference we"
        Write-Host "      know Premiere leaves unwritten until it is changed by hand is created"
        Write-Host "      when absent, so a report here means either a genuinely fresh profile"
        Write-Host "      or, on a machine that has had Premiere used on it, that Adobe renamed"
        Write-Host "      the node - diff a real prefs file around that control and update this"
        Write-Host "      script."
    }
}

# -----------------------------------------------------------------------------
# Explorer's default folder view
# -----------------------------------------------------------------------------
# Windows has no single "sort by / group by" preference. A folder's view is
# stored PER FOLDER, in shellbags, and the view a folder starts with comes from
# a folder-type template Explorer guesses from the contents.
#
# The goal is deliberately not one view everywhere: every folder should sort by
# Name ascending and never group, EXCEPT Downloads, which should sort by Date
# modified with the newest file first - and still not group.
#
# Windows treats Downloads as a known folder, which ignores registry templates
# entirely on first render.
#
# So the actual fix has two layers: the AllFolders\Shell\{type-id} templates
# below still matter for every OTHER type (Documents, Pictures, ... - ordinary
# content-guessed folders, not known folders, and their GroupView reliably DID
# inherit from the template in the same tests), and Downloads still gets its own
# Sort there too, on the chance a future Windows version does start reading it.
# But the thing that actually keeps Downloads ungrouped is Repair-FolderGrouping
# patching its bag after the fact, every run.
#
# Bags\<n> and BagMRU are the remembered per-folder views, which OVERRIDE the
# templates - cleared by Set-ExplorerDefaultView when the templates themselves
# are out of date (a genuinely rare case: first run on a profile, or this
# script's own templates changing). Repair-FolderGrouping deliberately does NOT
# do this wholesale clear - deleting a bag is exactly what let Windows reassert
# its hardcoded grouped default in attempts 1 and 2 above; patching in place is
# what makes the fix stick.
#
# Every path is HKCU, so this stays a fast-pass step and asks for no elevation.

# AllFolders\Shell is the template tree. Its SUBKEYS are named by folder type,
# not by view: a bag's view for a given type lives at <bag>\Shell\{type-guid},
# and the matching AllFolders\Shell\{type-guid} is the default every folder of
# that type inherits - for ordinary, content-guessed folder types. Known folders
# like Downloads do not reliably consult it. Every New-Item below is guarded by
# a Test-Path, and that guard is load-bearing: New-Item -Force on a key that
# already exists deletes the values in it.
$ExplorerAllFoldersKey = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"
$ExplorerFolderTypeKey = "HKCU:\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"

# The per-folder view memory, in both trees Explorer keeps it in. Recursively
# deleted by Set-ExplorerDefaultView, so these must stay HKCU-only.
$ExplorerBagPaths = @(
    "HKCU:\Software\Microsoft\Windows\Shell\BagMRU"
    "HKCU:\Software\Microsoft\Windows\Shell\Bags"
    "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU"
    "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags"
)

# Roots Repair-FolderGrouping and Test-NoFolderGrouping walk for EXISTING
# per-folder bags - the two "Bags" trees from $ExplorerBagPaths, not BagMRU
# (which holds the ItemIDList index, not view data).
$ExplorerBagRoots = @(
    "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags",
    "HKCU:\Software\Microsoft\Windows\Shell\Bags"
)

# Folder type ids, from HKLM\...\Explorer\FolderTypes\{guid}\CanonicalName.
$FOLDERTYPE_GENERIC = "{5C4F28B5-F869-4E84-8E60-F11DB97C5CC7}"
$FOLDERTYPE_DOCUMENTS = "{7D49D726-3C21-4F05-99AA-FDC2C9474656}"
$FOLDERTYPE_PICTURES = "{B3690E58-E961-423B-B687-386EBFD83239}"
$FOLDERTYPE_MUSIC = "{94D6DDCC-4A68-4175-A374-BD584A510B78}"
$FOLDERTYPE_VIDEOS = "{5FA96407-7E77-483C-AC93-691D05850DE8}"
$FOLDERTYPE_DOWNLOADS = "{885A186E-A440-4ADA-812B-DB871B942259}"


# "Sort" is a serialised SORTCOLUMN array:
#   [0x00] 16 bytes  reserved, always zero
#   [0x10] DWORD     column count
#   [0x14] 16 bytes  PROPERTYKEY fmtid, little-endian. {B725F130-47EF-101A-A5F1-
#                    02608C9EEBAC} is the shell's own property set
#   [0x24] DWORD     property id - 10 is System.ItemNameDisplay, i.e. "Name"
#                    (4 = Type, 12 = Size, 14 = Date modified)
#   [0x28] DWORD     direction - 1 ascending, 0xffffffff descending
$SORT_BY_NAME_ASC = [byte[]] @(
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00,
    0x30, 0xf1, 0x25, 0xb7, 0xef, 0x47, 0x1a, 0x10, 0xa5, 0xf1, 0x02, 0x60, 0x8c, 0x9e, 0xeb, 0xac,
    0x0a, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00
)

# Same layout, PID 14 (System.DateModified) descending, i.e. most recent first.
# Spelled out as a second literal rather than cloned-and-patched from the one
# above so it stays readable under Constrained Language Mode, where the method
# calls a builder would need are not available. The tests decode both blobs
# field by field, so a typo in either fails as "sorts by the wrong column"
# rather than as a view nobody notices is wrong.
$SORT_BY_DATE_MODIFIED_DESC = [byte[]] @(
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00,
    0x30, 0xf1, 0x25, 0xb7, 0xef, 0x47, 0x1a, 0x10, 0xa5, 0xf1, 0x02, 0x60, 0x8c, 0x9e, 0xeb, 0xac,
    0x0e, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff
)

# The template to write per folder type. Everything Explorer might guess a
# folder into gets Name/ascending; Downloads gets Date modified/descending too
# - it just cannot be trusted, alone, to keep Downloads ungrouped (see the
# section header comment; Repair-FolderGrouping is what actually does that).
# Ordered so the checklist and any failure message name Generic first.
$ExplorerViewTemplates = [ordered] @{
    $FOLDERTYPE_GENERIC   = $SORT_BY_NAME_ASC
    $FOLDERTYPE_DOCUMENTS = $SORT_BY_NAME_ASC
    $FOLDERTYPE_PICTURES  = $SORT_BY_NAME_ASC
    $FOLDERTYPE_MUSIC     = $SORT_BY_NAME_ASC
    $FOLDERTYPE_VIDEOS    = $SORT_BY_NAME_ASC
    $FOLDERTYPE_DOWNLOADS = $SORT_BY_DATE_MODIFIED_DESC
}

# Get-FolderBagTypeKey <bagRoots> - the registry path of every EXISTING
# per-folder bag's Shell\{type} key (not the AllFolders template - an actual
# folder Explorer has already rendered a view for). Shared by
# Test-NoFolderGrouping (read) and Repair-FolderGrouping (write) so the two
# can't drift apart on which bags count.
function Get-FolderBagTypeKey {
    param($bagRoots = $ExplorerBagRoots)
    foreach ($root in $bagRoots) {
        if (-not (Test-Path $root)) { continue }
        $bagNames = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -ne 'AllFolders' } |
            Select-Object -ExpandProperty PSChildName
        foreach ($bagName in $bagNames) {
            $shellKey = Join-Path $root "$bagName\Shell"
            if (-not (Test-Path -LiteralPath $shellKey)) { continue }
            Get-ChildItem -LiteralPath $shellKey -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $shellKey $_.PSChildName }
        }
    }
}

# Test-NoFolderGrouping - true when no EXISTING per-folder bag has grouping
# switched on, for any folder type. Read-only counterpart to
# Repair-FolderGrouping.
function Test-NoFolderGrouping {
    param($bagRoots = $ExplorerBagRoots)
    foreach ($k in (Get-FolderBagTypeKey $bagRoots)) {
        if ((Get-RegValue $k 'GroupView') -ne 0) { return $false }
    }
    return $true
}

# Repair-FolderGrouping - turn grouping off on every EXISTING per-folder bag
# that currently has it on, IN PLACE. Returns $true if it changed anything.
#
# Deliberately does not delete and let Explorer recreate these bags the way
# Set-ExplorerDefaultView does for a template mismatch: for Downloads
# specifically, deleting the bag is what let Windows reapply its hardcoded
# grouped default in the first place (see the section header comment) - a
# patched-in-place bag survived a real open-and-close cycle in the same test
# where a freshly recreated one did not. So this is the actual fix for
# Downloads drifting back to grouped, run every fast pass regardless of
# whether Set-ExplorerDefaultView's templates need anything.
#
# No Explorer restart needed - confirmed live: the patch took effect on the
# next real open without bouncing the shell, because it edits the bag Explorer
# will read next time rather than one it is currently holding open in memory.
function Repair-FolderGrouping {
    param($bagRoots = $ExplorerBagRoots)
    $changed = $false
    foreach ($k in (Get-FolderBagTypeKey $bagRoots)) {
        if ((Get-RegValue $k 'GroupView') -ne 0) {
            Set-ItemProperty -LiteralPath $k -Name "GroupView" -Value 0 -Type DWord
            Set-ItemProperty -LiteralPath $k -Name "GroupByKey:FMTID" -Value "{00000000-0000-0000-0000-000000000000}" -Type String
            Set-ItemProperty -LiteralPath $k -Name "GroupByKey:PID" -Value 0 -Type DWord
            Set-ItemProperty -LiteralPath $k -Name "GroupByDirection" -Value 1 -Type DWord
            $changed = $true
        }
    }
    return $changed
}

# Test-ExplorerDefaultView - true once every folder-type template is ours:
# ungrouped everywhere, sorted by Name ascending, except Downloads which sorts
# by Date modified descending. Drives Set-ExplorerDefaultView's early return, so
# a second run neither clears the shellbags nor restarts the shell again unless
# the templates themselves actually need it. Deliberately does NOT check
# Test-NoFolderGrouping.
#
# The Sort blob is compared as a joined string on purpose. `-eq` between two
# byte arrays is an element-wise FILTER in PowerShell, not an equality test: it
# returns the matching elements, so a perfect match against a blob starting with
# 0x00 would come back falsy and this would report "not applied" forever.
#
# Both keys are injectable so the comparison can be unit-tested against a probe
# key, the way Get-UserFolder takes its $key.
function Test-ExplorerDefaultView {
    param($baseKey = $ExplorerAllFoldersKey, $typeKey = $ExplorerFolderTypeKey)
    foreach ($type in $ExplorerViewTemplates.Keys) {
        $k = Join-Path $baseKey $type
        if (($ExplorerViewTemplates[$type] -join ',') -ne ((Get-RegValue $k 'Sort') -join ',')) { return $false }
        if ((Get-RegValue $k 'GroupView') -ne 0) { return $false }
    }
    # A leftover NotSpecified from an even earlier version of this script would
    # pin every folder to Generic - so its absence is part of the applied state.
    return $null -eq (Get-RegValue $typeKey 'FolderType')
}

# Test-ExplorerViewFullyApplied - Test-ExplorerDefaultView (the templates) AND
# Test-NoFolderGrouping (no per-folder bag has actually drifted back to grouped)
# together. This, not Test-ExplorerDefaultView alone, is the checklist's "is
# everything really as intended" answer.
#
# Kept OUT of Test-ExplorerDefaultView on purpose: that function gates
# Set-ExplorerDefaultView's wholesale bag wipe, and wiping is exactly what
# reintroduces Downloads' grouped default - folding grouping drift into that
# same gate would make a plain re-open of Downloads trigger a full
# reset-and-restart on the next run, undoing Repair-FolderGrouping's whole
# point. All three params are injectable so the comparison can be unit-tested
# against probe keys, the way Get-UserFolder takes its $key.
function Test-ExplorerViewFullyApplied {
    param($baseKey = $ExplorerAllFoldersKey, $typeKey = $ExplorerFolderTypeKey, $bagRoots = $null)
    if (-not (Test-ExplorerDefaultView $baseKey $typeKey)) { return $false }
    if ($null -ne $bagRoots) { return Test-NoFolderGrouping $bagRoots }
    return Test-NoFolderGrouping
}

# Set-ExplorerDefaultView - make "Group by: (None)" plus "Sort by: Name,
# ascending" the view every folder opens with, and "Sort by: Date modified,
# descending" the view Downloads opens with. Returns $true when it changed
# something, so the caller knows whether the shell has to be restarted.
#
# Only handles the templates being wrong (rare: first run on a profile, or
# this script's own templates changing) - it does NOT handle Downloads
# drifting back to grouped on an otherwise-correct profile. That is
# Repair-FolderGrouping's job, called separately, every run, and specifically
# NOT by wiping bags the way this function does (see the section header
# comment for why that reintroduces the bug for Downloads).
function Set-ExplorerDefaultView {
    if (Test-ExplorerDefaultView) { return $false }

    # The remembered per-folder views beat the template, so any folder already
    # visited would keep its old sort and grouping forever. Clearing them is
    # what "Reset Folders" does.
    foreach ($bag in $ExplorerBagPaths) {
        Remove-Item -LiteralPath $bag -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Written after the clear, not before: AllFolders is a subkey of Bags and
    # would have been deleted along with it.
    foreach ($type in $ExplorerViewTemplates.Keys) {
        $k = Join-Path $ExplorerAllFoldersKey $type
        # Unguarded New-Item, unlike everywhere else in this file: -Force wipes
        # an existing key's values, which is harmless here only because the bag
        # wipe above has just removed this key anyway, and because every value
        # the template needs is rewritten immediately below. Add a value that is
        # read but not written here and that stops being true.
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty -LiteralPath $k -Name "Sort" -Value $ExplorerViewTemplates[$type] -Type Binary

        # GroupView 0 alongside a null GroupByKey is what Explorer itself writes
        # for an ungrouped folder. Zeroing GroupView on its own is not enough -
        # the leftover GroupByKey names a column to group by and the headers
        # come back the next time the view is touched.
        Set-ItemProperty -LiteralPath $k -Name "GroupView" -Value 0 -Type DWord
        Set-ItemProperty -LiteralPath $k -Name "GroupByKey:FMTID" -Value "{00000000-0000-0000-0000-000000000000}" -Type String
        Set-ItemProperty -LiteralPath $k -Name "GroupByKey:PID" -Value 0 -Type DWord
        Set-ItemProperty -LiteralPath $k -Name "GroupByDirection" -Value 1 -Type DWord
    }

    # Undo the blanket folder-type override an earlier version of this script
    # wrote (and that a later attempt at this bug re-added, then reverted again
    # - see the section header comment). Left in place it would type every
    # folder as Generic, and Downloads would lose its own template entirely.
    Remove-ItemProperty -LiteralPath $ExplorerFolderTypeKey -Name "FolderType" -Force -ErrorAction SilentlyContinue

    return $true
}

# Restart-Explorer - bounce the shell so the view above takes effect now.
#
# Not cosmetic. explorer.exe holds the bags for the folders it has open in
# memory and writes them back as windows close, so leaving it running lets it
# re-create the per-folder views we just cleared - the same trap the macOS side
# has with Finder buffering .DS_Store. Stopping it is enough on a normal desktop
# (the shell relaunches itself); the explicit start is the fallback for a
# session where it does not.
#
# Cmdlets only, so this still works under Constrained Language Mode.
function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

# -----------------------------------------------------------------------------
# Taskbar and system tray
# -----------------------------------------------------------------------------
# On MMTaskbarEnabled the value is absent until the setting is first changed.
#
# Writing 1 is therefore both necessary and sufficient. Registry cmdlets only,
# so this survives Constrained Language Mode.
$TaskbarAdvancedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$TaskbarAdvancedValues = [ordered] @{
    TaskbarAl          = 1
    MMTaskbarEnabled   = 1
    ShowTaskViewButton = 0
}
$TaskbarSearchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
$TaskbarSearchValues = [ordered] @{
    SearchboxTaskbarMode = 3
}

# "Other system tray icons" in Settings.
$TrayIconKey = "HKCU:\Control Panel\NotifyIconSettings"
$TRAY_ICON_HIDDEN = 0
$TrayHideExecutable = "OneDrive.exe"

# Test-Taskbar - true once every taskbar value matches.
function Test-Taskbar {
    param($advancedKey = $TaskbarAdvancedKey, $searchKey = $TaskbarSearchKey)
    foreach ($name in $TaskbarAdvancedValues.Keys) {
        if ((Get-RegValue $advancedKey $name) -ne $TaskbarAdvancedValues[$name]) { return $false }
    }
    foreach ($name in $TaskbarSearchValues.Keys) {
        if ((Get-RegValue $searchKey $name) -ne $TaskbarSearchValues[$name]) { return $false }
    }
    return $true
}

# Get-TrayIconKeyPath - registry paths of the entries pointing at the named
# executable.
function Get-TrayIconKeyPath {
    param($exeName = $TrayHideExecutable, $trayKey = $TrayIconKey)
    if (-not (Test-Path -LiteralPath $trayKey)) { return }
    foreach ($sub in (Get-ChildItem -LiteralPath $trayKey -ErrorAction SilentlyContinue)) {
        $path = Join-Path $trayKey $sub.PSChildName
        $exe = Get-RegValue $path "ExecutablePath"
        if ($exe -and (Split-Path $exe -Leaf) -eq $exeName) { $path }
    }
}

function Test-TrayIcon {
    param($exeName = $TrayHideExecutable, $trayKey = $TrayIconKey)
    foreach ($k in (Get-TrayIconKeyPath $exeName $trayKey)) {
        if ((Get-RegValue $k "IsPromoted") -ne $TRAY_ICON_HIDDEN) { return $false }
    }
    return $true
}

# Set-Taskbar - apply the taskbar values and demote the tray icon.
function Set-Taskbar {
    if ((Test-Taskbar) -and (Test-TrayIcon)) { return $false }

    foreach ($pair in @(@($TaskbarAdvancedKey, $TaskbarAdvancedValues), @($TaskbarSearchKey, $TaskbarSearchValues))) {
        $key = $pair[0]
        $values = $pair[1]
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        foreach ($name in $values.Keys) {
            Set-ItemProperty -LiteralPath $key -Name $name -Value $values[$name] -Type DWord
        }
    }
    foreach ($k in (Get-TrayIconKeyPath)) {
        Set-ItemProperty -LiteralPath $k -Name "IsPromoted" -Value $TRAY_ICON_HIDDEN -Type DWord
    }
    return $true
}

# winget package lists. Kept above the guard so the test suite can source them
# and confirm every id still resolves on winget (catches
# renames/delisting/typos). uv is singled out: it installs per-user (its tools
# live in the user's home), so it's kept out of the elevated machine-wide batch
# and installed in the non-elevated process.
$UV_PKG = "astral-sh.uv"
# Named because --mse drops it from every list it appears in.
$AHK_PKG = "AutoHotkey.AutoHotkey"
$CORE_PKGS = @(
    "astral-sh.uv",
    "MediaArea.MediaInfo",
    "MediaArea.MediaInfo.GUI",
    "OliverBetz.ExifTool",
    "VideoLAN.VLC",
    "ZhornSoftware.Caffeine",
    "Gyan.FFmpeg"
)
$FULL_PKGS = @(  # Add if needed: "AxiomaticSystems.Bento4", "wez.atomicparsley"
    "AutoHotkey.AutoHotkey",
    "Google.Chrome",
    "Adobe.Acrobat.Reader.64-bit",
    "Audacity.Audacity",
    "MediaHuman.AudioConverter"
)
$CORE_UV = @(
    "triplecheck",
    "mhl-suite"
)
# Premiere Pro add-ons - installed only when Premiere is on the machine,
# alongside the plugins.
$PREMIERE_PKGS = @(
    "lucuma13.prem-down"
)

# Packages with a genuine per-user winget scope - AutoHotkey and ExifTool
# declare an explicit user-scope installer; MediaInfo/FFmpeg/Caffeine are
# portable zips with no declared scope, which winget installs per-user with no
# elevation. These skip the elevated machine-wide batch entirely (see
# Invoke-ElevatedInstall) and install as this user instead (see
# Invoke-SlowPass).
$USER_SCOPE_PKGS = @(
    "MediaArea.MediaInfo",
    "OliverBetz.ExifTool",
    "ZhornSoftware.Caffeine",
    "Gyan.FFmpeg",
    "AutoHotkey.AutoHotkey"
)

# Packages whose ONLY non-admin winget option is a portable zip. So these stay
# queued in the elevated machine-wide batch on every run, and only fall back to
# a per-user portable install when elevation isn't available.
$PORTABLE_FALLBACK_PKGS = @("VideoLAN.VLC", "Audacity.Audacity")

# The real (Program Files) install path for each $PORTABLE_FALLBACK_PKGS
# entry - used to tell "installed as the real thing" apart from "installed
# portable". winget's own DB (Test-WingetInstalled) can't tell scopes apart,
# so without this a portable fallback would read as "done" forever and the
# machine-wide install would never be retried once admin becomes available.
$MACHINE_EXE_PATH = @{
    "VideoLAN.VLC"      = "$(Get-ProgramFiles64)\VideoLAN\VLC\vlc.exe"
    "Audacity.Audacity" = "$(Get-ProgramFiles64)\Audacity\Audacity.exe"
}

# Friendly display names for the winget ids (uv tools are already friendly).
$PKG_ALIAS = @{
    "astral-sh.uv"                = "uv"
    "MediaArea.MediaInfo"         = "MediaInfo CLI"
    "MediaArea.MediaInfo.GUI"     = "MediaInfo GUI"
    "OliverBetz.ExifTool"         = "ExifTool"
    "VideoLAN.VLC"                = "VLC"
    "ZhornSoftware.Caffeine"      = "Caffeine"
    "Gyan.FFmpeg"                 = "FFmpeg"
    "AutoHotkey.AutoHotkey"       = "AutoHotKey"
    "Google.Chrome"               = "Google Chrome"
    "Adobe.Acrobat.Reader.64-bit" = "Adobe Acrobat Reader"
    "Audacity.Audacity"           = "Audacity"
    "MediaHuman.AudioConverter"   = "MediaHuman Audio Converter"
    "lucuma13.prem-down"          = "prem-down"
}
function Get-PkgAlias($id) { if ($PKG_ALIAS.ContainsKey($id)) { $PKG_ALIAS[$id] } else { $id } }

# Remove-SelfTemp - delete our own copy when we were launched from a temp file.
# The documented entrypoint downloads the script to %TEMP% before running it;
# PowerShell loads the whole script into memory first, so deleting the file
# mid-run is safe. Only ever removes a copy under %TEMP% - a checkout or any
# other location is left untouched.
function Remove-SelfTemp {
    # $path/$temp default to the live script path and TEMP, but are injectable so the
    # guard can be unit-tested. Guard on $temp being non-empty: StartsWith("") is true
    # for every path, so a blank TEMP must NOT match (and delete) an arbitrary script path.
    param([string]$path = $PSCommandPath, [string]$temp = $env:TEMP)
    if ($temp -and $path -and $path.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

# Test-AppInstalled <pattern> - true if any Windows uninstall entry's
# DisplayName matches <pattern> (per-machine 64- and 32-bit, plus per-user).
# Plenty of entries carry no DisplayName at all, so "/v DisplayName" drops them
# before the match runs.
#
# reg.exe rather than Get-ItemProperty: a 32-bit PowerShell host reads
# HKLM\SOFTWARE through WOW64 redirection, so both per-machine paths would
# collapse onto the 32-bit view and a 64-bit-only entry (Flicker Free registers
# one) would read as missing - reinstalling it on every run. /reg:64 and /reg:32
# name the view explicitly whatever the host's bitness, and unlike the .NET
# RegistryView API they still work under CLM. HKCU isn't redirected for this
# path, so one view covers it.
#
# Kept above the library guard, with Remove-SelfTemp, so the tests can reach it.
function Test-AppInstalled($pattern) {
    foreach ($key in @(
            @{ Path = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; View = "64" },
            @{ Path = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; View = "32" },
            @{ Path = "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; View = "64" }
        )) {
        # A key that isn't there (no per-user uninstall entries, or /reg:32 on 32-bit
        # Windows) goes to stderr and yields no lines - no match, no noise.
        foreach ($line in (reg.exe query $key.Path /s /v DisplayName "/reg:$($key.View)" 2>$null)) {
            if ($line -match '\sDisplayName\s+REG_SZ\s+(.+)$') {
                if ($Matches[1].Trim() -match $pattern) { return $true }
            }
        }
    }
    return $false
}

# Non-winget packages already on the machine? Each registers a Windows uninstall entry.
function Test-FlickerFreeInstalled { Test-AppInstalled 'Flicker Free' }
function Test-MisterHorseInstalled { Test-AppInstalled 'Mister Horse' }

# Sourced as a library (tests set $env:LOAD_LIB): stop here, run nothing below.
if ($env:LOAD_LIB) { return }

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------

$FULL = $args -contains "--full"
$FAST = $args -contains "--fast"
$DRY_RUN = $args -contains "--dry-run"

# --mse - leave AutoHotkey and its macros out of the run entirely, and skip the
# two Premiere plugins (Mister Horse, Flicker Free). Everything else Premiere
# still applies: shortcuts, workspaces, preferences, LUTs and $PREMIERE_PKGS.
$MSE = $args -contains "--mse"
if ($MSE) {
    $FULL_PKGS = @($FULL_PKGS | Where-Object { $_ -ne $AHK_PKG })
    $USER_SCOPE_PKGS = @($USER_SCOPE_PKGS | Where-Object { $_ -ne $AHK_PKG })
}

# No flag given - run the Fast pass inline now (quick config), then pause and
# run the Full pass in this same process. Bail if there's no interactive console
# (e.g. CI) so we don't run a heavy install on an unattended box.
$AUTO = $false
if (-not ($FULL -or $FAST -or $DRY_RUN)) {
    if ([System.Console]::IsInputRedirected) {
        Write-Error "No setup flag given and no interactive console. Pass --fast or --full."
        Remove-SelfTemp
        exit 1
    }
    $AUTO = $true
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

$PREMIERE_OK = Test-Path $PremiereDir
# Premiere may rewrites its prefs while running - activating a set while it's running can get clobbered.
$PREMIERE_RUNNING = $PREMIERE_OK -and ($null -ne (Get-Process -Name "Adobe Premiere Pro*" -ErrorAction SilentlyContinue))
$WINGET_OK = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)

# Long path support (HKLM, machine-wide) - lifts the 260-char MAX_PATH cap for
# any long-path-aware process, which matters the moment a tool walks a deeply
# nested folder tree (e.g. mhl-suite).
$LONG_PATHS_OK = (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled") -eq 1

# Audacity, by its Windows uninstall entry rather than an install path, so it is
# found however it got onto the machine - our own winget Audacity.Audacity, a
# manual download, or the Muse Hub build.
$AUDACITY_OK = Test-AppInstalled 'Audacity'
# Audacity rewrites audacity.cfg wholesale when it quits, so anything written
# while it is open is discarded on exit. Same reasoning as $PREMIERE_RUNNING.
$AUDACITY_RUNNING = $AUDACITY_OK -and ($null -ne (Get-Process -Name "audacity" -ErrorAction SilentlyContinue))

# Audacity's settings file.
$AUDACITY_CFG = Join-Path $env:APPDATA "audacity\audacity.cfg"

# The Audacity settings we enforce:
#   GUI/DefaultViewModeChoiceNew  new tracks open as a spectrogram, not a waveform
#   Spectrum/MaxFreq              top of the spectrogram's frequency range;
#                                 Audacity's 20 kHz default crops the display
#                                 well below what 96/192 kHz recordings carry
$AUDACITY_PREFS = @(
    "GUI/DefaultViewModeChoiceNew=Spectrogram",
    "Spectrum/MaxFreq=48000"
)

# Premiere shortcut set + workspace we distribute
$KYS_FILE = "LGG_25.1_WINDOWS.kys"
$LAYOUT_FILE_1 = "UserWorkspace_LGG_1.xml"
$LAYOUT_FILE_2 = "UserWorkspace_LGG_2.xml"

# Keyboard repeat. Via Get-RegValue: a fresh profile can be missing either value, and
# reading it by dotting would error twice instead of yielding $null.
$KB_Speed = Get-RegValue "HKCU:\Control Panel\Keyboard" "KeyboardSpeed"
$KB_Delay = Get-RegValue "HKCU:\Control Panel\Keyboard" "KeyboardDelay"
$KB_OK = ($KB_Speed -eq "31") -and ($KB_Delay -eq "0")

# Test-WingetInstalled <id> - true when exactly this package id is installed.
#
# --exact is load-bearing. Without it `winget list --id` filters on a SUBSTRING,
# and the match below is an unanchored regex over the output, so both halves of
# the check agree on the wrong answer: with only MediaInfo GUI installed,
# "MediaArea.MediaInfo" matches the id "MediaArea.MediaInfo.GUI" and the CLI
# package - a separate entry in $CORE_PKGS - reads as already installed and is
# never installed.
function Test-WingetInstalled($id) {
    if (-not $WINGET_OK) { return $false }
    $result = winget list --id $id --exact --accept-source-agreements 2>$null
    return $LASTEXITCODE -eq 0 -and ($result -match [regex]::Escape($id))
}

# Test-WingetUpgradePending <id> - true when winget still has a newer version
# for an already-installed package.
function Test-WingetUpgradePending($id) {
    if (-not $WINGET_OK) { return $false }
    $result = winget list --id $id --exact --upgrade-available --include-unknown --accept-source-agreements 2>$null
    return $LASTEXITCODE -eq 0 -and ($result -match [regex]::Escape($id))
}

# Test-PkgReallyInstalled <id> - like Test-WingetInstalled, but for
# $PORTABLE_FALLBACK_PKGS checks whether the REAL (Program Files) install is
# present, not just any scope. winget list reports a package "installed" the
# moment either scope's copy lands, which would otherwise make the checklist
# call a portable fallback "done" forever, and make the elevated batch "upgrade"
# that portable copy in place instead of ever installing the real one.
function Test-PkgReallyInstalled($id) {
    if ($MACHINE_EXE_PATH.ContainsKey($id)) { return Test-Path $MACHINE_EXE_PATH[$id] }
    return Test-WingetInstalled $id
}

# Packages the elevated batch was given and that were still not current when it
# came back.
$PKG_NOT_APPLIED = @()

# Test-PkgApplied <id> - installed, and not one the batch just failed to update.
function Test-PkgApplied($id) {
    return (Test-PkgReallyInstalled $id) -and ($PKG_NOT_APPLIED -notcontains $id)
}

# Invoke-WingetApply <id> [scope] - install the package, or upgrade it in place
# when already present. <scope> ("user"/"machine") is passed only on a fresh
# install; an upgrade keeps the existing install's scope. Used for the
# non-elevated, per-user installs (uv); the elevated machine-wide batch builds
# its own winget command lines (see Invoke-ElevatedInstall).
function Invoke-WingetApply($id, $scope) {
    # Redirecting a native command's stderr under $ErrorActionPreference='Stop'
    # wraps each line in a NativeCommandError that aborts the script, so soften
    # the preference while we capture winget's output.
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if (Test-WingetInstalled $id) {
        $out = winget upgrade --id $id --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
        # "already current" is winget's normal answer here, not a failure
        $ok = $LASTEXITCODE -eq 0 -or $out -match 'No available upgrade|No installed package|No newer package'
    }
    else {
        $scopeArg = if ($scope) { @("--scope", $scope) } else { @() }
        $out = winget install --id $id --exact --silent @scopeArg --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
        $ok = $LASTEXITCODE -eq 0
    }
    $ErrorActionPreference = $eap
    if (-not $ok) {
        Write-Host "  [warn] winget could not apply $(Get-PkgAlias $id):"
        Write-Host $out.TrimEnd()
    }
}

function Test-UvInstalled($pkg) {
    $uv = Find-UvExe
    if (-not $uv) { return $false }
    return [bool]((& $uv tool list 2>$null) -match "^$pkg")
}

# Test-PremiereApplied - true once our shortcut set is active in any Premiere
# profile (the prefs' Shortcuts.Filename points at our .kys). Decodes the prefs
# as UTF-8 to match how Set-PrefNode writes them - see the note on
# Get-WorkspaceName for why the 5.1 default (the ANSI code page, for a BOM-less
# file) is the wrong reader here.
function Test-PremiereApplied {
    if (-not $PREMIERE_OK) { return $false }
    foreach ($profileDir in Get-ChildItem "$PremiereDir\*\Profile-*" -Directory -ErrorAction SilentlyContinue) {
        $prefs = Join-Path $profileDir.FullName "Adobe Premiere Pro Prefs"
        if (-not (Test-Path $prefs)) { continue }
        $content = Get-Content -LiteralPath $prefs -Raw -Encoding UTF8
        if ($content -match "<FE\.Prefs\.Shortcuts\.Filename>$([regex]::Escape($KYS_FILE))</FE\.Prefs\.Shortcuts\.Filename>") { return $true }
    }
    return $false
}

# Test-LutPresent - true once at least one LUT has been downloaded into the work
# dir.
function Test-LutPresent { [bool](Get-ChildItem "$WorkDir\LUTs" -File -ErrorAction SilentlyContinue | Select-Object -First 1) }

# Test-AudacityApplied - true once every $AUDACITY_PREFS entry is in the cfg.
# Each entry's tail past the section is already the exact "key=value" line, so
# it is matched as a whole line with no reformatting.
function Test-AudacityApplied {
    if (-not (Test-Path $AUDACITY_CFG)) { return $false }
    $content = Get-Content -LiteralPath $AUDACITY_CFG -Raw -Encoding UTF8
    foreach ($pref in $AUDACITY_PREFS) {
        $line = $pref.Substring($pref.IndexOf('/') + 1)
        if ($content -notmatch ("(?m)^" + [regex]::Escape($line) + "\r?$")) { return $false }
    }
    return $true
}

# Set-AudacityConfig - write every $AUDACITY_PREFS entry into audacity.cfg.
#
# Deliberately re-checks for Audacity rather than reading the cached
# $AUDACITY_OK: it is called twice, and the second call happens after the
# elevated winget install.
#
# Runs in the NON-elevated process both times: the cfg lives under the invoking
# user's %APPDATA%, so doing this inside the elevated batch would write it into
# the admin's profile instead.
function Set-AudacityConfig {
    if ($CLM) { return }   # Set-AudacityPref needs .NET byte IO; see its header
    # Re-checked rather than reading $AUDACITY_OK - see the header.
    if (-not (Test-AppInstalled 'Audacity')) { return }
    if ($null -ne (Get-Process -Name "audacity" -ErrorAction SilentlyContinue)) {
        Write-Host "  [warn] Audacity is running - spectrogram settings not changed"
        return
    }
    foreach ($pref in $AUDACITY_PREFS) {
        $slash = $pref.IndexOf('/')
        $section = $pref.Substring(0, $slash)          # e.g. GUI
        $entry = $pref.Substring($slash + 1)           # e.g. DefaultViewModeChoiceNew=Spectrogram
        $eq = $entry.IndexOf('=')
        $key = $entry.Substring(0, $eq)
        if (-not (Set-AudacityPref -cfg $AUDACITY_CFG -section $section -key $key -value $entry.Substring($eq + 1))) {
            Write-Host "  [warn] Audacity settings file could not be written - $key not changed"
        }
    }
}

function Done { param($msg); Write-Host ("  " + "[done]".PadRight(12) + $msg) }
function Skipped { param($msg); Write-Host ("  " + "[skipped]".PadRight(12) + $msg) }
function WouldRun { param($msg); Write-Host ("  " + "[would run]".PadRight(12) + $msg) }

# Show-Checklist - print the live state of every action: [done], [skipped] or
# [would run]. The same call works at the start of a run (a preview - nothing
# done yet) or at the end (a summary - state reflects what ran), because every
# line is derived from the real current state plus the run mode. No flags, no
# "post" switch.
function Show-Checklist {
    $kbSpeed = Get-RegValue "HKCU:\Control Panel\Keyboard" "KeyboardSpeed"
    $kbDelay = Get-RegValue "HKCU:\Control Panel\Keyboard" "KeyboardDelay"
    $kbOk = ($kbSpeed -eq "31") -and ($kbDelay -eq "0")
    $toggle = "HKCU:\Keyboard Layout\Toggle"
    $togglesOk = ((Get-RegValue $toggle 'Hotkey') -eq "3") -and ((Get-RegValue $toggle 'Language Hotkey') -eq "3") -and ((Get-RegValue $toggle 'Layout Hotkey') -eq "3")
    $sysOk = $kbOk -and $togglesOk -and (Test-ExplorerViewFullyApplied) -and (Test-Taskbar) -and (Test-TrayIcon)
    $longPathsOk = (Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled") -eq 1
    $premiereRunning = $PREMIERE_OK -and ($null -ne (Get-Process -Name "Adobe Premiere Pro*" -ErrorAction SilentlyContinue))
    $ahkActive = Test-Path $AhkScript
    $ahkInstalled = [bool](Find-AhkExe)

    Write-Host ""

    # Constrained Language Mode disables the .NET-backed steps below; flag it
    # once up top so the per-line "skipped" reasons make sense.
    if ($CLM) { Write-Host "  [info] Constrained Language Mode active - default apps and Premiere prefs can't be scripted; keyboard/Explorer settings persist but apply at next sign-in." }

    # Premiere Pro - shortcuts, workspace, preferences and LUTs are the editing
    # setup, so they all require Premiere installed. (When Premiere is open the
    # files are dropped but not activated.)
    if (-not $PREMIERE_OK) { Skipped  "Premiere Pro (shortcuts, workspace, preferences, LUTs) - Premiere Pro not installed" }
    elseif ($premiereRunning) { Skipped  "Premiere Pro (shortcuts, workspace, preferences, LUTs) - Premiere Pro is open" }
    elseif ($CLM) { Skipped  "Premiere Pro (shortcuts, workspace, preferences, LUTs) - Not allowed under Constrained Language Mode" }
    elseif ((Test-PremiereApplied) -and (Test-LutPresent)) { Done "Premiere Pro (shortcuts, workspace, preferences, LUTs)" }
    else { WouldRun "Premiere Pro (shortcuts, workspace, preferences, LUTs)" }

    # Audacity - spectrogram track view and its frequency range.
    if (-not $AUDACITY_OK) { Skipped  "Audacity (track view, frequency range) - Audacity not installed" }
    elseif ($AUDACITY_RUNNING) { Skipped  "Audacity (track view, frequency range) - Audacity is open" }
    elseif ($CLM) { Skipped  "Audacity (track view, frequency range) - Not allowed under Constrained Language Mode" }
    elseif (Test-AudacityApplied) { Done "Audacity (track view, frequency range)" }
    else { WouldRun "Audacity (track view, frequency range)" }

    # Activate AHK macros - applied whenever AutoHotkey is present. In --fast we
    # might only have a pre-installed AutoHotkey to work with (installing it is
    # a Full-pass step).
    if ($MSE) { Skipped  "Activate AHK macros - --mse" }
    elseif ($ahkActive) { Done     "Activate AHK macros" }
    elseif ($ahkInstalled) { WouldRun "Activate AHK macros" }
    elseif ($FAST) { Skipped  "Activate AHK macros - AutoHotkey not installed" }
    else { WouldRun "Activate AHK macros" }

    # System preferences - keyboard repeat speed/delay, the disabled
    # layout-switch hotkeys, Explorer's default folder view and the taskbar.
    if ($sysOk) { Done "System preferences" } else { WouldRun "System preferences" }

    # Long path support - HKLM, needs elevation.
    if ($longPathsOk) { Done "Enable Windows long path support" }
    elseif ($FAST) { Skipped "Enable Windows long path support - requires --full (needs admin elevation)" }
    else { WouldRun "Enable Windows long path support" }

    # Install or update apps - winget packages, non-winget programs (Premiere Pro plugins) and uv tools
    # (each entry paired with its "already installed?" check). Installation is slow, so it runs last.
    $apps = @()
    foreach ($pkg in $CORE_PKGS) { $apps += @{ name = (Get-PkgAlias $pkg); ok = (Test-PkgApplied $pkg) } }
    if ($FULL) { foreach ($pkg in $FULL_PKGS) { $apps += @{ name = (Get-PkgAlias $pkg); ok = (Test-PkgApplied $pkg) } } }
    if ($PREMIERE_OK) {
        # The plugins are the only Premiere step --mse drops; $PREMIERE_PKGS and
        # every config step stay.
        if (-not $MSE) {
            $apps += @{ name = "Mister Horse"; ok = (Test-MisterHorseInstalled) }
            $apps += @{ name = "Flicker Free"; ok = (Test-FlickerFreeInstalled) }
        }
        foreach ($pkg in $PREMIERE_PKGS) { $apps += @{ name = (Get-PkgAlias $pkg); ok = (Test-PkgApplied $pkg) } }
    }
    foreach ($pkg in $CORE_UV) { $apps += @{ name = $pkg; ok = (Test-UvInstalled $pkg) } }

    if ($FAST) {
        Skipped ("Install or update: " + (($apps | ForEach-Object { $_.name }) -join ", "))
    }
    else {
        $done = @($apps | Where-Object { $_.ok }      | ForEach-Object { $_.name })
        $todo = @($apps | Where-Object { -not $_.ok }  | ForEach-Object { $_.name })
        if ($done.Count -gt 0) { Done     ("Install or update: " + ($done -join ", ")) }
        if ($todo.Count -gt 0) { WouldRun ("Install or update: " + ($todo -join ", ")) }
    }

    Write-Host ""
}

# -----------------------------------------------------------------------------
# Phase functions
# -----------------------------------------------------------------------------
# Invoke-FastPass - lightweight preference changes only (no downloads/installs).
# Invoke-SlowPass - everything that downloads or installs. The bare command runs
# Invoke-FastPass inline then hands off to a Full pass that runs Invoke-SlowPass;
# --fast runs Invoke-FastPass only and --full runs both.

function Install-AhkScript {
    # Download the AHK macro script into the work dir and launch it now so the
    # shortcuts work immediately. The file's presence there is the "done"
    # marker.
    #
    # --mse stops here too: the package is already out of the install lists,
    # but the macros would otherwise still be dropped and launched on a machine
    # that has its own AutoHotkey.
    if ($MSE) { return }
    if (Test-Path $AhkScript) { return }
    $ahkExe = Find-AhkExe
    if (-not $ahkExe) {
        Write-Host "  [warn] AutoHotkey not found - skipping AHK shortcuts"
        return
    }
    curl.exe -s -o $AhkScript "https://raw.githubusercontent.com/lucuma13/load/refs/heads/main/src/data/MacKeyboard_LGG.ahk"
    # Quote the path and launch non-elevated - so macros will work only on non-elevated apps.
    Start-Process $ahkExe -ArgumentList "`"$AhkScript`""
}

function Invoke-FastPass {
    # Audacity - spectrogram track view and its frequency range. Catches an
    # Audacity already on the machine (however it was installed), so it applies
    # in every mode, --fast included. A fresh machine where our own --full run
    # is what installs Audacity is handled by the second call in Invoke-SlowPass.
    #
    # Safe on a never-launched Audacity with no cfg yet: it writes one, and
    # Audacity merges a partial hand-written cfg over its defaults and keeps our
    # keys when it rewrites the file on quit.
    Set-AudacityConfig

    # Premiere Pro shortcuts, workspace & LUTs
    if ($PREMIERE_OK) {
        foreach ($profileDir in Get-ChildItem "$PremiereDir\*\Profile-*" -Directory -ErrorAction SilentlyContinue) {
            $prefs = Join-Path $profileDir.FullName "Adobe Premiere Pro Prefs"
            $winDir = Join-Path $profileDir.FullName "Win"
            $layouts = Join-Path $profileDir.FullName "Layouts"

            # Premiere creates Win/ and Layouts/ inside each profile, so we
            # write into them rather than creating them ourselves. Drop the
            # shortcuts into the Profile's Win folder (where Premiere reads
            # custom sets)
            curl.exe -s --output-dir $winDir  -O "https://raw.githubusercontent.com/lucuma13/load/refs/heads/main/src/data/$KYS_FILE"
            # Drop the workspaces into Layouts. Premiere auto-registers them on launch.
            curl.exe -s --output-dir $layouts -O "https://raw.githubusercontent.com/lucuma13/load/refs/heads/main/src/data/$LAYOUT_FILE_1"
            curl.exe -s --output-dir $layouts -O "https://raw.githubusercontent.com/lucuma13/load/refs/heads/main/src/data/$LAYOUT_FILE_2"
            # curl writes the body verbatim, so the payload lands LF. Re-end it CRLF to
            # match the rest of the Layouts folder. Skipped under CLM, where the no-BOM
            # .NET write is blocked.
            if (-not $CLM) {
                foreach ($layoutFile in @($LAYOUT_FILE_1, $LAYOUT_FILE_2)) {
                    $layoutPath = Join-Path $layouts $layoutFile
                    if (Test-Path $layoutPath) { ConvertTo-CrlfFile $layoutPath }
                }
            }
            $wsName = Get-WorkspaceName (Join-Path $layouts $LAYOUT_FILE_1)

            if ($PREMIERE_RUNNING) {
                Write-Host "  [warn] Premiere Pro is running - files dropped but not activated"
            }
            elseif ($CLM) {
                # The prefs write is a byte-level .NET edit (the only no-BOM
                # writer on PowerShell 5.1); it can't run under CLM. The
                # shortcut/workspace files are still dropped above - Premiere
                # registers the workspace on launch.
                Write-Host "  [warn] Constrained Language Mode - shortcut/workspace files dropped but prefs not modified"
            }
            elseif (Test-Path $prefs) {
                # $profileDir.Parent.Name is the version folder (e.g. "25.0"),
                # so each profile's warning is tagged with the Premiere version
                # it came from.
                Set-PremierePro -Prefs $prefs -KysFile $KYS_FILE -WsName $wsName -Version $profileDir.Parent.Name
            }
        }

        # LUTs - download every LUT in src/data/LUTs into $WorkDir\LUTs
        $lutDir = "$WorkDir\LUTs"
        $lutApi = "https://api.github.com/repos/lucuma13/load/contents/src/data/LUTs?ref=main"
        New-Item -ItemType Directory -Force -Path $lutDir | Out-Null
        try {
            $luts = Invoke-RestMethod -Uri $lutApi -Headers @{ "User-Agent" = "load-setup" }
            foreach ($lut in $luts) {
                if ($lut.download_url) {
                    curl.exe -s --output-dir "$lutDir" -O $lut.download_url
                }
            }
        }
        catch {
            Write-Host "  [warn] Could not fetch LUTs: $_"
        }
    }

    # AHK macros - apply now if AutoHotkey is already installed (covers --fast
    # on a machine that has it). On a Full run AutoHotkey is installed in
    # Invoke-SlowPass, which applies them there instead - so only act here when
    # it's already present.
    if (Find-AhkExe) { Install-AhkScript }

    # Keyboard preferences
    if (-not $KB_OK) {
        # Persist across reboots. Both values are REG_SZ - Windows ignores them as a
        # DWORD - and -Type String is what pins that: Set-ItemProperty infers the type
        # from the value only when it has to CREATE the entry, so passing a bare 31
        # writes a DWORD on exactly the fresh profile this script exists to set up,
        # while looking correct on any machine where the values already exist.
        Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardSpeed" -Value "31" -Type String
        Set-ItemProperty -Path "HKCU:\Control Panel\Keyboard" -Name "KeyboardDelay" -Value "0" -Type String

        # Apply to the active session immediately (no logoff needed). Needs
        # Add-Type + P/Invoke, both blocked under CLM - the registry writes
        # above still persist, so under CLM the change just takes effect at next
        # sign-in instead of instantly.
        if (-not $CLM) {
            if (-not ([System.Management.Automation.PSTypeName]'KeyboardConfig').Type) {
                Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class KeyboardConfig {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, uint pvParam, uint fWinIni);
}
"@
            }
            [KeyboardConfig]::SystemParametersInfo(0x0017, 0, 0, 0)  | Out-Null  # SPI_SETKEYBOARDDELAY
            [KeyboardConfig]::SystemParametersInfo(0x000B, 31, 0, 0) | Out-Null  # SPI_SETKEYBOARDSPEED
        }
    }

    # Disable the input-language / keyboard-layout switch hotkeys (Alt+Shift,
    # Ctrl+Shift) at the OS level - "3" = Not Assigned. Done here instead of in
    # the AHK macros because intercepting LAlt & LShift there swallowed Shift
    # and broke Alt+Shift shortcuts (e.g. Win+Alt+Shift+Backspace, Alt+Shift+2).
    # Values are REG_SZ; create the key if a fresh profile lacks it. Applies at
    # next sign-in.
    $toggle = "HKCU:\Keyboard Layout\Toggle"
    if (-not (Test-Path $toggle)) { New-Item -Path $toggle -Force | Out-Null }
    Set-ItemProperty -Path $toggle -Name "Hotkey"          -Value "3" -Type String
    Set-ItemProperty -Path $toggle -Name "Language Hotkey" -Value "3" -Type String
    Set-ItemProperty -Path $toggle -Name "Layout Hotkey"   -Value "3" -Type String

    # Explorer preferences - show all filename extensions (HideFileExt = 0), the
    # Windows counterpart of macOS's AppleShowAllExtensions.
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0

    # Show the status bar at the bottom of Explorer windows (ShowStatusBar = 1).
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowStatusBar" -Value 1

    # Tell Explorer to re-read its settings so the change applies without a
    # restart. Add-Type/P-Invoke is blocked under CLM; the HideFileExt write
    # above persists, so under CLM the change just applies on the next Explorer
    # restart instead of now.
    if (-not $CLM) {
        if (-not ([System.Management.Automation.PSTypeName]'Win32Shell').Type) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Shell {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
}
"@
        }
        [Win32Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)  # SHCNE_ASSOCCHANGED
    }

    # Taskbar and tray.
    $taskbarChanged = Set-Taskbar
    if ($taskbarChanged) {
        Write-Host "  [note] Taskbar set: icons centred, on all displays, no Task view,"
        Write-Host "         search icon and label, OneDrive out of the system tray."
    }

    # Default folder view - no grouping anywhere, sort by Name ascending
    # everywhere except Downloads, which sorts by Date modified with the newest
    # file first. Last in the pass deliberately: applying it restarts the
    # shell, so the relaunched Explorer picks up HideFileExt, the status bar,
    # the taskbar and the new default apps in the same bounce. Guarded by its
    # own state check, so a re-run neither clears the shellbags again nor closes
    # the user's windows a second time.
    $viewChanged = Set-ExplorerDefaultView
    if ($viewChanged) {
        Write-Host "  [note] Explorer default view set to Name / ascending with no grouping,"
        Write-Host "         and Downloads to Date modified / newest first."
    }
    # One restart for whichever of the two actually changed - the taskbar needs
    # it just as much as the folder view, and neither should bounce the shell a
    # second time on a re-run.
    if ($viewChanged -or $taskbarChanged) {
        Write-Host "  [note] Restarting Explorer to apply it - any open Explorer windows will close."
        Restart-Explorer
    }

    # Downloads drifting back to grouped is not a template problem (see the
    # section header comment above Set-ExplorerDefaultView) - it happens on an
    # otherwise perfectly-applied profile, every time Downloads is opened fresh,
    # so this runs unconditionally rather than folded into the check above.
    # Registry-only and does not need an Explorer restart (confirmed live).
    if (Repair-FolderGrouping) {
        Write-Host "  [note] A folder (Downloads, most likely) had drifted back to grouped - fixed."
    }
}

# Update-SessionPath - pull the freshly-installed tools' PATH entries into this
# session. Normally rebuilds $env:Path from the Machine + User stores via .NET
# (which expands %vars%). Under CLM that .NET call is blocked, so fall back to
# reading the registry with cmdlets and *appending* to the live $env:Path
# (REG_EXPAND_SZ entries come back unexpanded, so we keep the current PATH
# rather than replacing it).
function Update-SessionPath {
    if (-not $CLM) {
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [System.Environment]::GetEnvironmentVariable("Path", "User")
        return
    }
    $machine = Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" 'Path'
    $user = Get-RegValue "HKCU:\Environment" 'Path'
    $env:Path = (@($env:Path, $machine, $user) | Where-Object { $_ }) -join ";"
}

# Invoke-ElevatedInstall - run every install that needs admin rights in ONE
# elevated process, so a standard user is asked for the admin password just
# once. The install/upgrade decisions and the plugin downloads happen here
# (non-elevated); only the installers run elevated. winget runs with --scope
# machine so packages install system-wide and are available to the standard
# user; uv and $USER_SCOPE_PKGS are excluded (they must stay per-user - see
# Invoke-SlowPass). Does nothing, and prompts for nothing, when there's nothing
# left to install.
#
# The batch is handed to an elevated cmd.exe via its command line: AppLocker's
# script-file rules and AV script heuristics don't apply, and cmd works under
# CLM too.
#
# Returns $true when nothing needed elevation, or the elevated batch actually
# ran; $false when a prompt was needed but declined, cancelled, or the user has
# no admin rights at all. Invoke-SlowPass uses that to fall back to a portable,
# per-user install for $PORTABLE_FALLBACK_PKGS.
function Invoke-ElevatedInstall {
    $cmds = @()
    $wantMisterHorse = $false
    $wantFlickerFree = $false
    $wantApply = @()

    # Long path support.
    if (-not $LONG_PATHS_OK) {
        $cmds += 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f'
    }

    # Premiere plugins - download now (no admin needed), install in the elevated
    # batch. Both run unattended (msiexec /qn, NSIS /S) and both return
    # immediately, so wrap them in "start /wait" (the leading "" is the required
    # window-title placeholder) so the batch waits for each to finish.
    #
    # Queued AHEAD of the winget commands: winget returns as soon as a packaged
    # installer hands off, but that installer's own Windows Installer
    # transaction can still be open, and a second msiexec against a busy
    # Installer exits at once with ERROR_INSTALL_ALREADY_RUNNING (1618). Under
    # /qn that carries no dialog, and "&" ignores exit codes, so the install
    # would vanish leaving nothing in the batch output or the event log - which
    # is how Mister Horse got skipped behind an Acrobat install.
    #
    # Skipped entirely under --mse - including the downloads, so nothing is
    # fetched only to be thrown away.
    if ($PREMIERE_OK -and -not $MSE) {
        if (-not (Test-MisterHorseInstalled)) {
            $pmPath = "$WorkDir\MisterHorseProductManager.msi"
            curl.exe -fsSL -o $pmPath "https://misterhorse.com/downloads/product-manager/win"
            $cmds += "start `"`" /wait msiexec /i `"$pmPath`" /qn"
            $wantMisterHorse = $true
        }
        # Flicker Free 2.0 - the download is a zip wrapping the installer .exe.
        #
        # /S installs it unattended. The .exe is a Nullsoft Install System 3.10
        # installer (its exehead manifest says so), and the NSIS stub itself
        # handles /S by skipping every page - licence, install location, Finish
        # - and running the install sections straight through.
        if (-not (Test-FlickerFreeInstalled)) {
            $ffZip = "$WorkDir\flickerfree_229_AE.zip"
            $ffDir = "$WorkDir\flickerfree_229_AE"
            curl.exe -fsSL -o $ffZip "https://www.digitalanarchy.com/downloads/flickerfree_229_AE.zip"
            Expand-Archive -Path $ffZip -DestinationPath $ffDir -Force
            $ffExe = Get-ChildItem $ffDir -Filter *.exe | Select-Object -First 1
            if ($ffExe) {
                $cmds += "start `"`" /wait `"$($ffExe.FullName)`" /S"
                $wantFlickerFree = $true
            }
        }
    }

    # winget: everything except uv and $USER_SCOPE_PKGS (both installed
    # per-user, no elevation needed - see Invoke-SlowPass), installed
    # machine-wide. An upgrade keeps the existing install's scope, so --scope is
    # only set on a fresh install. Test-PkgReallyInstalled decides
    # install-vs-upgrade: for $PORTABLE_FALLBACK_PKGS winget's own DB can't tell
    # scopes apart, so once the per-user fallback in Invoke-SlowPass has
    # installed one of them, plain Test-WingetInstalled would call it
    # "installed" forever and "upgrade" would just refresh the portable copy in
    # place - never installing the real one even once admin is available.
    if ($WINGET_OK) {
        $ids = @($CORE_PKGS | Where-Object { $_ -ne $UV_PKG -and $USER_SCOPE_PKGS -notcontains $_ })
        if ($FULL) { $ids += ($FULL_PKGS | Where-Object { $USER_SCOPE_PKGS -notcontains $_ }) }
        if ($PREMIERE_OK) { $ids += $PREMIERE_PKGS }
        if ($ids.Count) {
            # Warm the package source ONCE, before any package command, and only
            # when there is a package command to run.
            #
            # winget is an MSIX app whose package source has to be registered
            # per user, and the user here is not the one who ran the script: a
            # standard user's elevation lands in whichever admin account
            # answered the UAC prompt. One serialised attempt ahead of the batch
            # is what that account needs
            $cmds += "winget source update --accept-source-agreements --disable-interactivity"
            foreach ($id in $ids) {
                if (Test-PkgReallyInstalled $id) {
                    $cmds += "winget upgrade --id $id --exact --silent --accept-package-agreements --accept-source-agreements"
                }
                else {
                    $cmds += "winget install --id $id --exact --silent --scope machine --accept-package-agreements --accept-source-agreements"
                }
                # Every queued package is re-checked afterwards.
                $wantApply += $id
            }
        }
    }

    if ($cmds.Count -eq 0) { return $true }  # nothing needs admin - no prompt, nothing failed either

    # Join with " & " (run each regardless of the previous one's exit code) and
    # hand it to one elevated cmd.exe. "/s /c" strips just the outermost quotes,
    # leaving the inner quotes around installer paths intact. -Wait so the
    # config that follows sees the installs finished; the elevated console shows
    # install progress.
    $chain = "/s /c `"" + ($cmds -join " & ") + "`""
    $elevated = $true
    try {
        Start-Process cmd.exe -ArgumentList $chain -Verb RunAs -Wait
    }
    catch {
        $elevated = $false
        Write-Host "  [warn] Elevated install step did not run: operation cancelled by the user. Continuing with standard privileges instead."
    }

    # Each plugin re-checked against its uninstall entry, because nothing above
    # reports a plugin that never installed: the batch swallows exit codes and a
    # 1618 msiexec is silent under /qn. The download is deleted only once its
    # plugin is actually there, so a failed install leaves the installer in
    # $WorkDir to be run by hand or retried without fetching it again.
    if ($wantMisterHorse) {
        if (Test-MisterHorseInstalled) { Remove-Item -LiteralPath $pmPath -Force -ErrorAction SilentlyContinue }
        else { Write-Host "  [warn] Mister Horse Product Manager did not install (another Windows Installer transaction may have been open) - re-run with --full, or run $pmPath yourself" }
    }
    if ($wantFlickerFree) {
        if (Test-FlickerFreeInstalled) {
            Remove-Item -LiteralPath $ffZip -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ffDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        else { Write-Host "  [warn] Flicker Free did not install - re-run with --full, or run the installer in $ffDir yourself" }
    }

    # Same idea for the winget packages: "&" runs every command regardless of
    # the previous one's exit code - which is what we want, one bad package
    # must not cost us the rest - but it also means a failure is swallowed, and
    # the cmd window closes over the error text before it can be read. So
    # re-check every package the batch was given and name the ones that didn't
    # land.
    #
    # Both halves are needed, because "applied" means different things either
    # side of the install/upgrade split: a fresh install that failed leaves
    # nothing behind and fails Test-PkgReallyInstalled, while a failed upgrade
    # leaves the OLD version sitting there, which passes it. Only
    # Test-WingetUpgradePending can tell that second case from a success - and
    # without it a batch that upgraded nothing at all still reported clean,
    # which is exactly how a stale Audacity reached the checklist as [done].
    if ($elevated -and $wantApply.Count) {
        $missing = @($wantApply | Where-Object { -not (Test-PkgReallyInstalled $_) -or (Test-WingetUpgradePending $_) })
        # Handed to Show-Checklist so the summary agrees with the warning below.
        $script:PKG_NOT_APPLIED = $missing
        if ($missing.Count) {
            Write-Host "  [warn] These did not install or update: $(($missing | ForEach-Object { Get-PkgAlias $_ }) -join ', '). The rest of the batch still ran - re-run with --full to retry them."
            if ($missing.Count -eq $wantApply.Count) {
                Write-Host "  [warn] Nothing in the batch applied. If elevation used a different (admin) account, winget's package source may not be registered for it - sign in to that account once and re-run with --full."
            }
        }
    }

    return $elevated
}

function Invoke-SlowPass {
    # Created here: this is the only pass that ever writes into it, so a
    # --fast-only or fast-then-decline run never creates it.
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

    # All installs that need admin rights (machine-wide winget packages + the
    # Premiere plugins) run in ONE elevated batch. Everything below stays in
    # this non-elevated process so it lands in the real user's profile.
    $elevated = Invoke-ElevatedInstall

    # uv and $USER_SCOPE_PKGS - installed per-user (no elevation, --scope
    # user) so they land in THIS user's home, not the admin's. Invoked by full
    # path where the script needs to run the result directly (see
    # Find-UvExe/Find-AhkExe) so it's found even when the session PATH didn't
    # pick up winget's change (common under CLM).
    if ($WINGET_OK) {
        Invoke-WingetApply $UV_PKG "user"
        foreach ($id in $USER_SCOPE_PKGS) { Invoke-WingetApply $id "user" }
    }

    # $PORTABLE_FALLBACK_PKGS (VLC, Audacity) only get a per-user portable
    # install when the elevated batch above genuinely didn't run - a real
    # admin install is strictly better (Start Menu shortcut/uninstall entry,
    # and VLC's default-app step below needs it) and stays queued in
    # Invoke-ElevatedInstall on every future run via Test-PkgReallyInstalled,
    # so this fallback only fires while no admin is available.
    if (-not $elevated -and $WINGET_OK) {
        foreach ($id in $PORTABLE_FALLBACK_PKGS) {
            if (-not (Test-PkgReallyInstalled $id)) {
                Write-Host "  [warn] Installing $(Get-PkgAlias $id) as a portable, per-user fallback. Re-run with admin available to get the full install."
                Invoke-WingetApply $id "user"
            }
        }
    }

    Update-SessionPath
    $uv = Find-UvExe
    if ($uv) {
        # --quiet silences uv's resolve/install progress on success but still
        # prints warnings and errors, so a failed install is surfaced without
        # any capture dance.
        foreach ($pkg in $CORE_UV) { & $uv tool install $pkg --upgrade --quiet }
        # Add uv's tool bin dir to PATH permanently and refresh for this
        # session.
        & $uv tool update-shell --quiet
        Update-SessionPath
    }
    else {
        Write-Host "  [warn] uv not found after install - reopen the terminal and re-run with --full to finish the uv tools ($($CORE_UV -join ', '))"
    }

    # Tell already-running apps to re-read the environment so the new PATH is
    # picked up without a logoff (this session is already refreshed above).
    # Needs Add-Type + P/Invoke, both blocked under CLM - skip the broadcast
    # there (other apps pick up the persisted PATH when they next start; this
    # session was already refreshed).
    if (-not $CLM) {
        if (-not ([System.Management.Automation.PSTypeName]'Win32Env').Type) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Env {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
        }
        $HWND_BROADCAST = [IntPtr]0xffff
        [IntPtr]$res = [IntPtr]::Zero
        [Win32Env]::SendMessageTimeout($HWND_BROADCAST, 0x001A, [IntPtr]::Zero, "Environment", 2, 5000, [ref]$res) | Out-Null  # WM_SETTINGCHANGE
    }

    # Audacity preferences, second pass. Invoke-FastPass already covered an
    # Audacity that was on the machine before this run; this catches the one the
    # --full winget batch just installed, which didn't exist when preflight (or
    # the fast pass) looked. Runs here in the non-elevated process so the cfg
    # lands in the real user's %APPDATA%, not the admin's. Idempotent.
    Set-AudacityConfig

    # AHK macros - AutoHotkey was installed above on a Full run (or already
    # present). Launched non-elevated from this process so the macros work on
    # non-elevated apps.
    Install-AhkScript
}

# -----------------------------------------------------------------------------
# Dispatch - Invoke-FastPass applies the quick config; Invoke-SlowPass does the
# downloads/installs. Both run in this same process.
# -----------------------------------------------------------------------------

# Wrapped so Remove-SelfTemp always runs (finally runs even on `exit`), deleting our
# %TEMP% copy of the script on every exit path - dry-run, fast and full.
try {
    # --dry-run just prints the checklist (a preview, since nothing has run), then stops.
    # Nothing above this point writes to disk, so the preview stays a pure read.
    if ($DRY_RUN) { Show-Checklist; exit 0 }

    # Fast pass runs for every mode (--fast, --full, and the bare command). It
    # never touches $WorkDir - see Invoke-SlowPass for why creating it is
    # deferred to there.
    Invoke-FastPass

    # The bare command pauses between the quick config and the heavy installs.
    # A single keypress: y/Y continues without Enter, and Enter alone continues
    # too. Any other key is ignored and the loop keeps waiting - there is no
    # way to decline into fast-only from here..
    if ($AUTO) {
        Write-Host ""
        Write-Host "  Fast loading is complete. Press (y) or Enter to continue on FULL mode " -NoNewline
        while ($true) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            if ($key.VirtualKeyCode -eq 13 -or $key.Character -eq 'y' -or $key.Character -eq 'Y') { break }
        }
        Write-Host ""
        $FULL = $true
    }
    if ($FULL) { Invoke-SlowPass }

    # End state summary.
    Show-Checklist
    Write-Host "  You're ready to roll!"
    Write-Host ""
}
finally {
    Remove-SelfTemp
}

# Completeness sentinel - MUST be the last line. The launch command verifies the
# downloaded file ends with this before executing, so a truncated download (e.g.
# a dropped connection) is rejected instead of run as an empty/partial script.
# === END load-win.ps1 ===
