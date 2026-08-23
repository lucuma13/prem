# Tests for src/load-win.ps1, both whole-script and Premiere-prefs:
#   - PowerShell 5.1 syntax compatibility (no 7+-only syntax ships)
#   - file encoding (pure ASCII, no BOM) so legacy PowerShell doesn't garble it
#   - liveness of the external resources the installer pulls (plugins, winget,
#     PyPI)
#   - Set-PremierePro / Get-WorkspaceName / Set-PrefNode / Set-ForcedPrefNode
#     prefs handling
#   - Test-AppInstalled across both registry views (a false negative reinstalls)
#   - Find-UvExe returning a single path from the right candidate
#   - Constrained Language Mode survival, statically (no blocked .NET is
#     reachable while $CLM is true) and at runtime (a real CLM child shell loads
#     and dry-runs it)
#
# The script is sourced with $env:LOAD_LIB so only its functions load (no
# installer).
#
# Run:  Invoke-Pester tests\load-win.Tests.ps1

BeforeAll {
    $env:LOAD_LIB = "1"
    . "$PSScriptRoot\..\src\load-win.ps1"
    $env:LOAD_LIB = $null
}

# Discover every captured version; adding a premiere_pro_* fixture dir is
# enough.
$PremiereVersions = Get-ChildItem "$PSScriptRoot/fixtures" -Directory -Filter 'premiere_pro_*' |
    Sort-Object Name | ForEach-Object {
        @{ Version = ($_.Name -replace '^premiere_pro_v?', ''); Dir = $_.Name }
    }

# Read a force-written pref table straight from the script. Adding a row to one
# automatically adds its checks below - no test edit needed.
function Get-ForcedTable($name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot/../src/load-win.ps1", [ref]$null, [ref]$null)
    $assign = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.UserPath -eq $name }, $true) | Select-Object -First 1
    $assign.Right.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
        ForEach-Object {
            $node, $value, $minMajor = $_.Value -split '\|'
            @{ Node = $node; Value = $value; MinMajor = $minMajor }
        }
}
# $forced is written on every run; $mseForced only under --mse.
$ForcedPrefs = Get-ForcedTable 'forced'
$MseForcedPrefs = Get-ForcedTable 'mseForced'

# Resolved at discovery time so -Skip can see them. The WOW64 registry test
# needs a 32-bit host to read from and elevation to plant a 64-bit-only entry to
# read.
#
# WindowsIdentity::GetCurrent() THROWS on non-Windows, and at discovery scope
# that aborts the whole file (0 tests collected) - so it must stay behind the
# host check for the platform-agnostic tests here to run on macOS/Linux.
# $IsWindows only exists on PowerShell 6+; on 5.1 it is undefined, hence the
# Test-Path rather than a bare truthiness check, which would otherwise read as
# "not Windows" on the 5.1 target.
$IsWindowsHost = (-not (Test-Path Variable:IsWindows)) -or $IsWindows
$Ps32Available = Test-Path "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
$IsElevatedHost = $IsWindowsHost -and ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# PSScriptAnalyzer's PSUseCompatibleSyntax rule flags any 7+-only syntax (??
# null-coalescing, ternaries, ?. etc.) for the target version, so this fails the
# build before such syntax can ship to the 5.1 default shell on Windows.
Describe "load-win.ps1 PowerShell 5.1 compatibility" {
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
        $script:violations = Invoke-ScriptAnalyzer -Path "$PSScriptRoot/../src/load-win.ps1" -Settings $settings -IncludeRule PSUseCompatibleSyntax
    }

    It "uses no syntax unavailable in Windows PowerShell 5.1" {
        $violations | Should -BeNullOrEmpty -Because (
            ($violations | ForEach-Object { "line $($_.Line): $($_.Message)" }) -join "`n")
    }
}

# The script is downloaded and run by pre-installed Windows PowerShell 5.1 on a
# fresh Windows Machine, which garbles a UTF-8 BOM and non-ASCII bytes into '?'.
# Keep the distributed script pure ASCII.
Describe "load-win.ps1 encoding (Windows PowerShell 5.1 safe)" {
    BeforeAll {
        $script:scriptBytes = [System.IO.File]::ReadAllBytes("$PSScriptRoot/../src/load-win.ps1")
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

# The script ends with a sentinel line so the launch command can confirm the
# download arrived whole - a truncated copy (dropped connection) loses the tail
# and is rejected before it runs. This guards the sentinel's presence so the
# check can't silently rot.
Describe "load-win.ps1 completeness sentinel" {
    BeforeAll {
        $script:sentinel = '# === END load-win.ps1 ==='
        $script:scriptText = Get-Content "$PSScriptRoot/../src/load-win.ps1" -Raw
    }

    It "is the last line of the distributed script" {
        $scriptText.TrimEnd() | Should -BeLike "*$sentinel"
    }

    It "a truncated copy fails the sentinel check" {
        $truncated = $scriptText.Substring(0, [int]($scriptText.Length / 2))
        # The sentinel string also appears in the .EXAMPLE header near the top,
        # so a truncated copy still *contains* it - which is exactly why the
        # launch check must test ends-with (the tail arrived), not merely
        # presence.
        $truncated | Should -BeLike "*$sentinel*" -Because "the header copy is within the first half"
        $truncated.TrimEnd() | Should -Not -BeLike "*$sentinel"
    }
}

# These hit the network to confirm the hard-coded plugin installer URLs are
# still live. Exclude them on an offline run with:  Invoke-Pester -ExcludeTag
# Live

# Confirms every pinned winget id still resolves on the winget source
Describe "winget package ids resolve" -Tag 'Live' {
    BeforeDiscovery {
        $env:LOAD_LIB = "1"
        . "$PSScriptRoot\..\src\load-win.ps1"
        $env:LOAD_LIB = $null
        $script:wingetIds = @($CORE_PKGS + $FULL_PKGS + $PREMIERE_PKGS)
    }

    It "<_> is found on winget" -ForEach $wingetIds {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because "winget is not installed"
            return
        }
        winget show --id $_ --exact --source winget --accept-source-agreements --disable-interactivity *> $null
        $LASTEXITCODE | Should -Be 0 -Because "'$_' did not resolve (renamed, delisted, or mistyped?)"
    }
}

# Confirms links to apps not available on winget are live
Describe "Plugin download links" -Tag 'Live' {
    $links = @(
        @{ Name = 'Mister Horse Product Manager'; Url = 'https://misterhorse.com/downloads/product-manager/win' }
        @{ Name = 'Flicker Free'; Url = 'https://www.digitalanarchy.com/downloads/flickerfree_229_AE.zip' }
    )

    It "<Name> link is live" -ForEach $links {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 30
        }
        catch {
            # Some servers reject HEAD - fall back to a 1-byte ranged GET.
            $resp = Invoke-WebRequest -Uri $Url -Headers @{ Range = 'bytes=0-0' } -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 30
        }
        [int]$resp.StatusCode | Should -BeIn @(200, 206)
    }
}

