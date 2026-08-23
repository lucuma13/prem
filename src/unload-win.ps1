<#
.SYNOPSIS
Windows workstation cleanup script

.DESCRIPTION
It removes custom setup - load-win's work directory, our Premiere Pro
workspaces, AutoHotkey, claude-code, Mister Horse Product Manager sign-in, and
the shell history. And it quits Google Chrome.

--dry-run is the only flag, to see the exact list before deleting.

.NOTES
Copyright (c) 2026 Luis Gomez Gutierrez

.EXAMPLE
# Stream and run in memory (avoids MOTW / blocking GPO).
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -Uri
"https://raw.githubusercontent.com/lucuma13/load/main/src/unload-win.ps1").Content))

.EXAMPLE
# Preview only - print everything that would be removed, remove nothing.
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -Uri
"https://raw.githubusercontent.com/lucuma13/load/main/src/unload-win.ps1").Content))
--dry-run

.EXAMPLE
# Alternative for Constrained Language Mode (download and run).
$f="$env:TEMP\unload-win.ps1"; Invoke-WebRequest -Uri
"https://raw.githubusercontent.com/lucuma13/load/main/src/unload-win.ps1"
-UseBasicParsing -OutFile $f -ErrorAction Stop; if(-not ((Get-Content $f
-Raw).TrimEnd().EndsWith('# === END unload-win.ps1 ==='))){throw "download
incomplete - try again"}; powershell -ExecutionPolicy Bypass -File $f;
Set-PSReadLineOption -HistorySaveStyle SaveNothing; Remove-Item
(Get-PSReadLineOption).HistorySavePath -Force -ErrorAction SilentlyContinue
#>

$ErrorActionPreference = "Continue"

Set-StrictMode -Version Latest

# -----------------------------------------------------------------------------
# Function library
#
# Everything above the LOAD_LIB guard is side-effect-free definitions, so the
# test suite can dot-source this file (with $env:LOAD_LIB set) to exercise
# individual functions without deleting anything.
# -----------------------------------------------------------------------------

# Test-KnownArgument <args> - false when any argument isn't a recognised option.
#
# The bare command removes everything this script knows about, so an
# unrecognised argument must stop the run rather than be ignored: a typo'd
# "--dryrun" would otherwise fall through and be treated as a bare command.
function Test-KnownArgument {
    param([string[]]$Arguments = @())
    foreach ($arg in $Arguments) {
        if ($arg -notin @("--dry-run", "--help", "-h")) { return $false }
    }
    return $true
}

function Show-Usage {
    Write-Host "Usage: unload-win.ps1 [--dry-run]"
    Write-Host ""
    Write-Host "  Removes, from this account only:"
    Write-Host "    - the work directory ~\Downloads\load-win (LUTs, AHK macros, downloads)"
    Write-Host "    - a leftover copy of load-win.ps1 in %TEMP%"
    Write-Host "    - the Premiere Pro workspaces load drops (other workspaces are left alone)"
    Write-Host "    - AutoHotkey: quit and uninstalled"
    Write-Host "    - Mister Horse Product Manager: signed out"
    Write-Host "    - Claude Code: signed out, uninstalled, and its local state wiped"
    Write-Host "    - the PowerShell (PSReadLine) command history"
    Write-Host ""
    Write-Host "  Quits, leaving the app and its profile in place:"
    Write-Host "    - Google Chrome"
    Write-Host ""
    Write-Host "  Other apps installed by load are left in place. There is no confirmation"
    Write-Host "  prompt, so use --dry-run to print what would be removed and remove nothing."
}

# Find-AhkExe - locate an installed AutoHotkey interpreter, or return $null.
function Find-AhkExe {
    $exe = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $exe) {
        $exe = Get-ChildItem `
            "$env:ProgramFiles\AutoHotkey", `
            "${env:ProgramFiles(x86)}\AutoHotkey" `
            -Recurse -Filter "AutoHotkey*.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    return $exe
}

# Get-RegValue <path> <name> - the value, or $null when the key or the value is
# absent.
function Get-RegValue($path, $name) {
    Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty $name -ErrorAction SilentlyContinue
}

# Get-DocumentsFolder - the real Documents folder, which is where Premiere keeps
# its profiles.
function Get-DocumentsFolder {
    param($key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
    $path = Get-RegValue $key 'Personal'
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    return "$HOME\Documents"
}

# The repo's src/data listing, where the workspaces `load-win` drops come from.
$WS_API = "https://api.github.com/repos/lucuma13/load/contents/src/data?ref=main"

# Get-WorkspaceFileName [uri] - the workspace filenames from the live listing.
# Empty when the listing can't be read, which the caller reports rather than
# treating as "nothing to remove".
#
# The whole thing is inside the try, the Where-Object included: an error response
# (rate limit, a moved repo) is valid JSON without a "name" property, and under
# Set-StrictMode -Version Latest reading that property throws.
function Get-WorkspaceFileName {
    param($uri = $WS_API)
    try {
        return @(Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = "load-setup" } |
                Where-Object { $_.name -like 'UserWorkspace_*.xml' } |
                ForEach-Object { $_.name })
    }
    catch { return @() }
}

# Get-PremiereLayoutDir - the Layouts folders of every Premiere Pro profile on
# this machine.
function Get-PremiereLayoutDir {
    param($premiereDir = (Join-Path (Get-DocumentsFolder) "Adobe\Premiere Pro"))
    $dirs = @()
    foreach ($version in Get-ChildItem -LiteralPath $premiereDir -Directory -ErrorAction SilentlyContinue) {
        foreach ($profileDir in Get-ChildItem -LiteralPath $version.FullName -Directory -Filter "Profile-*" -ErrorAction SilentlyContinue) {
            $layouts = Join-Path $profileDir.FullName "Layouts"
            if (Test-Path -LiteralPath $layouts) { $dirs += $layouts }
        }
    }
    return $dirs
}

# Get-ClaudeStatePath - every per-user path Claude Code writes.
#
# Windows has no keychain, so the OAuth token lives in .credentials.json INSIDE
# ~\.claude and goes with it.
#
# %APPDATA%\Claude is deliberately NOT here (belongs to the Claude desktop app),
# only the CLI's own state is in scope.
function Get-ClaudeStatePath {
    $paths = @(
        "$HOME\.claude"
        "$HOME\.claude.json"
        "$HOME\.claude.json.backup"
    )
    # The CLI's node cache. Confirmed as ~/Library/Caches/claude-cli-nodejs on
    # macOS; this is the LOCALAPPDATA equivalent. Guarded by Test-Path at the
    # call site like every other path here, so if the name ever differs it is a
    # silent no-op rather than an error.
    #
    # Appended only when LOCALAPPDATA is actually set: interpolating an empty
    # variable would yield the relative "\claude-cli-nodejs", which
    # Test-UnderHome then refuses with a warning - a confusing complaint about a
    # path we invented ourselves.
    if ($env:LOCALAPPDATA) { $paths += "$env:LOCALAPPDATA\claude-cli-nodejs" }
    # The native installer's own state/share dirs (XDG-style layout under
    # ~\.local), distinct from ~\.claude above, which every install method
    # writes to regardless of how the CLI itself got onto the machine.
    $paths += "$HOME\.local\share\claude"
    $paths += "$HOME\.local\state\claude"
    return $paths
}

# Get-ClaudeNativeExePath - the CLI's own binary when installed via Anthropic's
# native installer, which drops a single claude.exe into ~\.local\bin.
#
# That folder is shared with other per-user tools this machine may have (uv
# tool shims for triplecheck/mhl-suite land there too), so only this one
# filename is ever a removal target - never the folder itself.
function Get-ClaudeNativeExePath {
    return "$HOME\.local\bin\claude.exe"
}

# Get-MisterHorseStatePath - the per-user state Mister Horse keeps, which on
# Windows is also where the signed-in account lives.
#
# The session is held in the app's own encrypted .dat files under
# %LOCALAPPDATA%\MisterHorse - not in the registry and not in Credential Manager
# - so removing that tree IS the local sign-out.
#
# Guarded on LOCALAPPDATA being set: interpolating an empty variable would yield
# the relative "\MisterHorse", which Test-UnderHome then refuses with a warning
# - a confusing complaint about a path we invented ourselves.
function Get-MisterHorseStatePath {
    if (-not $env:LOCALAPPDATA) { return @() }
    return @("$env:LOCALAPPDATA\MisterHorse")
}

# Get-HistoryPath - every shell-history file to remove.
#
# PSReadLine is what actually persists command history on Windows, and its save
# path is per-host: each host writes its own "<HostName>_history.txt", and a
# profile can move the lot anywhere. So ask the live PSReadLine for its path
# first, then sweep the whole PSReadLine directory for the other hosts' files -
# a console this script was never launched from still has its history on disk.
#
# Deduped, because the live session's path is normally one of the files the
# sweep already found. A real run wouldn't care (Remove-TargetPath is silent the
# second time), but --dry-run would print the same path twice and read like a
# bug.
function Get-HistoryPath {
    $paths = @()
    # Probed with Get-Command: -ErrorAction does not suppress a CommandNotFound,
    # which is raised while the name is resolved, before a parameter is ever
    # bound. On a host without PSReadLine the bare call still leaves $opt null
    # and the sweep below still runs, so the outcome is the same - but it dumps
    # a red error into the middle of the run that reads like the cleanup failed.
    if (Get-Command Get-PSReadLineOption -ErrorAction SilentlyContinue) {
        $opt = Get-PSReadLineOption -ErrorAction SilentlyContinue
        if ($opt -and $opt.HistorySavePath) { $paths += $opt.HistorySavePath }
    }
    # Only when APPDATA is actually set: interpolating an empty variable would yield
    # a relative "\Microsoft\Windows\..." that Test-UnderHome then refuses with a
    # warning - a confusing complaint about a path we invented ourselves.
    if ($env:APPDATA) {
        $appData = $env:APPDATA.TrimEnd('\')
        $dir = "$appData\Microsoft\Windows\PowerShell\PSReadLine"
        $paths += "$dir\ConsoleHost_history.txt"
        if (Test-Path -LiteralPath $dir -ErrorAction SilentlyContinue) {
            $paths += @(Get-ChildItem -LiteralPath $dir -Filter "*_history.txt" -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName)
        }
    }
    return @($paths | Select-Object -Unique)
}

# Test-InCallerSession - true when this is running in the console the user types
# into, rather than in a child process.
#
# The streamed entrypoint shares the caller's process, so PSReadLine settings
# made here are the console's own. The Constrained Language Mode fallback
# entrypoint runs, a separate process whose settings die with it. A dynamic
# scriptblock has no file behind it, so $PSCommandPath is empty for the first
# and set for the second.
function Test-InCallerSession {
    param([string]$CommandPath = $PSCommandPath)
    return [string]::IsNullOrEmpty($CommandPath)
}

# Stop-HistorySaving - stop PSReadLine persisting this session's commands, and
# return whether that took effect.
#
# Returning $true from a child process would be a false assurance: the console
# that outlives it keeps saving. So the session check comes first, before the
# call that would otherwise succeed against a PSReadLine nobody is typing at.
function Stop-HistorySaving {
    param([bool]$InCallerSession = (Test-InCallerSession))
    if (-not $InCallerSession) { return $false }
    if (-not (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) { return $false }
    try {
        Set-PSReadLineOption -HistorySaveStyle SaveNothing -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# Clear-HistoryBuffer - drop the commands the live console can still hand back on
# arrow-up, and return whether that took effect.
function Clear-HistoryBuffer {
    param([bool]$InCallerSession = (Test-InCallerSession))
    if (-not $InCallerSession) { return $false }
    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory($null, $null)
        return $true
    }
    catch { return $false }
}

# Test-UnderHome <path> - true only for a path strictly inside $HOME (or
# LOCALAPPDATA/APPDATA, which sit outside $HOME under a redirected profile) and
# free of "..".
#
# Every removal this script makes is per-user, so this is the single guard
# between a variable that came back empty (or unexpanded, or relative) and a
# recursive delete with a catastrophic argument. Remove-TargetPath refuses
# anything that fails it rather than trusting its caller, because there is no
# undo for what follows.
function Test-UnderHome {
    param([string]$Path)
    if (-not $Path) { return $false }
    if ($Path -like "*..*") { return $false }
    foreach ($root in @($HOME, $env:LOCALAPPDATA, $env:APPDATA)) {
        if (-not $root) { continue }
        $prefix = $root.TrimEnd('\') + '\'
        if ($Path.Length -gt $prefix.Length -and $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# Remove-SelfTemp - delete our own copy when we were launched from a temp file
# (the CLM entrypoint downloads the script to %TEMP% first). PowerShell loads
# the whole script into memory before running it, so deleting the file mid-run
# is safe. Only ever removes a copy under %TEMP%; a checkout is left untouched.
function Remove-SelfTemp {
    param([string]$path = $PSCommandPath, [string]$temp = $env:TEMP)
    if ($temp -and $path -and $path.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

# Test-AppInstalled <pattern> - does any Windows uninstall entry's DisplayName
# match? Reads all three views because a 64-bit installer, a 32-bit one and a
# per-user one each register somewhere different.
function Test-AppInstalled($pattern) {
    foreach ($key in @(
            @{ Path = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; View = "64" },
            @{ Path = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; View = "32" },
            @{ Path = "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; View = "64" }
        )) {
        foreach ($line in (reg.exe query $key.Path /s /v DisplayName "/reg:$($key.View)" 2>$null)) {
            if ($line -match '\sDisplayName\s+REG_SZ\s+(.+)$') {
                if ($Matches[1].Trim() -match $pattern) { return $true }
            }
        }
    }
    return $false
}

# The two Premiere plugins load installs.
function Test-FlickerFreeInstalled { Test-AppInstalled 'Flicker Free' }
function Test-MisterHorseInstalled { Test-AppInstalled 'Mister Horse' }

# Report -Did -DoneMsg -WouldMsg -SkipMsg [-Failed -FailMsg] - the one status
# line each cleanup phase prints, chosen from whichever fits what actually
# happened: something is knowingly still there, something was removed, something
# would be removed (--dry-run), or there was nothing there to begin with.
function Report {
    param([bool]$Did, [string]$DoneMsg, [string]$WouldMsg, [string]$SkipMsg,
        [bool]$Failed, [string]$FailMsg)
    if ($Failed) { Write-Host ("  " + "[warn]".PadRight(12) + $FailMsg); return }
    if (-not $Did) { Write-Host ("  " + "[skipped]".PadRight(12) + $SkipMsg); return }
    if ($DRY_RUN) { Write-Host ("  " + "[would]".PadRight(12) + $WouldMsg) }
    else { Write-Host ("  " + "[done]".PadRight(12) + $DoneMsg) }
}

# Sourced as a library (tests set $env:LOAD_LIB): stop here, run nothing below.
if ($env:LOAD_LIB) { return }

# -----------------------------------------------------------------------------
# Flags - the only option is --dry-run.
# -----------------------------------------------------------------------------

if (-not (Test-KnownArgument -Arguments $args)) {
    Write-Host "  [warn] Unrecognised argument. Nothing was removed."
    Show-Usage
    exit 1
}

if (($args -contains "--help") -or ($args -contains "-h")) { Show-Usage; exit 0 }

$DRY_RUN = $args -contains "--dry-run"

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

# Mirrors $WorkDir in load-win.ps1.
$WorkDir = "$HOME\Downloads\load-win"

# The documented entrypoint downloads load-win.ps1 to %TEMP% and runs it from
# there; load-win deletes that copy in a finally block, but it survives if the
# run never reached it.
$LoadTempCopy = if ($env:TEMP) { Join-Path $env:TEMP "load-win.ps1" } else { "" }

$WINGET_OK = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)

# The winget package id load's Windows side would have used for the CLI.
$CLAUDE_PKG = "Anthropic.ClaudeCode"

# AutoHotkey's id in load-win.ps1's $FULL_PKGS. It is the one app load installs
# that exists purely to serve load - it runs the Mac-keyboard macros and nothing
# else - which is why unload removes it while leaving VLC, FFmpeg and the rest
# of the installed apps in place.
$AHK_PKG = "AutoHotkey.AutoHotkey"

# Whether this run left the console's history genuinely dealt with.
$script:HISTORY_STOPPED = $false

function Note { param($msg); Write-Host ("  " + "[note]".PadRight(12) + $msg) }

# Get-DisplayPath <path> - shorten a path under $HOME to ~\... for display.
# Presentation only; never feed the result back to a cmdlet.
function Get-DisplayPath {
    param([string]$Path)
    $prefix = $HOME.TrimEnd('\') + '\'
    if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "~\" + $Path.Substring($prefix.Length)
    }
    return $Path
}

# Remove-TargetPath <path> - remove a file or directory tree, honouring
# --dry-run. Silent on success or on a dry-run preview - the calling phase
# reports its own single status line (see Report) - but still prints a [warn]
# for the two cases worth interrupting that line for: a path outside the
# profile, or one Windows wouldn't let go of. Returns $false and stays silent
# when there is nothing there, so callers can distinguish "cleaned" from
# "already clean" and report an empty phase as such.
function Remove-TargetPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-UnderHome $Path)) {
        Write-Host "  [warn] Refusing to remove '$Path' - outside the user profile"
        return $false
    }
    if ($DRY_RUN) { return $true }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) {
        Write-Host "  [warn] Could not remove $(Get-DisplayPath $Path) - a program may be holding it open"
        return $false
    }
    return $true
}

# Test-WingetPackage <id> - true when winget reports the package installed.
function Test-WingetPackage($id) {
    if (-not $WINGET_OK) { return $false }
    $listed = winget list --id $id --exact --accept-source-agreements 2>$null
    return ($LASTEXITCODE -eq 0) -and ($listed -match [regex]::Escape($id))
}

# Uninstall-WingetPackage <id> <label> - uninstall a winget package, elevating
# only if it turns out to be necessary. Returns one of three outcomes, which the
# caller feeds to Report.
# The result is re-checked against winget because the elevated console swallows
# its own exit code.
function Uninstall-WingetPackage($id, $label) {
    if (-not (Test-WingetPackage $id)) { return 'absent' }
    if ($DRY_RUN) { return 'removed' }

    winget uninstall --id $id --exact --silent --accept-source-agreements 2>&1 | Out-Null
    if (-not (Test-WingetPackage $id)) { return 'removed' }

    try {
        Start-Process cmd.exe -Verb RunAs -Wait -ArgumentList (
            "/s /c `"winget uninstall --id $id --exact --silent --accept-source-agreements`"")
    }
    catch {
        Write-Host "  [warn] Elevated uninstall did not run (admin prompt cancelled?): $_"
    }
    if (-not (Test-WingetPackage $id)) { return 'removed' }
    return 'failed'
}

