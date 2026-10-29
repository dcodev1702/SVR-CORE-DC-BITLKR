# Make PowerShell 7 (pwsh) the command line of Windows Server Core 2025: SConfig still opens at sign-in, and SConfig option 15
# (Exit to command line) opens pwsh instead of Windows PowerShell 5.1. Also makes sure pwsh is on the machine PATH.
# Run ON the Server Core computer, elevated, in Windows PowerShell 5.1 or PowerShell 7. ASCII-only.
#
# How: the Server Core sign-in shell (servercoreshelllaunch.bat) runs  powershell.exe -noExit -Command "Invoke-SConfigLogon",
# so option 15 returns to that Windows PowerShell session. The registry setting behind it
# (HKLM\SOFTWARE\Microsoft\ServerCore\Shell Launcher) is owned by TrustedInstaller and read-only for Administrators, so this
# script leaves it alone and writes the Windows PowerShell all-users profile instead:
#   %SystemRoot%\System32\WindowsPowerShell\v1.0\profile.ps1
# The profile acts only in that sign-in session: when SConfig returns and the 5.1 prompt would appear, it starts pwsh in the
# same window. 'exit' in pwsh ends the session, and the shell launcher starts SConfig again, as 'exit' does today. Other
# Windows PowerShell sessions only evaluate one -match. If pwsh.exe is missing, the 5.1 prompt appears as before.
# Applies from the next sign-in (console or RDP).
#
#   .\Set-PwshDefaultShell.ps1               # shows the change and asks Y/N
#   .\Set-PwshDefaultShell.ps1 -NoConfirm    # automation: no prompt, still logged
#   .\Set-PwshDefaultShell.ps1 -WhatIf       # plan only, nothing changes
#   .\Set-PwshDefaultShell.ps1 -Revert       # remove the profile this script wrote (PATH is left as it is)
# Needs Confirm-Change.ps1 in the same folder. Evidence: <LogDir>\Set-PwshDefaultShell-<time>.log and .csv, plus backups.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # Full path of pwsh.exe. Empty = %ProgramFiles%\PowerShell\7\pwsh.exe (MSI install).
    [ValidatePattern('^$|^[A-Za-z]:\\[^''"*?<>|]+\\pwsh\.exe$')][string]$PwshPath = '',
    # Folder for the transcript, results CSV and backups. Empty = %SystemDrive%\Logs.
    [ValidatePattern('^$|^[A-Za-z]:\\[^"*?<>|]+$')][string]$LogDir = '',
    # Remove the profile this script wrote
    [switch]$Revert,
    [switch]$NoConfirm
)
$ErrorActionPreference = 'Stop'

$ProfilePath     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\profile.ps1'
$WinPowerShell   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ProfileMarker   = '# Managed by Set-PwshDefaultShell.ps1'
# The sign-in session's command line, as servercoreshelllaunch.bat builds it
$SignInPattern   = '(?i)\s-noExit\s+-Command\s+"?Invoke-SConfigLogon"?\s*$'
$SafePwshPath    = '^[A-Za-z]:\\[^''"*?<>|]+\\pwsh\.exe$'
$AllowedPolicies = @('RemoteSigned', 'Unrestricted', 'Bypass')   # policies that run an unsigned local profile
$EnvKeyReg       = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$MinBuild        = 26100   # Windows Server 2025, the build this was verified on
$ProductTypes    = @{ WinNT = 'client'; ServerNT = 'member or standalone server'; LanmanNT = 'domain controller' }

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Status, [string]$Check, [string]$Detail) { $Results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail }) }

# --- Decision logic (no system access) ---