# Every installer in the elevated batch has to run unattended. They are launched
# inside one elevated cmd.exe the user never opened, from a script that goes on
# to apply the rest of the setup and wait on that process, so an installer that
# stops on a licence page or a "Next" button hangs the whole run behind a window
# the user has to find. The non-winget plugins are the ones that need saying
# explicitly: msiexec takes /qn, Flicker Free's NSIS installer takes /S
# (case-sensitive - a lowercase /s reaches the script as an unknown argument and
# the wizard opens anyway). Text-based, because Invoke-ElevatedInstall lives
# below the $env:LOAD_LIB boundary and builds these as command-line strings for
# cmd rather than invoking them.
Describe "elevated installers run unattended" {
    BeforeAll {
        $loadWin = Get-Content "$PSScriptRoot/../src/load-win.ps1" -Raw
        $script:body = [regex]::Match($loadWin, '(?s)function Invoke-ElevatedInstall \{.*?\n\}').Value
        $script:queued = @($body -split "`r?`n" | Where-Object { $_ -match '\$cmds \+=' })
    }

    It "finds the queued install commands" {
        $body | Should -Not -BeNullOrEmpty -Because "Invoke-ElevatedInstall should be findable"
        $queued.Count | Should -BeGreaterThan 2 -Because "the batch queues the two plugins and the winget packages"
    }

    It "runs the Flicker Free installer silently" {
        $ff = @($queued | Where-Object { $_ -match 'ffExe' })
        $ff.Count | Should -Be 1 -Because "Flicker Free is queued once"
        $ff[0] | Should -CMatch '\s/S\b' -Because "without NSIS's /S the user has to click Accept through the wizard"
    }

    It "runs the Mister Horse MSI silently" {
        $mh = @($queued | Where-Object { $_ -match 'msiexec' })
        $mh.Count | Should -Be 1
        $mh[0] | Should -CMatch '\s/qn\b'
    }

    It "sets the long path registry value unattended" {
        $lp = @($queued | Where-Object { $_ -match 'LongPathsEnabled' })
        $lp.Count | Should -Be 1 -Because "long path support is queued once"
        $lp[0] | Should -CMatch '\s/f\b' -Because "without /f reg.exe prompts to overwrite an existing value"
        $lp[0] | Should -Match 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem' -Because "LongPathsEnabled must be written to its documented key"
    }

    # `winget source` installs nothing, so it carries no silent switch and is
    # held to the prompt it can raise instead:.
    It "refreshes the package source without prompting" {
        $src = @($queued | Where-Object { $_ -match '"winget source\b' })
        $src.Count | Should -Be 1 -Because "the source is warmed once, ahead of the package commands"
        $src[0] | Should -CMatch '\s--accept-source-agreements\b' -Because "a first-time account is otherwise asked to accept them"
        $src[0] | Should -CMatch '\s--disable-interactivity\b' -Because "nothing in an unattended batch may raise a prompt"
    }

    It "warms the package source before any package command" {
        $wingetCmds = @($queued | Where-Object { $_ -match '"winget\b' })
        $wingetCmds.Count | Should -BeGreaterThan 1
        $wingetCmds[0] | Should -CMatch '"winget source\b' -Because (
            "the source has to be registered before a package can resolve against it - " +
            "letting the package commands race to register it is what left every one of them failing 8A15000F")
    }

    # The catch-all: anything added to the batch later must carry a silent switch too.
    It "queues no installer that can stop for input" {
        $installers = @($queued | Where-Object { $_ -notmatch '"winget source\b' })
        $loud = @($installers | Where-Object { $_ -notmatch '(?-i)\s(/S|/qn|/f|--silent)\b' })
        $loud | Should -BeNullOrEmpty -Because (
            "each of these can open a window an unattended run then waits on:`n$($loud -join "`n")")
    }
}

# The batch discards every exit code ("&" between commands) and its output can't
# be captured (Start-Process -Verb RunAs uses ShellExecute, which forbids
# redirection), so the only thing standing between a batch that did nothing and
# a checklist that says [done] is the re-check afterwards. Text-based for the
# same reason as the suite above: Invoke-ElevatedInstall sits below the
# $env:LOAD_LIB boundary and can't be called.
#
Describe "the elevated batch verifies what it queued" {
    BeforeAll {
        $loadWin = Get-Content "$PSScriptRoot/../src/load-win.ps1" -Raw
        $script:body = [regex]::Match($loadWin, '(?s)function Invoke-ElevatedInstall \{.*?\n\}').Value
        $script:full = $loadWin
    }

    It "tracks every queued package, upgrades included" {
        $queuedIds = @($body -split "`r?`n" | Where-Object { $_ -match '\$wantApply \+= \$id' })
        $queuedIds.Count | Should -Be 1 -Because "one collection point covers both arms of the install/upgrade branch"
        $body | Should -Not -Match '\$wantInstall' -Because "the fresh-installs-only list is what let a failed upgrade through"
    }

    It "re-checks upgrades and not just presence" {
        $body | Should -Match 'Test-WingetUpgradePending' -Because (
            "Test-PkgReallyInstalled alone passes a failed upgrade - the old version is still there")
        $body | Should -Match 'Test-PkgReallyInstalled' -Because "a failed fresh install leaves nothing behind to find"
    }

    It "asks winget the question that survives an unreadable version" {
        $fn = [regex]::Match($full, '(?s)function Test-WingetUpgradePending\(\$id\) \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Match '--upgrade-available' -Because "that is what narrows the listing to packages that are behind"
        $fn | Should -Match '--include-unknown' -Because (
            "a package whose installed version winget can't read is otherwise dropped and reads as current")
        $fn | Should -Match '--exact' -Because (
            "without it --id filters on a substring and MediaArea.MediaInfo matches MediaArea.MediaInfo.GUI")
    }

    It "feeds the result to the checklist" {
        $body | Should -Match '\$script:PKG_NOT_APPLIED' -Because "the summary must not print [done] over the warning it just printed"
        $full | Should -Match 'function Test-PkgApplied' -Because "the checklist reads the measurement through this"
        $listed = @($full -split "`r?`n" | Where-Object { $_ -match 'ok\s*=\s*\(Test-PkgReallyInstalled' })
        $listed | Should -BeNullOrEmpty -Because (
            "the checklist's package lines go through Test-PkgApplied, which also excludes what the batch failed to update")
    }
}

# The uv tools install from PyPI, so existence is a PyPI lookup (200 = project
# exists, 404 = renamed/delisted/mistyped).
Describe "uv tool ids resolve on PyPI" -Tag 'Live' {
    BeforeDiscovery {
        $env:LOAD_LIB = "1"
        . "$PSScriptRoot\..\src\load-win.ps1"
        $env:LOAD_LIB = $null
        $script:uvTools = @($CORE_UV)
    }

    It "<_> exists on PyPI" -ForEach $uvTools {
        try {
            $resp = Invoke-WebRequest -Uri "https://pypi.org/pypi/$_/json" -Method Head -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 30
        }
        catch {
            $resp = Invoke-WebRequest -Uri "https://pypi.org/pypi/$_/json" -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 30
        }
        [int]$resp.StatusCode | Should -Be 200 -Because "'$_' did not resolve on PyPI (renamed, delisted, or mistyped?)"
    }
}

# Remove-SelfTemp only ever deletes a copy of the script under $env:TEMP. The blank-TEMP
# guard matters because StartsWith("") is true for every path - a blank TEMP must NOT be
# allowed to match and delete an arbitrary script location.
Describe "Remove-SelfTemp temp-dir guard" {
    BeforeAll {
        $env:LOAD_LIB = "1"
        . "$PSScriptRoot\..\src\load-win.ps1"
        $env:LOAD_LIB = $null
    }

    # The script is deleted only when it sits under a non-empty TEMP. The blank-TEMP row
    # guards the StartsWith("") footgun (every path "starts with" the empty string).
    It "<Name>" -ForEach @(
        @{ Name = 'deletes a copy under TEMP'; UnderTemp = $true; BlankTemp = $false; ShouldDelete = $true }
        @{ Name = 'leaves a copy outside TEMP untouched'; UnderTemp = $false; BlankTemp = $false; ShouldDelete = $false }
        @{ Name = 'deletes nothing when TEMP is blank'; UnderTemp = $false; BlankTemp = $true; ShouldDelete = $false }
    ) {
        $temp = Join-Path $TestDrive "temp"
        New-Item -ItemType Directory -Force -Path $temp | Out-Null
        $self = if ($UnderTemp) { Join-Path $temp "load-win.ps1" } else { Join-Path $TestDrive "elsewhere.ps1" }
        Set-Content $self "x"

        Remove-SelfTemp -path $self -temp $(if ($BlankTemp) { "" } else { $temp })

        Test-Path $self | Should -Be (-not $ShouldDelete)
    }
}

# Windows lets Documents and Downloads live anywhere, and OneDrive's folder backup
# moves them under %USERPROFILE%\OneDrive without touching $HOME - so "$HOME\Documents"
# finds nothing and the whole Premiere step silently no-ops. Registry-backed, so
# Windows-only.
# Get-RegValue is the only registry reader in the script, and every caller depends on
# a missing value coming back as $null rather than erroring. Under
# Set-StrictMode -Version Latest the obvious `(Get-ItemProperty -EA SilentlyContinue).X`
# still throws on a missing property, AND leaves the assignment target undefined, so
# the next read throws again - two errors per lookup on precisely the fresh profile
# this script targets (no Keyboard Layout\Toggle, no shellbag for an unopened folder).
# These run the reads in a child shell so the strict-mode error surfaces as it would
# in production rather than being absorbed by the test host.
Describe "Get-RegValue" -Skip:(-not $IsWindowsHost) {
    BeforeAll {
        $script:key = 'HKCU:\Software\ZZLoadWinRegProbe'
        New-Item -Path $script:key -Force | Out-Null
        New-ItemProperty -Path $script:key -Name 'Present' -Value 'yes' -PropertyType String -Force | Out-Null
        $script:srcPath = (Resolve-Path "$PSScriptRoot/../src/load-win.ps1").Path
    }

    AfterAll { Remove-Item -LiteralPath $script:key -Recurse -Force -ErrorAction SilentlyContinue }

    It "returns the value when present" {
        Get-RegValue $key 'Present' | Should -Be 'yes'
    }

    It "returns null for <Name>" -ForEach @(
        @{ Name = 'a missing value on an existing key'; Path = 'HKCU:\Software\ZZLoadWinRegProbe'; Value = 'Absent' }
        @{ Name = 'a key that does not exist'; Path = 'HKCU:\Software\ZZLoadWinNoSuchKey'; Value = 'Absent' }
    ) {
        Get-RegValue $Path $Value | Should -BeNullOrEmpty
    }

    # The regression itself: silence. A lookup that errors still "works" (the caller
    # sees a falsy value) but prints a stack trace mid-checklist on a clean machine.
    It "writes nothing to the error stream for <Name>" -ForEach @(
        @{ Name = 'a missing value on an existing key'; Path = 'HKCU:\Software\ZZLoadWinRegProbe'; Value = 'Absent' }
        @{ Name = 'a key that does not exist'; Path = 'HKCU:\Software\ZZLoadWinNoSuchKey'; Value = 'Absent' }
    ) {
        $errFile = Join-Path $TestDrive "regvalue-$([guid]::NewGuid().ToString('N')).err"
        $cmd = "`$env:LOAD_LIB='1'; . '$srcPath'; `$env:LOAD_LIB=`$null; " +
        "`$v = Get-RegValue '$Path' '$Value'; if (`$null -eq `$v) { 'NULL' } else { `$v }"
        $out = & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command $cmd 2> $errFile

        $stderr = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) + ''
        $stderr | Should -BeNullOrEmpty -Because "a clean lookup must not print:`n$stderr"
        $out | Should -Be 'NULL' -Because 'a missing value reads as $null, and the assignment must still happen'
    }
}

Describe "Get-UserFolder (known-folder redirection)" -Skip:(-not $IsWindowsHost) {
    BeforeAll {
        $script:probeKey = 'HKCU:\Software\ZZLoadWinFolderProbe'
        New-Item -Path $script:probeKey -Force | Out-Null
        # A redirected folder that exists, mimicking OneDrive's Documents move.
        $script:redirected = Join-Path $env:TEMP 'ZZLoadWinRedirected'
        New-Item -ItemType Directory -Force -Path $script:redirected | Out-Null
        New-ItemProperty -Path $script:probeKey -Name 'Personal' -Value $script:redirected `
            -PropertyType ExpandString -Force | Out-Null
        # A folder recorded in the registry but no longer on disk (detached OneDrive).
        New-ItemProperty -Path $script:probeKey -Name 'Stale' -Value 'Z:\gone\Documents' `
            -PropertyType ExpandString -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $script:probeKey -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:redirected -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "prefers the redirected path over the profile-relative guess" {
        Get-UserFolder 'Personal' 'C:\zz-fallback-must-not-win' $probeKey | Should -Be $redirected
    }

    It "falls back when the value name is absent" {
        Get-UserFolder 'ZZNoSuchValue' 'C:\Windows' $probeKey | Should -Be 'C:\Windows'
    }

    # A stale entry is worse than the guess - following it would write into
    # nowhere.
    It "falls back when the recorded folder no longer exists" {
        Get-UserFolder 'Stale' 'C:\Windows' $probeKey | Should -Be 'C:\Windows'
    }

    # The live read must actually resolve, or every caller silently runs on the
    # fallback.
    It "resolves the real Documents folder on this machine" {
        $real = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' `
                -Name Personal -ErrorAction SilentlyContinue).Personal
        $real | Should -Not -BeNullOrEmpty -Because 'User Shell Folders\Personal is the authority for Documents'
        Get-UserFolder 'Personal' 'C:\zz-fallback-must-not-win' | Should -Be $real
    }
}