# -----------------------------------------------------------------------------
# Cleanup phases
# -----------------------------------------------------------------------------

# Stop-AhkProcess - quit every running AutoHotkey interpreter.
#
# No attempt to single out load's own macro by command line. The macro is only a
# file in the work directory, so it goes when that directory does, and
# AutoHotkey itself is uninstalled moments later.
#
# This whole phase runs before the work directory is removed, so nothing is
# executing out of it by the time it goes.
function Stop-AhkProcess {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $false }
    if ($DRY_RUN) { return $true }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    return $true
}

# Clear-WorkDir - remove the scratch load leaves on disk: the work directory,
# and a copy of load-win.ps1 stranded in %TEMP% (see $LoadTempCopy). Both are
# load's own leavings, so they go together.
function Clear-WorkDir {
    $cleared = Remove-TargetPath $WorkDir
    if ($LoadTempCopy) { $cleared = (Remove-TargetPath $LoadTempCopy) -or $cleared }
    Report -Did $cleared -DoneMsg "Removed work files/directory" -WouldMsg "Would remove work files/directory" -SkipMsg "Work files - Nothing to remove"
}

# Clear-PremiereWorkspace - remove our workspace files into Premiere profile's
# Layouts folders.
function Clear-PremiereWorkspace {
    $dirs = @(Get-PremiereLayoutDir)
    # No Premiere profile means nothing to remove - and no reason to go to the
    # network for the list.
    if ($dirs.Count -eq 0) {
        Report -Did $false -SkipMsg "Premiere Pro workspaces - Nothing to remove"
        return
    }

    $names = @(Get-WorkspaceFileName)
    if ($names.Count -eq 0) {
        Write-Host "  [warn] Could not read the workspace list from GitHub - Premiere workspaces left in place"
        return
    }

    $did = $false
    foreach ($dir in $dirs) {
        foreach ($name in $names) {
            if (Remove-TargetPath (Join-Path $dir $name)) { $did = $true }
        }
    }
    Report -Did $did -DoneMsg "Removed Premiere Pro workspaces" -WouldMsg "Would remove Premiere Pro workspaces" -SkipMsg "Premiere Pro workspaces - Nothing to remove"
}

