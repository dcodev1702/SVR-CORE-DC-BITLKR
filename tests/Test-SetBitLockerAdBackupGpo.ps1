# Unit tests for scripts\Set-BitLockerAdBackupGpo.ps1 with mocks: nothing in AD, SYSVOL or on this computer is read or changed
# by the script under test. Also checks the settings file against the README and the real VolumeEncryption.admx.
# Windows PowerShell 5.1 and PowerShell 7. ASCII-only.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SetBitLockerAdBackupGpo.ps1
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SetBitLockerAdBackupGpo.ps1
param(
    [string]$ScriptPath = '',    # empty = ..\scripts\Set-BitLockerAdBackupGpo.ps1
    [string]$AdmxPath = '',      # empty = %SystemRoot%\PolicyDefinitions\VolumeEncryption.admx
    [string]$ReadmePath = ''     # empty = ..\README.md
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $ScriptPath) { $ScriptPath = Join-Path $Root 'scripts\Set-BitLockerAdBackupGpo.ps1' }
if (-not $AdmxPath) { $AdmxPath = Join-Path $env:SystemRoot 'PolicyDefinitions\VolumeEncryption.admx' }
if (-not $ReadmePath) { $ReadmePath = Join-Path $Root 'README.md' }
foreach ($P in $ScriptPath, $AdmxPath, $ReadmePath) { if (-not (Test-Path -LiteralPath $P -PathType Leaf)) { throw "STOP: $P not found." } }
$ScriptDir = Split-Path -Parent $ScriptPath
$SettingsFile = Join-Path $ScriptDir 'BitLockerAdBackupGpo.json'
$Work = Join-Path ([IO.Path]::GetTempPath()) ('GpoScriptTest-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $Work -ItemType Directory | Out-Null
Write-Host ('Edition {0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)

$Failures = New-Object System.Collections.Generic.List[string]
$Checks = 0
function Assert-That([bool]$Ok, [string]$Name, [string]$Why = '') {
    $script:Checks++
    if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green } else { $Failures.Add("$Name : $Why"); Write-Host "FAIL  $Name : $Why" -ForegroundColor Red }
}

# --- 0. Parse and ASCII checks, in this edition ---
foreach ($File in @($ScriptPath, (Join-Path $ScriptDir 'Confirm-Change.ps1'), $PSCommandPath)) {
    $Tokens = $null; $Errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($File, [ref]$Tokens, [ref]$Errors)
    $NonAscii = @([IO.File]::ReadAllBytes($File) | Where-Object { $_ -gt 127 }).Count
    Assert-That ((@($Errors).Count -eq 0) -and $NonAscii -eq 0) "parse + ASCII: $(Split-Path -Leaf $File)" "$(@($Errors).Count) parse error(s), $NonAscii non-ASCII byte(s)"
}
$SettingsText = [IO.File]::ReadAllText($SettingsFile)
Assert-That (@([IO.File]::ReadAllBytes($SettingsFile) | Where-Object { $_ -gt 127 }).Count -eq 0) 'ASCII: BitLockerAdBackupGpo.json'
$Settings = $SettingsText | ConvertFrom-Json
$AdmxText = [IO.File]::ReadAllText($AdmxPath)

# --- 1. The settings file says what README section 3 says ---
$Readme = [IO.File]::ReadAllText($ReadmePath).Replace("`r`n", "`n")
$Block = [regex]::Match($Readme, '(?s)```powershell\n(& \{\n.*?\n\})\n```').Groups[1].Value
Assert-That ([bool]$Block) 'README: GPO block found'
$RGpo = [regex]::Match($Block, '\$GpoName\s*=\s*''([^'']+)''').Groups[1].Value
$ROu = [regex]::Match($Block, '\$OuName\s*=\s*''([^'']+)''').Groups[1].Value
$RComment = [regex]::Match($Block, 'New-GPO -Name \$GpoName -Comment ''([^'']+)''').Groups[1].Value
$RPrefixes = @([regex]::Matches([regex]::Match($Block, 'foreach \(\$prefix in ([^)]+)\)').Groups[1].Value, '''([A-Z]+)''') | ForEach-Object { $_.Groups[1].Value })
$RValues = [ordered]@{}
foreach ($Mt in [regex]::Matches([regex]::Match($Block, '(?s)\$values = \[ordered\]@\{(.*?)\n\s*\}').Groups[1].Value, '(?m)^\s*(\w+)\s*=\s*(\d+)')) { $RValues[$Mt.Groups[1].Value] = [long]$Mt.Groups[2].Value }
Assert-That ($RGpo -ceq $Settings.GpoName) 'README = settings: GpoName' "README '$RGpo', settings '$($Settings.GpoName)'"
Assert-That ($ROu -ceq $Settings.OuName) 'README = settings: OuName' "README '$ROu', settings '$($Settings.OuName)'"
Assert-That ($RComment -ceq $Settings.GpoComment) 'README = settings: GpoComment' "README '$RComment'"
Assert-That (($RPrefixes -join ',') -ceq (@($Settings.Prefixes) -join ',')) 'README = settings: drive types' "README '$($RPrefixes -join ',')', settings '$(@($Settings.Prefixes) -join ',')'"
$SValues = @($Settings.Values.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join ','
$RValuesText = @($RValues.Keys | ForEach-Object { '{0}={1}' -f $_, $RValues[$_] }) -join ','
Assert-That ($RValuesText -ceq $SValues) 'README = settings: 8 values in the same order' "README '$RValuesText' / settings '$SValues'"
$MethodNames = @{ OS = 'EncryptionMethodWithXtsOs'; FDV = 'EncryptionMethodWithXtsFdv'; RDV = 'EncryptionMethodWithXtsRdv' }
$RMethods = @([regex]::Matches([regex]::Match($Block, '\$methods = \[ordered\]@\{([^}]*)\}').Groups[1].Value, '(\w+)\s*=\s*(\d+)') | ForEach-Object { '{0}={1}' -f $_.Groups[1].Value, $_.Groups[2].Value }) -join ','
$SMethods = @($Settings.EncryptionMethods.PSObject.Properties | ForEach-Object { '{0}={1}' -f $MethodNames[$_.Name], $_.Value }) -join ','
Assert-That ($RMethods -ceq $SMethods) 'README = settings: encryption methods' "README '$RMethods' / settings '$SMethods'"

# --- 2. Harness: real confirmation gate, mocked system access ---
$Global:GpoScriptTestHarness = $true
. (Join-Path $ScriptDir 'Confirm-Change.ps1')

$OuDn = 'OU=JMSC-WDAC-WRKSTNS,DC=skynet-home,DC=local'
$GpoId = [guid]'0a1b2c3d-1111-2222-3333-444455556666'
$Desired = [ordered]@{}
foreach ($P in $Settings.Prefixes) { foreach ($Pr in $Settings.Values.PSObject.Properties) { $Desired["$P$($Pr.Name)"] = [long]$Pr.Value } }
foreach ($P in $Settings.Prefixes) { $Desired[$MethodNames[$P]] = [long]$Settings.EncryptionMethods.$P }

function Test-Interactive { $Global:M.Interactive }
function Read-Host { param([string]$Prompt) $Global:M.ReadHostCalls++; if ($Global:M.Answers.Count -gt 0) { $Global:M.Answers.Dequeue() } else { '' } }
function Test-IsAdmin { $Global:M.Admin }
function Get-SettingsText { param([string]$Path) $Global:M.SettingsText }
function Import-GpModules { if ($Global:M.ModulesFail) { throw "The specified module 'GroupPolicy' was not loaded because no valid module file was found." }; 'GroupPolicy (mock), ActiveDirectory (mock)' }
function Test-DomainJoined { $Global:M.Joined }
function Get-DomainInfo { if ($Global:M.NoDc) { throw 'Unable to find a default server with Active Directory Web Services running.' }; [pscustomobject]@{ DNSRoot = 'skynet-home.local'; DistinguishedName = 'DC=skynet-home,DC=local' } }
function Get-AdmxSource { param([string]$DnsRoot) $Global:M.Admx }
function Find-OuByName { param([string]$Name, [string]$SearchBase) $Global:M.OuQueries.Add("$Name|$SearchBase"); $Global:M.Ous }
function Get-OuComputerNames { param([string]$Dn) $Global:M.Computers }
function Find-GpoByName { param([string]$Name) $Global:M.Gpos }
function Get-GpoFveValues { param([guid]$Id) $Copy = @{}; foreach ($K in $Global:M.Values.Keys) { $Copy[$K] = $Global:M.Values[$K] }; $Copy }
function Get-GpoLinkState { param([string]$Target, [guid]$Id) $Global:M.Link }
function Get-FveCompetitors { param([string]$Target, [guid]$ExcludeId) $Global:M.Competitors }
function Get-GpoEvidence { param([guid]$Id, [string]$DnsRoot) [pscustomobject]@{ GpoStatus = 'AllSettingsEnabled'; DSVersion = $Global:M.DsVersion; SysvolVersion = $Global:M.SysvolVersion; RegistryPol = '\\skynet-home.local\SYSVOL\x\Registry.pol'; Sha256 = $Global:M.PolHash } }
function Backup-ExistingGpo { [CmdletBinding()] param([guid]$Id, [string]$Path) $Global:M.Calls.Add('Backup'); 'backup-1' }
function New-EscrowGpo { [CmdletBinding()] param([string]$Name, [string]$Comment)
    $Global:M.Calls.Add('NewGpo'); $Global:M.Created = "$Name|$Comment"
    $G = [pscustomobject]@{ Id = $GpoId; DisplayName = $Name; GpoStatus = 'AllSettingsEnabled' }; $Global:M.Gpos = @($G); $G }
function Set-EscrowValue { [CmdletBinding()] param([guid]$Id, [string]$Name, [long]$Value)
    $Global:M.Calls.Add('Set'); $Global:M.SetLog.Add("$Name=$Value")
    if (-not $Global:M.SetIsNoop) { $Global:M.Values[$Name] = [pscustomobject]@{ Type = 'DWord'; Value = [int]$Value } } }
function New-EscrowLink { [CmdletBinding()] param([guid]$Id, [string]$Target) $Global:M.Calls.Add('NewLink'); $Global:M.LinkTarget = $Target; if (-not $Global:M.LinkIsNoop) { $Global:M.Link = 'Enabled' } }
function Enable-EscrowLink { [CmdletBinding()] param([guid]$Id, [string]$Target) $Global:M.Calls.Add('EnableLink'); if (-not $Global:M.LinkIsNoop) { $Global:M.Link = 'Enabled' } }

function Reset-Mock {
    $Global:M = @{
        Interactive = $false; Answers = New-Object System.Collections.Queue; ReadHostCalls = 0
        Admin = $true; SettingsText = $SettingsText; ModulesFail = $false; Joined = $true; NoDc = $false
        Admx = [pscustomobject]@{ Path = $AdmxPath; Text = $AdmxText; CentralStore = 'Used' }
        Ous = @($OuDn); OuQueries = New-Object System.Collections.Generic.List[string]; Computers = @('WIN11-PAW-WDAC')
        Gpos = @(); Values = @{}; Link = 'None'; Competitors = @()
        DsVersion = 25; SysvolVersion = 25; PolHash = ('AB' * 32)
        Calls = New-Object System.Collections.Generic.List[string]; SetLog = New-Object System.Collections.Generic.List[string]
        Created = ''; LinkTarget = ''; SetIsNoop = $false; LinkIsNoop = $false
    }
}
# The GPO exists, holds every desired value and is linked
function Set-Compliant {
    $Global:M.Gpos = @([pscustomobject]@{ Id = $GpoId; DisplayName = $Settings.GpoName; GpoStatus = 'AllSettingsEnabled' })
    foreach ($K in $Desired.Keys) { $Global:M.Values[$K] = [pscustomobject]@{ Type = 'DWord'; Value = [int]$Desired[$K] } }
    $Global:M.Link = 'Enabled'
}
function Set-Answers([string[]]$List) { $Global:M.Interactive = $true; foreach ($A in $List) { $Global:M.Answers.Enqueue($A) } }
# Settings text with one change applied to the parsed object
function Edit-Settings([scriptblock]$Change) { $O = $SettingsText | ConvertFrom-Json; & $Change $O; $O | ConvertTo-Json -Depth 5 }
# 'NewGpo,Set,Set,...' -> 'NewGpo,Set*24'
function Compress-Calls($List) {
    $Out = New-Object System.Collections.Generic.List[string]; $Prev = $null; $N = 0
    foreach ($C in @($List) + @('<end>')) {
        if ($C -eq $Prev) { $N++; continue }
        if ($null -ne $Prev) { if ($N -gt 1) { $Out.Add("$Prev*$N") } else { $Out.Add($Prev) } }
        $Prev = $C; $N = 1
    }
    $Out -join ','
}

$CaseNo = 0
# ExpectExit 99 = the script must not start at all (parameter validation)
function Invoke-Case {
    param([string]$Name, [hashtable]$Params = @{}, [scriptblock]$Setup = {}, [int]$ExpectExit = 0, [string]$ExpectCalls = '',
          [string[]]$ExpectText = @(), [int]$ExpectReadHost = -1, [scriptblock]$Extra = $null)
    $script:CaseNo++
    Reset-Mock
    & $Setup
    $LogDir = Join-Path $Work ('case{0:00}' -f $script:CaseNo)
    $P = @{ SettingsPath = 'C:\cfg\BitLockerAdBackupGpo.json'; LogDir = $LogDir }
    foreach ($K in $Params.Keys) { $P[$K] = $Params[$K] }
    $Global:LASTEXITCODE = 0
    try { $Out = & $ScriptPath @P *>&1 | Out-String -Width 4000; $Exit = $LASTEXITCODE }
    catch { $Out = $_.Exception.Message; $Exit = 99 }
    $Csv = @()
    if (Test-Path -LiteralPath $LogDir) { $Csv = @(Get-ChildItem -LiteralPath $LogDir -Filter '*.csv' | ForEach-Object { Import-Csv -LiteralPath $_.FullName }) }
    $Hay = $Out + "`n" + (($Csv | ForEach-Object { '{0} {1} {2}' -f $_.Status, $_.Check, $_.Detail }) -join "`n")

    $Problems = New-Object System.Collections.Generic.List[string]
    if ($Exit -ne $ExpectExit) { $Problems.Add("exit $Exit, expected $ExpectExit") }
    $Got = Compress-Calls $Global:M.Calls.ToArray()
    if ($Got -ne $ExpectCalls) { $Problems.Add("calls [$Got], expected [$ExpectCalls]") }
    foreach ($T in $ExpectText) { if ($Hay.IndexOf($T, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $Problems.Add("output lacks '$T'") } }
    if ($ExpectReadHost -ge 0 -and $Global:M.ReadHostCalls -ne $ExpectReadHost) { $Problems.Add("Read-Host called $($Global:M.ReadHostCalls) time(s), expected $ExpectReadHost") }
    if ($ExpectExit -ne 99) {
        if ($Csv.Count -eq 0) { $Problems.Add('no results CSV') }
        elseif ((@($Csv | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) -ne ($ExpectExit -ne 0)) { $Problems.Add('CSV FAIL rows do not match the exit code') }
    }
    if ($Extra) { $Msg = & $Extra; if ($Msg) { $Problems.Add($Msg) } }
    Assert-That ($Problems.Count -eq 0) $Name ($Problems -join '; ')
    if ($Problems.Count) { Write-Host $Out }
}
$NC = @{ NoConfirm = $true }
$Fresh = 'NewGpo,Set*27,NewLink'

# --- 3. Confirmation gate ---
Invoke-Case 'Fresh, -NoConfirm: create GPO, set 27 values, link' -Params $NC -ExpectCalls $Fresh -ExpectReadHost 0 -ExpectText 'Verify values', 'Verify link', 'Registry.pol SHA-256', 'encryption OS XTS-AES 256, FDV XTS-AES 256, RDV XTS-AES 256' -Extra {
    if ($Global:M.Created -cne "$($Settings.GpoName)|$($Settings.GpoComment)") { return "created '$($Global:M.Created)'" }
    if ($Global:M.LinkTarget -cne $OuDn) { return "linked to '$($Global:M.LinkTarget)'" }
    if (-not $Global:M.SetLog.Contains('RDVRequireActiveDirectoryBackup=1')) { return 'RDVRequireActiveDirectoryBackup=1 was not set' }
    foreach ($N in 'EncryptionMethodWithXtsOs=7', 'EncryptionMethodWithXtsFdv=7', 'EncryptionMethodWithXtsRdv=7') { if (-not $Global:M.SetLog.Contains($N)) { return "$N was not set" } }
    if (-not $Global:M.OuQueries.Contains('JMSC-WDAC-WRKSTNS|DC=skynet-home,DC=local')) { return "OU query was [$($Global:M.OuQueries -join '; ')]" } }
Invoke-Case 'Interactive Y: shows scope and effect, then applies' -Setup { Set-Answers 'Y' } -ExpectCalls $Fresh -ExpectReadHost 1 -ExpectText 'Applies to: 1 computer(s) in that OU: WIN11-PAW-WDAC', 'operating system, fixed data, removable data drives', 'Drives encrypted from then on use: OS XTS-AES 256', "Undo: Remove-GPO -Name 'JMSC_BitLocker_AD_Backup'"
Invoke-Case 'Interactive yes -> applies' -Setup { Set-Answers 'yes' } -ExpectCalls $Fresh -ExpectReadHost 1
Invoke-Case 'Interactive N -> STOP, nothing changed' -Setup { Set-Answers 'N' } -ExpectExit 1 -ExpectReadHost 1 -ExpectText 'not confirmed'
Invoke-Case 'Interactive invalid x3 -> STOP' -Setup { Set-Answers 'maybe', 'x', '' } -ExpectExit 1 -ExpectReadHost 3 -ExpectText 'not confirmed'
Invoke-Case 'Interactive invalid then Y -> applies' -Setup { Set-Answers 'ok', 'Y' } -ExpectCalls $Fresh -ExpectReadHost 2
Invoke-Case 'Non-interactive without -NoConfirm -> STOP' -ExpectExit 1 -ExpectReadHost 0 -ExpectText 'non-interactive'
Invoke-Case '-WhatIf -> plan only' -Params @{ WhatIf = $true } -ExpectReadHost 0 -ExpectText 'would create', 'would set 27', 'would link'
Invoke-Case 'Already compliant -> no prompt, no change, verified' -Setup { Set-Answers 'Y'; Set-Compliant } -ExpectReadHost 0 -ExpectText 'nothing to change', 'Verify values', 'Verify link'

# --- 4. Existing GPO ---
Invoke-Case 'One value differs -> backup, set 1' -Params $NC -Setup { Set-Compliant; $Global:M.Values['RDVRequireActiveDirectoryBackup'] = [pscustomobject]@{ Type = 'DWord'; Value = 0 } } -ExpectCalls 'Backup,Set' -ExpectText 'RDVRequireActiveDirectoryBackup : 0 -> 1' -Extra { if (($Global:M.SetLog -join ',') -ne 'RDVRequireActiveDirectoryBackup=1') { "set [$($Global:M.SetLog -join ',')]" } }
Invoke-Case 'Value stored as a string -> rewritten as DWORD' -Params $NC -Setup { Set-Compliant; $Global:M.Values['OSRecovery'] = [pscustomobject]@{ Type = 'String'; Value = '1' } } -ExpectCalls 'Backup,Set' -ExpectText 'OSRecovery : 1 (String) -> 1'
Invoke-Case 'Link disabled -> enabled, no backup' -Params $NC -Setup { Set-Compliant; $Global:M.Link = 'Disabled' } -ExpectCalls 'EnableLink' -ExpectText 'enable the existing, disabled link'
Invoke-Case 'Not linked -> linked, no backup' -Params $NC -Setup { Set-Compliant; $Global:M.Link = 'None' } -ExpectCalls 'NewLink'
Invoke-Case 'Extra value in the GPO -> WARN, left alone' -Params $NC -Setup { Set-Compliant; $Global:M.Values['OSEncryptionType'] = [pscustomobject]@{ Type = 'DWord'; Value = 1 } } -ExpectText 'WARN Other GPO values', 'OSEncryptionType'
Invoke-Case '-WhatIf on an existing GPO -> plan only' -Params @{ WhatIf = $true } -Setup { Set-Compliant; $Global:M.Values.Remove('FDVRecovery') } -ExpectText 'would set 1'
Invoke-Case 'GPO computer settings disabled -> STOP' -Params $NC -Setup { Set-Compliant; $Global:M.Gpos[0].GpoStatus = 'ComputerSettingsDisabled' } -ExpectExit 1 -ExpectText 'computer settings disabled'
Invoke-Case 'Two GPOs with the name -> STOP' -Params $NC -Setup { Set-Compliant; $Global:M.Gpos = @($Global:M.Gpos[0], [pscustomobject]@{ Id = [guid]::NewGuid(); DisplayName = $Settings.GpoName; GpoStatus = 'AllSettingsEnabled' }) } -ExpectExit 1 -ExpectText '2 GPOs are named'

# --- 5. Preconditions and settings (each must stop with nothing changed) ---
Invoke-Case 'Not elevated -> STOP' -Params $NC -Setup { $Global:M.Admin = $false } -ExpectExit 1 -ExpectText 'not elevated'
Invoke-Case 'Settings file missing -> STOP' -Params $NC -Setup { $Global:M.SettingsText = $null } -ExpectExit 1 -ExpectText 'not found'
Invoke-Case 'Settings not JSON -> STOP' -Params $NC -Setup { $Global:M.SettingsText = '{ "GpoName": ' } -ExpectExit 1 -ExpectText 'not valid JSON'
Invoke-Case 'Settings is a JSON list -> STOP' -Params $NC -Setup { $Global:M.SettingsText = '[ 1, 2 ]' } -ExpectExit 1 -ExpectText 'one JSON object'
Invoke-Case 'Settings missing OuName -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.PSObject.Properties.Remove('OuName') } } -ExpectExit 1 -ExpectText "no 'OuName'"
Invoke-Case 'Settings unknown field -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O | Add-Member -NotePropertyName Target -NotePropertyValue 'DC=x' } } -ExpectExit 1 -ExpectText 'unknown field(s): Target'
Invoke-Case "GpoName with a quote -> STOP" -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.GpoName = "Bit'Locker" } } -ExpectExit 1 -ExpectText 'GpoName'
Invoke-Case "OuName with a quote (AD filter injection) -> STOP" -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.OuName = "X' -or Name -like '*" } } -ExpectExit 1 -ExpectText 'OuName' -Extra { if ($Global:M.OuQueries.Count) { 'the OU was queried' } }
Invoke-Case 'GpoComment with a control character -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.GpoComment = "a`tb" } } -ExpectExit 1 -ExpectText 'GpoComment'
Invoke-Case 'Prefixes empty -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Prefixes = @() } } -ExpectExit 1 -ExpectText 'non-empty list'
Invoke-Case 'Prefixes not a list -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Prefixes = 'OS' } } -ExpectExit 1 -ExpectText 'non-empty list'
Invoke-Case 'Unknown prefix -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Prefixes = @('OS', 'XYZ') } } -ExpectExit 1 -ExpectText "prefix 'XYZ'"
Invoke-Case 'Prefix in lower case -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Prefixes = @('os') } } -ExpectExit 1 -ExpectText "prefix 'os'"
Invoke-Case 'Prefix twice -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Prefixes = @('OS', 'OS') } } -ExpectExit 1 -ExpectText 'listed twice'
Invoke-Case 'Unknown value name -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values | Add-Member -NotePropertyName EncryptionType -NotePropertyValue 1 } } -ExpectExit 1 -ExpectText 'unknown value name(s)'
Invoke-Case 'Value name missing -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values.PSObject.Properties.Remove('HideRecoveryPage') } } -ExpectExit 1 -ExpectText 'missing'
Invoke-Case 'Value as a string -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values.Recovery = '1' } } -ExpectExit 1 -ExpectText 'whole number'
Invoke-Case 'Value as true -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values.Recovery = $true } } -ExpectExit 1 -ExpectText 'whole number'
Invoke-Case 'Value 1.5 -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values.Recovery = 1.5 } } -ExpectExit 1 -ExpectText 'whole number'
Invoke-Case 'Negative value -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values.Recovery = -1 } } -ExpectExit 1 -ExpectText 'whole number'
Invoke-Case 'ActiveDirectoryBackup 0 -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values.ActiveDirectoryBackup = 0 } } -ExpectExit 1 -ExpectText 'must be 1'
Invoke-Case 'Value outside the ADMX (RecoveryPassword 3) -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values.RecoveryPassword = 3 } } -ExpectExit 1 -ExpectText 'OSRecoveryPassword = 3 (allowed: 2, 1, 0)'
Invoke-Case 'ActiveDirectoryInfoToStore 0 (not in the ADMX) -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Values.ActiveDirectoryInfoToStore = 0 } } -ExpectExit 1 -ExpectText 'ActiveDirectoryInfoToStore = 0'
Invoke-Case 'EncryptionMethods missing -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.PSObject.Properties.Remove('EncryptionMethods') } } -ExpectExit 1 -ExpectText "no 'EncryptionMethods'"
Invoke-Case 'EncryptionMethods for a drive type not in Prefixes -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Prefixes = @('OS', 'FDV') } } -ExpectExit 1 -ExpectText 'must name exactly the drive types'
Invoke-Case 'EncryptionMethods missing a drive type -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.EncryptionMethods.PSObject.Properties.Remove('FDV') } } -ExpectExit 1 -ExpectText 'must name exactly the drive types'
Invoke-Case 'Encryption method as a string -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.EncryptionMethods.OS = 'XtsAes256' } } -ExpectExit 1 -ExpectText 'EncryptionMethods.OS'
Invoke-Case 'Encryption method 5 (not in the ADMX) -> STOP' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.EncryptionMethods.OS = 5 } } -ExpectExit 1 -ExpectText 'EncryptionMethodWithXtsOs = 5 (allowed: 3, 4, 6, 7)'
Invoke-Case 'Encryption method 6 (XTS-AES 128) -> accepted' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.EncryptionMethods.RDV = 6 } } -ExpectCalls $Fresh -ExpectText 'RDV XTS-AES 128' -Extra { if (-not $Global:M.SetLog.Contains('EncryptionMethodWithXtsRdv=6')) { 'EncryptionMethodWithXtsRdv=6 was not set' } }
Invoke-Case 'Existing GPO without the encryption methods -> backup, set 3' -Params $NC -Setup { Set-Compliant; foreach ($N in $MethodNames.Values) { $Global:M.Values.Remove($N) } } -ExpectCalls 'Backup,Set*3' -ExpectText 'EncryptionMethodWithXtsOs : (not set) -> 7'
Invoke-Case 'Modules missing -> STOP' -Params $NC -Setup { $Global:M.ModulesFail = $true } -ExpectExit 1 -ExpectText 'could not be loaded'
Invoke-Case 'Not domain-joined -> STOP' -Params $NC -Setup { $Global:M.Joined = $false } -ExpectExit 1 -ExpectText 'not joined to an Active Directory domain'
Invoke-Case 'No DC answers -> STOP' -Params $NC -Setup { $Global:M.NoDc = $true } -ExpectExit 1 -ExpectText 'no domain controller answered'
Invoke-Case 'ADMX not found -> STOP' -Params $NC -Setup { $Global:M.Admx = $null } -ExpectExit 1 -ExpectText 'VolumeEncryption.admx was found neither'
Invoke-Case 'ADMX not XML -> STOP' -Params $NC -Setup { $Global:M.Admx = [pscustomobject]@{ Path = 'x.admx'; Text = '<policyDefinitions' } } -ExpectExit 1 -ExpectText 'not valid XML'
Invoke-Case 'ADMX without the removable-drive policy -> STOP' -Params $NC -Setup {
    $Doc = New-Object System.Xml.XmlDocument; $Doc.LoadXml($AdmxText)
    $Ns = New-Object System.Xml.XmlNamespaceManager($Doc.NameTable); $Ns.AddNamespace('p', $Doc.DocumentElement.NamespaceURI)
    $Node = $Doc.SelectSingleNode("//p:policy[@valueName='RDVRecovery']", $Ns); [void]$Node.ParentNode.RemoveChild($Node)
    $Global:M.Admx = [pscustomobject]@{ Path = 'trimmed.admx'; Text = $Doc.OuterXml } } -ExpectExit 1 -ExpectText 'RDVRecovery (not in the ADMX)'
