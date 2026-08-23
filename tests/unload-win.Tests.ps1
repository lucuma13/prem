# Tests for src/unload-win.ps1
#
# The script is sourced with $env:LOAD_LIB so only its functions load (nothing runs,
# nothing is deleted).
#
# Run:  Invoke-Pester tests\unload-win.Tests.ps1

BeforeAll {
    $env:LOAD_LIB = "1"
    . "$PSScriptRoot\..\src\unload-win.ps1"
    $env:LOAD_LIB = $null
}

# PSScriptAnalyzer's PSUseCompatibleSyntax rule flags any 7+-only syntax (??
# null-coalescing, ternaries, ?. etc.) for the target version, so this fails the
# build before such syntax can ship to the 5.1 default shell on Windows.
Describe "unload-win.ps1 PowerShell 5.1 compatibility" {
    BeforeAll {
        if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
            Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck
        }
        Import-Module PSScriptAnalyzer

        $settings = @{
            Rules = @{
                PSUseCompatibleSyntax = @{
                    Enable         = $true
                    TargetVersions = @('5.1')
                }
            }
        }
        $script:violations = Invoke-ScriptAnalyzer -Path "$PSScriptRoot/../src/unload-win.ps1" -Settings $settings -IncludeRule PSUseCompatibleSyntax
    }

    It "uses no syntax unavailable in Windows PowerShell 5.1" {
        $violations | Should -BeNullOrEmpty -Because (
            ($violations | ForEach-Object { "line $($_.Line): $($_.Message)" }) -join "`n")
    }
}

# The script is downloaded and run by pre-installed Windows PowerShell 5.1 on a fresh
# Windows machine, which garbles a UTF-8 BOM and non-ASCII bytes into '?'. Keep the
# distributed script pure ASCII.
Describe "unload-win.ps1 encoding (Windows PowerShell 5.1 safe)" {
    BeforeAll {
        $script:scriptBytes = [System.IO.File]::ReadAllBytes("$PSScriptRoot/../src/unload-win.ps1")
    }

    It "has no byte-order mark" {
        $hasBom = $scriptBytes.Length -ge 3 -and
        $scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF
        $hasBom | Should -BeFalse
    }

    It "is pure ASCII (no bytes that garble in legacy PowerShell)" {
        $offenders = for ($i = 0; $i -lt $scriptBytes.Length; $i++) {
            if ($scriptBytes[$i] -gt 0x7F) { $i }
        }
        @($offenders).Count | Should -Be 0 -Because "non-ASCII byte(s) at offset(s): $($offenders -join ', ')"
    }
}

# The script ends with a sentinel line so the launch command can confirm the download
# arrived whole - a truncated copy (dropped connection) loses the tail and is rejected
# before it runs. That matters more here than in the installer: half of a delete script
# is worse than none of it.
Describe "unload-win.ps1 completeness sentinel" {
    BeforeAll {
        $script:sentinel = '# === END unload-win.ps1 ==='
        $script:scriptText = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
    }

    It "is the last line of the distributed script" {
        $scriptText.TrimEnd() | Should -BeLike "*$sentinel"
    }

    It "a truncated copy fails the sentinel check" {
        $truncated = $scriptText.Substring(0, [int]($scriptText.Length / 2))
        # The sentinel string also appears in the .EXAMPLE header near the top, so a
        # truncated copy still *contains* it - which is exactly why the launch check must
        # test ends-with (the tail arrived), not merely presence.
        $truncated | Should -BeLike "*$sentinel*" -Because "the header copy is within the first half"
        $truncated.TrimEnd() | Should -Not -BeLike "*$sentinel"
    }
}

