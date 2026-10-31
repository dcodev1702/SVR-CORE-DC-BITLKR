# Join a Hyper-V guest to the domain in the same OU as a reference server, then turn on BitLocker for its OS drive with
# the recovery password backed up to AD DS - the procedure of servers/README.md in dcodev1702/SVR-CORE-DC-BITLKR.
# Run ON the Hyper-V host, elevated, in an interactive PowerShell 7 window. It asks for the guest's local admin and a
# domain admin credential (neither is written anywhere), appends every step to the running log, and stops at the first
# failed check. Each step checks the current state first, so running it again continues where it stopped.
param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$RepoScripts,
    [Parameter(Mandatory)][string]$RunLog,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$Domain = 'skynet-home.local',
    [string]$DcIp = '192.168.10.100',
    [string]$ReferenceServer = 'PDQ-SRVR',
    [string]$GpoName = 'JMSC_BitLocker_AD_Backup_Servers'
)
$ErrorActionPreference = 'Stop'
$BaseDn = 'DC=' + ($Domain -split '\.' -join ',DC=')
$GuestDir = 'C:\Windows\Temp\BitLockerOs'
$PwshExe = (Get-Process -Id $PID).Path
$Fence = '```'

function Log([string]$Message, [string]$Level = 'INFO') {
    $Tag = if ($Level -eq 'INFO') { '' } else { "**$Level** " }
    Add-Content -LiteralPath $RunLog -Value ('- `{0}` {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $Tag, $Message)
    Write-Host $Message -ForegroundColor (@{ INFO = 'Gray'; PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Level])
}
function Section([string]$Title) { Add-Content -LiteralPath $RunLog -Value @('', "### $Title", ''); Write-Host "`n== $Title ==" -ForegroundColor Cyan }
function LogBlock([string]$Text) { Add-Content -LiteralPath $RunLog -Value @('', ($Fence + 'text'), $Text.TrimEnd(), $Fence, '') }

# Ask up to 3 times; $Test returns the credential to use or throws
function Read-Cred([string]$Message, [scriptblock]$Test) {
    for ($I = 1; $I -le 3; $I++) {
        Write-Host "`n$Message" -ForegroundColor Cyan
        $C = Get-Credential -Message $Message
        if (-not $C) { throw 'STOP: no credential entered' }
        try { return (& $Test $C) } catch { Write-Host "  That did not work: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    throw "STOP: 3 failed attempts for: $Message"
}

function Find-Ad([string]$SearchBase, [string]$Filter, [string[]]$Props, [string]$Scope = 'Subtree') {
    $E = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DcIp/$SearchBase", $DomainCred.UserName, $DomainCred.GetNetworkCredential().Password)
    $S = New-Object System.DirectoryServices.DirectorySearcher($E, $Filter)
    $S.SearchScope = $Scope
    foreach ($P in $Props) { [void]$S.PropertiesToLoad.Add($P) }
    @($S.FindAll())
}
function Get-ComputerDn([string]$Name) {
    @(Find-Ad $BaseDn "(&(objectCategory=computer)(sAMAccountName=$Name`$))" @('distinguishedName') | ForEach-Object { [string]$_.Properties['distinguishedname'][0] })
}

function Invoke-Guest([scriptblock]$Block, [object[]]$ArgumentList = @()) {
    Invoke-Command -VMName $VMName -Credential $LocalCred -ScriptBlock $Block -ArgumentList $ArgumentList -ErrorAction Stop
}
# Windows PowerShell commands that misbehave in a remote session (feature installs) run in a local powershell.exe in the guest
function Invoke-GuestPs51([string]$Command) {
    $Enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    (Invoke-Guest { param($E) & powershell.exe -NoProfile -NonInteractive -EncodedCommand $E } @($Enc)) -join "`n"
}
function Get-GuestFeatureState { (Invoke-GuestPs51 '(Get-WindowsFeature -Name BitLocker).InstallState.ToString()').Trim() }

function Restart-Guest([string]$Why) {
    $Boot = Invoke-Guest { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
    Invoke-Guest { shutdown.exe /r /t 5 /d p:2:4 /c 'Domain join and BitLocker' } | Out-Null
    Log ('restart requested ({0}); previous boot {1}' -f $Why, $Boot)
    $Deadline = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds 10
        try {
            $Now = Invoke-Command -VMName $VMName -Credential $LocalCred -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } -ErrorAction Stop
            if ($Now -gt $Boot) { Log ('back up, booted {0}' -f $Now) 'PASS'; return }
        }
        catch { }
    }
    throw "STOP: $VMName did not come back within 20 minutes after the restart"
}

# Enable-BitLockerOsDrive.ps1 as SYSTEM through a one-time scheduled task (servers/README.md section 5): run in a remote
# session its AD lookups fail (second hop); as SYSTEM it reaches AD with the computer account
function Invoke-BitLockerScriptAsSystem([string]$ScriptArgs, [string]$OutName) {
    Invoke-Guest {
        param($Dir, $ScriptArgs, $OutName)
        $Pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        $Out = Join-Path $Dir $OutName
        $Run = "& '$Dir\Enable-BitLockerOsDrive.ps1' $ScriptArgs *> '$Out'; exit `$LASTEXITCODE"
        $A = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$Run`""
        $P = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'BitLockerOs-Enable' -Action $A -Principal $P -Force | Out-Null
        Start-ScheduledTask -TaskName 'BitLockerOs-Enable'
        Start-Sleep -Seconds 5
        $Deadline = (Get-Date).AddMinutes(15)
        while ((Get-ScheduledTask -TaskName 'BitLockerOs-Enable').State -eq 'Running' -and (Get-Date) -lt $Deadline) { Start-Sleep -Seconds 5 }
        $Info = Get-ScheduledTaskInfo -TaskName 'BitLockerOs-Enable'
        Unregister-ScheduledTask -TaskName 'BitLockerOs-Enable' -Confirm:$false
        [pscustomobject]@{
            ExitCode = $Info.LastTaskResult
            Output   = $(if (Test-Path -LiteralPath $Out) { Get-Content -LiteralPath $Out -Raw } else { "(no output file $Out)" })
        }
    } @($GuestDir, $ScriptArgs, $OutName)
}

try {
    Section "1. Run started on $env:COMPUTERNAME"
    Log ('elevated PowerShell {0}; VM {1}; domain {2} via DC {3}' -f $PSVersionTable.PSVersion, $VMName, $Domain, $DcIp)
    $Vm = Get-VM -Name $VMName
    if ([string]$Vm.State -ne 'Running') { throw "STOP: $VMName is $($Vm.State), expected Running" }

    $LocalCred = Read-Cred "1 of 2: LOCAL administrator of $VMName (for example Administrator)" {
        param($C)
        $U = $C.UserName
        if ($U -like '.\*') { $U = "$VMName\" + $U.Substring(2) } elseif ($U -notmatch '[\\@]') { $U = "$VMName\$U" }
        $N = New-Object System.Management.Automation.PSCredential($U, $C.Password)
        [void](Invoke-Command -VMName $VMName -Credential $N -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop)
        $N
    }
    Log ('guest credential works: {0} (PowerShell Direct)' -f $LocalCred.UserName) 'PASS'
    $DomainCred = Read-Cred "2 of 2: DOMAIN admin for $Domain (for example SKYNET\lorenzo)" {
        param($C)
        $E = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DcIp/$BaseDn", $C.UserName, $C.GetNetworkCredential().Password)
        $E.RefreshCache(@('distinguishedName'))
        $C
    }
    Log ('domain credential works: {0} (LDAP bind to {1})' -f $DomainCred.UserName, $DcIp) 'PASS'

    Section "2. Target OU (same as $ReferenceServer)"
    $Ref = @(Get-ComputerDn $ReferenceServer)
    if ($Ref.Count -ne 1) { throw "STOP: found $($Ref.Count) computer objects named $ReferenceServer" }
    $OuDn = $Ref[0].Substring($Ref[0].IndexOf(',') + 1)
    Log ('{0} is {1} -> target OU **{2}**' -f $ReferenceServer, $Ref[0], $OuDn) 'PASS'
    $Existing = @(Get-ComputerDn $VMName)
    if ($Existing.Count -and $Existing[0] -ne "CN=$VMName,$OuDn") { throw "STOP: computer object $($Existing[0]) already exists outside the target OU. Move or delete it first." }
    if ($Existing.Count) { Log ('computer object already exists in the target OU: {0}' -f $Existing[0]) 'WARN' }
    else { Log ('no computer object for {0} yet; the join creates CN={0},{1}' -f $VMName, $OuDn) }

    Section '3. Guest before'
    $Pre = Invoke-Guest {
        $Cs = Get-CimInstance Win32_ComputerSystem
        $Ip = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1
        $T = Get-Tpm
        [pscustomobject]@{
            Name = $env:COMPUTERNAME; PartOfDomain = [bool]$Cs.PartOfDomain; Domain = [string]$Cs.Domain
            IfIndex = $Ip.InterfaceIndex; IfAlias = $Ip.InterfaceAlias; IP = $Ip.IPAddress
            Dns = ((Get-DnsClientServerAddress -InterfaceIndex $Ip.InterfaceIndex -AddressFamily IPv4).ServerAddresses -join ', ')
            Tpm = 'present {0}, ready {1}' -f $T.TpmPresent, $T.TpmReady
            SecureBoot = $(try { [string](Confirm-SecureBootUEFI) } catch { 'unknown' })
        }
    }
    $Feature = Get-GuestFeatureState
    Log ('{0}: domain member {1} ({2}); NIC "{3}" {4}, DNS {5}; TPM {6}; Secure Boot {7}; BitLocker feature {8}' -f $Pre.Name, $Pre.PartOfDomain, $Pre.Domain, $Pre.IfAlias, $Pre.IP, $Pre.Dns, $Pre.Tpm, $Pre.SecureBoot, $Feature)
    if ($Pre.Name -ne $VMName) { throw "STOP: the guest's computer name is $($Pre.Name), not $VMName" }

    Section '4. DNS and domain join'
    $JoinedNow = $false
    if ($Pre.PartOfDomain -and $Pre.Domain -eq $Domain) { Log "already a member of $Domain - join skipped" 'PASS' }
    elseif ($Pre.PartOfDomain) { throw "STOP: the guest is a member of $($Pre.Domain), not $Domain" }
    else {
        $Dns = Invoke-Guest {
            param($IfIndex, $DcIp, $Domain)
            Set-DnsClientServerAddress -InterfaceIndex $IfIndex -ServerAddresses $DcIp
            Clear-DnsClientCache
            $Srv = Resolve-DnsName "_ldap._tcp.dc._msdcs.$Domain" -Type SRV -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'SRV' } | Select-Object -First 1
            [pscustomobject]@{
                Dns = ((Get-DnsClientServerAddress -InterfaceIndex $IfIndex -AddressFamily IPv4).ServerAddresses -join ', ')
                Dc = [string]$Srv.NameTarget
                Ldap = (Test-NetConnection $Srv.NameTarget -Port 389 -WarningAction SilentlyContinue).TcpTestSucceeded
            }
        } @($Pre.IfIndex, $DcIp, $Domain)
        Log ('DNS on "{0}" set to {1} (was {2}); DC locator finds {3}; LDAP reachable {4}' -f $Pre.IfAlias, $Dns.Dns, $Pre.Dns, $Dns.Dc, $Dns.Ldap) 'PASS'
        if (-not $Dns.Ldap) { throw 'STOP: the DC is not reachable on LDAP from the guest' }
        $Join = Invoke-Guest {
            param($Domain, $OuDn, $Cred)
            Add-Computer -DomainName $Domain -OUPath $OuDn -Credential $Cred -Force -PassThru -ErrorAction Stop
        } @($Domain, $OuDn, $DomainCred)
        if (-not $Join.HasSucceeded) { throw 'STOP: Add-Computer did not report success' }
        Log ('Add-Computer -DomainName {0} -OUPath "{1}": succeeded, restart pending' -f $Domain, $OuDn) 'PASS'
        $JoinedNow = $true
    }

    Section '5. BitLocker feature'
    if ($Feature -eq 'Installed') { Log 'BitLocker feature already installed' 'PASS' }
    else {
        $Feat = Invoke-GuestPs51 '$R = Install-WindowsFeature -Name BitLocker -IncludeAllSubFeature -IncludeManagementTools; "Success={0}; RestartNeeded={1}; ExitCode={2}; {3} feature(s): {4}" -f $R.Success, $R.RestartNeeded, $R.ExitCode, @($R.FeatureResult).Count, ((@($R.FeatureResult) | ForEach-Object { $_.DisplayName }) -join ", ")'
        Log "Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools: $Feat"
        if ($Feat -notmatch 'Success=True') { throw 'STOP: the BitLocker feature did not install' }
    }

    Section '6. Virtual DVD and vTPM (host)'
    foreach ($D in @(Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path })) {
        $Old = $D.Path
        Set-VMDvdDrive -VMName $VMName -ControllerNumber $D.ControllerNumber -ControllerLocation $D.ControllerLocation -Path $null
        Log ('ejected "{0}" from the virtual DVD drive (controller {1}:{2})' -f $Old, $D.ControllerNumber, $D.ControllerLocation) 'PASS'
    }
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
    $TpmOut = & $PwshExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoScripts 'Enable-VmTpm.ps1') -VMName $VMName -NoConfirm -LogDir $EvidenceDir 2>&1 | Out-String
    $TpmExit = $LASTEXITCODE
    Log 'Enable-VmTpm.ps1 -VMName FILE-SRVR-1 -NoConfirm output:'
    LogBlock $TpmOut
    if ($TpmExit -ne 0) { throw 'STOP: Enable-VmTpm.ps1 failed (output above)' }
    Log 'Enable-VmTpm.ps1 passed' 'PASS'

    Section '7. Restart: finish the join and the feature install'
    if ($JoinedNow -or (Get-GuestFeatureState) -ne 'Installed') { Restart-Guest 'domain join and BitLocker feature' }
    $Feature = Get-GuestFeatureState
    if ($Feature -ne 'Installed') { Restart-Guest "BitLocker feature still $Feature"; $Feature = Get-GuestFeatureState }
    if ($Feature -ne 'Installed') { throw "STOP: the BitLocker feature is $Feature after two restarts" }
    $Post = Invoke-Guest {
        $Cs = Get-CimInstance Win32_ComputerSystem
        $T = Get-Tpm
        [pscustomobject]@{
            PartOfDomain = [bool]$Cs.PartOfDomain; Domain = [string]$Cs.Domain
            SecureChannel = $(try { [bool](Test-ComputerSecureChannel) } catch { $false })
            Tpm = 'present {0}, ready {1}' -f $T.TpmPresent, $T.TpmReady
            BitLockerModule = [bool](Get-Module -ListAvailable -Name BitLocker)
        }
    }
    Log ('domain member {0} ({1}); secure channel {2}; TPM {3}; BitLocker feature {4}, module {5}' -f $Post.PartOfDomain, $Post.Domain, $Post.SecureChannel, $Post.Tpm, $Feature, $Post.BitLockerModule) $(if ($Post.PartOfDomain -and $Post.SecureChannel) { 'PASS' } else { 'FAIL' })
    if (-not ($Post.PartOfDomain -and $Post.Domain -eq $Domain -and $Post.SecureChannel)) { throw 'STOP: the guest is not a working member of the domain' }
    $MyDn = @(Get-ComputerDn $VMName)
    if ($MyDn.Count -ne 1 -or $MyDn[0] -ne "CN=$VMName,$OuDn") { throw ('STOP: computer object is "{0}", expected CN={1},{2}' -f ($MyDn -join '; '), $VMName, $OuDn) }
    $MyDn = $MyDn[0]
    Log ('AD: {0} - same OU as {1}' -f $MyDn, $ReferenceServer) 'PASS'

    Section '8. Group Policy'
    $Gp = Invoke-Guest {
        param($GpoName)
        $Upd = ((gpupdate.exe /target:computer /force) | Where-Object { $_.Trim() }) -join ' '
        $Res = (gpresult.exe /scope computer /r) -join "`n"
        $Fve = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Update = $Upd
            Applied = $Res -match [regex]::Escape($GpoName)
            Count = $(if ($Fve) { $Fve.Property.Count } else { 0 })
            Key = $(if ($Fve) { 'OSActiveDirectoryBackup={0}, OSRequireActiveDirectoryBackup={1}, EncryptionMethodWithXtsOs={2}, OSEncryptionType={3}' -f $Fve.GetValue('OSActiveDirectoryBackup'), $Fve.GetValue('OSRequireActiveDirectoryBackup'), $Fve.GetValue('EncryptionMethodWithXtsOs'), $Fve.GetValue('OSEncryptionType') } else { 'FVE policy key missing' })
        }
    } @($GpoName)
    Log "gpupdate: $($Gp.Update)"
    Log ('{0} applied: {1}; {2} values under HKLM\SOFTWARE\Policies\Microsoft\FVE ({3})' -f $GpoName, $Gp.Applied, $Gp.Count, $Gp.Key) $(if ($Gp.Applied) { 'PASS' } else { 'FAIL' })
    if (-not $Gp.Applied) { throw "STOP: $GpoName is not applied to $VMName" }

    Section '9. Enable-BitLockerOsDrive.ps1 -WhatIf (as SYSTEM)'
    $S = New-PSSession -VMName $VMName -Credential $LocalCred
    Invoke-Command -Session $S { param($D) New-Item -ItemType Directory -Path $D -Force | Out-Null } -ArgumentList $GuestDir
    foreach ($F in 'Enable-BitLockerOsDrive.ps1', 'Confirm-Change.ps1', 'VmTpmGuidance.ps1') { Copy-Item -LiteralPath (Join-Path $RepoScripts $F) -Destination "$GuestDir\$F" -ToSession $S }
    Remove-PSSession $S
    Log "copied Enable-BitLockerOsDrive.ps1, Confirm-Change.ps1, VmTpmGuidance.ps1 to $GuestDir"
    $W = Invoke-BitLockerScriptAsSystem '-WhatIf' 'whatif.txt'
    LogBlock $W.Output
    if ($W.Output -notmatch '(?m)^PASSED' -or $W.Output -match '(?m)^FAILED') { throw 'STOP: the -WhatIf run did not pass (output above); nothing was changed by it' }
    Log "-WhatIf passed (task result $($W.ExitCode))" 'PASS'

    Section '10. Enable-BitLockerOsDrive.ps1 -NoConfirm (as SYSTEM)'
    $R = Invoke-BitLockerScriptAsSystem '-NoConfirm' 'enable.txt'
    LogBlock $R.Output
    if ($R.Output -notmatch '(?m)^PASSED' -or $R.Output -match '(?m)^FAILED') { throw 'STOP: Enable-BitLockerOsDrive.ps1 did not pass (output above)' }
    Log "Enable-BitLockerOsDrive.ps1 passed (task result $($R.ExitCode))" 'PASS'

    Section '11. Restart for the hardware test, then verify'
    Restart-Guest 'BitLocker hardware test'
    $Deadline = (Get-Date).AddMinutes(5)
    do {
        $V = Invoke-Guest {
            $B = Get-BitLockerVolume -MountPoint 'C:'
            [pscustomobject]@{
                Status = [string]$B.VolumeStatus; Pct = $B.EncryptionPercentage; Method = [string]$B.EncryptionMethod; Protection = [string]$B.ProtectionStatus
                Protectors = (@($B.KeyProtector) | ForEach-Object { '{0} {1}' -f $_.KeyProtectorType, $_.KeyProtectorId }) -join ', '
            }
        }
        if ($V.Status -in 'EncryptionInProgress', 'FullyEncrypted') { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $Deadline)
    $Ok = $V.Status -in 'EncryptionInProgress', 'FullyEncrypted'
    Log ('C: {0} ({1}%), {2}, protection {3}; protectors: {4}' -f $V.Status, $V.Pct, $V.Method, $V.Protection, $V.Protectors) $(if ($Ok) { 'PASS' } else { 'FAIL' })
    if (-not $Ok) { throw 'STOP: encryption did not start after the restart' }
    $Ev = Invoke-Guest {
        $E = Get-WinEvent -LogName 'Microsoft-Windows-BitLocker/BitLocker Management' -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq 784 } | Select-Object -First 1
        if ($E) { [pscustomobject]@{ Time = $E.TimeCreated; Id = [string]$E.Properties[3].Value } }
    }
    $RpId = ([regex]::Match($V.Protectors, 'RecoveryPassword (\{[0-9A-Fa-f-]{36}\})')).Groups[1].Value.ToUpperInvariant()
    # The event holds the ID in lower case without braces
    if ($Ev) { Log ('event 784 (recovery information backed up to AD DS) at {0} for protector {1}' -f $Ev.Time, $Ev.Id) $(if (('{' + $Ev.Id.Trim('{}').ToUpperInvariant() + '}') -eq $RpId) { 'PASS' } else { 'WARN' }) }
    else { Log 'no event 784 found' 'WARN' }
    $Names = @(Find-Ad $MyDn '(objectClass=msFVE-RecoveryInformation)' @('name') 'OneLevel' | ForEach-Object { [string]$_.Properties['name'][0] })
    if ($RpId -and ($Names | Where-Object { $_.ToUpperInvariant().Contains($RpId) })) { Log ('AD: {0} recovery object(s) under {1}: {2} - matches the drive''s recovery password {3}' -f $Names.Count, $MyDn, ($Names -join '; '), $RpId) 'PASS' }
    else { throw ('STOP: recovery password {0} not found in AD under {1} (found: {2})' -f $RpId, $MyDn, ($Names -join '; ')) }

    Section '12. Clean-up and evidence'
    $Gone = Invoke-Guest { param($D) Remove-Item -LiteralPath $D -Recurse -Force -ErrorAction SilentlyContinue; -not (Test-Path -LiteralPath $D) } @($GuestDir)
    Log "removed $GuestDir from the guest: $Gone"
    $S = New-PSSession -VMName $VMName -Credential $LocalCred
    $Files = @(Invoke-Command -Session $S { Get-ChildItem -LiteralPath 'C:\Logs' -Filter 'Enable-BitLockerOsDrive-*' | ForEach-Object { $_.FullName } })
    foreach ($F in $Files) { Copy-Item -FromSession $S -LiteralPath $F -Destination $EvidenceDir }
    Remove-PSSession $S
    Log ('copied {0} BitLocker log file(s) from the guest''s C:\Logs to {1}' -f $Files.Count, $EvidenceDir)
    try { $A = (Resolve-DnsName "$VMName.$Domain" -Type A -Server $DcIp -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress }).IPAddress -join ', '; Log ('DNS: {0}.{1} -> {2}' -f $VMName, $Domain, $A) 'PASS' }
    catch { Log ('DNS: no A record for {0}.{1} yet ({2})' -f $VMName, $Domain, $_.Exception.Message) 'WARN' }

    Section 'Done'
    Log 'all steps passed' 'PASS'
}
catch {
    Log $_.Exception.Message 'FAIL'
    Log 'run stopped here; later steps were not run. Fix the cause and run the script again: finished steps are skipped.'
}
finally {
    Write-Host "`nThis window closes in 20 seconds." -ForegroundColor Cyan
    Start-Sleep -Seconds 20
}