# Clear-Ahk - quit AutoHotkey and uninstall it.
function Clear-Ahk {
    $did = $false
    if (Stop-AhkProcess) { $did = $true }
    $uninstall = Uninstall-WingetPackage $AHK_PKG "AutoHotkey"
    if ($uninstall -eq 'removed') { $did = $true }

    # Two ways AutoHotkey outlives this phase, and one line for both. A 'failed'
    # uninstall is the winget package still there, which Settings can remove.
    # Still on disk after an uninstall that did not fail is the .exe/.zip build
    # from autohotkey.com, which this script doesn't touch and Settings won't
    # list - so that one carries the path.
    $exe = if ($DRY_RUN -or $uninstall -eq 'failed') { $null } else { Find-AhkExe }

    $failMsg = if ($uninstall -eq 'failed') {
        "AutoHotkey is still installed - remove it from Settings > Apps by hand"
    }
    else { "AutoHotkey is still installed at $exe - not a winget install; remove it by hand" }

    Report -Did $did -Failed:(($uninstall -eq 'failed') -or [bool]$exe) `
        -DoneMsg "Uninstalled AutoHotkey" `
        -WouldMsg "Would uninstall AutoHotkey" `
        -SkipMsg "AutoHotkey - Nothing to remove" `
        -FailMsg $failMsg
}