# The default folder view is a set of registry facts that have to agree, none of
# which is readable as a plain "sort by" setting: an opaque Sort blob and a
# GroupView/GroupByKey pair per folder type, plus the ABSENCE of FolderType in
# a second Bags tree, PLUS - separately - whatever GroupView an actual
# per-folder bag currently holds, since Downloads does not reliably take that
# value from the template. Each Sort blob is decoded field by field so
# a typo in 44 hand-written bytes fails as "sorts by the wrong column" rather
# than as a folder view nobody notices is wrong.
Describe "Explorer default folder view" -Skip:(-not $IsWindowsHost) {
    BeforeAll {
        $script:baseKey = 'HKCU:\Software\ZZLoadWinViewProbe\Base'
        $script:typeKey = 'HKCU:\Software\ZZLoadWinViewProbe\Type'
        # A probe root for Test-NoFolderGrouping/Repair-FolderGrouping,
        # standing in for this machine's real Bags trees - without it, these
        # would also be reading (or patching!) this machine's actual, live
        # shellbags, and a test could fail on an otherwise clean probe state,
        # or pass by accident on a machine whose real Downloads folder happens
        # to be ungrouped.
        $script:bagRoots = @('HKCU:\Software\ZZLoadWinViewProbe\Bags')
        New-Item -Path $script:baseKey -Force | Out-Null
        New-Item -Path $script:typeKey -Force | Out-Null
        New-Item -Path $script:bagRoots[0] -Force | Out-Null

        # Put the probe keys in the state Set-ExplorerDefaultView would leave
        # them in: every template written, and no FolderType override.
        function Set-ProbeApplied {
            foreach ($t in $ExplorerViewTemplates.Keys) {
                $k = Join-Path $script:baseKey $t
                New-Item -Path $k -Force | Out-Null
                Set-ItemProperty -LiteralPath $k -Name 'Sort' -Value $ExplorerViewTemplates[$t] -Type Binary
                Set-ItemProperty -LiteralPath $k -Name 'GroupView' -Value 0 -Type DWord
            }
            Remove-ItemProperty -LiteralPath $script:typeKey -Name 'FolderType' -Force -ErrorAction SilentlyContinue
        }

        $script:srcPath = (Resolve-Path "$PSScriptRoot/../src/load-win.ps1").Path
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$null, [ref]$null)
    }

    AfterAll {
        Remove-Item -LiteralPath 'HKCU:\Software\ZZLoadWinViewProbe' -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Recreated rather than cleared value-by-value: Remove-ItemProperty -Name
    # '*' does not wildcard, so with -ErrorAction SilentlyContinue it left the
    # previous test's values in place and the "never been set up" case read as
    # already applied.
    BeforeEach {
        Remove-Item -LiteralPath 'HKCU:\Software\ZZLoadWinViewProbe' -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $script:baseKey -Force | Out-Null
        New-Item -Path $script:typeKey -Force | Out-Null
        New-Item -Path $script:bagRoots[0] -Force | Out-Null
    }

    Context "the Sort blobs" {
        # Offsets from the SORTCOLUMN layout documented on $SORT_BY_NAME_ASC.
        It "<Name> is one column on the shell property set" -ForEach @(
            @{ Name = 'SORT_BY_NAME_ASC'; Blob = { $SORT_BY_NAME_ASC } }
            @{ Name = 'SORT_BY_DATE_MODIFIED_DESC'; Blob = { $SORT_BY_DATE_MODIFIED_DESC } }
        ) {
            $b = & $Blob
            $b.Count | Should -Be 44 -Because '16-byte reserved header + count + one 24-byte SORTCOLUMN'
            # Reserved header.
            @($b[0..15] | Where-Object { $_ -ne 0 }) | Should -BeNullOrEmpty
            [System.BitConverter]::ToUInt32($b, 0x10) | Should -Be 1 -Because 'one sort column'
            # The shell's own property set, stored little-endian.
            (New-Object System.Guid (, [byte[]]$b[0x14..0x23])).ToString() |
                Should -Be 'b725f130-47ef-101a-a5f1-02608c9eebac'
        }

        It "sorts by Name, ascending" {
            [System.BitConverter]::ToUInt32($SORT_BY_NAME_ASC, 0x24) | Should -Be 10 -Because 'PID 10 is System.ItemNameDisplay ("Name")'
            [System.BitConverter]::ToInt32($SORT_BY_NAME_ASC, 0x28) | Should -Be 1 -Because '1 is ascending, -1 descending'
        }

        # The whole point of the Downloads template: newest file at the top.
        It "sorts by Date modified, descending" {
            [System.BitConverter]::ToUInt32($SORT_BY_DATE_MODIFIED_DESC, 0x24) | Should -Be 14 -Because 'PID 14 is System.DateModified'
            [System.BitConverter]::ToInt32($SORT_BY_DATE_MODIFIED_DESC, 0x28) | Should -Be -1 -Because 'descending is most recent first'
        }
    }

    Context "the folder-type templates" {
        # Downloads getting a different sort from everything else is the entire
        # reason this is keyed by folder type rather than written once, so
        # assert the split.
        It "give Downloads Date modified and every other type Name" {
            $ExplorerViewTemplates.Keys | Should -Contain $FOLDERTYPE_DOWNLOADS
            ($ExplorerViewTemplates[$FOLDERTYPE_DOWNLOADS] -join ',') |
                Should -Be ($SORT_BY_DATE_MODIFIED_DESC -join ',')
            foreach ($t in $ExplorerViewTemplates.Keys) {
                if ($t -eq $FOLDERTYPE_DOWNLOADS) { continue }
                ($ExplorerViewTemplates[$t] -join ',') |
                    Should -Be ($SORT_BY_NAME_ASC -join ',') -Because "$t should keep Name/ascending"
            }
        }

        # Every type Explorer can guess a plain filesystem folder into needs a template,
        # or that folder falls back to a built-in one and the sort changes under you as
        # its contents change type.
        It "cover every guessable folder type" {
            $ExplorerViewTemplates.Keys | Should -Contain $FOLDERTYPE_GENERIC
            $ExplorerViewTemplates.Keys | Should -Contain $FOLDERTYPE_DOCUMENTS
            $ExplorerViewTemplates.Keys | Should -Contain $FOLDERTYPE_PICTURES
            $ExplorerViewTemplates.Keys | Should -Contain $FOLDERTYPE_MUSIC
            $ExplorerViewTemplates.Keys | Should -Contain $FOLDERTYPE_VIDEOS
        }

        # The GUIDs are not guessable and a wrong one fails silently - the
        # template is simply never read. HKLM is the authority Explorer itself
        # uses.
        It "name the folder type <Canonical> correctly" -ForEach @(
            @{ Canonical = 'Generic'; Guid = { $FOLDERTYPE_GENERIC } }
            @{ Canonical = 'Documents'; Guid = { $FOLDERTYPE_DOCUMENTS } }
            @{ Canonical = 'Pictures'; Guid = { $FOLDERTYPE_PICTURES } }
            @{ Canonical = 'Music'; Guid = { $FOLDERTYPE_MUSIC } }
            @{ Canonical = 'Videos'; Guid = { $FOLDERTYPE_VIDEOS } }
            @{ Canonical = 'Downloads'; Guid = { $FOLDERTYPE_DOWNLOADS } }
        ) {
            $g = & $Guid
            $p = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes\$g"
            (Get-ItemProperty -LiteralPath $p -Name CanonicalName -ErrorAction SilentlyContinue).CanonicalName |
                Should -Be $Canonical
        }
    }

    Context "Test-NoFolderGrouping" {
        It "is true when no per-folder bag exists yet" {
            Test-NoFolderGrouping $bagRoots | Should -BeTrue
        }

        It "is true when an existing bag is already ungrouped" {
            $k = Join-Path $bagRoots[0] "2\Shell\$FOLDERTYPE_DOWNLOADS"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty -LiteralPath $k -Name 'GroupView' -Value 0 -Type DWord
            Test-NoFolderGrouping $bagRoots | Should -BeTrue
        }

        # The exact scenario this exists to catch: Windows recreates a
        # per-folder bag for the Downloads type grouped by Date modified,
        # independent of what the AllFolders template's GroupView says - see
        # the section header comment. A real machine's own bags reproduced
        # this byte-for-byte (GroupView 0xffffffff, GroupByKey:PID 14).
        It "is false when an existing Downloads-type bag is grouped" {
            $k = Join-Path $bagRoots[0] "2\Shell\$FOLDERTYPE_DOWNLOADS"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty -LiteralPath $k -Name 'GroupView' -Value 0xffffffff -Type DWord
            Set-ItemProperty -LiteralPath $k -Name 'GroupByKey:PID' -Value 14 -Type DWord
            Test-NoFolderGrouping $bagRoots | Should -BeFalse
        }

        It "ignores the AllFolders template itself, not a per-folder instance" {
            $k = Join-Path $bagRoots[0] "AllFolders\Shell\$FOLDERTYPE_DOWNLOADS"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty -LiteralPath $k -Name 'GroupView' -Value 0xffffffff -Type DWord
            Test-NoFolderGrouping $bagRoots | Should -BeTrue
        }
    }

    Context "Repair-FolderGrouping" {
        It "changes nothing, and reports no change, when no bag is grouped" {
            Repair-FolderGrouping $bagRoots | Should -BeFalse
        }

        # The verified fix: patch the existing bag in place rather than delete
        # it. A real machine's Downloads bag stayed ungrouped across a genuine
        # open-and-close cycle after exactly this patch, where deleting the bag
        # and letting Explorer recreate it did not - so this must edit, never
        # remove, the key.
        It "clears an existing grouped bag in place" {
            $k = Join-Path $bagRoots[0] "2\Shell\$FOLDERTYPE_DOWNLOADS"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty -LiteralPath $k -Name 'GroupView' -Value 0xffffffff -Type DWord
            Set-ItemProperty -LiteralPath $k -Name 'GroupByKey:PID' -Value 14 -Type DWord

            Repair-FolderGrouping $bagRoots | Should -BeTrue

            Test-Path -LiteralPath $k | Should -BeTrue -Because 'the bag must be patched, not deleted'
            (Get-ItemProperty -LiteralPath $k).GroupView | Should -Be 0
            (Get-ItemProperty -LiteralPath $k).'GroupByKey:PID' | Should -Be 0
        }

        It "leaves an already-ungrouped bag alone" {
            $k = Join-Path $bagRoots[0] "2\Shell\$FOLDERTYPE_DOWNLOADS"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty -LiteralPath $k -Name 'GroupView' -Value 0 -Type DWord
            Set-ItemProperty -LiteralPath $k -Name 'Sort' -Value $SORT_BY_DATE_MODIFIED_DESC -Type Binary

            Repair-FolderGrouping $bagRoots | Should -BeFalse

            (Get-ItemProperty -LiteralPath $k).Sort -join ',' | Should -Be ($SORT_BY_DATE_MODIFIED_DESC -join ',') -Because (
                'only GroupView/GroupByKey should ever be touched')
        }

        It "never touches the AllFolders template itself" {
            $k = Join-Path $bagRoots[0] "AllFolders\Shell\$FOLDERTYPE_DOWNLOADS"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty -LiteralPath $k -Name 'GroupView' -Value 0xffffffff -Type DWord
            $before = (Get-ItemProperty -LiteralPath $k).GroupView

            Repair-FolderGrouping $bagRoots | Should -BeFalse
            (Get-ItemProperty -LiteralPath $k).GroupView | Should -Be $before
        }
    }

    Context "Test-ExplorerDefaultView" {
        It "is true once every template is ours" {
            Set-ProbeApplied
            Test-ExplorerDefaultView $baseKey $typeKey | Should -BeTrue
        }

        It "is false on a machine that has never been set up" {
            Test-ExplorerDefaultView $baseKey $typeKey | Should -BeFalse
        }

        # The regression this shape exists to prevent: `-eq` between two byte
        # arrays FILTERS rather than compares, so a match on a blob whose first
        # byte is 0x00 reads as falsy and the step re-runs (clearing shellbags,
        # bouncing the shell) on every single run.
        It "does not report a perfect Sort match as a mismatch" {
            Set-ProbeApplied
            $SORT_BY_NAME_ASC[0] | Should -Be 0 -Because 'the leading zero is what made the naive -eq wrong'
            $SORT_BY_DATE_MODIFIED_DESC[0] | Should -Be 0
            Test-ExplorerDefaultView $baseKey $typeKey | Should -BeTrue
        }

        It "is false when <Name>" -ForEach @(
            @{ Name = 'a generic folder sorts by Date modified'; Break = 'sort' }
            @{ Name = 'Downloads was left on Name like everything else'; Break = 'downloads' }
            @{ Name = 'grouping is still on in the template'; Break = 'group' }
            @{ Name = 'an older run left FolderType pinned'; Break = 'foldertype' }
        ) {
            Set-ProbeApplied
            $generic = Join-Path $baseKey $FOLDERTYPE_GENERIC
            switch ($Break) {
                'sort' { Set-ItemProperty -LiteralPath $generic -Name 'Sort' -Value $SORT_BY_DATE_MODIFIED_DESC -Type Binary }
                'downloads' {
                    Set-ItemProperty -LiteralPath (Join-Path $baseKey $FOLDERTYPE_DOWNLOADS) `
                        -Name 'Sort' -Value $SORT_BY_NAME_ASC -Type Binary
                }
                'group' { Set-ItemProperty -LiteralPath $generic -Name 'GroupView' -Value 0xffffffff -Type DWord }
                'foldertype' { Set-ItemProperty -LiteralPath $typeKey -Name 'FolderType' -Value 'NotSpecified' -Type String }
            }
            Test-ExplorerDefaultView $baseKey $typeKey | Should -BeFalse
        }
    }

    # The combined, checklist-facing check - deliberately a THIN wrapper kept
    # separate from Test-ExplorerDefaultView (see that function's comment and
    # Test-ExplorerViewFullyApplied's in load-win.ps1): folding grouping drift
    # into the function that gates Set-ExplorerDefaultView's bag wipe would make
    # a plain re-open of Downloads trigger a full reset-and-restart on the next
    # run, which is what broke the fix in the first place.
    Context "Test-ExplorerViewFullyApplied" {
        It "is true once the templates are ours and nothing is grouped" {
            Set-ProbeApplied
            Test-ExplorerViewFullyApplied $baseKey $typeKey $bagRoots | Should -BeTrue
        }

        It "is false when the templates are right but a real bag is grouped" {
            Set-ProbeApplied
            $k = Join-Path $bagRoots[0] "2\Shell\$FOLDERTYPE_DOWNLOADS"
            New-Item -Path $k -Force | Out-Null
            Set-ItemProperty -LiteralPath $k -Name 'GroupView' -Value 0xffffffff -Type DWord
            Test-ExplorerViewFullyApplied $baseKey $typeKey $bagRoots | Should -BeFalse
        }

        It "is false when the templates themselves are wrong, even with nothing grouped" {
            Test-ExplorerViewFullyApplied $baseKey $typeKey $bagRoots | Should -BeFalse
        }
    }

    Context "Set-ExplorerDefaultView safety" {
        # Applying the view recursively deletes four registry trees and kills the
        # shell. Both facts below are what keep that from happening on every run - and
        # neither can be tested by calling the function, which is the point.

        It "clears shellbags only under HKCU" {
            $ExplorerBagPaths | Should -Not -BeNullOrEmpty
            foreach ($p in $ExplorerBagPaths) {
                $p | Should -BeLike 'HKCU:\*' -Because "$p is passed to Remove-Item -Recurse"
                $p | Should -BeLike '*\Shell\Bag*' -Because "$p must name a shellbag tree, not a parent of one"
            }
        }

        # Re-introducing this would be silent: every folder type still gets its
        # template written, the run still reports success, and Downloads still sorts by
        # Name because it is no longer typed as Downloads. Asserted against the source
        # because the damage is a write that must NOT happen. (Pinning FolderType was
        # tried again, deliberately, while chasing the grouping bug this section fixes -
        # and confirmed live to make Downloads WORSE, not better - so this guard stands.)
        It "never pins FolderType, which would starve the Downloads template" {
            $fn = $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq 'Set-ExplorerDefaultView' }, $true) | Select-Object -First 1
            $fn.Extent.Text | Should -Not -Match 'NotSpecified' -Because (
                'pinning every folder to Generic stops Downloads reaching its own template')
            $fn.Extent.Text | Should -Match 'Remove-ItemProperty[^\r\n]*FolderType' -Because (
                'a previous version wrote it, so applying the new view has to undo that')
        }

        # Set-ExplorerDefaultView must gate on the templates alone, NOT on
        # grouping drift. If it gated on Test-ExplorerViewFullyApplied instead,
        # a plain re-open of Downloads would trigger the wholesale bag wipe on
        # the next run, deleting Repair-FolderGrouping's in-place fix along with
        # everything else and reintroducing the bug it exists to prevent.
        It "gates on Test-ExplorerDefaultView, not the combined grouping-aware check" {
            $fn = $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq 'Set-ExplorerDefaultView' }, $true) | Select-Object -First 1
            $first = $fn.Body.EndBlock.Statements | Select-Object -First 1
            $first.Extent.Text | Should -Match 'Test-ExplorerDefaultView' -Because 'the gate function'
            $first.Extent.Text | Should -Not -Match 'Test-ExplorerViewFullyApplied' -Because (
                'that would fold grouping drift into the wipe-everything gate')
        }

        It "returns early when the view is already applied" {
            $fn = $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $n.Name -eq 'Set-ExplorerDefaultView' }, $true) | Select-Object -First 1
            $fn | Should -Not -BeNullOrEmpty

            $first = $fn.Body.EndBlock.Statements | Select-Object -First 1
            $first.Extent.Text | Should -Match 'Test-ExplorerDefaultView' -Because (
                'without the guard, every run wipes the remembered folder views and restarts Explorer')
            $first.Extent.Text | Should -Match 'return'
        }

        # The shell restart is the second half of the reset: explorer.exe writes
        # its in-memory bags back as windows close, so a clear with the shell
        # left running is undone by the time the user looks.
        #
        # Followed through the variable rather: the taskbar shares the one
        # bounce, so what gates the restart is "the view changed OR the taskbar
        # did".
        It "is followed by a shell restart at its call site" {
            $assign = $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Right.Extent.Text -match 'Set-ExplorerDefaultView' }, $true) |
                Select-Object -First 1
            $assign | Should -Not -BeNullOrEmpty -Because 'the return value is what gates the restart'

            $flag = $assign.Left.Extent.Text
            $call = $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and
                    $n.Clauses[0].Item1.Extent.Text -match [regex]::Escape($flag) -and
                    $n.Clauses[0].Item2.Extent.Text -match 'Restart-Explorer' }, $true) |
                Select-Object -First 1
            $call | Should -Not -BeNullOrEmpty -Because (
                "$flag has to gate a Restart-Explorer, or the cleared bags are written straight back")
        }
    }
}

# An AutoHotkey v2 install ships several AutoHotkey*.exe files. Two must never be
# chosen to run the macros: the _UIA build exists to drive ELEVATED windows (the
# opposite of the documented non-elevated launch) and AutoHotkeyUX.exe is the
# launcher GUI, not an interpreter.
Describe "Find-AhkExe picks the plain 64-bit interpreter" -Skip:(-not $IsWindowsHost) {
    BeforeEach {
        $script:saved = @{ Path = $env:Path; ProgramW6432 = $env:ProgramW6432; LocalAppData = $env:LOCALAPPDATA }
        $script:box = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        # Neutralise the PATH probe and both scan roots (Program Files for a
        # machine-scope install, LocalAppData for AutoHotkey's own per-user
        # default - see $USER_SCOPE_PKGS) so only what a given test sets up is
        # under test.
        $env:Path = "$env:WINDIR\System32"
        $env:ProgramW6432 = $script:box
        $env:LOCALAPPDATA = Join-Path $script:box 'localappdata'
    }

    AfterEach {
        $env:Path = $script:saved.Path
        $env:ProgramW6432 = $script:saved.ProgramW6432
        $env:LOCALAPPDATA = $script:saved.LocalAppData
    }

    It "skips the _UIA and UX builds and takes AutoHotkey64.exe" {
        $v2 = Join-Path $box 'AutoHotkey\v2'
        New-Item -ItemType Directory -Force -Path $v2, (Join-Path $box 'AutoHotkey\UX') | Out-Null
        # Written in the order a real install enumerates them - _UIA before the plain
        # build, which is what made the old sort pick the wrong one.
        foreach ($n in 'AutoHotkey.exe', 'AutoHotkey32_UIA.exe', 'AutoHotkey32.exe',
            'AutoHotkey64_UIA.exe', 'AutoHotkey64.exe') {
            Set-Content -LiteralPath (Join-Path $v2 $n) -Value '' -Encoding Ascii
        }
        Set-Content -LiteralPath (Join-Path $box 'AutoHotkey\UX\AutoHotkeyUX.exe') -Value '' -Encoding Ascii

        Find-AhkExe | Should -Be (Join-Path $v2 'AutoHotkey64.exe')
    }

    It "falls back to the 32-bit interpreter when no 64-bit build exists" {
        $v2 = Join-Path $box 'AutoHotkey\v2'
        New-Item -ItemType Directory -Force -Path $v2 | Out-Null
        Set-Content -LiteralPath (Join-Path $v2 'AutoHotkey32_UIA.exe') -Value '' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $v2 'AutoHotkey32.exe') -Value '' -Encoding Ascii

        Find-AhkExe | Should -Be (Join-Path $v2 'AutoHotkey32.exe')
    }

    It "returns nothing when only non-interpreter executables are present" {
        $ux = Join-Path $box 'AutoHotkey\UX'
        New-Item -ItemType Directory -Force -Path $ux | Out-Null
        Set-Content -LiteralPath (Join-Path $ux 'AutoHotkeyUX.exe') -Value '' -Encoding Ascii

        Find-AhkExe | Should -BeNullOrEmpty
    }

    # AutoHotkey is in $USER_SCOPE_PKGS - "winget --scope user" runs the vendor
    # installer non-elevated, which defaults to %LocalAppData%\Programs\AutoHotkey
    # instead of Program Files.
    It "finds a user-scope install under LocalAppData when Program Files has none" {
        $v2 = Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey\v2'
        New-Item -ItemType Directory -Force -Path $v2 | Out-Null
        Set-Content -LiteralPath (Join-Path $v2 'AutoHotkey64.exe') -Value '' -Encoding Ascii

        Find-AhkExe | Should -Be (Join-Path $v2 'AutoHotkey64.exe')
    }
}

# Show-Checklist derives each package's friendly name from its WingetId via
# $PKG_ALIAS, so a rename/typo there shows a raw id (or nothing). Membership is
# computed at discovery so each id gets its own named test.
Describe "Package-list consistency" {
    BeforeDiscovery {
        $env:LOAD_LIB = "1"
        . "$PSScriptRoot\..\src\load-win.ps1"
        $env:LOAD_LIB = $null
        $allPkgs = @($CORE_PKGS + $FULL_PKGS + $PREMIERE_PKGS)
        $script:aliasIds = @($allPkgs | ForEach-Object {
                @{ Id = $_; HasAlias = $PKG_ALIAS.ContainsKey($_) } })
    }

    It "package <Id> has a friendly alias in PKG_ALIAS" -ForEach $aliasIds {
        $HasAlias | Should -BeTrue -Because "$Id has no entry in PKG_ALIAS, so it shows as a raw id"
    }
}

# The script is meant to survive Constrained Language Mode (WDAC/AppLocker): the
# .NET- backed steps (Add-Type/P-Invoke, the Premiere prefs byte write) are gated on $CLM and degrade to "skipped" instead
# of crashing. These guard that contract so a future edit can't quietly
# reintroduce an unguarded .NET call.
#
# Two independent angles, because neither alone is enough:
#   - static: the CLM-blocked .NET in the script is unreachable while $CLM is
#     true (covers the apply paths, which a test run must not actually execute)
#   - runtime: a real child shell forced into ConstrainedLanguage loads and
#     dry-runs the script with no language-mode error on its error stream
#
# Both angles carry a canary test that plants a deliberate violation and asserts
# the check FAILS on it.
Describe "Constrained Language Mode resilience" {
    BeforeAll {
        $script:srcPath = (Resolve-Path "$PSScriptRoot/../src/load-win.ps1").Path

        # The CLM entrypoint in the .EXAMPLE header hands the file to
        # `powershell`, so Windows PowerShell 5.1 is the shell that actually
        # meets CLM in production - test there rather than in pwsh. Off Windows
        # there is only pwsh. ($IsWindowsHost is a discovery-scope variable, so
        # it is recomputed here for the run phase - see the note on its
        # definition at the top of this file.)
        $onWindows = (-not (Test-Path Variable:IsWindows)) -or $IsWindows
        $ps51 = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $script:clmShell = if ($onWindows -and (Test-Path $ps51)) { $ps51 } else { 'pwsh' }

        # --- runtime harness ------------------------------------------------
        # Runs $Path in a child shell forced into ConstrainedLanguage and
        # reports what happened. Returns the language mode the child actually
        # reached (a positive control: if the assignment ever stops taking, the
        # whole Describe would go vacuous silently), whether the child ran to
        # completion, its exit code, and its error stream.
        #
        # Limitation worth knowing: this sees only errors that reach stderr, so
        # a CLM violation inside one of the script's `try { } catch { }` blocks
        # stays invisible here. That is what the static angle below is for.
        function Invoke-UnderClm {
            param([string]$Path, [string]$Arguments = '', [string]$Prologue = '')

            $out = Join-Path $TestDrive "clm-$([guid]::NewGuid().ToString('N')).out"
            $err = [System.IO.Path]::ChangeExtension($out, '.err')
            $cmd = @(
                "`$ExecutionContext.SessionState.LanguageMode='ConstrainedLanguage'"
                "'ZZ-MODE=' + `$ExecutionContext.SessionState.LanguageMode"
                $Prologue
                "& '$Path' $Arguments"
                "'ZZ-DONE'"
            ) | Where-Object { $_ }
            $cmd = $cmd -join '; '

            & $script:clmShell -NoProfile -Command $cmd 1> $out 2> $err
            $exit = $LASTEXITCODE

            $stdout = (Get-Content $out -Raw -ErrorAction SilentlyContinue) + ''
            $stderr = (Get-Content $err -Raw -ErrorAction SilentlyContinue) + ''
            [pscustomobject]@{
                Mode       = if ($stdout -match 'ZZ-MODE=(\w+)') { $Matches[1] } else { '<none>' }
                Completed  = $stdout -match 'ZZ-DONE'
                ExitCode   = $exit
                Stderr     = $stderr
                # Every engine refusal ends "... in this language mode"; the
                # FullyQualifiedErrorId form is matched too for the views that
                # print it.
                Violations = @([regex]::Matches($stderr, '(?m)^.*(in this language mode|ConstrainedLanguage).*$') |
                        ForEach-Object { $_.Value.Trim() })
            }
        }

        # Asserts the three things every CLM run must satisfy, with the child's
        # own error text in the failure message.
        function Assert-ClmSurvived($result, [string]$what) {
            $result.Mode | Should -Be 'ConstrainedLanguage' -Because (
                "the child never entered CLM, so '$what' proved nothing (mode: $($result.Mode))")
            $result.Violations | Should -BeNullOrEmpty -Because (
                "$what hit a language-mode block:`n$($result.Violations -join "`n")")
            $result.Completed | Should -BeTrue -Because (
                "$what did not run to completion under CLM:`n$($result.Stderr)")
        }
    }

    # Sourcing the script as a library must not execute any CLM-blocked .NET at module
    # scope (the $CLM probe itself, the top-level statements). Cross-platform.
    It "loads as a library under Constrained Language Mode" {
        $r = Invoke-UnderClm -Path $srcPath -Prologue "`$env:LOAD_LIB='1'"
        Assert-ClmSurvived $r 'sourcing the script as a library'
        $r.ExitCode | Should -Be 0
    }

    # End-to-end smoke: a --dry-run (preview + full checklist) must complete under CLM
    # without a language-mode violation. Windows-only - the checklist reads HKCU/HKLM,
    # which don't exist on other platforms.
    It "a --dry-run completes under Constrained Language Mode" -Skip:(-not $IsWindowsHost) {
        $r = Invoke-UnderClm -Path $srcPath -Arguments '--dry-run'
        Assert-ClmSurvived $r 'a --dry-run'
        $r.ExitCode | Should -Be 0
    }

    # Canary: proves the harness above can actually fail. Without this, a change
    # to the error view, the shell, or the match pattern turns every runtime
    # test in this block green-forever.
    It "the runtime harness detects a planted language-mode violation" {
        $canary = Join-Path $TestDrive 'clm-canary.ps1'
        Set-Content -LiteralPath $canary -Encoding Ascii -Value @'
$ErrorActionPreference = "Continue"
$null = [System.Environment]::GetEnvironmentVariable("Path", "User")
'@
        $r = Invoke-UnderClm -Path $canary

        $r.Mode | Should -Be 'ConstrainedLanguage'
        $r.Violations | Should -Not -BeNullOrEmpty -Because 'a blocked static call must be reported'
        # The two signals the old test relied on, shown to be worthless on their own.
        $r.ExitCode | Should -Be 0 -Because 'a CLM violation is non-terminating - exit code cannot detect it'
        $r.Completed | Should -BeTrue -Because 'execution continues past the violation'
    }
}

# The static half of the CLM contract. A dry run exercises only the preview
# paths, so the code that actually applies settings (prefs writes, the P/Invoke
# broadcasts) can only be checked by
# reading it - a test must not run it on a real machine. This walks the call
# graph to find what could execute while $CLM is true, then checks that none of
# it touches .NET the engine would refuse.
Describe "Constrained Language Mode static reachability" {
    BeforeAll {
        $script:srcPath = (Resolve-Path "$PSScriptRoot/../src/load-win.ps1").Path

        # Types confirmed callable in ConstrainedLanguage on Windows PowerShell
        # 5.1. To re-derive after a Windows change, run the expression in a
        # child shell with LanguageMode set to ConstrainedLanguage and see
        # whether it throws; anything not listed here is treated as blocked, so
        # the list only ever needs widening when a genuinely-safe call trips
        # this test.
        $script:clmSafeTypes = '^(regex|System\.Text\.RegularExpressions\.Regex|IntPtr|System\.IntPtr|' +
        'datetime|System\.DateTime|System\.Console|System\.StringComparison|bool|string|int|long|byte)$'

        # True when $node cannot execute while $CLM is true. Three gating shapes
        # are in use in the script, and all three have to be understood or this
        # reports noise:
        #   1. `if (-not $CLM) { ... }`  - the node sits in that clause's body
        #   2. `... elseif ($CLM) { skip } elseif (...) { node }`
        #                               - an earlier clause peeled off the CLM case
        #   3. `function F { if ($CLM) { return } ... }`
        #                               - an early return covers the whole body
        # Containment is by extent offsets, so a node in the ELSE of `if (-not
        # $CLM)` is correctly seen as ungated - the previous version matched any
        # clause of the enclosing if-statement and so called that case guarded.
        function Test-ClmGated($node) {
            $p = $node.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $p.Clauses) {
                        $cond = $clause.Item1.Extent.Text
                        $body = $clause.Item2.Extent
                        $inBody = $body.StartOffset -le $node.Extent.StartOffset -and
                        $node.Extent.EndOffset -le $body.EndOffset
                        if ($cond -match '-not\s+\$CLM' -and $inBody) { return $true }
                        if ($cond -match '^\s*\$CLM\s*$' -and $node.Extent.StartOffset -gt $body.EndOffset) { return $true }
                    }
                }
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $first = $p.Body.EndBlock.Statements | Select-Object -First 1
                    if ($first -is [System.Management.Automation.Language.IfStatementAst] -and
                        $first.Clauses[0].Item1.Extent.Text -match '^\s*\$CLM\s*$' -and
                        $first.Clauses[0].Item2.Extent.Text -match 'return') { return $true }
                    return $false   # function scope is the ceiling - callers are the graph's job
                }
                $p = $p.Parent
            }
            return $false
        }

        function Get-EnclosingFunction($node) {
            $p = $node.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
                $p = $p.Parent
            }
            return $null
        }

        # Returns every CLM-blocked .NET construct that can run while $CLM is
        # true, as "line N  what  [fn=F]" strings. Takes a path so the canary
        # test can point it at a planted violation and prove it fires.
        function Get-ClmReachableDotNet([string]$Path) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)

            $funcs = @{}
            $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $funcs[$_.Name] = $_ }

            # Reachability from the script's top level, refusing to traverse
            # call sites that are themselves CLM-gated. A function is "live" if
            # some ungated chain of calls reaches it.
            $live = New-Object 'System.Collections.Generic.HashSet[string]'
            $stack = New-Object 'System.Collections.Generic.Stack[string]'
            $allCalls = $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] }, $true)

            foreach ($c in $allCalls) {
                if ($null -ne (Get-EnclosingFunction $c)) { continue }   # top-level calls seed the walk
                $n = $c.GetCommandName()
                if ($n -and $funcs.ContainsKey($n) -and -not (Test-ClmGated $c) -and $live.Add($n)) { $stack.Push($n) }
            }
            while ($stack.Count) {
                $name = $stack.Pop()
                foreach ($c in $funcs[$name].Body.FindAll({ param($n)
                            $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                    $callee = $c.GetCommandName()
                    if ($callee -and $funcs.ContainsKey($callee) -and -not (Test-ClmGated $c) -and $live.Add($callee)) {
                        $stack.Push($callee)
                    }
                }
            }

            # Add-Type and New-Object are refused outright for non-core types; a
            # static method call is refused unless the type is one of the core
            # ones.
            $suspects = $ast.FindAll({ param($n)
                    ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static) -or
                    ($n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -in @('Add-Type', 'New-Object')) }, $true)

            foreach ($n in $suspects) {
                if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    $type = $n.Expression.TypeName.FullName
                    if ($type -match $script:clmSafeTypes) { continue }
                    $what = "$type::$($n.Member.Value)"
                }
                else { $what = $n.GetCommandName() }

                $fn = Get-EnclosingFunction $n
                $reachable = if ($null -eq $fn) { -not (Test-ClmGated $n) } else { $live.Contains($fn) -and -not (Test-ClmGated $n) }
                if ($reachable) { "line $($n.Extent.StartLineNumber)  $what  [fn=$(if ($fn) { $fn } else { '<top level>' })]" }
            }
        }
    }

    It "no CLM-blocked .NET is reachable while `$CLM is true" {
        $found = @(Get-ClmReachableDotNet $srcPath)
        $found | Should -BeNullOrEmpty -Because (
            "these run under CLM and the engine will refuse them - gate them on `$CLM:`n$($found -join "`n")")
    }

    # The analysis is only as good as its ability to say no. Each canary is a
    # shape the script actually uses, so a refactor that breaks one of the three
    # gate forms shows up here as a false-clean rather than passing unnoticed.
    It "the analysis flags <Name>" -ForEach @(
        @{ Name = 'an ungated Add-Type'; Body = 'Add-Type -TypeDefinition "public class Z {}"' }
        @{ Name = 'an ungated static .NET call'; Body = '[System.IO.File]::ReadAllBytes("x")' }
        @{ Name = 'an ungated New-Object'; Body = 'New-Object System.Security.Cryptography.SHA256Managed' }
        @{ Name = 'a call in the ELSE of "if (-not $CLM)"'; Body = 'if (-not $CLM) { "ok" } else { Add-Type -TypeDefinition "public class Z {}" }' }
        @{ Name = 'a violation behind an ungated function call'; Body = "function Get-Thing { [System.IO.File]::ReadAllBytes('x') }`nGet-Thing" }
    ) {
        $canary = Join-Path $TestDrive "canary-$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content -LiteralPath $canary -Encoding Ascii -Value "`$CLM = `$true`n$Body`n"
        @(Get-ClmReachableDotNet $canary) | Should -Not -BeNullOrEmpty
    }

    # The mirror of the above: the gate forms the script relies on must read as
    # safe, or the test becomes noise a maintainer learns to ignore.
    It "the analysis accepts <Name>" -ForEach @(
        @{ Name = 'a call inside "if (-not $CLM)"'; Body = 'if (-not $CLM) { Add-Type -TypeDefinition "public class Z {}" }' }
        @{ Name  = 'a function behind an "if ($CLM) { return }" guard'
            Body = "function Set-Thing { if (`$CLM) { return }`n[System.IO.File]::ReadAllBytes('x') }`nSet-Thing"
        }
        @{ Name  = 'an elseif branch after an "elseif ($CLM)" skip'
            Body = "if (`$false) { 'a' } elseif (`$CLM) { 'skip' } else { [System.IO.File]::ReadAllBytes('x') }"
        }
    ) {
        $canary = Join-Path $TestDrive "canary-$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content -LiteralPath $canary -Encoding Ascii -Value "`$CLM = `$true`n$Body`n"
        @(Get-ClmReachableDotNet $canary) | Should -BeNullOrEmpty
    }
}