# There are no target flags: the bare command is the whole interface. That makes
# argument validation the safety property worth testing - a typo'd "--dryrun" that
# fell through to "no options given" would delete for real at exactly the moment the
# caller was asking for a preview.
Describe "Test-KnownArgument" {
    It "accepts <Name>" -ForEach @(
        @{ Name = 'the bare command'; Arguments = @() }
        @{ Name = '--dry-run'; Arguments = @('--dry-run') }
        @{ Name = '--help'; Arguments = @('--help') }
        @{ Name = '-h'; Arguments = @('-h') }
    ) {
        Test-KnownArgument -Arguments $Arguments | Should -BeTrue
    }

    It "rejects <Name>" -ForEach @(
        @{ Name = 'a misspelt --dry-run'; Arguments = @('--dryrun') }
        @{ Name = 'an underscored --dry_run'; Arguments = @('--dry_run') }
        @{ Name = 'a target flag that no longer exists'; Arguments = @('--workdir') }
        @{ Name = '--all'; Arguments = @('--all') }
        @{ Name = 'an unknown flag beside a valid one'; Arguments = @('--dry-run', '--nope') }
        @{ Name = 'a bare word'; Arguments = @('workdir') }
    ) {
        Test-KnownArgument -Arguments $Arguments | Should -BeFalse
    }
}