# Get-ChromeProcess - every running Google Chrome process (the browser and the
# renderer/GPU children beside it).
#
# Matched on the image PATH as well as the name: "chrome.exe" is also the
# executable of every other Chromium build on the machine. The CIM lookup
# is what supplies that path - Get-Process alone would throw reading .Path on a
# process this account can't open - and the ids are then resolved back to
# process objects, which is what Stop-ChromeProcess needs to close a window
# politely.
function Get-ChromeProcess {
    $ids = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath -match '(?i)\\Google\\Chrome' } |
            ForEach-Object { $_.ProcessId })
    if ($ids.Count -eq 0) { return @() }
    return @(Get-Process -Id $ids -ErrorAction SilentlyContinue)
}

# Stop-ChromeProcess - ask Google Chrome to close, and force only what is left.
#
# Asked, not killed: a straight Stop-Process costs the session - Chrome comes
# back with the "didn't shut down correctly" restore bar and a half-written
# profile - whereas CloseMainWindow closes the profile cleanly and saves the
# open tabs for next launch.
function Stop-ChromeProcess {
    $procs = @(Get-ChromeProcess)
    if ($procs.Count -eq 0) { return $false }
    if ($DRY_RUN) { return $true }
    foreach ($p in $procs) {
        if ($p.MainWindowHandle -ne [System.IntPtr]::Zero) { $p.CloseMainWindow() | Out-Null }
    }
    $left = @(Get-ChromeProcess)
    $waited = 0
    while ($left.Count -gt 0 -and $waited -lt 10) {
        Start-Sleep -Seconds 1
        $waited++
        $left = @(Get-ChromeProcess)
    }
    if ($left.Count -gt 0) {
        foreach ($p in $left) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    return $true
}

# Clear-Chrome - quit Google Chrome. Never uninstalled - the app and its
# profile (bookmarks, history, whoever is signed in) are left exactly as they
# are, unlike every other phase here.
function Clear-Chrome {
    $did = Stop-ChromeProcess
    Report -Did $did -DoneMsg "Quit Google Chrome" -WouldMsg "Would quit Google Chrome" -SkipMsg "Google Chrome - Not running"
}

# Get-MisterHorseProcess - every running Mister Horse process (the Product
# Manager and the crash handler that sits beside it).
#
# Matched on the image PATH, not the process name: "ProductManager.exe" is a
# generic enough name to belong to some other vendor's app. A regex rather than
# a WQL filter so both spellings of the vendor's own folder are covered -
# "Mister Horse Product Manager" under Program Files, "MisterHorse" for anything
# installed beside its state dir.
function Get-MisterHorseProcess {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath -match '(?i)mister ?horse' })
}