# Two whole-script contracts that are easiest to state over the AST, since the
# code they cover sits below the $env:LOAD_LIB library boundary and cannot be
# sourced.
Describe "whole-script invariants" {
    BeforeAll {
        $script:srcPath = (Resolve-Path "$PSScriptRoot/../src/load-win.ps1").Path
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$null, [ref]$null)
    }

    # `winget list --id X` filters on a SUBSTRING, and the caller then does an
    # unanchored regex over the output, so without --exact both halves agree on
    # the wrong answer: with only MediaInfo GUI installed, "MediaArea.MediaInfo"
    # matches "MediaArea.MediaInfo.GUI" and the separately-listed CLI package
    # reads as already installed and never gets installed. It is loose enough
    # that a nonexistent id ("VideoLAN.VL") also comes back true.
    It "every 'winget list' query is --exact" {
        $lists = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'winget' -and
                $n.CommandElements.Count -gt 1 -and
                $n.CommandElements[1].Extent.Text -eq 'list' }, $true)
        $lists | Should -Not -BeNullOrEmpty -Because 'the guard is meaningless with no winget list call to check'

        $loose = foreach ($c in $lists) {
            if ($c.Extent.Text -notmatch '--exact') { "line $($c.Extent.StartLineNumber)" }
        }
        @($loose) | Should -BeNullOrEmpty -Because (
            "a substring match reports the wrong package as installed. Missing --exact at: $($loose -join ', ')")
    }

    # --dry-run is a preview and must not touch the disk, and the test suite
    # sources this file as a library - so nothing at module scope (above the
    # $env:LOAD_LIB return) may write. Creating the work dir there did both.
    It "no filesystem write runs at module scope" {
        $guard = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.IfStatementAst] -and
                $n.Clauses[0].Item1.Extent.Text -match 'env:LOAD_LIB' }, $true) | Select-Object -First 1
        $guard | Should -Not -BeNullOrEmpty -Because 'the library boundary is what makes module scope testable'

        $writers = 'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Remove-Item',
        'Copy-Item', 'Move-Item', 'Set-ItemProperty', 'New-ItemProperty', 'curl.exe',
        'Expand-Archive', 'Start-Process'

        $offenders = foreach ($c in $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            # Module scope = before the guard and not nested inside a function.
            if ($c.Extent.StartOffset -ge $guard.Extent.StartOffset) { continue }
            $p = $c.Parent; $inFunc = $false
            while ($p) {
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFunc = $true; break }
                $p = $p.Parent
            }
            if (-not $inFunc -and $c.GetCommandName() -in $writers) {
                "line $($c.Extent.StartLineNumber): $($c.GetCommandName())"
            }
        }
        @($offenders) | Should -BeNullOrEmpty -Because (
            "sourcing the script and --dry-run must both be side-effect free; found: $($offenders -join ', ')")
    }
}