# AutoHotkey is the one app load installs that unload also removes: it exists purely
# to run load's Mac-keyboard macros, unlike VLC/FFmpeg, which are the machine's now.
Describe "AutoHotkey target" {
    It "uninstalls the same winget id load installs" {
        $loadWin = Get-Content "$PSScriptRoot/../src/load-win.ps1" -Raw
        $unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
        $id = 'AutoHotkey.AutoHotkey'
        $loadWin | Should -BeLike "*$id*" -Because "load-win.ps1 should still install it"
        $unloadWin | Should -BeLike "*`$AHK_PKG = `"$id`"*" -Because "a rename in load must be mirrored here"
    }

    # Stopping the interpreters is what lets the uninstall replace files - a live
    # AutoHotkey process would otherwise defer it to a reboot, which on a machine
    # being handed back is the same as not running at all.
    It "quits AutoHotkey before uninstalling it" {
        $unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
        $body = [regex]::Match($unloadWin, '(?s)function Clear-Ahk \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty -Because "Clear-Ahk should be findable"
        $body | Should -BeLike "*Stop-AhkProcess*"
        $body.IndexOf('Stop-AhkProcess') | Should -BeLessThan $body.IndexOf('Uninstall-WingetPackage')
    }

    # No command-line matching: load's macro is just a file in the work directory, so
    # it goes when that directory does, and uninstalling AutoHotkey stops every macro
    # on the machine anyway. Singling one process out would protect nothing.
    It "stops every interpreter rather than matching load's macro by name" {
        $unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
        $body = [regex]::Match($unloadWin, '(?s)function Stop-AhkProcess \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Not -BeLike "*MacKeyboard_LGG*"
        $body | Should -Not -BeLike "*CommandLine*"
    }

    # The work-directory phase does no AutoHotkey handling of its own, and doesn't need
    # to - the AutoHotkey phase runs first and has already quit everything.
    It "clears the work directory without any AutoHotkey handling of its own" {
        $unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
        $body = [regex]::Match($unloadWin, '(?s)function Clear-WorkDir \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Not -BeLike "*Ahk*"
    }

    # The ordering is the whole mechanism: quit the interpreters, then delete the
    # directory they were running out of. Reversed, the macro script would be pulled
    # out from under a live process and the uninstall would meet open file handles.
    It "runs the AutoHotkey phase before the work-directory phase" {
        $unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
        $dispatch = [regex]::Match($unloadWin, '(?s)^try \{.*?\n\}', 'Multiline').Value
        $dispatch | Should -Not -BeNullOrEmpty -Because "the dispatch block should be findable"
        $dispatch.IndexOf('Clear-Ahk') | Should -BeLessThan $dispatch.IndexOf('Clear-WorkDir')
    }
}

# load-win runs from a %TEMP% copy and deletes it in a finally block, but a copy
# survives if the run never got there. Cleaning it is unload's job, and these
# pin the two ways that goes wrong: targeting the wrong file, and letting a
# stranded copy report "nothing to do". $LoadTempCopy is defined below the
# library guard, so assert against the source text.
Describe "Leftover load-win.ps1 in TEMP" {
    BeforeAll {
        $script:unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
        $script:workDirBody = [regex]::Match($script:unloadWin, '(?s)function Clear-WorkDir \{.*?\n\}').Value
    }

    # The name matters: unload-win.ps1 may itself be running from a %TEMP% copy,
    # and that one belongs to Remove-SelfTemp in the finally block, not to this
    # phase.
    It "targets load-win.ps1, not the running script's own temp copy" {
        $script:unloadWin | Should -Match '\$LoadTempCopy\s*=.*Join-Path \$env:TEMP "load-win\.ps1"'
        $script:workDirBody | Should -BeLike '*$LoadTempCopy*'
        $script:workDirBody | Should -Not -BeLike '*unload-win.ps1*'
    }

    # A blank TEMP would make Join-Path produce a bare "load-win.ps1" - a
    # relative path that Test-UnderHome rejects, but the phase should not go
    # near it in the first place.
    It "skips the temp copy when TEMP is unset" {
        $script:unloadWin | Should -Match '\$LoadTempCopy = if \(\$env:TEMP\)'
        $script:workDirBody | Should -Match 'if \(\$LoadTempCopy\)'
    }

    # Removing only the stranded temp copy is still work done: the section has
    # to say so rather than printing "Nothing to remove" over a delete that just
    # happened.
    It "reports work done when only one of the two was there" {
        $script:workDirBody | Should -Match '-or \$cleared'
        # An early return after the work directory would strand the temp copy.
        $script:workDirBody | Should -Not -Match '(?m)^\s*(return|exit)\b'
    }
}

# Test-UnderHome is the single guard between a variable that came back empty (or
# unexpanded, or relative) and a recursive delete with a catastrophic argument.
Describe "Test-UnderHome" {
    It "accepts a path strictly inside the profile" {
        Test-UnderHome "$HOME\Downloads\load-win" | Should -BeTrue
        Test-UnderHome "$HOME\.claude" | Should -BeTrue
    }

    # An empty or unexpanded value is the failure mode that matters most: a blank
    # path must never satisfy the guard.
    It "rejects <Name>" -ForEach @(
        @{ Name = 'an empty path'; Path = '' }
        @{ Name = 'a null path'; Path = $null }
        @{ Name = 'the profile root itself'; Path = $HOME }
        @{ Name = 'the profile root with a trailing separator'; Path = "$HOME\" }
        @{ Name = 'a relative path'; Path = 'relative\path' }
        @{ Name = 'parent-directory traversal'; Path = "$HOME\..\..\Windows" }
    ) {
        Test-UnderHome $Path | Should -BeFalse
    }

    It "rejects a path outside the profile" {
        Test-UnderHome "C:\Windows\System32" | Should -BeFalse
        Test-UnderHome "/etc/passwd" | Should -BeFalse
    }
}

# Mister Horse is a sign-out, not an uninstall: the plugins are the machine's now, the
# way VLC and FFmpeg are, but the account signed into them is the departing user's. On
# Windows that session lives in the app's own encrypted files rather than in a keychain,
# so removing them IS the sign-out - which makes the contents of that path list, and the
# order the phase does things in, the properties worth pinning.
Describe "Mister Horse sign-out" {
    BeforeAll {
        $script:unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
    }

    # %LOCALAPPDATA%\MisterHorse holds the Product Manager's session alongside the
    # panel's cached copy of it, so one removal signs out both.
    It "covers the per-user state dir" {
        if (-not $env:LOCALAPPDATA) {
            Set-ItResult -Skipped -Because "LOCALAPPDATA is not set on this host"
            return
        }
        Get-MisterHorseStatePath | Should -Contain "$env:LOCALAPPDATA\MisterHorse"
    }

    # An unset LOCALAPPDATA must yield nothing at all. Interpolating it blindly would
    # produce the relative "\MisterHorse", which Remove-TargetPath then refuses with a
    # warning about a path the script invented itself.
    It "yields nothing when LOCALAPPDATA is unset" {
        $saved = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = ""
            @(Get-MisterHorseStatePath).Count | Should -Be 0
        }
        finally { $env:LOCALAPPDATA = $saved }
    }

    It "yields only paths the delete guard will accept" {
        foreach ($path in Get-MisterHorseStatePath) {
            Test-UnderHome $path | Should -BeTrue -Because "'$path' would be refused by Remove-TargetPath"
        }
    }

    # The sign-out must not turn into an uninstall: the plugins live in Program Files
    # and the shared Adobe plug-in folders, and both are out of scope here (they are
    # also machine-wide, so the per-user guard would refuse them anyway).
    It "removes no installed plugin" {
        foreach ($path in Get-MisterHorseStatePath) {
            $path | Should -Not -BeLike "*Program Files*"
            $path | Should -Not -BeLike "*\Adobe\*"
        }
        $body = [regex]::Match($unloadWin, '(?s)function Clear-MisterHorse \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty -Because "Clear-MisterHorse should be findable"
        $body | Should -Not -BeLike "*Uninstall-WingetPackage*"
    }

    # The ordering is the mechanism, as with AutoHotkey: a running Product Manager holds
    # the session in memory and writes its state back as it closes, so files deleted
    # underneath it come straight back and the account is still signed in.
    It "quits the Product Manager before removing its state" {
        $body = [regex]::Match($unloadWin, '(?s)function Clear-MisterHorse \{.*?\n\}').Value
        $body | Should -BeLike "*Stop-MisterHorseProcess*"
        $body.IndexOf('Stop-MisterHorseProcess') | Should -BeLessThan $body.IndexOf('Remove-TargetPath')
    }

    # "ProductManager.exe" is a generic enough name to belong to another vendor
    # entirely, so the process match is on the image path.
    It "matches the app by image path, not by process name" {
        $body = [regex]::Match($unloadWin, '(?s)function Get-MisterHorseProcess \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -BeLike "*ExecutablePath*"
    }

    It "runs as its own phase in the dispatch block" {
        $dispatch = [regex]::Match($unloadWin, '(?s)^try \{.*?\n\}', 'Multiline').Value
        $dispatch | Should -Not -BeNullOrEmpty -Because "the dispatch block should be findable"
        $dispatch | Should -BeLike "*Clear-MisterHorse*"
    }
}

# Quit Google Chrome the polite way, since a forced Chrome reopens with the
# "didn't shut down correctly" bar and a half-written profile.
Describe "Google Chrome" {
    BeforeAll {
        $script:unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
        $script:stopBody = [regex]::Match($script:unloadWin, '(?s)function Stop-ChromeProcess \{.*?\n\}').Value
        $script:clearBody = [regex]::Match($script:unloadWin, '(?s)function Clear-Chrome \{.*?\n\}').Value
    }

    # "chrome.exe" is the executable of every other Chromium build on the
    # machine too, and quitting someone's Brave is not this script's business.
    It "matches the browser by image path, not by process name alone" {
        $body = [regex]::Match($script:unloadWin, '(?s)function Get-ChromeProcess \{.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty -Because "Get-ChromeProcess should be findable"
        $body | Should -BeLike "*ExecutablePath*"
        $body | Should -BeLike "*Google*"
    }

    # CloseMainWindow is the same as clicking the X - the profile closes cleanly
    # and the open tabs are saved - so it has to come first, with Stop-Process
    # only as the timeout.
    It "asks Chrome to close before it forces anything" {
        $script:stopBody | Should -Not -BeNullOrEmpty -Because "Stop-ChromeProcess should be findable"
        $script:stopBody | Should -BeLike "*CloseMainWindow*"
        $script:stopBody.IndexOf('CloseMainWindow') | Should -BeLessThan $script:stopBody.IndexOf('Stop-Process')
    }

    # The wait has to be bounded. A "Leave site?" dialog can hold a close up for
    # as long as nobody clicks it, and an unload that hangs behind it is worse
    # than a lost tab.
    It "does not wait forever for Chrome to close" {
        $script:stopBody | Should -BeLike "*`$waited -lt 10*"
        $script:stopBody | Should -Not -BeLike "*while (`$true)*"
    }

    # A dry run must not close the browser any more than it deletes a file.
    # Stop-ChromeProcess itself stays silent (Clear-Chrome reports the single
    # phase-level line via Report), so what's pinned here is that the
    # $DRY_RUN early-return comes before CloseMainWindow is ever reached, and
    # that Clear-Chrome's own report line names the dry-run wording.
    It "reports and returns under --dry-run without touching Chrome" {
        $script:stopBody.IndexOf('$DRY_RUN') | Should -BeLessThan $script:stopBody.IndexOf('CloseMainWindow')
        $script:clearBody | Should -BeLike "*Would quit Google Chrome*"
    }

    # A quit and nothing more: Chrome stays installed and the profile - bookmarks,
    # history, whoever is signed into it - is left exactly as it is.
    It "removes nothing and uninstalls nothing" {
        $script:clearBody | Should -Not -BeNullOrEmpty -Because "Clear-Chrome should be findable"
        $script:clearBody | Should -Not -BeLike "*Remove-TargetPath*"
        $script:clearBody | Should -Not -BeLike "*Uninstall-WingetPackage*"
        $script:unloadWin | Should -Not -BeLike "*User Data*" -Because "the Chrome profile is not unload's to touch"
    }

    It "runs as its own phase in the dispatch block" {
        $dispatch = [regex]::Match($script:unloadWin, '(?s)^try \{.*?\n\}', 'Multiline').Value
        $dispatch | Should -Not -BeNullOrEmpty -Because "the dispatch block should be findable"
        $dispatch | Should -BeLike "*Clear-Chrome*"
    }
}

