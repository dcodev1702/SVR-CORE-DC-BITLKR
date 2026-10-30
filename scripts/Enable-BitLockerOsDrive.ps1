# Turn on BitLocker for the operating system drive of a domain-joined computer, with its recovery password in AD DS first
# (README section 5). Run ON that computer, elevated, in Windows PowerShell 5.1 or PowerShell 7. ASCII-only.
#
# In order - each step runs only after the one before it succeeded:
#   1. Checks: elevation, OS drive, domain-joined and a DC answers, the AD backup policy (GPO) is applied, TPM ready.
#      Without a TPM it names the platform (Hyper-V, VMware, KVM / Proxmox, or physical) and shows how to add one; on a
#      Hyper-V VM that is the exact Enable-VmTpm.ps1 command for its host.
#   2. Recovery password. When BitLocker is on for the drive (encrypted, incl. 'Waiting for Activation'): add one or back
#      up an existing one, then confirm in AD that the object for that exact protector exists before any other step.
#      When the drive is decrypted, BitLocker cannot back up yet (FVE_E_NOT_ACTIVATED): the password is added, and
#      BitLocker writes it to AD when step 3 turns it on - with RequireActiveDirectoryBackup = 1 it does not encrypt
#      unless that write succeeds. The script then looks for the AD object; if the hardware test is still pending, it
#      may only appear once encryption starts after the restart, so run the script again then to confirm it.
#   3. TPM protector and protection:
#        - decrypted drive         -> Enable-BitLocker with the encryption method (XTS-AES 256 by default) and the TPM.
#                                     Encryption starts after the restart that runs the hardware test (-SkipHardwareTest: now).
#        - encrypted, same method  -> add the TPM protector and turn protection on. This also completes a drive that
#                                     Windows device encryption left 'Waiting for Activation' (clear key, no protectors).
#        - encrypted, other method -> only with -ReEncrypt: decrypt, wait, then as for a decrypted drive.
#   4. Verify from BitLocker and AD. Running it again when everything matches changes nothing.
#
#   .\Enable-BitLockerOsDrive.ps1 -WhatIf          # plan only
#   .\Enable-BitLockerOsDrive.ps1                  # shows the plan in yellow, asks Y/N
#   .\Enable-BitLockerOsDrive.ps1 -ReEncrypt       # drive uses another method (e.g. XTS-AES 128): decrypt, re-encrypt
#   .\Enable-BitLockerOsDrive.ps1 -NoConfirm       # automation
# The recovery password is never printed or logged (the BitLocker cmdlets' warnings, which contain it, are suppressed).
# Needs Confirm-Change.ps1 in the same folder, and VmTpmGuidance.ps1 for the no-TPM guidance (without it, a short hint).
# Evidence: <LogDir>\Enable-BitLockerOsDrive-<time>.log and .csv.
# Read the recovery password from AD with README section 6.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # Operating system drive. Empty = %SystemDrive%.
    [ValidatePattern('^$|^[A-Za-z]:$')][string]$MountPoint = '',
    # Must match the GPO's 'Choose drive encryption method' setting when one applies.
    [ValidateSet('XtsAes256', 'XtsAes128', 'Aes256', 'Aes128')][string]$EncryptionMethod = 'XtsAes256',
    # Decrypt a drive encrypted with another method and encrypt it again. Its data is not encrypted while this runs.
    [switch]$ReEncrypt,
    # How long to wait for decryption before stopping (run the script again later to continue).
    [ValidateRange(1, 1440)][int]$DecryptWaitMinutes = 240,
    # Encrypt only used space (faster; free space keeps whatever it held before).
    [switch]$UsedSpaceOnly,
    # Start encrypting now instead of after the restart that tests TPM unlock.
    [switch]$SkipHardwareTest,
    # Folder for the transcript and results CSV. Empty = %SystemDrive%\Logs.
    [ValidatePattern('^$|^[A-Za-z]:\\[^"*?<>|]+$')][string]$LogDir = '',
    [switch]$NoConfirm
)
$ErrorActionPreference = 'Stop'

$MethodCodes   = @{ Aes128 = 3; Aes256 = 4; XtsAes128 = 6; XtsAes256 = 7 }
$MethodNames   = @{ 3 = 'Aes128'; 4 = 'Aes256'; 6 = 'XtsAes128'; 7 = 'XtsAes256' }
$AdWaitSeconds = 60

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Status, [string]$Check, [string]$Detail) { $Results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail }) }

# The results table, one console line at a time: PASS rows green, WARN yellow, FAIL (every STOP) red. Wrapped lines of a
# row keep its color; the header stays plain.
function Write-ResultsTable($Rows) {
    $Colors = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
    $Color = $null
    foreach ($Line in (($Rows | Format-Table -AutoSize -Wrap | Out-String -Width 220) -split '\r?\n')) {
        $First = ($Line -split '\s+', 2)[0]
        if ($Colors.ContainsKey($First)) { $Color = $Colors[$First] }
        elseif ($Line -notmatch '^\s') { $Color = $null }
        if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line }
    }
}