# Fast mode (--fast) must never trigger UAC: it applies only per-user config
# (HKCU writes, file drops into the user's profile, a non-elevated AHK launch).
# The script's single elevation point is `Start-Process ... -Verb RunAs` in
# Invoke-ElevatedInstall, reached only via Invoke-SlowPass (the $FULL pass).
# These walk the AST (not the text, and no sourcing - the installer functions
# live below the $env:LOAD_LIB boundary) to prove a fast run can't reach it, so
# a refactor can't quietly add an elevated step to the fast path or sneak in a
# second RunAs.
Describe "fast mode requests no elevation (no UAC)" {
    BeforeAll {
        $srcPath = (Resolve-Path "$PSScriptRoot/../src/load-win.ps1").Path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$null, [ref]$null)

        # name -> FunctionDefinitionAst, for the call-graph walk
        $script:funcs = @{}
        $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $script:funcs[$_.Name] = $_ }

        # A command is an elevation point when it passes `-Verb RunAs`.
        function Test-IsRunAsVerb($cmd) {
            $els = $cmd.CommandElements
            for ($i = 0; $i -lt $els.Count - 1; $i++) {
                if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $els[$i].ParameterName -eq 'Verb' -and
                    $els[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $els[$i + 1].Value -eq 'RunAs') { return $true }
            }
            return $false
        }

        # The enclosing function name for an AST node (walks up to the FunctionDefinitionAst).
        function Get-EnclosingFunc($node) {
            $p = $node.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
                $p = $p.Parent
            }
            return $null
        }

        # Every -Verb RunAs call in the script, tagged with the function it sits in.
        $script:runAsCmds = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { Test-IsRunAsVerb $_ }
        $script:runAsFuncs = @($script:runAsCmds | ForEach-Object { Get-EnclosingFunc $_ } | Sort-Object -Unique)

        # Functions transitively reachable from Invoke-FastPass (including itself),
        # restricted to functions the script defines.
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        [void]$seen.Add('Invoke-FastPass'); $stack.Push('Invoke-FastPass')
        while ($stack.Count) {
            $name = $stack.Pop()
            if (-not $script:funcs.ContainsKey($name)) { continue }
            foreach ($c in $script:funcs[$name].Body.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $callee = $c.GetCommandName()
                if ($callee -and $script:funcs.ContainsKey($callee) -and $seen.Add($callee)) { $stack.Push($callee) }
            }
        }
        $script:fastReach = $seen

        # Any function in the fast call graph that itself requests elevation.
        $script:fastRunAsFuncs = @($script:runAsFuncs | Where-Object { $script:fastReach.Contains($_) })
    }

    It "has exactly one elevation point in the whole script" {
        @($runAsCmds).Count | Should -Be 1 -Because (
            "the no-UAC-in-fast-mode contract assumes a single, locatable RunAs; found in: $($runAsFuncs -join ', ')")
    }

    It "the only elevation lives in Invoke-ElevatedInstall" {
        $runAsFuncs | Should -Be 'Invoke-ElevatedInstall' -Because (
            "elevation must stay behind the slow/full pass, not in: $($runAsFuncs -join ', ')")
    }

    It "Invoke-FastPass's call graph never reaches an elevated step" {
        foreach ($elevated in 'Invoke-SlowPass', 'Invoke-ElevatedInstall') {
            $fastReach.Contains($elevated) | Should -BeFalse -Because "a --fast run must not call $elevated"
        }
    }

    It "no command reached by Invoke-FastPass requests elevation" {
        @($fastRunAsFuncs) | Should -BeNullOrEmpty -Because (
            "a fast run must prompt for no admin rights; elevation reachable via: $($fastRunAsFuncs -join ', ')")
    }
}

