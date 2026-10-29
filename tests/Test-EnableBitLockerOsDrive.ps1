# Unit tests for scripts\Enable-BitLockerOsDrive.ps1 with mocks: BitLocker, the TPM and AD are not touched by the script under
# test. Windows PowerShell 5.1 and PowerShell 7. ASCII-only.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-EnableBitLockerOsDrive.ps1
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-EnableBitLockerOsDrive.ps1
param([string]$ScriptPath = '')   # empty = ..\scripts\Enable-BitLockerOsDrive.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $ScriptPath) { $ScriptPath = Join-Path $Root 'scripts\Enable-BitLockerOsDrive.ps1' }
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "STOP: $ScriptPath not found." }
$ScriptDir = Split-Path -Parent $ScriptPath
$Work = Join-Path ([IO.Path]::GetTempPath()) ('BitLockerScriptTest-' + [guid]::NewGuid().ToString('N'))
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

# --- 1. Secret hygiene (static): the recovery password must never reach the console, transcript or CSV ---
$Source = [IO.File]::ReadAllText($ScriptPath)
Assert-That ($Source -notmatch '\.RecoveryPassword\b') 'No .RecoveryPassword property is read anywhere'
$Tokens = $null; $Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$Errors)
$Risky = @('Add-BitLockerKeyProtector', 'Backup-BitLockerKeyProtector', 'Enable-BitLocker', 'Disable-BitLocker', 'Resume-BitLocker')
$Calls = @($Ast.FindAll({ param($N) $N -is [Management.Automation.Language.CommandAst] -and $Risky -contains $N.GetCommandName() }, $true))
Assert-That ($Calls.Count -eq 6) 'Six BitLocker cmdlet calls found' "found $($Calls.Count)"
foreach ($C in $Calls) {
    $Text = $C.Extent.Text
    $Pipeline = $C.Parent.Extent.Text
    $Quiet = ($Text -match '-WarningAction SilentlyContinue') -or ($Text -match '@A' -and $Source -match "WarningAction = 'SilentlyContinue'")
    Assert-That ($Quiet -and $Pipeline -match '\|\s*Out-Null') "Warnings suppressed and output discarded: $($C.GetCommandName()) (line $($C.Extent.StartLineNumber))" $Pipeline
}
# The BitLocker module reports failures with Write-Error, which the script's $ErrorActionPreference does not reach inside a
# module: without -ErrorAction Stop a refused Enable-BitLocker was logged as PASS on WIN11-PAW-WDAC.
$Reads = @($Ast.FindAll({ param($N) $N -is [Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Get-BitLockerVolume' }, $true))
foreach ($C in @($Calls) + @($Reads)) {
    $Text = $C.Extent.Text
    $Stops = ($Text -match '-ErrorAction Stop') -or ($Text -match '@A' -and $Source -match "ErrorAction = 'Stop'")
    Assert-That $Stops "Errors stop the script: $($C.GetCommandName()) (line $($C.Extent.StartLineNumber))" $Text
}

# --- 2. Harness: real confirmation gate, mocked system access ---
$Global:BitLockerScriptTestHarness = $true
. (Join-Path $ScriptDir 'Confirm-Change.ps1')

$Dn = 'CN=WIN11-PAW-WDAC,OU=JMSC-WDAC-WRKSTNS,DC=skynet-home,DC=local'
$RpId = '{11111111-2222-3333-4444-555555555555}'
$TpmId = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'

function Test-Interactive { $Global:M.Interactive }
function Read-Host { param([string]$Prompt) $Global:M.ReadHostCalls++; if ($Global:M.Answers.Count -gt 0) { $Global:M.Answers.Dequeue() } else { '' } }
function Test-IsAdmin { $Global:M.Admin }
function Import-BitLockerModules { if ($Global:M.ModulesFail) { throw "The specified module 'BitLocker' was not loaded." }; 'BitLocker (mock)' }
function Get-OsVolumeState { param([string]$Drive)
    $V = $Global:M.Vol
    [pscustomobject]@{ MountPoint = $V.MountPoint; VolumeType = $V.VolumeType; VolumeStatus = $V.VolumeStatus; ProtectionStatus = $V.ProtectionStatus
        EncryptionMethod = $V.EncryptionMethod; EncryptionPercentage = $V.EncryptionPercentage
        Protectors = @($V.Protectors | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Type = $_.Type } }) } }
function Get-HardwareTestStatus { param([string]$Drive) $Global:M.Hw }
function Test-DomainJoined { $Global:M.Joined }
function Get-DomainControllerName { if ($Global:M.NoDc) { throw 'The specified domain either does not exist or could not be contacted.' }; 'DC25-1.skynet-home.local' }
function Get-ComputerDn { param([string]$Dc, [string]$Name) $Global:M.Dn }
function Find-AdRecoveryIds { param([string]$Dc, [string]$ComputerDn) $Global:M.AdIds.ToArray() }
function Wait-AdRecoveryId { param([string]$Dc, [string]$ComputerDn, [string]$Id, [int]$Seconds) $Global:M.AdIds.Contains($Id) }
function Get-FvePolicy { $Copy = @{}; foreach ($K in $Global:M.Pol.Keys) { $Copy[$K] = $Global:M.Pol[$K] }; $Copy }
function Get-TpmState { [pscustomobject]@{ Present = $Global:M.TpmPresent; Ready = $Global:M.TpmReady } }
function Get-SecureBootState { $Global:M.SecureBoot }
function Get-WinReState { $Global:M.WinRe }
function Get-OpticalMedia { $Global:M.Optical }
function Wait-Decryption { param([string]$Drive, [int]$Minutes)
    $Global:M.Calls.Add('Wait')
    if ($Global:M.DecryptTimesOut) { return $false }
    $Global:M.Vol.VolumeStatus = 'FullyDecrypted'; $Global:M.Vol.EncryptionMethod = 'None'; $Global:M.Vol.EncryptionPercentage = 0; $true }
function Start-Decryption { [CmdletBinding()] param([string]$Drive)
    $Global:M.Calls.Add('Decrypt'); $Global:M.Vol.VolumeStatus = 'DecryptionInProgress'; $Global:M.Vol.Protectors = @(); $Global:M.Vol.ProtectionStatus = 'Off' }
function Add-RecoveryPasswordProtector { [CmdletBinding()] param([string]$Drive)
    $Global:M.Calls.Add('AddRp')
    if ($Global:M.AddRpFails) { throw 'BitLocker could not back up the recovery information to Active Directory Domain Services.' }
    $Id = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
    $Global:M.Vol.Protectors = @($Global:M.Vol.Protectors) + @([pscustomobject]@{ Id = $Id; Type = 'RecoveryPassword' })
    # As seen on WIN11-PAW-WDAC: on a decrypted drive the protector is created, but nothing is written to AD yet
    if ($Global:M.Escrow -and $Global:M.Vol.VolumeStatus -ne 'FullyDecrypted') { $Global:M.AdIds.Add($Id) }
    $Global:M.NewRp = $Id
    $Id }
function Backup-RecoveryPassword { [CmdletBinding()] param([string]$Drive, [string]$Id) $Global:M.Calls.Add('BackupRp'); if ($Global:M.Escrow) { $Global:M.AdIds.Add($Id) } }
function Add-TpmProtector { [CmdletBinding()] param([string]$Drive) $Global:M.Calls.Add('AddTpm'); $Global:M.Vol.Protectors = @($Global:M.Vol.Protectors) + @([pscustomobject]@{ Id = $TpmId; Type = 'Tpm' }) }
function Enable-OsEncryption { [CmdletBinding()] param([string]$Drive, [string]$Method, [bool]$UsedOnly, [bool]$SkipTest)
    $Global:M.Calls.Add('Enable'); $Global:M.EnableArgs = "$Method|$UsedOnly|$SkipTest"
    if ($Global:M.EnableFails) { throw 'BitLocker Drive Encryption detected bootable media (CD or DVD) in the computer. Remove the media and restart the computer before configuring BitLocker. (0x80310030)' }
    # Turning BitLocker on writes the recovery passwords to AD (EscrowAtEnable = $false: only once encryption starts)
    if ($Global:M.EscrowAtEnable) { foreach ($P in @($Global:M.Vol.Protectors | Where-Object { $_.Type -eq 'RecoveryPassword' })) { if (-not $Global:M.AdIds.Contains($P.Id)) { $Global:M.AdIds.Add($P.Id) } } }
    $Global:M.Vol.Protectors = @($Global:M.Vol.Protectors) + @([pscustomobject]@{ Id = $TpmId; Type = 'Tpm' })
    if ($SkipTest) { $Global:M.Vol.VolumeStatus = 'EncryptionInProgress'; $Global:M.Vol.EncryptionMethod = $Method; $Global:M.Vol.EncryptionPercentage = 1 } else { $Global:M.Hw = 'Pending' } }
function Resume-Protection { [CmdletBinding()] param([string]$Drive) $Global:M.Calls.Add('Resume'); if (-not $Global:M.ResumeNoop) { $Global:M.Vol.ProtectionStatus = 'On' } }

function New-Vol([string]$Status, [string]$Method, [string]$Protection, $Protectors) {
    [pscustomobject]@{ MountPoint = 'C:'; VolumeType = 'OperatingSystem'; VolumeStatus = $Status; ProtectionStatus = $Protection; EncryptionMethod = $Method; EncryptionPercentage = $(if ($Status -eq 'FullyEncrypted') { 100 } else { 0 }); Protectors = @($Protectors) }
}
function P([string]$Type, [string]$Id) { [pscustomobject]@{ Type = $Type; Id = $Id } }
function Reset-Mock {
    $Global:M = @{
        Interactive = $false; Answers = New-Object System.Collections.Queue; ReadHostCalls = 0
        Admin = $true; ModulesFail = $false; Joined = $true; NoDc = $false; Dn = $Dn
        AdIds = New-Object System.Collections.Generic.List[string]; Escrow = $true; EscrowAtEnable = $true; AddRpFails = $false
        Pol = @{ OSRecovery = 1; OSActiveDirectoryBackup = 1; OSRequireActiveDirectoryBackup = 1; OSRecoveryPassword = 2; EncryptionMethodWithXtsOs = 7 }
        TpmPresent = $true; TpmReady = $true; SecureBoot = $true; WinRe = 'Enabled'; Hw = 'None'
        Vol = New-Vol 'FullyEncrypted' 'XtsAes128' 'Off' @()      # this PAW: device encryption, Waiting for Activation, XTS-AES 128
        DecryptTimesOut = $false; ResumeNoop = $false; Optical = @(); EnableFails = $false
        Calls = New-Object System.Collections.Generic.List[string]; EnableArgs = ''; NewRp = ''
    }
}
function Set-Answers([string[]]$List) { $Global:M.Interactive = $true; foreach ($A in $List) { $Global:M.Answers.Enqueue($A) } }
function Set-Compliant { $Global:M.Vol = New-Vol 'FullyEncrypted' 'XtsAes256' 'On' @((P 'RecoveryPassword' $RpId), (P 'Tpm' $TpmId)); $Global:M.AdIds.Add($RpId) }

$CaseNo = 0
# ExpectExit 99 = the script must not start at all (parameter validation)
function Invoke-Case {
    param([string]$Name, [hashtable]$Params = @{}, [scriptblock]$Setup = {}, [int]$ExpectExit = 0, [string]$ExpectCalls = '',
          [string[]]$ExpectText = @(), [int]$ExpectReadHost = -1, [scriptblock]$Extra = $null)
    $script:CaseNo++
    Reset-Mock
    & $Setup
    $LogDir = Join-Path $Work ('case{0:00}' -f $script:CaseNo)
    $P = @{ LogDir = $LogDir }
    foreach ($K in $Params.Keys) { $P[$K] = $Params[$K] }
    $Global:LASTEXITCODE = 0
    try { $Out = & $ScriptPath @P *>&1 | Out-String -Width 4000; $Exit = $LASTEXITCODE }
    catch { $Out = $_.Exception.Message; $Exit = 99 }
    $Csv = @()
    if (Test-Path -LiteralPath $LogDir) { $Csv = @(Get-ChildItem -LiteralPath $LogDir -Filter '*.csv' | ForEach-Object { Import-Csv -LiteralPath $_.FullName }) }
    $Hay = $Out + "`n" + (($Csv | ForEach-Object { '{0} {1} {2}' -f $_.Status, $_.Check, $_.Detail }) -join "`n")
    $Problems = New-Object System.Collections.Generic.List[string]
    if ($Exit -ne $ExpectExit) { $Problems.Add("exit $Exit, expected $ExpectExit") }
    $Got = $Global:M.Calls.ToArray() -join ','
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
$RE = @{ NoConfirm = $true; ReEncrypt = $true }

# --- 3. This PAW's state: XTS-AES 128, Waiting for Activation ---
Invoke-Case 'PAW state without -ReEncrypt -> STOP: method differs' -Params $NC -ExpectExit 1 -ExpectText 'encrypted with XtsAes128, not XtsAes256', '-ReEncrypt'
Invoke-Case 'PAW state, -ReEncrypt: decrypt, wait, recovery password, encrypt XTS-AES 256, password in AD' -Params $RE -ExpectCalls 'Decrypt,Wait,AddRp,Enable' -ExpectText 'BitLocker writes it to AD when encryption is turned on', 'PASS Verify recovery password', 'hardware test pending', 'NEXT: Restart' -Extra {
    if ($Global:M.EnableArgs -ne 'XtsAes256|False|False') { return "Enable args '$($Global:M.EnableArgs)'" }
    if (-not $Global:M.AdIds.Contains($Global:M.NewRp)) { return 'the new recovery password is not in AD' } }
Invoke-Case 'PAW state, -ReEncrypt -UsedSpaceOnly -SkipHardwareTest: encryption starts now' -Params @{ NoConfirm = $true; ReEncrypt = $true; UsedSpaceOnly = $true; SkipHardwareTest = $true } -ExpectCalls 'Decrypt,Wait,AddRp,Enable' -ExpectText 'Verify method', 'XtsAes256 (EncryptionInProgress' -Extra { if ($Global:M.EnableArgs -ne 'XtsAes256|True|True') { "Enable args '$($Global:M.EnableArgs)'" } }
Invoke-Case 'PAW state, -ReEncrypt, interactive Y: plan shows the risk' -Params @{ ReEncrypt = $true } -Setup { Set-Answers 'Y' } -ExpectCalls 'Decrypt,Wait,AddRp,Enable' -ExpectReadHost 1 -ExpectText '1. decrypt C:', 'NOT encrypted until encryption completes again', '3. add a recovery password; BitLocker writes it to AD when the next step turns encryption on'
Invoke-Case 'This PAW after the first run: decrypted, recovery password not in AD -> encrypt, then found in AD' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @((P 'RecoveryPassword' $RpId)) } -ExpectCalls 'Enable' -ExpectText "Verify recovery password $RpId in AD", 'hardware test pending' -Extra { if (-not $Global:M.AdIds.Contains($RpId)) { 'the recovery password did not reach AD' } }
Invoke-Case 'Decrypted, BitLocker writes to AD only when encryption starts -> WARN, run again after the restart' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @(); $Global:M.EscrowAtEnable = $false } -ExpectCalls 'AddRp,Enable' -ExpectText 'WARN Verify recovery password', 'Run this script again after the restart'
Invoke-Case 'Encryption started now (-SkipHardwareTest) but password not in AD -> FAIL' -Params @{ NoConfirm = $true; SkipHardwareTest = $true } -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @(); $Global:M.EscrowAtEnable = $false } -ExpectExit 1 -ExpectCalls 'AddRp,Enable' -ExpectText 'FAIL Verify recovery password'
Invoke-Case 'Restart pending, password not in AD yet -> WARN, no backup attempt' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @((P 'RecoveryPassword' $RpId), (P 'Tpm' $TpmId)); $Global:M.Hw = 'Pending' } -ExpectText 'WARN Plan', 'NEXT: Restart'
Invoke-Case 'Interactive N -> STOP, nothing changed' -Params @{ ReEncrypt = $true } -Setup { Set-Answers 'N' } -ExpectExit 1 -ExpectReadHost 1 -ExpectText 'not confirmed'
Invoke-Case 'Interactive invalid x3 -> STOP' -Params @{ ReEncrypt = $true } -Setup { Set-Answers 'maybe', 'x', '' } -ExpectExit 1 -ExpectReadHost 3
Invoke-Case 'Non-interactive without -NoConfirm -> STOP' -Params @{ ReEncrypt = $true } -ExpectExit 1 -ExpectReadHost 0 -ExpectText 'non-interactive'
Invoke-Case '-ReEncrypt -WhatIf -> plan only' -Params @{ ReEncrypt = $true; WhatIf = $true } -ExpectText 'would decrypt C:', 'would add one and confirm it in AD', 'would encrypt with XtsAes256'