# --- Decision logic (no system access) ---

# 'Encrypt', 'Activate', 'ReEncrypt', 'WaitThenEncrypt', 'InProgress' or 'PendingRestart'; throws STOP for anything else
function Get-Mode($Vol, [string]$Method, [bool]$AllowReEncrypt, [string]$HardwareTest) {
    $HasTpm = @($Vol.Protectors | Where-Object { $_.Type -like 'Tpm*' }).Count -gt 0
    switch ($Vol.VolumeStatus) {
        'FullyDecrypted' {
            if ($HardwareTest -eq 'Failed') { throw 'STOP: the last BitLocker hardware test failed, so encryption did not start (the TPM could not unlock the drive). Check the System event log, fix the TPM, then run this again. Nothing was changed.' }
            if ($HardwareTest -eq 'Pending' -and $HasTpm) { return 'PendingRestart' }
            if ($HasTpm) { throw "STOP: $($Vol.MountPoint) is decrypted but already has a TPM protector without a pending hardware test. Remove it (Remove-BitLockerKeyProtector) or finish encryption by hand. Nothing was changed." }
            return 'Encrypt'
        }
        'FullyEncrypted' {
            if ($Vol.EncryptionMethod -eq $Method) { return 'Activate' }
            if ($AllowReEncrypt) { return 'ReEncrypt' }
            throw "STOP: $($Vol.MountPoint) is encrypted with $($Vol.EncryptionMethod), not $Method. A method can only change by decrypting and encrypting again: run this with -ReEncrypt (its data is not encrypted while that runs), or pass -EncryptionMethod $($Vol.EncryptionMethod). Nothing was changed."
        }
        'EncryptionInProgress' {
            if ($Vol.EncryptionMethod -eq $Method) { return 'InProgress' }
            throw "STOP: $($Vol.MountPoint) is being encrypted with $($Vol.EncryptionMethod), not $Method. Let it finish, then run this with -ReEncrypt. Nothing was changed."
        }
        'DecryptionInProgress' {
            if ($AllowReEncrypt) { return 'WaitThenEncrypt' }
            throw "STOP: $($Vol.MountPoint) is being decrypted. Let it finish, or run this with -ReEncrypt to wait for it and encrypt again. Nothing was changed."
        }
        default { throw "STOP: $($Vol.MountPoint) is '$($Vol.VolumeStatus)'. Finish or resume that first (manage-bde -status / manage-bde -resume). Nothing was changed." }
    }
}

# 'RecoveryPassword {ID}, Tpm {ID}' - IDs only, never the password
function Format-Protectors($Vol) {
    $P = @($Vol.Protectors)
    if ($P.Count -eq 0) { return 'none' }
    ($P | ForEach-Object { '{0} {1}' -f $_.Type, $_.Id }) -join ', '
}

# --- System access (the test harness replaces these with mocks) ---