# The work dir (Downloads\load-win) exists only to hold what Invoke-SlowPass
# downloads into it (LUTs, the Mister Horse/Flicker Free installers, the AHK
# script) - Invoke-FastPass never writes there. Creating it unconditionally in
# the top-level dispatch block, ahead of Invoke-FastPass, meant a --fast-only
# run - or a bare run where the user declined the Full prompt - left an empty
# load-win folder behind in Downloads forever, since nothing ever deletes it.
# AST-based (not text) so a reformat can't dodge the check.
Describe "the work dir is only created by the pass that uses it" {
    BeforeAll {
        $srcPath = (Resolve-Path "$PSScriptRoot/../src/load-win.ps1").Path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($srcPath, [ref]$null, [ref]$null)

        function Get-EnclosingFunc($node) {
            $p = $node.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
                $p = $p.Parent
            }
            return $null
        }

        # Every `New-Item ... $WorkDir ...` call in the script, wherever it lives.
        $script:workDirCreates = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'New-Item' -and
                ($n.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $_.VariablePath.UserPath -eq 'WorkDir' })
            }, $true)
    }

    It "creates `$WorkDir exactly once" {
        @($workDirCreates).Count | Should -Be 1 -Because "one creation point keeps this easy to reason about"
    }

    It "creates it inside Invoke-SlowPass, not the top-level dispatch block" {
        $enclosing = Get-EnclosingFunc $workDirCreates[0]
        $enclosing | Should -Be 'Invoke-SlowPass' -Because (
            "only the Full pass writes into it (LUTs, Mister Horse, Flicker Free, the AHK script) - " +
            "creating it earlier (e.g. before Invoke-FastPass runs) leaves an empty load-win folder " +
            "behind in Downloads on any --fast-only or fast-then-decline run")
    }
}

# The prefs format is Premiere-version-dependent (not platform-dependent), so
# these run against every captured version.
Describe "Set-PremierePro (Premiere <Version>)" -ForEach $PremiereVersions {
    BeforeEach {
        # The prefs fixtures are LF and that is faithful ON WINDOWS TOO: Premiere
        # writes this file LF on both platforms, unlike UserWorkspace*.xml which is
        # CRLF here. So this fixture is not a macOS-capture artefact to be corrected
        # - see the serialiser split on ConvertTo-CrlfFile in load-win.ps1.
        $fixture = "$PSScriptRoot\fixtures\$Dir\Adobe Premiere Pro Prefs_truncated"
        $prefs = Join-Path $TestDrive "prefs"
        Copy-Item $fixture $prefs
    }

    It "shortcut set is activated" {
        Set-PremierePro $prefs "LGG_25.1_WINDOWS.kys" "LGG - Single monitor" $Version
        Get-Content $prefs -Raw | Should -Match '<FE\.Prefs\.Shortcuts\.Filename>LGG_25\.1_WINDOWS\.kys</FE\.Prefs\.Shortcuts\.Filename>'
    }

    It "workspace is activated, spaces preserved" {
        Set-PremierePro $prefs "LGG_25.1_WINDOWS.kys" "LGG - Single monitor" $Version
        Get-Content $prefs -Raw | Should -Match '<FE\.Application\.LastWorkspaceName>LGG - Single monitor</FE\.Application\.LastWorkspaceName>'
    }

    It "labels switch to Classic (names + colours + marker)" {
        Set-PremierePro $prefs "x.kys" "WS" $Version
        $content = Get-Content $prefs -Raw
        $content | Should -Match '<BE\.Prefs\.LabelNames\.0>Violet</BE\.Prefs\.LabelNames\.0>'
        $content | Should -Match '<BE\.Prefs\.LabelNames\.15>Yellow</BE\.Prefs\.LabelNames\.15>'
        $content | Should -Match '<BE\.Prefs\.LabelColors\.0>14717094</BE\.Prefs\.LabelColors\.0>'
        $content | Should -Match '<BE\.Prefs\.LabelColors\.15>6611682</BE\.Prefs\.LabelColors\.15>'
        $content | Should -Match '"name":"Classic"'
        $content | Should -Not -Match 'Vibrant'
    }

    It "auto-save enabled every 5 minutes, keeping 200 project versions" {
        Set-PremierePro $prefs "x.kys" "WS" $Version
        $content = Get-Content $prefs -Raw
        $content | Should -Match '<BE\.Prefs\.AutoSave\.DoSave>true</BE\.Prefs\.AutoSave\.DoSave>'
        $content | Should -Match '<BE\.Prefs\.AutoSave\.Interval>5</BE\.Prefs\.AutoSave\.Interval>'
        $content | Should -Match '<BE\.Prefs\.AutoSave\.MaxProjectVersions>200</BE\.Prefs\.AutoSave\.MaxProjectVersions>'
    }

    It "Linked Selection is enabled" {
        Set-PremierePro $prefs "x.kys" "WS" $Version
        Get-Content $prefs -Raw | Should -Match '<TL\.PREFLinkedSelectionState>true</TL\.PREFLinkedSelectionState>'
    }

    # One test per row of the script's $forced table (see $ForcedPrefs above). A row
    # with a min-major above this Premiere is a preference that does not exist yet:
    # the file must be left alone for it, and nothing reported, since its absence is
    # permanent rather than a fresh-install artefact.
    It "forced pref <Node> is written" -ForEach $ForcedPrefs {
        $tag = [regex]::Escape($Node)
        $output = Set-PremierePro $prefs "x.kys" "WS" $Version 6>&1 | Out-String
        $output | Should -Not -Match 'not found and skipped'
        $content = Get-Content $prefs -Raw
        if ($MinMajor -and [int](($Version -split '\.')[0]) -lt [int]$MinMajor) {
            $content | Should -Not -Match $tag
        }
        else {
            $content | Should -Match "<$tag>$([regex]::Escape($Value))</$tag>"
        }
    }

    # Premiere has not persisted these on a fresh install, so they must be CREATED
    # rather than skipped - otherwise the default we disagree with silently stands.
    It "forced pref <Node> is created when absent on a whitelisted version" -ForEach $ForcedPrefs {
        $tag = [regex]::Escape($Node)
        $kept = [System.IO.File]::ReadAllText($prefs) -split "`n" | Where-Object { $_ -notmatch $tag }
        [System.IO.File]::WriteAllText($prefs, ($kept -join "`n"))

        $output = Set-PremierePro $prefs "x.kys" "WS" $Version 6>&1 | Out-String
        $output | Should -Not -Match 'not found and skipped'
        $content = Get-Content $prefs -Raw
        if ($MinMajor -and [int](($Version -split '\.')[0]) -lt [int]$MinMajor) {
            $content | Should -Not -Match $tag
        }
        else {
            $content | Should -Match "<$tag>$([regex]::Escape($Value))</$tag>"
        }
        { [xml]$content } | Should -Not -Throw
    }

    # On a non-whitelisted version an absent node is reported and skipped, leaving
    # the file untouched for it.
    It "forced pref <Node> is skipped (not created) on a non-whitelisted version" -ForEach $ForcedPrefs {
        $tag = [regex]::Escape($Node)
        $kept = [System.IO.File]::ReadAllText($prefs) -split "`n" | Where-Object { $_ -notmatch $tag }
        [System.IO.File]::WriteAllText($prefs, ($kept -join "`n"))

        $output = Set-PremierePro $prefs "x.kys" "WS" "0.0" 6>&1 | Out-String
        Get-Content $prefs -Raw | Should -Not -Match $tag
        # A row with a min-major is skipped silently on an unknown version, not reported.
        if (-not $MinMajor) { $output | Should -Match ([regex]::Escape($Node)) }
    }

    # One test per row of the script's $mseForced table. This is the
    # create-when-absent case; the in-place edit is the test below it.
    It "mse pref <Node> is created under -Mse" -ForEach $MseForcedPrefs {
        $tag = [regex]::Escape($Node)
        $output = Set-PremierePro $prefs "x.kys" "WS" $Version -Mse 6>&1 | Out-String
        $output | Should -Not -Match 'not found and skipped'
        $content = Get-Content $prefs -Raw
        if ($MinMajor -and [int](($Version -split '\.')[0]) -lt [int]$MinMajor) {
            $content | Should -Not -Match $tag
        }
        else {
            $content | Should -Match "<$tag>$([regex]::Escape($Value))</$tag>"
        }
        { [xml]$content } | Should -Not -Throw
    }

    It "mse pref <Node> is overwritten under -Mse when Premiere already wrote it" -ForEach $MseForcedPrefs {
        $tag = [regex]::Escape($Node)
        Set-ForcedPrefNode -Prefs $prefs -Node $Node -Value 'true' | Out-Null

        Set-PremierePro $prefs "x.kys" "WS" $Version -Mse | Out-Null
        $expected = if ($MinMajor -and [int](($Version -split '\.')[0]) -lt [int]$MinMajor) { 'true' } else { $Value }
        Get-Content $prefs -Raw | Should -Match "<$tag>$([regex]::Escape($expected))</$tag>"
    }

    # --mse is the only mode that writes these: a plain run leaves the node
    # exactly as it found it.
    It "mse pref <Node> is left alone without -Mse" -ForEach $MseForcedPrefs {
        $tag = [regex]::Escape($Node)
        $before = [regex]::Match([System.IO.File]::ReadAllText($prefs), "<$tag>[^<]*</$tag>").Value
        $output = Set-PremierePro $prefs "x.kys" "WS" $Version 6>&1 | Out-String
        $output | Should -Not -Match ([regex]::Escape($Node))
        [regex]::Match((Get-Content $prefs -Raw), "<$tag>[^<]*</$tag>").Value | Should -Be $before
    }

    It "output prefs is valid XML" {
        Set-PremierePro $prefs "x.kys" "WS" $Version
        { [xml](Get-Content $prefs -Raw) } | Should -Not -Throw
    }

    It "no BOM is introduced" {
        Set-PremierePro $prefs "x.kys" "WS" $Version
        $bytes = [System.IO.File]::ReadAllBytes($prefs)
        $bytes[0] | Should -Be 0x3C  # '<' - would be 0xEF/0xFF if a BOM were prepended
    }

    It "idempotent: second run is byte-identical to first" {
        Set-PremierePro $prefs "LGG_25.1_WINDOWS.kys" "LGG - Single monitor" $Version
        $hash1 = (Get-FileHash $prefs -Algorithm SHA256).Hash
        Set-PremierePro $prefs "LGG_25.1_WINDOWS.kys" "LGG - Single monitor" $Version
        $hash2 = (Get-FileHash $prefs -Algorithm SHA256).Hash
        $hash2 | Should -Be $hash1
    }

    It "a renamed node is skipped without corrupting others, with an informative warning" {
        $content = Get-Content $prefs -Raw
        $content = $content -replace 'TL\.PREFLinkedSelectionState', 'TL.PREFLinkedSelectionStateRENAMED'
        Set-Content $prefs $content -Encoding UTF8 -NoNewline
        $output = Set-PremierePro $prefs "LGG_25.1_WINDOWS.kys" "LGG - Single monitor" $Version 6>&1 | Out-String
        $output | Should -Match 'TL\.PREFLinkedSelectionState'
        $output | Should -Match 'Adobe renamed'
        { [xml](Get-Content $prefs -Raw) } | Should -Not -Throw
        Get-Content $prefs -Raw | Should -Match '<BE\.Prefs\.AutoSave\.Interval>5</BE\.Prefs\.AutoSave\.Interval>'
        Get-Content $prefs -Raw | Should -Match '<TL\.PREFLinkedSelectionStateRENAMED>false</TL\.PREFLinkedSelectionStateRENAMED>'
    }
}