# --- 4. Other drive states ---
Invoke-Case 'Waiting for Activation with XTS-AES 256 -> recovery password, TPM, protection on' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyEncrypted' 'XtsAes256' 'Off' @() } -ExpectCalls 'AddRp,AddTpm,Resume' -ExpectText 'Verify protection on', 'Verify TPM protector present'
Invoke-Case 'Decrypted drive -> recovery password, encrypt' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @() } -ExpectCalls 'AddRp,Enable' -ExpectText 'hardware test pending'
Invoke-Case 'Already compliant -> no prompt, nothing changed' -Setup { Set-Answers 'Y'; Set-Compliant } -ExpectReadHost 0 -ExpectText 'nothing to change'
Invoke-Case 'Recovery password not in AD -> backed up (backfill)' -Params $NC -Setup { Set-Compliant; $Global:M.AdIds.Clear() } -ExpectCalls 'BackupRp' -ExpectText 'backed up and found in AD'
Invoke-Case 'Protection suspended -> turned on' -Params $NC -Setup { Set-Compliant; $Global:M.Vol.ProtectionStatus = 'Off' } -ExpectCalls 'Resume'
Invoke-Case 'No TPM protector, protection off -> TPM added, turned on' -Params $NC -Setup { Set-Compliant; $Global:M.Vol.Protectors = @((P 'RecoveryPassword' $RpId)); $Global:M.Vol.ProtectionStatus = 'Off' } -ExpectCalls 'AddTpm,Resume'
Invoke-Case 'Hardware test pending -> nothing, restart' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @((P 'RecoveryPassword' $RpId), (P 'Tpm' $TpmId)); $Global:M.AdIds.Add($RpId); $Global:M.Hw = 'Pending' } -ExpectText 'restart to start encryption', 'NEXT: Restart'
Invoke-Case 'Hardware test failed -> STOP' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @(); $Global:M.Hw = 'Failed' } -ExpectExit 1 -ExpectText 'hardware test failed'
Invoke-Case 'Decrypted with a TPM protector, no test pending -> STOP' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @((P 'Tpm' $TpmId)) } -ExpectExit 1 -ExpectText 'already has a TPM protector'
Invoke-Case 'Encryption in progress, same method -> nothing' -Params $NC -Setup { Set-Compliant; $Global:M.Vol.VolumeStatus = 'EncryptionInProgress'; $Global:M.Vol.EncryptionPercentage = 40 } -ExpectText 'in progress (40%)'
Invoke-Case 'Encryption in progress, other method -> STOP' -Params $NC -Setup { Set-Compliant; $Global:M.Vol.VolumeStatus = 'EncryptionInProgress'; $Global:M.Vol.EncryptionMethod = 'XtsAes128' } -ExpectExit 1 -ExpectText 'being encrypted with XtsAes128'
Invoke-Case 'Decryption in progress without -ReEncrypt -> STOP' -Params $NC -Setup { $Global:M.Vol = New-Vol 'DecryptionInProgress' 'XtsAes128' 'Off' @() } -ExpectExit 1 -ExpectText 'being decrypted'
Invoke-Case 'Decryption in progress with -ReEncrypt -> wait, recovery password, encrypt' -Params $RE -Setup { $Global:M.Vol = New-Vol 'DecryptionInProgress' 'XtsAes128' 'Off' @() } -ExpectCalls 'Wait,AddRp,Enable'
Invoke-Case 'Paused encryption -> STOP' -Params $NC -Setup { $Global:M.Vol = New-Vol 'EncryptionPaused' 'XtsAes256' 'Off' @() } -ExpectExit 1 -ExpectText "'EncryptionPaused'"
Invoke-Case 'Decryption still running at the deadline -> WARN, stops before the recovery password' -Params $RE -Setup { $Global:M.DecryptTimesOut = $true } -ExpectCalls 'Decrypt,Wait' -ExpectText 'WARN Decryption', 'Run this script again with -ReEncrypt'