# Stop-MisterHorseProcess - quit the Product Manager so the sign-out below
# sticks.
#
# It holds the session in memory and writes its state back as it closes, so
# files deleted underneath a running Product Manager come straight back.
function Stop-MisterHorseProcess {
    # Re-wrapped in @() at the call site, exactly as Stop-AhkProcess wraps its
    # own Get-CimInstance: PowerShell unrolls a returned array, so with nothing
    # running $procs is $null - and under Set-StrictMode -Version Latest,
    # reading .Count off $null is an error rather than a zero.
    $procs = @(Get-MisterHorseProcess)
    if ($procs.Count -eq 0) { return $false }
    if ($DRY_RUN) { return $true }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    return $true
}

# Clear-MisterHorse - sign this account out of Mister Horse, leaving the plugins
# installed. See Get-MisterHorseStatePath for why removing that state is the
# sign-out.
function Clear-MisterHorse {
    $did = $false
    if (Stop-MisterHorseProcess) { $did = $true }
    foreach ($path in Get-MisterHorseStatePath) {
        if (Remove-TargetPath $path) { $did = $true }
    }
    $skipMsg = if (Test-MisterHorseInstalled) {
        "Mister Horse Product Manager - already signed out (the app stays installed)"
    }
    else { "Mister Horse Product Manager - Nothing to remove" }

    Report -Did $did -DoneMsg "Signed out of Mister Horse Product Manager" -WouldMsg "Would sign out of Mister Horse Product Manager" -SkipMsg $skipMsg

    # A panel open inside a running Premiere or After Effects has the same
    # session in memory and writes its own copy back when the host quits, so a
    # sign-out performed underneath it does not stick. Killing the host would
    # cost the user unsaved work, so say so instead. Skipped on a dry run, where
    # nothing has been removed for a panel to undo.
    if (-not $DRY_RUN) {
        $hostApps = @(Get-Process -Name "Adobe Premiere Pro*", "AfterFX*" -ErrorAction SilentlyContinue)
        if ($hostApps.Count -gt 0) {
            Note "Premiere Pro / After Effects is open - close it and re-run, or its Mister Horse panel will write the session back."
        }
    }
}