Describe "Get-WorkspaceName (Premiere <Version>)" -ForEach $PremiereVersions {
    It "extracts the UserName" {
        $ws = "$PSScriptRoot/fixtures/$Dir/UserWorkspace_truncated.xml"
        Get-WorkspaceName $ws | Should -Be 'LGG - Single monitor'
    }

    # The fixtures are LF (macOS default), but every real UserWorkspace*.xml on
    # Windows is pure CRLF - so on this platform the LF fixture is the shape we
    # DON'T meet in production. Assert the CRLF shape too, and that no \r leaks
    # into the name: it gets copied into the prefs as element text, so the
    # extractor must return the field and nothing else, whatever EOLs the
    # surrounding file uses. Premiere writes these UTF-8 with no BOM, and
    # Windows PowerShell 5.1 decodes a BOM-less file with the ANSI code page. A
    # workspace name with an accent then comes back mojibaked and is copied into
    # the prefs as LastWorkspaceName, naming a workspace that does not exist.
    # Guards the explicit -Encoding UTF8 on the read.
    It "reads a non-ASCII workspace name without mojibake" {
        $utf8 = Join-Path $TestDrive "ws_utf8_$Dir.xml"
        [System.IO.File]::WriteAllText(
            $utf8,
            "<root>`r`n<key>UserName</key><ustring>Edicion Camara</ustring>`r`n</root>`r`n".Replace('Edicion Camara', "Edici$([char]0xF3)n C$([char]0xE1)mara"),
            (New-Object System.Text.UTF8Encoding $false))

        Get-WorkspaceName $utf8 | Should -Be "Edici$([char]0xF3)n C$([char]0xE1)mara"
    }

    It "extracts the UserName from a CRLF workspace" {
        $lf = Get-Content -LiteralPath "$PSScriptRoot/fixtures/$Dir/UserWorkspace_truncated.xml" -Raw
        $crlf = Join-Path $TestDrive "ws_crlf_$Dir.xml"
        [System.IO.File]::WriteAllText($crlf, ($lf -replace "`r?`n", "`r`n"))
        # Guard: the conversion actually produced CRLF, so this can't pass vacuously.
        [System.IO.File]::ReadAllText($crlf) | Should -Match "`r`n"

        $name = Get-WorkspaceName $crlf
        $name | Should -Be 'LGG - Single monitor'
        $name | Should -Not -Match "`r"
    }
}

# The workspace payload ships LF (one source of truth in the repo) but Premiere
# authors these CRLF on Windows, so the installer re-ends them on delivery. Pure
# .NET file I/O, so these run on any host - no Windows runner needed.
Describe "ConvertTo-CrlfFile (Premiere <Version>)" -ForEach $PremiereVersions {
    BeforeEach {
        $script:src = "$PSScriptRoot/fixtures/$Dir/UserWorkspace_truncated.xml"
        $script:target = Join-Path $TestDrive "convert_$Dir.xml"
        Copy-Item -LiteralPath $script:src -Destination $script:target -Force
    }

    It "re-ends an LF payload as CRLF" {
        # Guard: the fixture really is the LF shape this is meant to convert.
        [System.IO.File]::ReadAllText($src) | Should -Not -Match "`r"

        ConvertTo-CrlfFile $target
        $out = [System.IO.File]::ReadAllText($target)
        $out | Should -Match "`r`n"
        # Every newline converted, none left bare.
        ([regex]::Matches($out, "(?<!`r)`n")).Count | Should -Be 0
    }

    It "changes only the line endings" {
        ConvertTo-CrlfFile $target
        ([System.IO.File]::ReadAllText($target) -replace "`r`n", "`n") |
            Should -BeExactly ([System.IO.File]::ReadAllText($src))
    }

    It "introduces no BOM" {
        ConvertTo-CrlfFile $target
        $bytes = [System.IO.File]::ReadAllBytes($target)
        # EF BB BF would make Premiere's parser choke on the declaration.
        @($bytes[0], $bytes[1], $bytes[2]) -join ',' | Should -Not -Be '239,187,191'
        $bytes[0] | Should -Be ([byte][char]'<')
    }

    It "is idempotent - a second pass is byte-identical" {
        ConvertTo-CrlfFile $target
        $once = [System.IO.File]::ReadAllBytes($target)
        ConvertTo-CrlfFile $target
        [System.IO.File]::ReadAllBytes($target) | Should -Be $once
    }

    It "leaves the workspace name readable after conversion" {
        ConvertTo-CrlfFile $target
        Get-WorkspaceName $target | Should -Be 'LGG - Single monitor'
    }
}

# Set-PrefNode is the engine under Set-PremierePro. Its "no edit = no
# corruption" contract (a missing node must leave the file byte-for-byte
# untouched) is the safety guarantee the rest of the prefs handling relies on.
Describe "Set-PrefNode" {
    BeforeEach {
        $script:prefs = Join-Path $TestDrive "node-prefs"
        # Write without a BOM, matching what Premiere actually authors.
        [System.IO.File]::WriteAllText(
            $prefs, "<root><x>old</x></root>", (New-Object System.Text.UTF8Encoding $false))
    }

    It "replaces a present node's value and reports success" {
        Set-PrefNode $prefs "x" "new" | Should -BeTrue
        Get-Content $prefs -Raw | Should -Match '<x>new</x>'
    }

    # Enforces the "do not reimplement with Set-Content/Out-File" note on
    # Set-PrefNode: those would normalise the WHOLE file as a side effect of
    # changing one value. Uses a CRLF file because that is the shape a
    # normaliser would visibly destroy, and because it proves the installer
    # cannot be what re-ended a user's prefs.
    It "preserves the file's line endings" {
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($prefs, "<root>`r`n<x>old</x>`r`n</root>`r`n", $enc)

        Set-PrefNode $prefs "x" "new" | Should -BeTrue

        $out = [System.IO.File]::ReadAllText($prefs)
        $out | Should -BeExactly "<root>`r`n<x>new</x>`r`n</root>`r`n"
        ([regex]::Matches($out, "(?<!`r)`n")).Count | Should -Be 0 -Because 'no ending may be downgraded to a bare LF'
    }

    It "returns false and leaves the file byte-for-byte untouched when the node is absent" {
        $before = (Get-FileHash $prefs -Algorithm SHA256).Hash
        Set-PrefNode $prefs "missing" "new" | Should -BeFalse
        (Get-FileHash $prefs -Algorithm SHA256).Hash | Should -Be $before
    }
}