# --- 5. The recovery password must be in AD before anything else ---
Invoke-Case 'Encrypted drive: recovery password never appears in AD -> STOP before the TPM protector' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyEncrypted' 'XtsAes256' 'Off' @(); $Global:M.Escrow = $false } -ExpectExit 1 -ExpectCalls 'AddRp' -ExpectText 'no AD object for it appeared'
Invoke-Case 'Adding the recovery password fails (AD backup) -> FAIL, nothing after it' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyEncrypted' 'XtsAes256' 'Off' @(); $Global:M.AddRpFails = $true } -ExpectExit 1 -ExpectCalls 'AddRp' -ExpectText 'adding the recovery password failed'
Invoke-Case 'Backup never appears in AD -> FAIL' -Params $NC -Setup { Set-Compliant; $Global:M.AdIds.Clear(); $Global:M.Escrow = $false } -ExpectExit 1 -ExpectCalls 'BackupRp' -ExpectText 'was backed up, but no AD object'
Invoke-Case 'Protection does not turn on -> FAIL from the re-read' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyEncrypted' 'XtsAes256' 'Off' @(); $Global:M.ResumeNoop = $true } -ExpectExit 1 -ExpectCalls 'AddRp,AddTpm,Resume' -ExpectText 'FAIL Verify protection'