function Clear-Claude {
    $did = $false

    # Uninstall before wiping state, so a half-removed install can't confuse
    # winget's own uninstall.
    $uninstall = Uninstall-WingetPackage $CLAUDE_PKG "Claude Code"
    if ($uninstall -eq 'removed') { $did = $true }

    # The native installer's binary, removed by exact filename only - see
    # Get-ClaudeNativeExePath for why the containing folder is never touched.
    if (Remove-TargetPath (Get-ClaudeNativeExePath)) { $did = $true }

    foreach ($path in Get-ClaudeStatePath) {
        if (Remove-TargetPath $path) { $did = $true }
    }

    Report -Did $did -Failed:($uninstall -eq 'failed') `
        -DoneMsg "Uninstalled Claude" `
        -WouldMsg "Would uninstall Claude" `
        -SkipMsg "Claude Code - Nothing to remove" `
        -FailMsg "Claude Code is still installed - remove it from Settings > Apps by hand"

    # A `claude` still on PATH after all that was installed some other way - a
    # global npm package, most likely - which this script deliberately doesn't
    # touch. Say so rather than let a "cleaned" summary imply the machine is
    # clear. Skipped on a dry run, where nothing has been removed yet and the
    # binary is still there by definition.
    if (-not $DRY_RUN) {
        $claude = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
        if ($claude) { Note "'claude' is still on PATH at $claude - not a winget or native install; remove it by hand" }
    }
}