Describe "Claude Code target paths" {
    # ~\.claude is the whole point of the Claude target on a machine you're leaving:
    # it holds transcripts, per-project history, memory and the credentials file.
    It "covers the CLI's state" {
        $paths = Get-ClaudeStatePath
        $paths | Should -Contain "$HOME\.claude"
        $paths | Should -Contain "$HOME\.claude.json"
        $paths | Should -Contain "$HOME\.claude.json.backup"
    }

    # The native installer keeps its own state/share dirs under ~\.local,
    # separate from ~\.claude - both must go or a reinstall on the same
    # machine would inherit stale state.
    It "covers the native installer's state/share dirs" {
        $paths = Get-ClaudeStatePath
        $paths | Should -Contain "$HOME\.local\share\claude"
        $paths | Should -Contain "$HOME\.local\state\claude"
    }

    # The Claude desktop app is a separate product that may well belong to someone
    # else on a shared machine. Only the CLI's own state is in scope, so %APPDATA%\Claude
    # must never creep into the list.
    It "leaves the Claude desktop app alone" {
        Get-ClaudeStatePath | Where-Object { $_ -eq "$env:APPDATA\Claude" } | Should -BeNullOrEmpty
    }

    It "yields only paths the delete guard will accept" {
        foreach ($path in Get-ClaudeStatePath) {
            Test-UnderHome $path | Should -BeTrue -Because "'$path' would be refused by Remove-TargetPath"
        }
    }
}