# --- 6. Bootable media (seen on WIN11-PAW-WDAC: Windows ISO in the virtual DVD drive, 0x80310030) ---
$Iso = 'D: (CPBA_X64FRE_EN-US_DV9)'
Invoke-Case 'ISO in the DVD drive -> STOP before encrypting' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @((P 'RecoveryPassword' $RpId)); $Global:M.Optical = @($Iso) } -ExpectExit 1 -ExpectText 'CPBA_X64FRE_EN-US_DV9', '0x80310030', 'Set-VMDvdDrive'
Invoke-Case 'ISO in the DVD drive, -ReEncrypt -> STOP before decrypting' -Params $RE -Setup { $Global:M.Optical = @($Iso) } -ExpectExit 1 -ExpectText '0x80310030'
Invoke-Case 'ISO in the DVD drive, backfill only -> runs' -Params $NC -Setup { Set-Compliant; $Global:M.AdIds.Clear(); $Global:M.Optical = @($Iso) } -ExpectCalls 'BackupRp'
Invoke-Case 'Enable-BitLocker refused -> FAIL with its message, never PASS Encrypt' -Params $NC -Setup { $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @((P 'RecoveryPassword' $RpId)); $Global:M.EnableFails = $true } -ExpectExit 1 -ExpectCalls 'Enable' -ExpectText 'FAIL Stopped', '0x80310030' -Extra { if ($Hay -match 'PASS Encrypt') { 'PASS Encrypt was logged' } }