function Clear-ShellHistory {
    # The console you launched this from holds its own commands in memory -
    # including the command that ran this script - in two separate places: the
    # engine's Get-History table, which Clear-History empties, and PSReadLine's own
    # list behind arrow-up, which only Clear-HistoryBuffer reaches.
    #
    # All of it before the files rather than after. PSReadLine appends to a fresh
    # history file as you keep typing, so switching saving off first leaves no
    # order in which a flush can land after the delete. Nothing can be typed into
    # this console while the script is running, so that window was never really
    # open - but this is also the order of the one-liner the summary hands the user
    # to run by hand, and the two should not disagree.
    if (-not $DRY_RUN) {
        # Both evaluated before the -and, deliberately: it short-circuits, and the
        # buffer still wants clearing even when saving could not be switched off.
        $stopped = Stop-HistorySaving
        Clear-History -ErrorAction SilentlyContinue
        $cleared = Clear-HistoryBuffer
        # Only "clean" when both took. Saving switched off while arrow-up still
        # hands back the entrypoint is not what that sign-off promises.
        $script:HISTORY_STOPPED = $stopped -and $cleared
    }

    $did = $false
    foreach ($path in Get-HistoryPath) {
        if (Remove-TargetPath $path) { $did = $true }
    }

    Report -Did $did -DoneMsg "Cleared shell history" -WouldMsg "Would clear shell history" -SkipMsg "Shell history - Nothing to remove"
}