$UnderTest = [bool](Get-Variable -Name BitLockerScriptTestHarness -ErrorAction SilentlyContinue)
if (-not $UnderTest) {
    function Test-IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

    # -WhatIf (global when started with -File, script-scoped when started with &) turns module set-up into 'What if' noise
    function Import-BitLockerModules {
        $Saved = $Global:WhatIfPreference
        $Global:WhatIfPreference = $false
        $WhatIfPreference = $false
        try {
            Import-Module -Name BitLocker -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop
            foreach ($Name in 'TrustedPlatformModule', 'SecureBoot', 'CimCmdlets') { Import-Module -Name $Name -ErrorAction Stop }
            'PowerShell {0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion
        }
        finally { $Global:WhatIfPreference = $Saved }
    }

    # Read-only queries must run under -WhatIf too: Get-BitLockerVolume calls Invoke-CimMethod (GetLockStatus) internally,
    # which -WhatIf would skip, and the query then fails. Each query clears -WhatIf for its own duration.

    # Copies only status, method and protector IDs/types - never a recovery password
    function Get-OsVolumeState([string]$Drive) {
        $Saved = $Global:WhatIfPreference; $Global:WhatIfPreference = $false; $WhatIfPreference = $false
        try { $V = Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop } finally { $Global:WhatIfPreference = $Saved }
        [pscustomobject]@{
            MountPoint = [string]$V.MountPoint; VolumeType = [string]$V.VolumeType; VolumeStatus = [string]$V.VolumeStatus
            ProtectionStatus = [string]$V.ProtectionStatus; EncryptionMethod = [string]$V.EncryptionMethod; EncryptionPercentage = [double]$V.EncryptionPercentage
            Protectors = @($V.KeyProtector | ForEach-Object { [pscustomobject]@{ Id = ([string]$_.KeyProtectorId).ToUpperInvariant(); Type = [string]$_.KeyProtectorType } })
        }
    }

    # 'None', 'Failed' or 'Pending' (Win32_EncryptableVolume.GetHardwareTestStatus: 0, 1, 2)
    function Get-HardwareTestStatus([string]$Drive) {
        $Saved = $Global:WhatIfPreference; $Global:WhatIfPreference = $false; $WhatIfPreference = $false
        try {
            $Ev = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter = '$Drive'"
            if (-not $Ev) { return 'Unknown' }
            $R = Invoke-CimMethod -InputObject $Ev -MethodName GetHardwareTestStatus
        }
        finally { $Global:WhatIfPreference = $Saved }
        switch ([int]$R.TestStatus) { 0 { 'None' } 1 { 'Failed' } 2 { 'Pending' } default { 'Unknown' } }
    }

    function Test-DomainJoined { [bool](Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain }

    # The DC the locator picks for this computer - the same kind of DC the BitLocker backup writes to
    function Get-DomainControllerName { [string][System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().FindDomainController().Name }

    # $null unless exactly one computer object matches (the name is checked against a strict pattern before it gets here)
    function Get-ComputerDn([string]$Dc, [string]$Name) {
        $S = New-Object System.DirectoryServices.DirectorySearcher([adsi]"LDAP://$Dc")
        $S.Filter = "(&(objectCategory=computer)(sAMAccountName=$Name`$))"
        [void]$S.PropertiesToLoad.Add('distinguishedName')
        $Found = @($S.FindAll())
        if ($Found.Count -ne 1) { return $null }
        [string]$Found[0].Properties['distinguishedname'][0]
    }

    # Recovery password IDs ({GUID}, upper case) of the msFVE-RecoveryInformation objects under the computer object.
    # Their names are '<time>{<recovery password ID>}'. Only names are read, never the password attribute.
    function Find-AdRecoveryIds([string]$Dc, [string]$ComputerDn) {
        $S = New-Object System.DirectoryServices.DirectorySearcher((New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Dc/$ComputerDn")))
        $S.Filter = '(objectClass=msFVE-RecoveryInformation)'
        $S.SearchScope = 'OneLevel'
        [void]$S.PropertiesToLoad.Add('name')
        foreach ($R in $S.FindAll()) {
            $M = [regex]::Match([string]$R.Properties['name'][0], '\{[0-9A-Fa-f-]{36}\}')
            if ($M.Success) { $M.Value.ToUpperInvariant() }
        }
    }

    function Wait-AdRecoveryId([string]$Dc, [string]$ComputerDn, [string]$Id, [int]$Seconds) {
        $Deadline = (Get-Date).AddSeconds($Seconds)
        do {
            if (@(Find-AdRecoveryIds $Dc $ComputerDn) -contains $Id) { return $true }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $Deadline)
        return $false
    }

    function Get-FvePolicy {
        $Map = @{}
        $Path = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'
        if (Test-Path -LiteralPath $Path) { $K = Get-Item -LiteralPath $Path; foreach ($N in $K.Property) { $Map[$N] = $K.GetValue($N) } }
        return $Map
    }

    function Get-TpmState {
        $Saved = $Global:WhatIfPreference; $Global:WhatIfPreference = $false; $WhatIfPreference = $false
        try { $T = Get-Tpm } finally { $Global:WhatIfPreference = $Saved }
        [pscustomobject]@{ Present = [bool]$T.TpmPresent; Ready = [bool]$T.TpmReady }
    }

    function Get-SecureBootState { try { [bool](Confirm-SecureBootUEFI) } catch { $null } }

    # What this computer is (SMBIOS), and on a Hyper-V VM its name and host from the Data Exchange integration service
    function Get-PlatformFacts {
        $Cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $Bios = Get-CimInstance -ClassName Win32_BIOS
        $Guest = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Manufacturer = [string]$Cs.Manufacturer; Model = [string]$Cs.Model
            BiosManufacturer = [string]$Bios.Manufacturer; BiosVersion = [string]$Bios.SMBIOSBIOSVersion
            GuestVmName = $(if ($Guest) { [string]$Guest.VirtualMachineName } else { '' })
            GuestHostName = $(if ($Guest) { [string]$Guest.PhysicalHostNameFullyQualified } else { '' })
        }
    }

    function Get-WinReState {
        $Out = (& (Join-Path $env:SystemRoot 'System32\reagentc.exe') /info) -join "`n"
        if ($Out -match 'Windows RE status:\s*Enabled') { 'Enabled' } elseif ($Out -match 'Windows RE status:\s*Disabled') { 'Disabled' } else { 'Unknown' }
    }

    # 'D: (LABEL)' for each optical drive with a disc or ISO in it
    function Get-OpticalMedia { Get-CimInstance -ClassName Win32_CDROMDrive | Where-Object { $_.MediaLoaded } | ForEach-Object { '{0} ({1})' -f $_.Drive, $_.VolumeName } }

    # True when the drive is fully decrypted before the deadline
    function Wait-Decryption([string]$Drive, [int]$Minutes) {
        $Deadline = (Get-Date).AddMinutes($Minutes)
        while ((Get-Date) -lt $Deadline) {
            $V = Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop
            if ([string]$V.VolumeStatus -eq 'FullyDecrypted') { Write-Progress -Activity "Decrypting $Drive" -Completed; return $true }
            Write-Progress -Activity "Decrypting $Drive" -Status ('{0:N1}% still encrypted' -f $V.EncryptionPercentage) -PercentComplete ([Math]::Max(0, [Math]::Min(100, 100 - $V.EncryptionPercentage)))
            Start-Sleep -Seconds 15
        }
        return $false
    }

    function Start-Decryption([string]$Drive) { Disable-BitLocker -MountPoint $Drive -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null }

    # Returns the new protector's ID. The cmdlet's warning (which shows the password) and its output are discarded.
    function Add-RecoveryPasswordProtector([string]$Drive) {
        $Before = @((Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop).KeyProtector | Where-Object { [string]$_.KeyProtectorType -eq 'RecoveryPassword' } | ForEach-Object { ([string]$_.KeyProtectorId).ToUpperInvariant() })
        Add-BitLockerKeyProtector -MountPoint $Drive -RecoveryPasswordProtector -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        $After = @((Get-BitLockerVolume -MountPoint $Drive -ErrorAction Stop).KeyProtector | Where-Object { [string]$_.KeyProtectorType -eq 'RecoveryPassword' } | ForEach-Object { ([string]$_.KeyProtectorId).ToUpperInvariant() })
        @($After | Where-Object { $Before -notcontains $_ })[0]
    }

    function Backup-RecoveryPassword([string]$Drive, [string]$Id) { Backup-BitLockerKeyProtector -MountPoint $Drive -KeyProtectorId $Id -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null }

    function Add-TpmProtector([string]$Drive) { Add-BitLockerKeyProtector -MountPoint $Drive -TpmProtector -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null }

    function Enable-OsEncryption([string]$Drive, [string]$Method, [bool]$UsedOnly, [bool]$SkipTest) {
        $A = @{ MountPoint = $Drive; EncryptionMethod = $Method; TpmProtector = $true; WarningAction = 'SilentlyContinue'; ErrorAction = 'Stop' }
        if ($UsedOnly) { $A['UsedSpaceOnly'] = $true }
        if ($SkipTest) { $A['SkipHardwareTest'] = $true }
        Enable-BitLocker @A | Out-Null
    }

    function Resume-Protection([string]$Drive) { Resume-BitLocker -MountPoint $Drive -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null }
}

# --- Run ---

if (-not $LogDir) { $LogDir = Join-Path $env:SystemDrive 'Logs' }
$Log = Join-Path $LogDir ('Enable-BitLockerOsDrive-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -Path $LogDir -ItemType Directory -Force -WhatIf:$false | Out-Null
Start-Transcript -LiteralPath "$Log.log" -WhatIf:$false | Out-Null
$Restart = ''
try {
    # 1. Preconditions - nothing is changed until the confirmation below
    if ($UnderTest) {
        foreach ($Name in 'Start-Decryption', 'Add-RecoveryPasswordProtector', 'Backup-RecoveryPassword', 'Add-TpmProtector', 'Enable-OsEncryption', 'Resume-Protection') {
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
    try { $ModuleInfo = Import-BitLockerModules } catch { throw "STOP: the BitLocker, TPM and Secure Boot modules could not be loaded ($($_.Exception.Message)). Nothing was changed." }
    Add-Result 'PASS' 'Modules' ([string]$ModuleInfo)

    if (-not $MountPoint) { $MountPoint = $env:SystemDrive }
    $MountPoint = $MountPoint.ToUpperInvariant()
    $Vol = Get-OsVolumeState $MountPoint
    if ($Vol.VolumeType -ne 'OperatingSystem') { throw "STOP: $MountPoint is a $($Vol.VolumeType) volume. This script handles the operating system drive only. Nothing was changed." }

    $ComputerName = $env:COMPUTERNAME
    if ($ComputerName -notmatch '^[A-Za-z0-9-]{1,15}$') { throw "STOP: the computer name '$ComputerName' is not a plain NetBIOS name. Nothing was changed." }
    if (-not (Test-DomainJoined)) { throw 'STOP: this computer is not joined to an Active Directory domain, so there is nowhere to store the recovery password. Nothing was changed.' }
    try { $Dc = Get-DomainControllerName } catch { throw "STOP: no domain controller answered ($($_.Exception.Message)). The recovery password cannot be stored in AD now. Nothing was changed." }
    $ComputerDn = Get-ComputerDn $Dc $ComputerName
    if (-not $ComputerDn) { throw "STOP: the computer object for $ComputerName was not found in AD on $Dc. Nothing was changed." }
    $AdIds = @(Find-AdRecoveryIds $Dc $ComputerDn)
    Add-Result 'PASS' 'Active Directory' ('{0} on {1}; {2} recovery object(s) stored for it' -f $ComputerDn, $Dc, $AdIds.Count)

    # The GPO must be in effect here, or the recovery password would not reach AD
    $Pol = Get-FvePolicy
    $NotSet = @(foreach ($N in 'OSRecovery', 'OSActiveDirectoryBackup', 'OSRequireActiveDirectoryBackup') { if ($Pol[$N] -ne 1) { '{0}={1}' -f $N, $(if ($null -eq $Pol[$N]) { 'not set' } else { $Pol[$N] }) } })
    if ($NotSet.Count) { throw "STOP: the AD backup policy is not in effect on this computer ($($NotSet -join ', ')). Run 'gpupdate /target:computer' and check 'gpresult /scope computer /r' for the BitLocker GPO. Nothing was changed." }
    if ($Pol['OSRecoveryPassword'] -eq 0) { throw 'STOP: policy OSRecoveryPassword = 0 does not allow a recovery password, so nothing could be stored in AD. Allow it in the GPO. Nothing was changed.' }
    if ($Pol['UseAdvancedStartup'] -eq 1 -and $Pol['UseTPM'] -eq 0) { throw 'STOP: policy UseTPM = 0 does not allow TPM-only startup, and this script adds a TPM-only protector. Nothing was changed.' }
    if ($UsedSpaceOnly -and $Pol['OSEncryptionType'] -eq 1) { throw 'STOP: policy OSEncryptionType = 1 requires full encryption; drop -UsedSpaceOnly. Nothing was changed.' }
    if (-not $UsedSpaceOnly -and $Pol['OSEncryptionType'] -eq 2) { throw 'STOP: policy OSEncryptionType = 2 requires used-space-only encryption; add -UsedSpaceOnly. Nothing was changed.' }
    $PolMethod = $Pol['EncryptionMethodWithXtsOs']
    if ($null -ne $PolMethod -and [int]$PolMethod -ne $MethodCodes[$EncryptionMethod]) {
        throw "STOP: the GPO sets EncryptionMethodWithXtsOs = $PolMethod ($($MethodNames[[int]$PolMethod])), but -EncryptionMethod is $EncryptionMethod. BitLocker refuses a method that differs from policy. Nothing was changed."
    }
    if ($null -eq $PolMethod) { Add-Result 'WARN' 'Policy' "AD backup is required by policy; no encryption-method policy applies, so $EncryptionMethod comes from -EncryptionMethod" }
    else { Add-Result 'PASS' 'Policy' "AD backup required; encryption method $EncryptionMethod (EncryptionMethodWithXtsOs = $PolMethod)" }

    $Tpm = Get-TpmState
    if (-not $Tpm.Present) {
        # Say what this computer is and how it gets a TPM; on a Hyper-V VM, the exact command for its host
        $Facts = Get-PlatformFacts
        $GuidanceFile = Join-Path $PSScriptRoot 'VmTpmGuidance.ps1'
        $Message = 'STOP: no TPM was found. Add one (README section 8), then run this script again. Nothing was changed.'
        if (Test-Path -LiteralPath $GuidanceFile -PathType Leaf) {
            . $GuidanceFile
            $Platform = Resolve-VmPlatform $Facts.Manufacturer $Facts.Model $Facts.BiosManufacturer $Facts.BiosVersion
            $What = '{0} is a {1} ({2} / {3})' -f $ComputerName, $VmPlatformText[$Platform], $Facts.Manufacturer, $Facts.Model
            if ($Platform -eq 'Hyper-V' -and $Facts.GuestVmName) { $What += ": VM '$($Facts.GuestVmName)' on the Hyper-V host $($Facts.GuestHostName)" }
            Write-Host ''
            Write-Host "No TPM: $What." -ForegroundColor Yellow
            foreach ($Line in (Get-VtpmGuidance $Platform $Facts.GuestVmName $Facts.GuestHostName)) { Write-Host $Line -ForegroundColor Yellow }
            Write-Host ''
            $Message = 'STOP: no TPM was found on this {0}. To add one, {1}. The steps are shown above (README section 8); then run this script again. Nothing was changed.' -f $VmPlatformText[$Platform], (Get-VtpmFix $Platform $Facts.GuestVmName $Facts.GuestHostName)
        }
        throw $Message
    }
    if (-not $Tpm.Ready) { throw 'STOP: the TPM is not ready (Get-Tpm: TpmReady = False). Initialize it (Initialize-Tpm, or tpm.msc) first. Nothing was changed.' }
    Add-Result 'PASS' 'TPM' 'present and ready'
    $SecureBoot = Get-SecureBootState
    if ($SecureBoot -eq $true) { Add-Result 'PASS' 'Secure Boot' 'on' } else { Add-Result 'WARN' 'Secure Boot' 'off or unknown: BitLocker falls back to a TPM profile that firmware and boot changes break more easily' }
    $WinRe = Get-WinReState
    if ($WinRe -eq 'Enabled') { Add-Result 'PASS' 'WinRE' 'enabled' } else { Add-Result 'WARN' 'WinRE' "$WinRe : the recovery screen still works, but recovery tools are not available from WinRE" }

    # 2. Plan
    $Hw = Get-HardwareTestStatus $MountPoint
    Add-Result 'PASS' 'Drive' ('{0} {1}, {2}, protection {3}, protectors: {4}' -f $MountPoint, $Vol.VolumeStatus, $Vol.EncryptionMethod, $Vol.ProtectionStatus, (Format-Protectors $Vol))
    $Mode = Get-Mode $Vol $EncryptionMethod ([bool]$ReEncrypt) $Hw

    $Steps = New-Object System.Collections.Generic.List[string]
    if ($Mode -eq 'ReEncrypt') { $Steps.Add('Decrypt') }
    if ($Mode -eq 'ReEncrypt' -or $Mode -eq 'WaitThenEncrypt') { $Steps.Add('WaitDecrypt') }
    $Rps = @($Vol.Protectors | Where-Object { $_.Type -eq 'RecoveryPassword' })
    $RpNotInAd = @($Rps | Where-Object { $AdIds -notcontains $_.Id })
    # Decrypted when its recovery password is added: BitLocker stores it in AD only when encryption is turned on
    $Decrypted = @('Encrypt', 'ReEncrypt', 'WaitThenEncrypt', 'PendingRestart') -contains $Mode
    if ($Mode -eq 'ReEncrypt' -or $Mode -eq 'WaitThenEncrypt' -or $Rps.Count -eq 0) { $Steps.Add('AddRecoveryPassword') }
    elseif ($RpNotInAd.Count -and -not $Decrypted) { $Steps.Add('BackupRecoveryPassword') }
    if ($Mode -eq 'Encrypt' -or $Mode -eq 'ReEncrypt' -or $Mode -eq 'WaitThenEncrypt') { $Steps.Add('Encrypt') }
    if ($Mode -eq 'Activate') {
        if (@($Vol.Protectors | Where-Object { $_.Type -like 'Tpm*' }).Count -eq 0) { $Steps.Add('AddTpm') }
        if ($Vol.ProtectionStatus -ne 'On') { $Steps.Add('Resume') }
    }

    # BitLocker refuses to turn on while bootable media is in the computer (FVE_E_BOOTABLE_CDDVD, 0x80310030; seen on
    # WIN11-PAW-WDAC with the Windows ISO in its virtual DVD drive). Checked before the first change - before -ReEncrypt decrypts.
    if (@($Steps | Where-Object { @('Decrypt', 'Encrypt', 'AddTpm', 'Resume') -contains $_ }).Count) {
        $Media = @(Get-OpticalMedia)
        if ($Media.Count) { throw "STOP: $($Media -join ', ') holds a disc or ISO, and BitLocker refuses to turn on while bootable media is in the computer (0x80310030). Remove it - on a Hyper-V VM, on the host: Get-VMDvdDrive -VMName <vm> | Set-VMDvdDrive -Path `$null - then restart and run this again. Nothing was changed." }
        Add-Result 'PASS' 'Optical drives' 'no disc or ISO loaded'
    }

    if ($Steps.Count -eq 0) {
        if ($Mode -eq 'InProgress') { Add-Result 'PASS' 'Plan' ('encryption with {0} is in progress ({1:N0}%); recovery password stored in AD - nothing to change' -f $Vol.EncryptionMethod, $Vol.EncryptionPercentage) }
        elseif ($Mode -eq 'PendingRestart') {
            if ($RpNotInAd.Count) { Add-Result 'WARN' 'Plan' 'the hardware test is pending and the recovery password is not in AD yet: BitLocker writes it when encryption starts after the restart, and does not encrypt without it' }
            else { Add-Result 'PASS' 'Plan' 'recovery password stored in AD; the hardware test is pending - restart to start encryption' }
            $Restart = 'Restart the computer: the hardware test runs, then encryption starts. Run this script again afterwards to confirm the recovery password in AD.'
        }
        else { Add-Result 'PASS' 'Plan' "protection is on with $($Vol.EncryptionMethod), TPM and recovery password; the recovery password is in AD - nothing to change" }
    }
    else {
        # 3. Confirm - one yellow Y/N for everything below
        if (-not $WhatIfPreference) {
            $Words = @{
                Decrypt = "decrypt $MountPoint (Disable-BitLocker removes all protectors; its data is NOT encrypted until encryption completes again)"
                WaitDecrypt = "wait up to $DecryptWaitMinutes minutes for decryption to finish"
                AddRecoveryPassword = $(if ($Decrypted) { 'add a recovery password; BitLocker writes it to AD when the next step turns encryption on, and does not encrypt if that fails' } else { 'add a recovery password; the GPO writes it to AD, and this script confirms the AD object before going on' })
                BackupRecoveryPassword = 'back up the existing recovery password to AD and confirm the AD object'
                Encrypt = ('encrypt with {0} and a TPM protector ({1}{2})' -f $EncryptionMethod, $(if ($UsedSpaceOnly) { 'used space only' } else { 'full drive' }), $(if ($SkipHardwareTest) { ', starting now' } else { ', starting after the restart that tests TPM unlock' }))
                AddTpm = 'add a TPM protector (it replaces the clear key of a drive that is Waiting for Activation)'
                Resume = 'turn protection on'
            }
            $Detail = New-Object System.Collections.Generic.List[string]
            $Detail.Add("Computer: $ComputerName ($ComputerDn)")
            $Detail.Add(('Drive now: {0} {1}, {2}, protection {3}, protectors: {4}' -f $MountPoint, $Vol.VolumeStatus, $Vol.EncryptionMethod, $Vol.ProtectionStatus, (Format-Protectors $Vol)))
            $N = 0
            foreach ($S in $Steps) { $N++; $Detail.Add(('  {0}. {1}' -f $N, $Words[$S])) }
            $Detail.Add('Effect: no encryption without the recovery password in AD; read it with README section 6.')
            $Detail.Add("Undo: Disable-BitLocker -MountPoint $MountPoint (decrypts the drive). The recovery password stays in AD.")
            Confirm-Change -NoConfirm:$NoConfirm -Action "turn on BitLocker for $MountPoint on $ComputerName" -Detail $Detail.ToArray()
            $ConfirmPreference = 'None'
        }

        # 4. Apply, step by step; each one only after the one before it succeeded
        $Done = $true
        foreach ($S in $Steps) {
            if ($S -eq 'Decrypt') {
                if (-not $PSCmdlet.ShouldProcess($MountPoint, 'Decrypt (Disable-BitLocker)')) { Add-Result 'PASS' 'Decrypt' "-WhatIf: would decrypt $MountPoint"; continue }
                Start-Decryption $MountPoint
                Add-Result 'PASS' 'Decrypt' "started on $MountPoint (all protectors removed)"
            }
            elseif ($S -eq 'WaitDecrypt') {
                if ($WhatIfPreference) { Add-Result 'PASS' 'Wait' "-WhatIf: would wait up to $DecryptWaitMinutes minutes for decryption"; continue }
                if (-not (Wait-Decryption $MountPoint $DecryptWaitMinutes)) {
                    Add-Result 'WARN' 'Decryption' "still running after $DecryptWaitMinutes minutes. Run this script again with -ReEncrypt: it waits for the rest and then encrypts."
                    $Done = $false
                    break
                }
                Add-Result 'PASS' 'Decryption' "$MountPoint is fully decrypted"
            }
            elseif ($S -eq 'AddRecoveryPassword') {
                if (-not $PSCmdlet.ShouldProcess($MountPoint, 'Add a recovery password (stored in AD by policy)')) { Add-Result 'PASS' 'Recovery password' "-WhatIf: would add one and confirm it in AD"; continue }
                try { $NewId = Add-RecoveryPasswordProtector $MountPoint }
                catch { throw "STOP: adding the recovery password failed ($($_.Exception.Message)). With RequireActiveDirectoryBackup = 1 this usually means it could not be written to AD. No further step was run." }
                if (-not $NewId) { throw 'STOP: the new recovery password protector was not found on the drive. No further step was run.' }
                if ($Decrypted) { Add-Result 'PASS' 'Recovery password' "$NewId added; BitLocker writes it to AD when encryption is turned on" }
                else {
                    if (-not (Wait-AdRecoveryId $Dc $ComputerDn $NewId $AdWaitSeconds)) { throw "STOP: recovery password $NewId was added, but no AD object for it appeared on $Dc within $AdWaitSeconds seconds. Check AD (README section 6) before going on; no further step was run." }
                    Add-Result 'PASS' 'Recovery password' "$NewId added and found in AD on $Dc"
                }
            }
            elseif ($S -eq 'BackupRecoveryPassword') {
                if (-not $PSCmdlet.ShouldProcess($MountPoint, 'Back up the recovery password to AD')) { Add-Result 'PASS' 'Recovery password' "-WhatIf: would back up $(($RpNotInAd | ForEach-Object { $_.Id }) -join ', ') to AD"; continue }
                foreach ($Rp in $RpNotInAd) {
                    Backup-RecoveryPassword $MountPoint $Rp.Id
                    if (-not (Wait-AdRecoveryId $Dc $ComputerDn $Rp.Id $AdWaitSeconds)) { throw "STOP: recovery password $($Rp.Id) was backed up, but no AD object for it appeared on $Dc within $AdWaitSeconds seconds. No further step was run." }
                    Add-Result 'PASS' 'Recovery password' "$($Rp.Id) backed up and found in AD on $Dc"
                }
            }
            elseif ($S -eq 'Encrypt') {
                if (-not $PSCmdlet.ShouldProcess($MountPoint, "Enable-BitLocker $EncryptionMethod with TPM")) { Add-Result 'PASS' 'Encrypt' "-WhatIf: would encrypt with $EncryptionMethod and a TPM protector"; continue }
                Enable-OsEncryption $MountPoint $EncryptionMethod ([bool]$UsedSpaceOnly) ([bool]$SkipHardwareTest)
                Add-Result 'PASS' 'Encrypt' "Enable-BitLocker with $EncryptionMethod and a TPM protector"
                if (-not $SkipHardwareTest) { $Restart = 'Restart the computer: the hardware test checks that the TPM unlocks the drive, then encryption starts. Run this script again afterwards to confirm the recovery password in AD.' }
            }
            elseif ($S -eq 'AddTpm') {
                if (-not $PSCmdlet.ShouldProcess($MountPoint, 'Add a TPM protector')) { Add-Result 'PASS' 'TPM protector' '-WhatIf: would add one'; continue }
                Add-TpmProtector $MountPoint
                Add-Result 'PASS' 'TPM protector' 'added'
            }
            elseif ($S -eq 'Resume') {
                if (-not $PSCmdlet.ShouldProcess($MountPoint, 'Turn protection on')) { Add-Result 'PASS' 'Protection' '-WhatIf: would turn it on'; continue }
                Resume-Protection $MountPoint
                Add-Result 'PASS' 'Protection' 'turned on'
            }
        }

        # 5. Verify from BitLocker and AD
        if ($Done -and -not $WhatIfPreference) {
            $After = Get-OsVolumeState $MountPoint
            $AfterIds = @(Find-AdRecoveryIds $Dc $ComputerDn)
            $AfterRps = @($After.Protectors | Where-Object { $_.Type -eq 'RecoveryPassword' })
            # Give AD a moment for a password that BitLocker wrote when encryption was turned on just now
            $Missing = @($AfterRps | Where-Object { $AfterIds -notcontains $_.Id -and -not (Wait-AdRecoveryId $Dc $ComputerDn $_.Id $AdWaitSeconds) })
            $MissingText = ($Missing | ForEach-Object { $_.Id }) -join ', '
            if ($AfterRps.Count -eq 0) { Add-Result 'FAIL' 'Verify recovery password' "$MountPoint has no recovery password protector" }
            elseif ($Missing.Count -and $After.VolumeStatus -eq 'FullyDecrypted' -and (Get-HardwareTestStatus $MountPoint) -eq 'Pending') {
                Add-Result 'WARN' 'Verify recovery password' "$MissingText is not in AD yet. BitLocker writes it when encryption starts after the restart and does not encrypt without it (RequireActiveDirectoryBackup = 1). Run this script again after the restart to confirm it in AD."
            }
            elseif ($Missing.Count) { Add-Result 'FAIL' 'Verify recovery password' "not in AD: $MissingText" }
            else { Add-Result 'PASS' 'Verify recovery password' "$(($AfterRps | ForEach-Object { $_.Id }) -join ', ') in AD" }
            if (@($After.Protectors | Where-Object { $_.Type -like 'Tpm*' }).Count -eq 0) { Add-Result 'FAIL' 'Verify TPM protector' "$MountPoint has no TPM protector" }
            else { Add-Result 'PASS' 'Verify TPM protector' 'present' }
            if ($After.VolumeStatus -eq 'FullyEncrypted' -or $After.VolumeStatus -eq 'EncryptionInProgress') {
                if ($After.EncryptionMethod -ne $EncryptionMethod) { Add-Result 'FAIL' 'Verify method' "$($After.EncryptionMethod), expected $EncryptionMethod" }
                else { Add-Result 'PASS' 'Verify method' ('{0} ({1}, {2:N0}%)' -f $After.EncryptionMethod, $After.VolumeStatus, $After.EncryptionPercentage) }
                if ($After.VolumeStatus -eq 'FullyEncrypted' -and $After.ProtectionStatus -ne 'On') { Add-Result 'FAIL' 'Verify protection' "protection is $($After.ProtectionStatus)" }
                elseif ($After.VolumeStatus -eq 'FullyEncrypted') { Add-Result 'PASS' 'Verify protection' 'on' }
            }
            elseif ($After.VolumeStatus -eq 'FullyDecrypted' -and (Get-HardwareTestStatus $MountPoint) -eq 'Pending') { Add-Result 'PASS' 'Verify' 'hardware test pending: encryption starts after the restart' }
            else { Add-Result 'FAIL' 'Verify' "$MountPoint is $($After.VolumeStatus), which is not what the steps should have left" }
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
    Write-ResultsTable $Results
    Write-Host $Summary -ForegroundColor $Color
    if ($Restart -and -not $FailCount) { Write-Host "NEXT: $Restart" -ForegroundColor Yellow }
    $Results | Export-Csv -LiteralPath "$Log.csv" -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Host "Transcript: $Log.log   Results: $Log.csv"
    $StopArgs = @{}
    if ((Get-Command -Name Stop-Transcript).Parameters.ContainsKey('WhatIf')) { $StopArgs['WhatIf'] = $false }
    try { Stop-Transcript @StopArgs | Out-Null } catch { }
}
if ($FailCount) { exit 1 }
exit 0