# --- 7. Preconditions (each must stop with nothing changed) ---
Invoke-Case 'Not elevated -> STOP' -Params $NC -Setup { $Global:M.Admin = $false } -ExpectExit 1 -ExpectText 'not elevated'
Invoke-Case 'Modules missing -> STOP' -Params $NC -Setup { $Global:M.ModulesFail = $true } -ExpectExit 1 -ExpectText 'could not be loaded'
Invoke-Case 'Data volume -> STOP' -Params $NC -Setup { $Global:M.Vol.VolumeType = 'Data' } -ExpectExit 1 -ExpectText 'operating system drive only'
Invoke-Case 'Not domain-joined -> STOP' -Params $NC -Setup { $Global:M.Joined = $false } -ExpectExit 1 -ExpectText 'not joined'
Invoke-Case 'No DC answers -> STOP' -Params $NC -Setup { $Global:M.NoDc = $true } -ExpectExit 1 -ExpectText 'no domain controller answered'
Invoke-Case 'Computer object not found -> STOP' -Params $NC -Setup { $Global:M.Dn = $null } -ExpectExit 1 -ExpectText 'computer object'
Invoke-Case 'GPO not applied -> STOP' -Params $NC -Setup { $Global:M.Pol = @{} } -ExpectExit 1 -ExpectText 'not in effect', 'gpupdate'
Invoke-Case 'RequireActiveDirectoryBackup off -> STOP' -Params $NC -Setup { $Global:M.Pol.OSRequireActiveDirectoryBackup = 0 } -ExpectExit 1 -ExpectText 'OSRequireActiveDirectoryBackup=0'
Invoke-Case 'Recovery password not allowed -> STOP' -Params $NC -Setup { $Global:M.Pol.OSRecoveryPassword = 0 } -ExpectExit 1 -ExpectText 'OSRecoveryPassword = 0'
Invoke-Case 'TPM-only startup not allowed -> STOP' -Params $NC -Setup { $Global:M.Pol.UseAdvancedStartup = 1; $Global:M.Pol.UseTPM = 0 } -ExpectExit 1 -ExpectText 'UseTPM = 0'
Invoke-Case 'Full encryption required, -UsedSpaceOnly -> STOP' -Params @{ NoConfirm = $true; UsedSpaceOnly = $true } -Setup { $Global:M.Pol.OSEncryptionType = 1 } -ExpectExit 1 -ExpectText 'OSEncryptionType = 1'
Invoke-Case 'Used-space-only required, no -UsedSpaceOnly -> STOP' -Params $NC -Setup { $Global:M.Pol.OSEncryptionType = 2 } -ExpectExit 1 -ExpectText 'OSEncryptionType = 2'
Invoke-Case 'GPO method XTS-AES 128 vs -EncryptionMethod XtsAes256 -> STOP' -Params $NC -Setup { $Global:M.Pol.EncryptionMethodWithXtsOs = 6 } -ExpectExit 1 -ExpectText 'EncryptionMethodWithXtsOs = 6 (XtsAes128)'
Invoke-Case 'No TPM -> STOP' -Params $NC -Setup { $Global:M.TpmPresent = $false } -ExpectExit 1 -ExpectText 'no TPM'
Invoke-Case 'TPM not ready -> STOP' -Params $NC -Setup { $Global:M.TpmReady = $false } -ExpectExit 1 -ExpectText 'not ready'
Invoke-Case '-MountPoint not a drive letter -> rejected before the script runs' -Params @{ NoConfirm = $true; MountPoint = 'C:\Windows' } -ExpectExit 99 -ExpectText 'MountPoint'