# The all-users Windows PowerShell profile this script writes (ASCII, CRLF).
# pwsh is started with Process.Start, not '&': the host collects a prompt function's output as the prompt text, so '&' would
# pipe pwsh's output into a string. WaitForExit() blocks this host while pwsh runs, so Ctrl+C in pwsh cannot wake it up as a
# second shell on the same console; 'finally' still ends it when pwsh exits.
function Get-ProfileContent([string]$Pwsh) {
    $Lines = @(
        "$ProfileMarker. Remove it with: Set-PwshDefaultShell.ps1 -Revert",
        '# Server Core sign-in session only (powershell.exe -noExit -Command "Invoke-SConfigLogon"): when SConfig option 15',
        '# returns and the Windows PowerShell prompt would appear, start PowerShell 7 in this window instead. ''exit'' in',
        '# PowerShell 7 ends the session, and the Server Core shell launcher starts SConfig again.',
        '# Every other Windows PowerShell session is left alone.',
        ("if ([Environment]::CommandLine -match '{0}' -and (Test-Path -LiteralPath '{1}')) {{" -f $SignInPattern, $Pwsh),
        '    function global:prompt {',
        '        try {',
        ("            `$Psi = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList '{0}', '-NoLogo'" -f $Pwsh),
        '            $Psi.UseShellExecute = $false',
        '            [System.Diagnostics.Process]::Start($Psi).WaitForExit()',
        '        }',
        '        finally { [Environment]::Exit(0) }',
        '    }',
        '}'
    )
    ($Lines -join "`r`n") + "`r`n"
}

# 'None' = already as wanted; 'Write' / 'Remove' = ours to change; 'Foreign' = a profile someone else wrote, leave it alone.
# Untyped on purpose: a [string] parameter turns $null (file absent) into ''.
function Get-ProfilePlan($Current, $Desired) {
    $Exists = $null -ne $Current
    $IsOurs = $Exists -and $Current.StartsWith($ProfileMarker)
    if ($Exists -and -not $IsOurs) { return 'Foreign' }
    if ($null -eq $Desired) { if ($Exists) { return 'Remove' } else { return 'None' } }
    if ($Exists -and $Current -ceq $Desired) { return 'None' }
    return 'Write'
}

function Get-TextSha256([string]$Text) {
    $Sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($Sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('X2') }) } finally { $Sha.Dispose() }
}