# Set-ForcedPrefNode is Set-PrefNode plus creation, for the nodes whose Premiere
# default is wrong for us (a fresh install has never written them). Mirrors
# force_pref_node in load-mac.sh.
Describe "Set-ForcedPrefNode" {
    BeforeEach {
        $script:prefs = Join-Path $TestDrive "forced-prefs"
        $script:enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText(
            $prefs, "<PremiereData>`n<Properties Version=`"1`">`n<x>old</x>`n</Properties>`n</PremiereData>`n", $enc)
    }

    It "edits a present node in place, like Set-PrefNode" {
        Set-ForcedPrefNode $prefs "x" "new" | Should -BeTrue
        Get-Content $prefs -Raw | Should -Match '<x>new</x>'
    }

    It "creates an absent node inside the Properties block" {
        Set-ForcedPrefNode $prefs "y" "yes" | Should -BeTrue
        Get-Content $prefs -Raw | Should -Match '<y>yes</y>'
        { [xml](Get-Content $prefs -Raw) } | Should -Not -Throw
    }

    It "is idempotent: the created node is edited in place next time" {
        Set-ForcedPrefNode $prefs "y" "yes" | Should -BeTrue
        $hash1 = (Get-FileHash $prefs -Algorithm SHA256).Hash
        Set-ForcedPrefNode $prefs "y" "yes" | Should -BeTrue
        (Get-FileHash $prefs -Algorithm SHA256).Hash | Should -Be $hash1
    }

    # The node it authors is the only line ending this script writes into the
    # prefs, and Premiere writes that file LF on Windows too.
    It "writes its new node with a bare LF and no BOM" {
        Set-ForcedPrefNode $prefs "y" "yes" | Should -BeTrue
        $out = [System.IO.File]::ReadAllText($prefs)
        $out | Should -Match "`n`t`t`t<y>yes</y>"
        ([System.IO.File]::ReadAllBytes($prefs))[0] | Should -Be 0x3C
    }

    It "returns false and changes nothing when there is no Properties block" {
        [System.IO.File]::WriteAllText($prefs, "<root><x>old</x></root>", $enc)
        $before = (Get-FileHash $prefs -Algorithm SHA256).Hash
        Set-ForcedPrefNode $prefs "y" "yes" | Should -BeFalse
        (Get-FileHash $prefs -Algorithm SHA256).Hash | Should -Be $before
    }
}

# Test-AppInstalled gates the non-winget installers, so a false negative
# reinstalls Flicker Free and Mister Horse on every single run. Uninstall
# entries live in a per-machine 64-bit view, a per-machine 32-bit view and a
# per-user one, and a 32-bit PowerShell host reads HKLM:\SOFTWARE through WOW64
# redirection - both per-machine provider paths collapse onto the 32-bit view -
# so the lookup has to name the view. Registry-backed end to end (HKCU: provider
# + reg.exe), so it is Windows-only: skipped at Describe level because even the
# BeforeAll probe needs the HKCU drive.
Describe "Test-AppInstalled" -Skip:(-not $IsWindowsHost) {
    BeforeAll {
        # A per-user entry needs no elevation and isn't WOW64-redirected, so it
        # exercises the reg.exe output parsing on any runner, elevated or not.
        $script:probeName = 'ZZ Load-Win Pester Probe'
        $script:userKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ZZLoadWinPesterProbe'
        New-Item -Path $script:userKey -Force | Out-Null
        New-ItemProperty -Path $script:userKey -Name DisplayName -Value $script:probeName `
            -PropertyType String -Force | Out-Null
    }

    AfterAll {
        Remove-Item -LiteralPath $script:userKey -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "finds an uninstall entry by its DisplayName" {
        Test-AppInstalled ([regex]::Escape($probeName)) | Should -BeTrue
    }

    It "reports a DisplayName that matches nothing as absent" {
        Test-AppInstalled 'ZZ No Such Application 4f2c9e' | Should -BeFalse
    }

    # The regression itself: a 64-bit-only per-machine entry (Flicker Free
    # registers one) read from a 32-bit host, which is where the redirected
    # provider paths used to report "not installed" forever. Writing under HKLM
    # needs elevation, so this runs on CI and on an elevated dev shell, and
    # skips otherwise.
    It "finds a 64-bit-only per-machine entry from a 32-bit host" -Skip:(-not ($IsElevatedHost -and $Ps32Available)) {
        $key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ZZLoadWinPesterProbe64'
        $name = 'ZZ Load-Win Pester Probe 64'
        # /reg:64 puts it in the native view only, invisible to a redirected reader.
        reg.exe add $key /v DisplayName /t REG_SZ /d $name /reg:64 /f | Out-Null
        try {
            $child = Join-Path $TestDrive 'probe32.ps1'
            $src = (Resolve-Path "$PSScriptRoot/../src/load-win.ps1").Path
            Set-Content -LiteralPath $child -Encoding Ascii -Value @"
`$env:LOAD_LIB = '1'
. '$src'
`$env:LOAD_LIB = `$null
if (Test-AppInstalled '$name') { 'FOUND' } else { 'MISSING' }
"@
            $ps32 = "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
            (& $ps32 -NoProfile -ExecutionPolicy Bypass -File $child) |
                Should -Be 'FOUND' -Because 'a 32-bit host must still read the 64-bit view'
        }
        finally {
            reg.exe delete $key /f /reg:64 | Out-Null
        }
    }
}

# Find-UvExe picks the uv that the uv-tool installs are invoked through. It has
# to return exactly one path: an array is truthy, so it would skip the fallback
# list below it, and it can't be invoked with & either. Resolves uv.exe through
# Windows PATH and winget shim layouts (';' separator, %LOCALAPPDATA% shims), so
# the semantics under test only exist on Windows.
Describe "Find-UvExe" -Skip:(-not $IsWindowsHost) {
    BeforeAll {
        function New-FakeUv($dir) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $exe = Join-Path $dir 'uv.exe'
            Set-Content -LiteralPath $exe -Value '' -Encoding Ascii
            return $exe
        }
    }

    BeforeEach {
        $script:saved = @{
            Path         = $env:Path
            LocalAppData = $env:LOCALAPPDATA
            ProgramW6432 = $env:ProgramW6432
            UserProfile  = $env:USERPROFILE
        }
        $script:box = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        # Every candidate starts pointing at an empty sandbox, so each test opts in to
        # only the location it is about.
        $env:Path = "$env:WINDIR\System32"
        $env:LOCALAPPDATA = Join-Path $script:box 'localappdata'
        $env:ProgramW6432 = Join-Path $script:box 'programfiles64'
        $env:USERPROFILE = Join-Path $script:box 'userprofile'
    }

    AfterEach {
        $env:Path = $script:saved.Path
        $env:LOCALAPPDATA = $script:saved.LocalAppData
        $env:ProgramW6432 = $script:saved.ProgramW6432
        $env:USERPROFILE = $script:saved.UserProfile
    }

    It "returns one path, not an array, when uv.exe sits in two PATH directories" {
        $first = New-FakeUv (Join-Path $box 'binA')
        $second = New-FakeUv (Join-Path $box 'binB')
        $env:Path = "$(Split-Path $first);$(Split-Path $second);$env:Path"
        $uv = Find-UvExe
        $uv | Should -BeOfType [string] -Because 'an array skips the fallbacks and cannot be invoked with &'
        $uv | Should -Be $first -Because 'PATH order decides, matching the copy the shell itself would run'
    }

    It "falls back to the winget user-scope shim when PATH has no uv" {
        $shim = New-FakeUv (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
        Find-UvExe | Should -Be $shim
    }

    It "prefers the Links shim over the package directory" {
        $shim = New-FakeUv (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links')
        New-FakeUv (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\astral-sh.uv_test') | Out-Null
        Find-UvExe | Should -Be $shim
    }

    # $env:ProgramFiles reads as the x86 directory under a 32-bit host, which
    # would never match a machine-scope install; ProgramW6432 names the 64-bit
    # one from both.
    It "resolves the machine-scope candidate under the 64-bit Program Files" {
        $machine = New-FakeUv (Join-Path $env:ProgramW6432 'WinGet\Links')
        Find-UvExe | Should -Be $machine
    }

    It "returns nothing when uv is installed nowhere" {
        Find-UvExe | Should -BeNullOrEmpty
    }
}

# Set-AudacityPref is the engine behind the Audacity settings. audacity.cfg is a
# wxFileConfig INI, so it needs its own section/key handling - these cover the
# shapes it meets in the wild.
Describe "Set-AudacityPref" {
    BeforeAll {
        $env:LOAD_LIB = "1"
        . "$PSScriptRoot\..\src\load-win.ps1"
        $env:LOAD_LIB = $null

        # Read/write the fixture bytes directly, bypassing Set-Content's newline
        # handling, so the CRLF cases are genuinely CRLF on any host and the
        # assertions compare the file's real bytes.
        function script:Write-Cfg($path, $text) { [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false)) }
        function script:Read-Cfg($path) { [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding $false)) }
    }
    BeforeEach { $script:cfg = Join-Path $TestDrive "audacity.cfg" }

    It "replaces an existing key in place" {
        Write-Cfg $cfg "PrefsVersion=1.1.1r1`r`n[GUI]`r`nTheme=classic`r`nDefaultViewModeChoiceNew=Waveform`r`n[Tracks]`r`nAutoScroll=1`r`n"
        Set-AudacityPref $cfg 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Should -BeTrue
        Read-Cfg $cfg | Should -Be "PrefsVersion=1.1.1r1`r`n[GUI]`r`nTheme=classic`r`nDefaultViewModeChoiceNew=Spectrogram`r`n[Tracks]`r`nAutoScroll=1`r`n"
    }

    It "adds the key when the section exists without it" {
        Write-Cfg $cfg "[GUI]`r`nTheme=classic`r`n[Tracks]`r`nAutoScroll=1`r`n"
        Set-AudacityPref $cfg 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Should -BeTrue
        Read-Cfg $cfg | Should -Be "[GUI]`r`nDefaultViewModeChoiceNew=Spectrogram`r`nTheme=classic`r`n[Tracks]`r`nAutoScroll=1`r`n"
    }

    It "appends the section when it is absent" {
        Write-Cfg $cfg "PrefsVersion=1.1.1r1`r`n[Tracks]`r`nAutoScroll=1`r`n"
        Set-AudacityPref $cfg 'Spectrum' 'MaxFreq' '48000' | Should -BeTrue
        Read-Cfg $cfg | Should -Be "PrefsVersion=1.1.1r1`r`n[Tracks]`r`nAutoScroll=1`r`n[Spectrum]`r`nMaxFreq=48000`r`n"
    }

    # The fresh-install path: Audacity writes no cfg (and no %APPDATA%\audacity)
    # until it first quits, so the helper must author both or the setting would
    # only ever land on a second run of the installer.
    It "creates the file and its directory when neither exists" {
        $fresh = Join-Path $TestDrive "fresh\audacity\audacity.cfg"
        Set-AudacityPref $fresh 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Should -BeTrue
        Read-Cfg $fresh | Should -Be "[GUI]`r`nDefaultViewModeChoiceNew=Spectrogram`r`n"
    }

    # Keys are only unique within a section - [Tracks] and [GUI] can both hold a
    # DefaultViewModeChoiceNew - so a file-wide match would write the wrong one.
    It "only edits the named section" {
        Write-Cfg $cfg "[Tracks]`r`nDefaultViewModeChoiceNew=Waveform`r`n[GUI]`r`nDefaultViewModeChoiceNew=Waveform`r`n"
        Set-AudacityPref $cfg 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Should -BeTrue
        Read-Cfg $cfg | Should -Be "[Tracks]`r`nDefaultViewModeChoiceNew=Waveform`r`n[GUI]`r`nDefaultViewModeChoiceNew=Spectrogram`r`n"
    }

    # Audacity writes this file CRLF on Windows and LF on macOS (wxTextFile uses
    # native endings). A normalising rewrite is what would silently churn every
    # line of the user's cfg, so both shapes must survive an edit untouched.
    It "preserves CRLF endings" {
        Write-Cfg $cfg "[GUI]`r`nTheme=classic`r`n"
        Set-AudacityPref $cfg 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Should -BeTrue
        $out = Read-Cfg $cfg
        $out | Should -Be "[GUI]`r`nDefaultViewModeChoiceNew=Spectrogram`r`nTheme=classic`r`n"
        ([regex]::Matches($out, "(?<!`r)`n")).Count | Should -Be 0
    }

    It "preserves LF endings" {
        Write-Cfg $cfg "[GUI]`nTheme=classic`n"
        Set-AudacityPref $cfg 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Should -BeTrue
        $out = Read-Cfg $cfg
        $out | Should -Be "[GUI]`nDefaultViewModeChoiceNew=Spectrogram`nTheme=classic`n"
        $out | Should -Not -Match "`r"
    }

    It "is idempotent" {
        Write-Cfg $cfg "PrefsVersion=1.1.1r1`r`n[GUI]`r`nTheme=classic`r`n"
        Set-AudacityPref $cfg 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Out-Null
        $first = Read-Cfg $cfg
        Set-AudacityPref $cfg 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Out-Null
        Read-Cfg $cfg | Should -Be $first
    }

    # Windows PowerShell 5.1's `-Encoding UTF8` writes a BOM, which would glue
    # itself to the first key name in the file. Set-AudacityPref goes byte-level
    # precisely to avoid that, so pin it.
    It "introduces no BOM" {
        Set-AudacityPref $cfg 'GUI' 'DefaultViewModeChoiceNew' 'Spectrogram' | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($cfg)
        @($bytes[0], $bytes[1], $bytes[2]) | Should -Not -Be @(0xEF, 0xBB, 0xBF)
    }

    # The two platform scripts must enforce the same Audacity settings; the whole
    # point of the shared "/Section/Key=Value" shape is that the lists can be
    # compared verbatim. Guards against one side being edited alone.
    It "enforces the same prefs as load-mac.sh" {
        $win = Select-String -Path "$PSScriptRoot\..\src\load-win.ps1" -Pattern '^\s*"([A-Za-z]+/[A-Za-z]+=[^"]+)"' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
        $mac = Select-String -Path "$PSScriptRoot\..\src\load-mac.sh" -Pattern '^\s*"([A-Za-z]+/[A-Za-z]+=[^"]+)"' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
        $win | Should -Not -BeNullOrEmpty
        ($win -join ',') | Should -Be ($mac -join ',')
    }
}

# Taskbar and system tray.
#
# Four DWORDs across two keys, plus the tray promotion. MMTaskbarEnabled is the
# one with teeth: it is ABSENT on a machine where the setting was never touched
# and reads as ON in that state, so "absent" must NOT count as applied -
# otherwise this can never fix a machine somebody switched off.
Describe "Test-Taskbar" {
    It "is true once every value matches" {
        Mock Get-RegValue {
            switch ($name) {
                "TaskbarAl" { 1 }
                "MMTaskbarEnabled" { 1 }
                "ShowTaskViewButton" { 0 }
                "SearchboxTaskbarMode" { 3 }
                default { $null }
            }
        }
        Test-Taskbar | Should -BeTrue
    }
    It "is false while the icons are left-aligned" {
        Mock Get-RegValue { if ($name -eq "TaskbarAl") { 0 } elseif ($name -eq "ShowTaskViewButton") { 0 } elseif ($name -eq "SearchboxTaskbarMode") { 3 } else { 1 } }
        Test-Taskbar | Should -BeFalse
    }
    It "is false while the Task view button is shown" {
        Mock Get-RegValue { if ($name -eq "ShowTaskViewButton") { 1 } elseif ($name -eq "SearchboxTaskbarMode") { 3 } else { 1 } }
        Test-Taskbar | Should -BeFalse
    }
    It "is false while search is anything but icon and label" {
        Mock Get-RegValue { if ($name -eq "SearchboxTaskbarMode") { 2 } elseif ($name -eq "ShowTaskViewButton") { 0 } else { 1 } }
        Test-Taskbar | Should -BeFalse
    }
    # Absent reads as ON in the UI, but nothing can tell "on by default" from
    # "off" without the value, so it must be written either way.
    It "is false when MMTaskbarEnabled has never been written" {
        Mock Get-RegValue {
            switch ($name) {
                "TaskbarAl" { 1 }
                "MMTaskbarEnabled" { $null }
                "ShowTaskViewButton" { 0 }
                "SearchboxTaskbarMode" { 3 }
                default { $null }
            }
        }
        Test-Taskbar | Should -BeFalse
    }
}

# The tray entry is keyed by a per-app id that differs on every machine, so
# everything here turns on finding it by ExecutablePath instead. The probe key is
# drive-free: Join-Path resolves HKCU:, and there is no such drive on a Mac.
#
# The Get-RegValue mocks are inline rather than shared: a mock body runs later,
# in its own scope, so a parameter of some set-up helper is long gone by then.
Describe "Test-TrayIcon" {
    BeforeAll { $Probe = "probe-tray" }
    BeforeEach {
        Mock Test-Path { $true }
        Mock Get-ChildItem {
            @(
                [pscustomobject] @{ PSChildName = "111" }
                [pscustomobject] @{ PSChildName = "8003706424901561507" }
                [pscustomobject] @{ PSChildName = "333" }
            )
        }
    }

    It "finds the OneDrive entry by executable, not by key name" {
        Mock Get-RegValue {
            if ($path -match "8003706424901561507") { "C:\Users\T\AppData\Local\Microsoft\OneDrive\OneDrive.exe" }
            else { "C:\Windows\System32\other.exe" }
        }
        $found = @(Get-TrayIconKeyPath "OneDrive.exe" $Probe)
        $found.Count | Should -Be 1
        $found[0] | Should -Match "8003706424901561507"
    }

    It "is true when OneDrive is not promoted" {
        Mock Get-RegValue {
            if ($name -eq "ExecutablePath") {
                if ($path -match "8003706424901561507") { "C:\Users\T\AppData\Local\Microsoft\OneDrive\OneDrive.exe" }
                else { "C:\Windows\System32\other.exe" }
            }
            else { 0 }
        }
        Test-TrayIcon "OneDrive.exe" $Probe | Should -BeTrue
    }

    It "is false while OneDrive is promoted to the tray" {
        Mock Get-RegValue {
            if ($name -eq "ExecutablePath") {
                if ($path -match "8003706424901561507") { "C:\Users\T\AppData\Local\Microsoft\OneDrive\OneDrive.exe" }
                else { "C:\Windows\System32\other.exe" }
            }
            else { 1 }
        }
        Test-TrayIcon "OneDrive.exe" $Probe | Should -BeFalse
    }

    # An app that has never shown a tray icon has no entry, so there is nothing
    # to hide - which is applied, not broken.
    It "is true when there is no NotifyIconSettings key at all" {
        Mock Test-Path { $false }
        Test-TrayIcon "OneDrive.exe" $Probe | Should -BeTrue
    }
}

# The state check gates the write, so a re-run does not bounce the shell again.
Describe "Set-Taskbar" {
    It "does nothing, and asks for no restart, once it is already applied" {
        Mock Test-Taskbar { $true }
        Mock Test-TrayIcon { $true }
        Set-Taskbar | Should -BeFalse
    }
}