# --- 7. Policy variants and warnings ---
Invoke-Case 'No encryption-method policy -> WARN, uses -EncryptionMethod' -Params $NC -Setup { $Global:M.Pol.Remove('EncryptionMethodWithXtsOs'); $Global:M.Vol = New-Vol 'FullyDecrypted' 'None' 'Off' @() } -ExpectCalls 'AddRp,Enable' -ExpectText 'WARN Policy'
Invoke-Case '-EncryptionMethod XtsAes128 with a matching GPO -> activates the XTS-AES 128 drive' -Params @{ NoConfirm = $true; EncryptionMethod = 'XtsAes128' } -Setup { $Global:M.Pol.EncryptionMethodWithXtsOs = 6 } -ExpectCalls 'AddRp,AddTpm,Resume'
Invoke-Case 'Secure Boot off -> WARN' -Params $NC -Setup { Set-Compliant; $Global:M.SecureBoot = $false } -ExpectText 'WARN Secure Boot'
Invoke-Case 'WinRE disabled -> WARN' -Params $NC -Setup { Set-Compliant; $Global:M.WinRe = 'Disabled' } -ExpectText 'WARN WinRE'

# --- 8. Console colors of the results table: PASS green, WARN yellow, FAIL (every STOP) red, header plain ---
# Write-Host lines arrive on the information stream with their ForegroundColor (the host default when none is given).
function Get-ConsoleLines([hashtable]$Params, [scriptblock]$Setup) {
    Reset-Mock; & $Setup
    $P = @{ LogDir = (Join-Path $Work 'colors') }
    foreach ($K in $Params.Keys) { $P[$K] = $Params[$K] }
    foreach ($R in @(& $ScriptPath @P 6>&1)) {
        if ($R -is [System.Management.Automation.InformationRecord] -and $R.MessageData -is [System.Management.Automation.HostInformationMessage]) {
            [pscustomobject]@{ Text = [string]$R.MessageData.Message; Color = [string]$R.MessageData.ForegroundColor }
        }
    }
}
function Test-RowColors([string]$Name, $Lines, [string[]]$MustHave) {
    $Expect = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
    $Bad = New-Object System.Collections.Generic.List[string]
    $Row = $null
    foreach ($L in $Lines) {
        $First = ($L.Text -split '\s+', 2)[0]
        if ($Expect.ContainsKey($First)) { $Row = $First; if ($L.Color -ne $Expect[$First]) { $Bad.Add("$First row is '$($L.Color)'") } }
        elseif ($Row -and $L.Text -match '^\s+\S') { if ($L.Color -ne $Expect[$Row]) { $Bad.Add("wrapped $Row line is '$($L.Color)'") } }
        else { $Row = $null; if ($L.Text -match '^Status\s+Check' -and $Expect.Values -contains $L.Color) { $Bad.Add("header is '$($L.Color)'") } }
    }
    foreach ($S in $MustHave) { if (-not @($Lines | Where-Object { $_.Text -match "^$S " }).Count) { $Bad.Add("no $S row") } }
    Assert-That ($Bad.Count -eq 0) $Name (($Bad | Select-Object -Unique) -join '; ')
}
Test-RowColors 'Colors: PASS rows green, WARN rows yellow' (Get-ConsoleLines $NC { Set-Compliant; $Global:M.SecureBoot = $false }) 'PASS', 'WARN'
$StopLines = @(Get-ConsoleLines $NC { $Global:M.Pol = @{} })
Test-RowColors 'Colors: STOP (FAIL) row red, wrapped lines too' $StopLines 'PASS', 'FAIL'
Assert-That (@($StopLines | Where-Object { $_.Text -match '^\s+\S' -and $_.Color -eq 'Red' }).Count -gt 0) 'Colors: the long STOP message wraps and stays red' 'no wrapped red line found'

# --- 9. Guard: a real (module) command must never run under the harness (last: it leaves the mocks unusable) ---
function Invoke-GuardCase {
    New-Module -Name FakeRealStartDecryption -ScriptBlock { function Start-Decryption { param($Drive) $Global:M.Calls.Add('REAL') }; Export-ModuleMember -Function Start-Decryption } | Import-Module -Scope Local
    try { Invoke-Case 'Guard: module command instead of a mock -> STOP' -Params $RE -ExpectExit 1 -ExpectText 'is not a mock function' }
    finally { Remove-Module -Name FakeRealStartDecryption -ErrorAction SilentlyContinue }
}
Invoke-GuardCase

Remove-Variable -Name BitLockerScriptTestHarness -Scope Global
Remove-Item -LiteralPath $Work -Recurse -Force
Write-Host ''
if ($Failures.Count) { Write-Host "FAILED: $($Failures.Count) of $Checks check(s)" -ForegroundColor Red; exit 1 }
Write-Host "PASSED: $Checks checks ($CaseNo script runs)" -ForegroundColor Green