# The native installer's binary sits inside ~\.local\bin, a folder this
# machine can share with unrelated per-user tools (uv shims for
# triplecheck/mhl-suite land there too) - so the removal target has to be the
# exact filename, never the folder.
Describe "Claude Code native installer binary" {
    BeforeAll {
        $script:unloadWin = Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw
        $script:clearBody = [regex]::Match($script:unloadWin, '(?s)function Clear-Claude \{.*?\n\}').Value
    }

    It "targets the exact filename under ~\.local\bin" {
        Get-ClaudeNativeExePath | Should -Be "$HOME\.local\bin\claude.exe"
    }

    It "yields a path the delete guard will accept" {
        Test-UnderHome (Get-ClaudeNativeExePath) | Should -BeTrue
    }

    It "removes only that file, never the whole ~\.local\bin folder" {
        $clearBody | Should -Not -BeNullOrEmpty -Because "Clear-Claude should be findable"
        $clearBody | Should -BeLike "*Get-ClaudeNativeExePath*"
        $clearBody | Should -Not -BeLike '*Remove-TargetPath "$HOME\.local\bin"*'
        $clearBody | Should -Not -BeLike '*.local\bin*claude*.exe*wildcard*'
    }
}

Describe "Shell history target paths" {
    # PSReadLine is what actually persists command history on Windows. The path is
    # built from %APPDATA%, which only exists on the target platform - on a macOS/Linux
    # host running this suite the entry is correctly omitted, so there is nothing to
    # assert there.
    It "covers the PSReadLine history file" {
        if (-not $env:APPDATA) {
            Set-ItResult -Skipped -Because "APPDATA is not set on this host"
            return
        }
        Get-HistoryPath | Should -Contain "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
    }

    # The live session's save path is normally one of the files the directory sweep
    # already finds. A real run wouldn't care - Remove-TargetPath is silent the second
    # time - but --dry-run would print the same path twice and read like a bug.
    It "contains no duplicates" {
        $paths = @(Get-HistoryPath)
        @($paths | Select-Object -Unique).Count | Should -Be $paths.Count
    }

    # A trailing backslash on APPDATA would build "...Roaming\\Microsoft\...".
    # Windows resolves that, so the file is still removed - but it is no longer
    # string-equal to the same file's FullName from the directory sweep, so
    # Select-Object -Unique stops collapsing the two and --dry-run lists it twice.
    It "normalises a trailing backslash on APPDATA" {
        $original = $env:APPDATA
        try {
            $env:APPDATA = "C:\Users\test\AppData\Roaming\"
            Get-HistoryPath |
                Should -Contain "C:\Users\test\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
        }
        finally { $env:APPDATA = $original }
    }
}