# Show-FlickerFree - report the plugin, remove nothing.
function Show-FlickerFree {
    $skipMsg = if (Test-FlickerFreeInstalled) {
        "Flicker Free - still installed (plugins are left in place)"
    }
    else { "Flicker Free - Nothing to remove" }

    Report -Did $false -DoneMsg "" -WouldMsg "" -SkipMsg $skipMsg
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------

try {
    Write-Host ""
    if ($DRY_RUN) {
        Write-Host "  Dry run - nothing will be removed."
        Write-Host ""
    }

    # AutoHotkey first, and deliberately: it quits every interpreter, so by the time
    # the work directory goes nothing is running out of it.
    Clear-Ahk
    # Chrome next: quitting it is the one step that interrupts what the user is
    # looking at, so it happens up front rather than partway through the run.
    Clear-Chrome
    Clear-WorkDir
    Clear-PremiereWorkspace
    Clear-MisterHorse
    Show-FlickerFree
    Clear-Claude
    Clear-ShellHistory

    Write-Host ""
    if ($DRY_RUN) { Write-Host "  Dry run complete - re-run without --dry-run to remove the above." }
    elseif ($script:HISTORY_STOPPED) { Write-Host "  You're clean now!" }
    else {
        # Reached when this run cannot switch saving off.
        Write-Host "  Almost clean now!"
        Write-Host "  Run this here if it doesn't run automatically:"
        Write-Host '      Set-PSReadLineOption -HistorySaveStyle SaveNothing; Remove-Item (Get-PSReadLineOption).HistorySavePath -Force -ErrorAction SilentlyContinue'
    }
    Write-Host ""
}
finally {
    Remove-SelfTemp
}

# Completeness sentinel - MUST be the last line. The download entrypoint
# verifies the file ends with this before executing, so a truncated download is
# rejected.
# === END unload-win.ps1 ===