# True when a raw PATH string (may hold %vars%) contains Dir, ignoring case and a trailing backslash
function Test-PathHasDir([string]$PathValue, [string]$Dir) {
    $Want = $Dir.TrimEnd('\')
    foreach ($Entry in ($PathValue -split ';')) {
        $Expanded = [Environment]::ExpandEnvironmentVariables($Entry.Trim()).TrimEnd('\')
        if ($Expanded -and $Expanded -ieq $Want) { return $true }
    }
    return $false
}

# --- System access (the test harness replaces these with mocks) ---

$UnderTest = [bool](Get-Variable -Name PwshShellTestHarness -ErrorAction SilentlyContinue)
if (-not $UnderTest) {
    function Test-IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

    function Get-OsInfo {
        $Cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $Po = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions'
        [pscustomobject]@{ ProductName = [string]$Cv.ProductName; InstallationType = [string]$Cv.InstallationType; Build = [int]$Cv.CurrentBuildNumber; Ubr = [int]$Cv.UBR; ProductType = [string]$Po.ProductType }
    }

    # $null when the file does not exist
    function Get-ProfileText {
        if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) { return $null }
        [IO.File]::ReadAllText($ProfilePath)
    }

    function Get-MachinePathRaw {
        $Key = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        [pscustomobject]@{ Value = [string]$Key.GetValue('Path', '', 'DoNotExpandEnvironmentNames'); Kind = [string]$Key.GetValueKind('Path') }
    }

    # Effective policy of Windows PowerShell 5.1 (the profile runs there, not in pwsh)
    function Get-WinPSExecutionPolicy {
        $Out = & $WinPowerShell -NoProfile -NonInteractive -Command Get-ExecutionPolicy
        if ($LASTEXITCODE -ne 0) { return '' }
        ([string]($Out | Select-Object -Last 1)).Trim()
    }

    # Write access for broad groups (Everyone, Authenticated Users, Users, Interactive) on the given files and folders
    function Get-BroadWriters([string[]]$Paths) {
        $Broad = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4')
        $WriteBits = [int]([Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete, ChangePermissions, TakeOwnership')
        $WriteBits = $WriteBits -bor 0x40000000 -bor 0x10000000   # GENERIC_WRITE, GENERIC_ALL
        $Found = New-Object System.Collections.Generic.List[string]
        foreach ($Item in $Paths) {
            foreach ($Ace in (Get-Acl -LiteralPath $Item).Access) {   # files and folders only; FileInfo.GetAccessControl() is missing in PowerShell 7
                if ($Ace.AccessControlType -ne 'Allow') { continue }
                if ([int]$Ace.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
                try { $Sid = $Ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
                if (($Broad -contains $Sid) -and ([int]$Ace.FileSystemRights -band $WriteBits)) { $Found.Add(('{0} on {1} ({2})' -f $Ace.IdentityReference, $Item, $Ace.FileSystemRights)) }
            }
        }
        return , $Found.ToArray()
    }

    # Signature, hash and permissions first; pwsh only runs (to report its version) when its signature is valid
    function Get-PwshInfo([string]$Path) {
        $Info = [pscustomobject]@{ Exists = $false; Signature = ''; Signer = ''; Version = ''; Sha256 = ''; WritableBy = '' }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Info }
        $Info.Exists = $true
        $Sig = Get-AuthenticodeSignature -LiteralPath $Path
        $Info.Signature = [string]$Sig.Status
        if ($Sig.SignerCertificate) { $Info.Signer = [string]$Sig.SignerCertificate.Subject }
        $Info.Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        $Info.WritableBy = (Get-BroadWriters @($Path, (Split-Path -Parent $Path))) -join '; '
        if ($Info.Signature -eq 'Valid') {
            $Out = & $Path -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
            if ($LASTEXITCODE -eq 0) { $Info.Version = ([string]($Out | Select-Object -Last 1)).Trim() }
        }
        return $Info
    }

    function Backup-File([string]$Path, [string]$Destination) { Copy-Item -LiteralPath $Path -Destination $Destination -Force }

    # ASCII content, written as UTF-8 without BOM (identical bytes), so Windows PowerShell 5.1 reads it as written
    function Write-ProfileText([string]$Text) { [IO.File]::WriteAllText($ProfilePath, $Text, (New-Object System.Text.UTF8Encoding($false))) }

    function Remove-ProfileFile { Remove-Item -LiteralPath $ProfilePath -Force }

    function Backup-RegKey([string]$RegPath, [string]$File) {
        $null = & (Join-Path $env:SystemRoot 'System32\reg.exe') export $RegPath $File /y
        if ($LASTEXITCODE -ne 0) { throw "STOP: backup of $RegPath failed (reg.exe exit code $LASTEXITCODE). Nothing was changed." }
    }

    # Keeps the value kind (REG_EXPAND_SZ stays REG_EXPAND_SZ, so %SystemRoot% entries keep working)
    function Set-MachinePathRaw([string]$Value, [string]$Kind) {
        $Key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
        try { $Key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $Key.Close() }
    }
}

# --- Run ---

if (-not $LogDir) { $LogDir = Join-Path $env:SystemDrive 'Logs' }
$Log = Join-Path $LogDir ('Set-PwshDefaultShell-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -Path $LogDir -ItemType Directory -Force -WhatIf:$false | Out-Null
Start-Transcript -LiteralPath "$Log.log" -WhatIf:$false | Out-Null
try {
    # 1. Preconditions and plan - nothing is changed in this block
    if ($UnderTest) {
        foreach ($Name in 'Backup-File', 'Write-ProfileText', 'Remove-ProfileFile', 'Backup-RegKey', 'Set-MachinePathRaw') {
            $Cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
            if (-not $Cmd -or $Cmd.CommandType -ne 'Function' -or $Cmd.Module) { throw "STOP: test harness detected, but $Name is not a mock function. Nothing was changed." }
        }
    }
    else {
        $Helper = Join-Path $PSScriptRoot 'Confirm-Change.ps1'
        if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) { throw "STOP: $Helper is missing. Copy Confirm-Change.ps1 next to this script. Nothing was changed." }
        . $Helper
    }
    if (-not (Test-IsAdmin)) { throw 'STOP: this session is not elevated. Run the script from an elevated PowerShell. Nothing was changed.' }

    $Os = Get-OsInfo
    $TypeName = $ProductTypes[$Os.ProductType]
    if (-not $TypeName) { $TypeName = 'unknown' }
    $TypeText = '{0} ({1})' -f $Os.ProductType, $TypeName
    if ($Os.ProductType -notin 'ServerNT', 'LanmanNT') { throw "STOP: $($Os.ProductName) has ProductType $TypeText. This script is for Windows Server Core. Nothing was changed." }
    if ($Os.InstallationType -ne 'Server Core') { throw "STOP: the installation type is '$($Os.InstallationType)', not 'Server Core'. Only Server Core starts SConfig at sign-in this way. Nothing was changed." }
    if ($Os.Build -lt $MinBuild) { throw "STOP: build $($Os.Build) is older than $MinBuild (Windows Server 2025), the build this script was verified on. Nothing was changed." }
    Add-Result 'PASS' 'Operating system' ('{0} build {1}.{2}, Server Core, ProductType {3}' -f $Os.ProductName, $Os.Build, $Os.Ubr, $TypeText)

    if (-not $PwshPath) { $PwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
    if ($PwshPath -notmatch $SafePwshPath) { throw "STOP: the pwsh path '$PwshPath' has characters that cannot go into the profile safely. Pass -PwshPath with a plain path. Nothing was changed." }
    $PwshDir = Split-Path -Parent $PwshPath

    $PathChange = $false
    if ($Revert) {
        $Desired = $null
        Add-Result 'PASS' 'Mode' 'Revert: remove the profile this script wrote. PATH is left as it is.'
    }
    else {
        $Desired = Get-ProfileContent $PwshPath
        $Pw = Get-PwshInfo $PwshPath
        if (-not $Pw.Exists) { throw "STOP: $PwshPath was not found. Install PowerShell 7 (MSI) first, or pass -PwshPath. Nothing was changed." }
        if ($Pw.Signature -ne 'Valid' -or $Pw.Signer -notmatch '^CN=Microsoft Corporation,') { throw "STOP: the signature of $PwshPath is '$($Pw.Signature)' by '$($Pw.Signer)', expected Valid by Microsoft Corporation. Nothing was changed." }
        if ($Pw.WritableBy) { throw "STOP: non-administrators can write to pwsh: $($Pw.WritableBy). Any user could replace what the profile starts. Fix the permissions first. Nothing was changed." }
        $Ver = $null
        if (-not [version]::TryParse(($Pw.Version -replace '-.*$', ''), [ref]$Ver) -or $Ver.Major -lt 7) { throw "STOP: $PwshPath reports version '$($Pw.Version)', expected 7 or later. Nothing was changed." }
        Add-Result 'PASS' 'pwsh.exe' ('{0}, version {1}, signature Valid (Microsoft Corporation)' -f $PwshPath, $Pw.Version)
        Add-Result 'PASS' 'pwsh.exe SHA-256' $Pw.Sha256
        Add-Result 'PASS' 'pwsh.exe permissions' 'no write access for Everyone, Authenticated Users, Users or Interactive'

        $Policy = Get-WinPSExecutionPolicy
        if ($AllowedPolicies -notcontains $Policy) { throw "STOP: the Windows PowerShell 5.1 execution policy is '$Policy', so it would not run an unsigned profile. Allowed: $($AllowedPolicies -join ', '). Nothing was changed." }
        Add-Result 'PASS' 'Windows PowerShell execution policy' "$Policy (runs local profile scripts)"

        $FolderWriters = (Get-BroadWriters @((Split-Path -Parent $ProfilePath))) -join '; '
        if ($FolderWriters) { throw "STOP: non-administrators can write to the profile folder: $FolderWriters. Fix the permissions first. Nothing was changed." }
        Add-Result 'PASS' 'Profile folder permissions' 'no write access for Everyone, Authenticated Users, Users or Interactive'

        $MachinePath = Get-MachinePathRaw
        if (Test-PathHasDir $MachinePath.Value $PwshDir) { Add-Result 'PASS' 'Machine PATH' "already contains $PwshDir" }
        else {
            $PathChange = $true
            if ($MachinePath.Value.Trim()) { $NewPath = $MachinePath.Value.TrimEnd(';') + ';' + $PwshDir + '\' } else { $NewPath = $PwshDir + '\' }
        }
    }

    $Current = Get-ProfileText
    $ProfilePlan = Get-ProfilePlan $Current $Desired
    if ($ProfilePlan -eq 'Foreign') { throw "STOP: $ProfilePath already exists and was not written by this script. Leaving it alone. Merge the hook by hand or move that file first. Nothing was changed." }
    if ($ProfilePlan -eq 'None') { Add-Result 'PASS' 'Profile' 'already as wanted - nothing to change' }

    if ($ProfilePlan -ne 'None' -or $PathChange) {
        # 2. Confirm - one yellow Y/N for everything below
        if (-not $WhatIfPreference) {
            $Detail = New-Object System.Collections.Generic.List[string]
            $Detail.Add("Computer: $env:COMPUTERNAME, ProductType $TypeText")
            if ($ProfilePlan -eq 'Write' -and $null -eq $Current) { $Detail.Add("File: create $ProfilePath (Windows PowerShell all-users profile)") }
            if ($ProfilePlan -eq 'Write' -and $null -ne $Current) { $Detail.Add("File: replace $ProfilePath (an older version written by this script)") }
            if ($ProfilePlan -eq 'Remove') { $Detail.Add("File: delete $ProfilePath (a copy goes to $LogDir)") }
            if ($PathChange) { $Detail.Add("Machine PATH: append $PwshDir\") }
            if ($Revert) {
                $Detail.Add('Effect: from the next sign-in, SConfig option 15 returns to Windows PowerShell 5.1 again (the Server Core default).')
                $Detail.Add('Undo: .\Set-PwshDefaultShell.ps1')
            }
            else {
                $Detail.Add('Effect: from the next sign-in (console or RDP), SConfig still opens, and option 15 (Exit to command line) opens')
                $Detail.Add("        PowerShell 7 in the same window. 'exit' in PowerShell 7 brings SConfig back. Other Windows PowerShell")
                $Detail.Add('        sessions are not affected. If pwsh.exe is ever missing, option 15 returns to Windows PowerShell 5.1.')
                $Detail.Add("Undo: .\Set-PwshDefaultShell.ps1 -Revert   (or delete $ProfilePath)")
            }
            $Detail.Add('Sessions that are signed in now keep their current behavior until they sign out.')
            if ($Revert) { $Action = "remove the SConfig option 15 -> PowerShell 7 hook on $env:COMPUTERNAME" } else { $Action = "make SConfig option 15 open PowerShell 7 on $env:COMPUTERNAME" }
            Confirm-Change -NoConfirm:$NoConfirm -Action $Action -Detail $Detail.ToArray()
            $ConfirmPreference = 'None'
        }

        # 3. Back up, apply, verify from the system
        if ($ProfilePlan -eq 'Write') {
            if ($PSCmdlet.ShouldProcess($ProfilePath, 'Write the SConfig option 15 -> PowerShell 7 hook')) {
                if ($null -ne $Current) { Backup-File $ProfilePath "$Log-profile.ps1.bak"; Add-Result 'PASS' 'Backup' "$Log-profile.ps1.bak" }
                Write-ProfileText $Desired
                $After = Get-ProfileText
                if ($After -ceq $Desired) { Add-Result 'PASS' 'Profile written' $ProfilePath; Add-Result 'PASS' 'Profile SHA-256' (Get-TextSha256 $After) }
                else { Add-Result 'FAIL' 'Profile written' "$ProfilePath does not hold the expected content after writing it. Delete it, or run -Revert." }
                $FileWriters = (Get-BroadWriters @($ProfilePath)) -join '; '
                if ($FileWriters) { Add-Result 'FAIL' 'Profile permissions' "non-administrators can write to the new profile: $FileWriters. Fix the permissions or delete the file." }
                else { Add-Result 'PASS' 'Profile permissions' 'no write access for Everyone, Authenticated Users, Users or Interactive' }
            }
            else { Add-Result 'PASS' 'Profile' "-WhatIf: would write $ProfilePath" }
        }
        if ($ProfilePlan -eq 'Remove') {
            if ($PSCmdlet.ShouldProcess($ProfilePath, 'Delete the SConfig option 15 -> PowerShell 7 hook')) {
                Backup-File $ProfilePath "$Log-profile.ps1.bak"
                Add-Result 'PASS' 'Backup' "$Log-profile.ps1.bak"
                Remove-ProfileFile
                if ($null -eq (Get-ProfileText)) { Add-Result 'PASS' 'Profile removed' $ProfilePath }
                else { Add-Result 'FAIL' 'Profile removed' "$ProfilePath still exists after deleting it." }
            }
            else { Add-Result 'PASS' 'Profile' "-WhatIf: would delete $ProfilePath" }
        }
        if ($PathChange) {
            if ($PSCmdlet.ShouldProcess("$EnvKeyReg\Path", "Append $PwshDir\")) {
                Backup-RegKey $EnvKeyReg "$Log-Environment.reg"
                Add-Result 'PASS' 'Backup' "$Log-Environment.reg"
                Set-MachinePathRaw $NewPath $MachinePath.Kind
                $AfterPath = Get-MachinePathRaw
                if ((Test-PathHasDir $AfterPath.Value $PwshDir) -and $AfterPath.Kind -eq $MachinePath.Kind) { Add-Result 'PASS' 'Machine PATH set' "appended $PwshDir\ (applies to new sessions)" }
                else { Add-Result 'FAIL' 'Machine PATH set' "PATH does not contain $PwshDir after the change. Restore it from $Log-Environment.reg." }
            }
            else { Add-Result 'PASS' 'Machine PATH' "-WhatIf: would append $PwshDir\" }
        }
    }
}
catch { Add-Result 'FAIL' 'Stopped' $_.Exception.Message }
finally {
    $FailCount = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $WarnCount = @($Results | Where-Object { $_.Status -eq 'WARN' }).Count
    if ($FailCount) { $Summary = 'FAILED'; $Color = 'Red' }
    elseif ($WarnCount) { $Summary = "PASSED with $WarnCount warning(s)"; $Color = 'Yellow' }
    else { $Summary = 'PASSED'; $Color = 'Green' }
    $Results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    Write-Host $Summary -ForegroundColor $Color
    $Results | Export-Csv -LiteralPath "$Log.csv" -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Host "Transcript: $Log.log   Results: $Log.csv"
    $StopArgs = @{}
    if ((Get-Command -Name Stop-Transcript).Parameters.ContainsKey('WhatIf')) { $StopArgs['WhatIf'] = $false }
    try { Stop-Transcript @StopArgs | Out-Null } catch { }
}
if ($FailCount) { exit 1 }