# Deleting the history file is only half the job: PSReadLine's default save
# style is SaveIncrementally, so it writes the file straight back as the user
# keeps typing.
Describe "Stopping history saving" {
    BeforeAll {
        $script:originalStyle = (Get-PSReadLineOption -ErrorAction SilentlyContinue).HistorySaveStyle
    }

    AfterAll {
        # Never leave the suite's own session with saving switched off.
        if ($script:originalStyle) { Set-PSReadLineOption -HistorySaveStyle $script:originalStyle }
    }

    It "switches PSReadLine to SaveNothing" {
        if (-not (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "PSReadLine is not available on this host"
            return
        }
        Stop-HistorySaving -InCallerSession $true | Should -BeTrue
        (Get-PSReadLineOption).HistorySaveStyle | Should -Be "SaveNothing"
    }

    # The Constrained Language Mode entrypoint runs `powershell -File`, so the
    # console the user types at is a different process that carries on saving.
    # Succeeding there would print "You're clean now!" over a console still
    # writing history, so the child case has to report failure and let the
    # summary hand the user the line instead.
    It "reports failure from a child process rather than a false assurance" {
        Stop-HistorySaving -InCallerSession $false | Should -BeFalse
    }

    It "leaves the save style alone when it cannot reach the caller's session" {
        if (-not (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "PSReadLine is not available on this host"
            return
        }
        Set-PSReadLineOption -HistorySaveStyle SaveIncrementally
        Stop-HistorySaving -InCallerSession $false | Out-Null
        (Get-PSReadLineOption).HistorySaveStyle | Should -Be "SaveIncrementally"
    }

    # The entrypoint is `& ([scriptblock]::Create(...))`, which runs in a child
    # scope of the caller's session. PSReadLine's options are process-wide rather
    # than scoped, which is the whole reason this works - assert it, because a
    # scoped setting would leave the console still writing history.
    It "takes effect on the caller's session, not just the scriptblock's scope" {
        if (-not (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "PSReadLine is not available on this host"
            return
        }
        Set-PSReadLineOption -HistorySaveStyle SaveIncrementally
        & ([scriptblock]::Create("Stop-HistorySaving -InCallerSession `$true")) | Out-Null
        (Get-PSReadLineOption).HistorySaveStyle | Should -Be "SaveNothing"
    }
}

# Removing the file leaves the console's own copy behind: PSReadLine read the
# history into memory when the session started and serves arrow-up from that list,
# which Clear-History never touches - it empties the engine's Get-History table, a
# different store.
Describe "Clearing the in-memory history buffer" {
    It "reports failure from a child process rather than a false assurance" {
        Clear-HistoryBuffer -InCallerSession $false | Should -BeFalse
    }

    It "wraps the PSReadLine call so an absent type cannot abort the run" {
        $body = [regex]::Match(
            (Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw),
            '(?s)function Clear-HistoryBuffer \{.*?\n\}').Value
        $body | Should -BeLike "*PSConsoleReadLine*ClearHistory*"
        $body | Should -BeLike "*try*catch*"
    }
}

# Saving has to go off before the files go, not after: PSReadLine appends to a
# fresh history file as the user keeps typing.
Describe "Shell history cleanup order" {
    BeforeAll {
        $script:historyBody = [regex]::Match(
            (Get-Content "$PSScriptRoot/../src/unload-win.ps1" -Raw),
            '(?s)function Clear-ShellHistory \{.*?\n\}').Value
    }

    It "clears both of the console's own buffers, not just the files" {
        $historyBody | Should -Not -BeNullOrEmpty -Because "Clear-ShellHistory should be findable"
        $historyBody | Should -BeLike "*Clear-History *"
        $historyBody | Should -BeLike "*Clear-HistoryBuffer*"
    }

    It "switches saving off before removing the files" {
        $historyBody.IndexOf("Stop-HistorySaving") | Should -BeGreaterOrEqual 0
        $historyBody.IndexOf("Stop-HistorySaving") |
            Should -BeLessThan $historyBody.IndexOf("Remove-TargetPath")
    }

    It "claims a clean console only when both buffers were dealt with" {
        $historyBody | Should -BeLike '*$stopped -and $cleared*'
    }
}

# Which entrypoint was used decides whether this process is the console at all.
# A dynamic scriptblock has no file behind it; anything run from a file - the
# --File fallback included - does.
Describe "Detecting the caller's session" {
    It "treats a streamed scriptblock as the caller's own session" {
        Test-InCallerSession -CommandPath "" | Should -BeTrue
    }

    It "treats a run from a file as a child process" {
        Test-InCallerSession -CommandPath "C:\Users\me\AppData\Local\Temp\unload-win.ps1" | Should -BeFalse
    }

    # The discriminator the default argument relies on: $PSCommandPath is empty
    # inside a scriptblock built at runtime, which is the streamed entrypoint.
    It "reads an empty PSCommandPath inside a dynamic scriptblock" {
        & ([scriptblock]::Create('$PSCommandPath')) | Should -BeNullOrEmpty
    }
}

# The workspaces filenames are read from the repo's src/data listing, so what is
# testable offline is the parts either side of the fetch - where the files are
# looked for, and what happens when the listing can't be read.
Describe "Premiere workspace targets" {
    BeforeAll {
        # A Premiere profile tree as the machine has it: one profile per
        # version, each with its own Layouts folder, plus a version folder
        # Premiere never finished writing (no Layouts) to prove it contributes
        # nothing.
        $script:premiereDir = Join-Path $TestDrive "Adobe/Premiere Pro"
        $script:layouts251 = Join-Path $premiereDir "25.1/Profile-lgg/Layouts"
        $script:layouts240 = Join-Path $premiereDir "24.0/Profile-lgg/Layouts"
        New-Item -ItemType Directory -Force -Path $layouts251, $layouts240 | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $premiereDir "26.0/Profile-lgg") | Out-Null
    }

    It "finds the Layouts folder of every profile" {
        $dirs = @(Get-PremiereLayoutDir -premiereDir $premiereDir)
        $dirs | Should -Contain $layouts251
        $dirs | Should -Contain $layouts240
        $dirs.Count | Should -Be 2 -Because "the 26.0 profile has no Layouts folder yet"
    }

    # No profile means no removal AND no fetch - the caller returns before it
    # goes to the network.
    It "yields nothing when Premiere was never installed" {
        @(Get-PremiereLayoutDir -premiereDir (Join-Path $TestDrive "no-such-dir")).Count | Should -Be 0
    }

    # An unreadable listing (offline, rate-limited, moved repo) must come back
    # empty so the caller can say so, rather than throw or read as "nothing to
    # remove".
    It "returns no filenames when the listing can't be read" {
        @(Get-WorkspaceFileName -uri "https://127.0.0.1:9/no-such-listing").Count | Should -Be 0
    }
}

# Premiere writes its profiles into the REAL Documents folder, which OneDrive's
# "Back up this PC's folders" relocates without changing $HOME - the same
# resolution load-win.ps1 does before it writes there. Guessing wrong would
# leave the workspaces in place while reporting a clean run.
Describe "Get-DocumentsFolder" {
    It "falls back to the profile-relative guess when the key is absent" {
        Get-DocumentsFolder -key 'HKCU:\Software\ZZNoSuchUnloadProbeKey' | Should -Be "$HOME\Documents"
    }

    It "resolves the real Documents folder on this machine" -Skip:(-not ((-not (Test-Path Variable:IsWindows)) -or $IsWindows)) {
        $real = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' `
                -Name Personal -ErrorAction SilentlyContinue).Personal
        $real | Should -Not -BeNullOrEmpty -Because 'User Shell Folders\Personal is the authority for Documents'
        Get-DocumentsFolder | Should -Be $real
    }
}

# Remove-SelfTemp only ever deletes a copy of the script under $env:TEMP. The blank-TEMP
# guard matters because StartsWith("") is true for every path - a blank TEMP must NOT be
# allowed to match and delete an arbitrary script location.
Describe "Remove-SelfTemp temp-dir guard" {
    It "<Name>" -ForEach @(
        @{ Name = 'deletes a copy under TEMP'; UnderTemp = $true; BlankTemp = $false; ShouldDelete = $true }
        @{ Name = 'leaves a copy outside TEMP untouched'; UnderTemp = $false; BlankTemp = $false; ShouldDelete = $false }
        @{ Name = 'deletes nothing when TEMP is blank'; UnderTemp = $false; BlankTemp = $true; ShouldDelete = $false }
    ) {
        $temp = Join-Path $TestDrive "temp"
        New-Item -ItemType Directory -Force -Path $temp | Out-Null
        $self = if ($UnderTemp) { Join-Path $temp "unload-win.ps1" } else { Join-Path $TestDrive "elsewhere.ps1" }
        Set-Content $self "x"

        Remove-SelfTemp -path $self -temp $(if ($BlankTemp) { "" } else { $temp })

        Test-Path $self | Should -Be (-not $ShouldDelete)
    }
}

# The contract that matters: unload must remove exactly the workspaces load
# drops. Both sides read the same src/data listing, so this confirms the listing
# still carries the filenames load-win.ps1 delivers - a rename in the repo that
# reached only one of the two scripts shows up here.
Describe "Premiere workspace listing" {
    BeforeAll {
        # The same UserWorkspace_*.xml match, applied to the checkout's own
        # src/data.
        function Get-LocalWorkspaceFileName {
            return @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "../src/data") `
                    -Filter "UserWorkspace_*.xml" -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Name })
        }

        # The filenames unload would act on: the published listing, falling back
        # to the checkout when the fetch comes back empty (no network, or GitHub
        # rate-limiting the unauthenticated request).
        function Get-ResolvedWorkspaceFileName {
            param($uri = $WS_API)
            $listed = @(Get-WorkspaceFileName -uri $uri)
            if ($listed.Count -eq 0) { $listed = @(Get-LocalWorkspaceFileName) }
            return $listed
        }

        # Read from the source text rather than by sourcing it: load-win.ps1
        # sets $LAYOUT_FILE_* below its own library guard, so $env:LOAD_LIB
        # never reaches them.
        $loadWin = Get-Content "$PSScriptRoot/../src/load-win.ps1" -Raw
        $script:dropped = @([regex]::Matches($loadWin, '(?m)^\$LAYOUT_FILE_\d+\s*=\s*"([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value })
    }

    It "carries the workspaces load-win drops" {
        $dropped.Count | Should -BeGreaterThan 0 -Because "load-win.ps1 should still name the workspaces it drops"
        $listed = @(Get-ResolvedWorkspaceFileName)
        $listed.Count | Should -BeGreaterThan 0 -Because "no listing from GitHub and no UserWorkspace_*.xml in src/data"
        foreach ($name in $dropped) {
            $listed | Should -Contain $name -Because "load-win drops '$name', so unload must find it in src/data"
        }
    }

    # The fallback is only worth having if it holds the same filenames the
    # published listing does, so point the fetch at a dead URL and confirm the
    # checkout answers with the workspaces load-win drops.
    It "falls back to the checkout when the fetch fails" {
        $listed = @(Get-ResolvedWorkspaceFileName -uri "https://127.0.0.1:9/no-such-listing")
        foreach ($name in $dropped) {
            $listed | Should -Contain $name -Because "the offline fallback should still yield '$name'"
        }
    }
}

# Hits the network to confirm the pinned winget id is still the one that ships Claude
# Code. Exclude on an offline run with:  Invoke-Pester -ExcludeTag Live
Describe "Claude Code winget id resolves" -Tag 'Live' {
    It "Anthropic.ClaudeCode is found on winget" {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "winget is not installed"
            return
        }
        winget show --id "Anthropic.ClaudeCode" --exact --source winget --accept-source-agreements --disable-interactivity *> $null
        $LASTEXITCODE | Should -Be 0 -Because "'Anthropic.ClaudeCode' did not resolve (renamed, delisted, or mistyped?)"
    }
}