Invoke-Case 'OU not found -> STOP' -Params $NC -Setup { $Global:M.Ous = @() } -ExpectExit 1 -ExpectText 'found 0'
Invoke-Case 'Two OUs with the name -> STOP' -Params $NC -Setup { $Global:M.Ous = @($OuDn, 'OU=JMSC-WDAC-WRKSTNS,OU=Old,DC=skynet-home,DC=local') } -ExpectExit 1 -ExpectText 'found 2'
Invoke-Case '-SettingsPath that is not .json -> rejected before the script runs' -Params @{ NoConfirm = $true; SettingsPath = 'C:\cfg\settings.txt' } -ExpectExit 99 -ExpectText 'SettingsPath'

# --- 6. Other settings and warnings ---
Invoke-Case 'Only OS and FDV -> 18 values' -Params $NC -Setup { $Global:M.SettingsText = Edit-Settings { param($O) $O.Prefixes = @('OS', 'FDV'); $O.EncryptionMethods.PSObject.Properties.Remove('RDV') } } -ExpectCalls 'NewGpo,Set*18,NewLink' -Extra { if (@($Global:M.SetLog | Where-Object { $_ -like 'RDV*' -or $_ -like '*Rdv=*' }).Count) { 'an RDV value was set' } }
Invoke-Case 'Another GPO sets BitLocker values -> WARN, still applies' -Params $NC -Setup { $Global:M.Competitors = @('Old BitLocker (precedence 1, linked at DC=skynet-home,DC=local)') } -ExpectCalls $Fresh -ExpectText 'WARN Other BitLocker GPOs'
Invoke-Case 'OU without computers -> WARN, still applies' -Params $NC -Setup { $Global:M.Computers = @() } -ExpectCalls $Fresh -ExpectText 'holds no computer objects'
Invoke-Case 'AD and SYSVOL versions differ -> WARN' -Params $NC -Setup { Set-Compliant; $Global:M.SysvolVersion = 24 } -ExpectText 'replication may still be running'
Invoke-Case 'Central store without this ADMX -> WARN, still applies' -Params $NC -Setup { $Global:M.Admx.CentralStore = 'MissingFile' } -ExpectCalls $Fresh -ExpectText 'WARN Central store', 'Extra Registry Settings'
Invoke-Case 'Central store has this ADMX -> no central-store warning' -Params $NC -ExpectCalls $Fresh -Extra { if ($Hay -match 'WARN Central store') { 'unexpected central-store warning' } }

# --- 7. Verification from the system ---
Invoke-Case 'Values do not stick -> FAIL' -Params $NC -Setup { $Global:M.SetIsNoop = $true } -ExpectExit 1 -ExpectCalls $Fresh -ExpectText 'FAIL Verify values'
Invoke-Case 'Link does not stick -> FAIL' -Params $NC -Setup { $Global:M.LinkIsNoop = $true } -ExpectExit 1 -ExpectCalls $Fresh -ExpectText 'FAIL Verify link'
Invoke-Case 'Registry.pol missing -> FAIL' -Params $NC -Setup { Set-Compliant; $Global:M.PolHash = '' } -ExpectExit 1 -ExpectText 'FAIL Registry.pol'

# --- 8. Guard: a real (module) command must never run under the harness ---
function Invoke-GuardCase {
    New-Module -Name FakeRealSetEscrowValue -ScriptBlock { function Set-EscrowValue { param($Id, $Name, $Value) $Global:M.Calls.Add('REAL') }; Export-ModuleMember -Function Set-EscrowValue } | Import-Module -Scope Local
    try { Invoke-Case 'Guard: module command instead of a mock -> STOP' -Params $NC -ExpectExit 1 -ExpectText 'is not a mock function' }
    finally { Remove-Module -Name FakeRealSetEscrowValue -ErrorAction SilentlyContinue }
}
Invoke-GuardCase

Remove-Variable -Name GpoScriptTestHarness -Scope Global
Remove-Item -LiteralPath $Work -Recurse -Force
Write-Host ''
if ($Failures.Count) { Write-Host "FAILED: $($Failures.Count) of $Checks check(s)" -ForegroundColor Red; exit 1 }
Write-Host "PASSED: $Checks checks ($CaseNo script runs)" -ForegroundColor Green
