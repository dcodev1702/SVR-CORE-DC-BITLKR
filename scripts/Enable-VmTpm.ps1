# Give a Hyper-V virtual machine a virtual TPM 2.0, so BitLocker in it can use a TPM protector (README section 8).
# Run ON the Hyper-V host, elevated, in Windows PowerShell 5.1 or PowerShell 7. ASCII-only.
#
# In order - nothing changes before step 4:
#   1. Checks: elevation, and that this computer is a Hyper-V host (vmms service, Hyper-V module). If it is not, it says
#      which platform it is on, shows how to add a vTPM on Hyper-V, VMware vSphere and Proxmox VE, and stops.
#   2. Finds exactly one VM with that name and reads its generation, state, vTPM and key protector.
#   3. Plans only what is missing. The VM must be off while its security settings change: a running VM is shut down
#      through the guest (a normal shutdown, never a power-off). A Saved or Paused VM is refused.
#   4. Shows the plan in yellow and asks Y/N, then: shut down (if running), add a local key protector (only if the VM
#      has none - an existing one is kept), enable the vTPM, start the VM again (if it was running), and verify from
#      Hyper-V. Running it again when the vTPM is on changes nothing and does not touch the VM.
#
#   .\Enable-VmTpm.ps1 -VMName 'PDQ - Server 2025' -WhatIf      # plan only
#   .\Enable-VmTpm.ps1 -VMName 'PDQ - Server 2025'              # shows the plan in yellow, asks Y/N
#   .\Enable-VmTpm.ps1 -VMName 'PDQ - Server 2025' -LeaveOff    # do not start the VM afterwards
#   .\Enable-VmTpm.ps1 -VMName 'PDQ - Server 2025' -NoConfirm   # automation
# Needs Confirm-Change.ps1 and VmTpmGuidance.ps1 in the same folder. Evidence: <LogDir>\Enable-VmTpm-<time>.log and .csv.
# Undo, with the VM off: Disable-VMTPM -VMName '<name>'. Anything sealed to the vTPM, such as a BitLocker TPM protector,
# then needs its recovery password at the next boot.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # The VM's name in Hyper-V Manager (Get-VM). Wildcards are not allowed: the script changes exactly one VM.
    [Parameter(Mandatory)][ValidatePattern('^[^*?\[\]"<>|\x00-\x1f]{1,100}$')][string]$VMName,
    # How long a running VM gets to shut down before the script stops (and changes nothing else).
    [ValidateRange(1, 60)][int]$ShutdownTimeoutMinutes = 10,
    # Leave the VM off afterwards, even if it was running.
    [switch]$LeaveOff,
    # Folder for the transcript and results CSV. Empty = %SystemDrive%\Logs.
    [ValidatePattern('^$|^[A-Za-z]:\\[^"*?<>|]+$')][string]$LogDir = '',
    [switch]$NoConfirm
)
$ErrorActionPreference = 'Stop'

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

# A key protector of more than 4 bytes is a real one (Hyper-V returns a short placeholder when there is none). Keeping
# an existing protector matters: replacing it would orphan whatever is sealed to the vTPM.
function Test-HasKeyProtector($Bytes) { @($Bytes).Count -gt 4 }

# The steps for $Vm (Name, State, Generation, TpmEnabled, HasKeyProtector), or $null when the vTPM is already on.
# Throws STOP for a VM that cannot get a vTPM now.
function Get-VmTpmPlan($Vm, [bool]$StartAfter) {
    if ([int]$Vm.Generation -ne 2) { throw "STOP: '$($Vm.Name)' is a Generation $($Vm.Generation) VM. Only Generation 2 VMs can have a vTPM; the generation cannot be changed, so the VM has to be rebuilt as Generation 2. Nothing was changed." }
    if ($Vm.TpmEnabled) { return $null }
    $Running = $false
    switch ([string]$Vm.State) {
        'Off'     { }
        'Running' { $Running = $true }
        'Saved'   { throw "STOP: '$($Vm.Name)' is in a saved state. Start it and shut it down from inside the guest, or delete the saved state, then run this again. Nothing was changed." }
        'Paused'  { throw "STOP: '$($Vm.Name)' is paused. Resume it (Resume-VM) and run this again, or shut it down first. Nothing was changed." }
        default   { throw "STOP: '$($Vm.Name)' is '$($Vm.State)'. Wait until it is Running or Off, then run this again. Nothing was changed." }
    }
    [pscustomobject]@{
        Stop       = $Running
        AddKey     = -not $Vm.HasKeyProtector
        EnableTpm  = $true
        Start      = $Running -and $StartAfter
    }
}

# --- System access (the test harness replaces these with mocks) ---

$UnderTest = [bool](Get-Variable -Name VmTpmScriptTestHarness -ErrorAction SilentlyContinue)
if (-not $UnderTest) {
    function Test-IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

    # This computer: is it a Hyper-V host, and what does its SMBIOS say it is? A Hyper-V guest also reports its VM name
    # and host through the Data Exchange integration service.
    function Get-HostFacts {
        $Cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $Bios = Get-CimInstance -ClassName Win32_BIOS
        $Guest = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -ErrorAction SilentlyContinue
        [pscustomobject]@{
            ComputerName     = $env:COMPUTERNAME
            HyperVService    = [bool](Get-Service -Name vmms -ErrorAction SilentlyContinue)
            HyperVModule     = [bool](Get-Module -ListAvailable -Name Hyper-V)
            Manufacturer     = [string]$Cs.Manufacturer
            Model            = [string]$Cs.Model
            BiosManufacturer = [string]$Bios.Manufacturer
            BiosVersion      = [string]$Bios.SMBIOSBIOSVersion
            GuestVmName      = $(if ($Guest) { [string]$Guest.VirtualMachineName } else { '' })
            GuestHostName    = $(if ($Guest) { [string]$Guest.PhysicalHostNameFullyQualified } else { '' })
        }
    }

    function Import-HyperVModule {
        $Saved = $Global:WhatIfPreference; $Global:WhatIfPreference = $false; $WhatIfPreference = $false
        try {
            try { Import-Module -Name Hyper-V -ErrorAction Stop }
            catch { if ($PSVersionTable.PSEdition -eq 'Core') { Import-Module -Name Hyper-V -SkipEditionCheck -ErrorAction Stop } else { throw } }
            $M = Get-Module -Name Hyper-V
            'Hyper-V {0} in PowerShell {1} {2}' -f $M.Version, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion
        }
        finally { $Global:WhatIfPreference = $Saved }
    }

    # Every VM whose name is exactly $Name (Hyper-V allows duplicates), with what the plan needs
    function Get-VmInfo([string]$Name) {
        $Saved = $Global:WhatIfPreference; $Global:WhatIfPreference = $false; $WhatIfPreference = $false
        try {
            foreach ($V in @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -eq $Name })) {
                $Sec = Get-VMSecurity -VM $V -ErrorAction Stop
                [pscustomobject]@{
                    Name = [string]$V.Name; Id = [string]$V.Id; State = [string]$V.State; Generation = [int]$V.Generation
                    TpmEnabled = [bool]$Sec.TpmEnabled; HasKeyProtector = (Test-HasKeyProtector (Get-VMKeyProtector -VM $V -ErrorAction Stop))
                }
            }
        }
        finally { $Global:WhatIfPreference = $Saved }
    }

    function Get-VmNames { @(Get-VM -ErrorAction Stop | ForEach-Object { [string]$_.Name } | Sort-Object) }

    # True once the VM is Off, false when $Minutes pass first
    function Wait-VmOff([string]$Id, [int]$Minutes) {
        $Deadline = (Get-Date).AddMinutes($Minutes)
        do {
            if ([string](Get-VM -Id $Id -ErrorAction Stop).State -eq 'Off') { return $true }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $Deadline)
        return $false
    }

    # The changes. -Force on Stop-VM skips Hyper-V's own prompt for a locked guest; it is still a shutdown through the
    # guest, not a power-off (that would be Stop-VM's TurnOff switch, which this script never uses).
    function Stop-GuestVm([string]$Id) { Stop-VM -VM (Get-VM -Id $Id) -Force -Confirm:$false -ErrorAction Stop }
    function Set-LocalKeyProtector([string]$Id) { Set-VMKeyProtector -VM (Get-VM -Id $Id) -NewLocalKeyProtector -Confirm:$false -ErrorAction Stop }
    function Enable-VmTpmDevice([string]$Id) { Enable-VMTPM -VM (Get-VM -Id $Id) -Confirm:$false -ErrorAction Stop }
    function Start-GuestVm([string]$Id) { Start-VM -VM (Get-VM -Id $Id) -Confirm:$false -ErrorAction Stop }
}

# --- Run ---

if (-not $LogDir) { $LogDir = Join-Path $env:SystemDrive 'Logs' }
$Log = Join-Path $LogDir ('Enable-VmTpm-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -Path $LogDir -ItemType Directory -Force -WhatIf:$false | Out-Null
Start-Transcript -LiteralPath "$Log.log" -WhatIf:$false | Out-Null
try {
    # 1. Preconditions - nothing is changed until the confirmation below
    $Guidance = Join-Path $PSScriptRoot 'VmTpmGuidance.ps1'
    if (-not (Test-Path -LiteralPath $Guidance -PathType Leaf)) { throw "STOP: $Guidance is missing. Copy VmTpmGuidance.ps1 next to this script. Nothing was changed." }
    . $Guidance
    if ($UnderTest) {
        foreach ($Name in 'Stop-GuestVm', 'Set-LocalKeyProtector', 'Enable-VmTpmDevice', 'Start-GuestVm') {
            $Cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
            if (-not $Cmd -or $Cmd.CommandType -ne 'Function' -or $Cmd.Module) { throw "STOP: test harness detected, but $Name is not a mock function. Nothing was changed." }
        }
    }
    else {
        $Helper = Join-Path $PSScriptRoot 'Confirm-Change.ps1'
        if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) { throw "STOP: $Helper is missing. Copy Confirm-Change.ps1 next to this script. Nothing was changed." }
        . $Helper
    }
    if ($VMName -ne $VMName.Trim()) { throw "STOP: -VMName '$VMName' starts or ends with a space. Pass the name exactly as Get-VM shows it. Nothing was changed." }
    if (-not (Test-IsAdmin)) { throw 'STOP: this session is not elevated. Run the script from an elevated PowerShell on the Hyper-V host. Nothing was changed.' }

    # Hyper-V host? If not, say what this computer is and how a vTPM is added on each platform
    $Facts = Get-HostFacts
    $Platform = Resolve-VmPlatform $Facts.Manufacturer $Facts.Model $Facts.BiosManufacturer $Facts.BiosVersion
    if (-not ($Facts.HyperVService -and $Facts.HyperVModule)) {
        $Missing = @($(if (-not $Facts.HyperVService) { 'the Hyper-V service (vmms)' }), $(if (-not $Facts.HyperVModule) { 'the Hyper-V PowerShell module' }) | Where-Object { $_ }) -join ' and '
        $ThisPc = '{0} is a {1} ({2} / {3})' -f $Facts.ComputerName, $VmPlatformText[$Platform], $Facts.Manufacturer, $Facts.Model
        if ($Platform -eq 'Hyper-V' -and $Facts.GuestHostName) { $ThisPc += ": VM '$($Facts.GuestVmName)' on the Hyper-V host $($Facts.GuestHostName)" }
        Write-Host ''
        Write-Host "This computer is not a Hyper-V host: $Missing not found." -ForegroundColor Yellow
        Write-Host "Platform: $ThisPc." -ForegroundColor Yellow
        Write-Host "The vTPM for '$VMName' has to be added on the platform that runs '$VMName':" -ForegroundColor Yellow
        foreach ($P in @('Hyper-V', 'VMware', 'KVM')) {
            Write-Host ''
            Write-Host ("[{0}]" -f $VmPlatformText[$P]) -ForegroundColor Yellow
            foreach ($Line in (Get-VtpmGuidance $P $VMName '')) { Write-Host $Line -ForegroundColor Yellow }
        }
        Write-Host ''
        $Hint = if ($Platform -eq 'Hyper-V' -and $Facts.GuestHostName) { " Run it on $($Facts.GuestHostName) instead." } else { '' }
        throw "STOP: $($Facts.ComputerName) is not a Hyper-V host ($Missing not found); it is a $($VmPlatformText[$Platform]).$Hint The steps for Hyper-V, VMware vSphere and Proxmox VE are shown above. Nothing was changed."
    }
    try { $ModuleInfo = Import-HyperVModule } catch { throw "STOP: the Hyper-V PowerShell module could not be loaded ($($_.Exception.Message)). Nothing was changed." }
    Add-Result 'PASS' 'Hyper-V host' ('{0}; {1}' -f $Facts.ComputerName, $ModuleInfo)

    # 2. The VM - exactly one, by exact name
    $Vms = @(Get-VmInfo $VMName)
    if ($Vms.Count -eq 0) {
        $Names = @(Get-VmNames)
        $List = if ($Names.Count) { ($Names | ForEach-Object { "'$_'" }) -join ', ' } else { 'none' }
        throw "STOP: no VM named '$VMName' on $($Facts.ComputerName). VMs on this host: $List. Nothing was changed."
    }
    if ($Vms.Count -gt 1) { throw "STOP: $($Vms.Count) VMs are named '$VMName' on $($Facts.ComputerName) (IDs $(($Vms | ForEach-Object { $_.Id }) -join ', ')). Rename them so the name is unique, then run this again. Nothing was changed." }
    $Vm = $Vms[0]
    Add-Result 'PASS' 'VM' ("'{0}' ({1}): Generation {2}, {3}; vTPM {4}; key protector {5}" -f $Vm.Name, $Vm.Id, $Vm.Generation, $Vm.State, $(if ($Vm.TpmEnabled) { 'on' } else { 'off' }), $(if ($Vm.HasKeyProtector) { 'present' } else { 'none' }))

    # 3. Plan
    $Plan = Get-VmTpmPlan $Vm (-not $LeaveOff)
    if (-not $Plan) {
        Add-Result 'PASS' 'Plan' "the vTPM is already on - nothing to change; '$($Vm.Name)' stays $($Vm.State)"
    }
    else {
        # 4. Confirm - one yellow Y/N for everything below
        if (-not $WhatIfPreference) {
            $Detail = New-Object System.Collections.Generic.List[string]
            $Detail.Add("Host: $($Facts.ComputerName); VM: '$($Vm.Name)' ($($Vm.Id)), Generation 2, now $($Vm.State)")
            $N = 0
            if ($Plan.Stop) { $N++; $Detail.Add("  $N. shut the VM down through its guest OS (a normal shutdown, not a power-off; up to $ShutdownTimeoutMinutes minutes)") }
            $N++; $Detail.Add($(if ($Plan.AddKey) { "  $N. add a local key protector (Set-VMKeyProtector -NewLocalKeyProtector), held by this host's Hyper-V guardian" } else { "  $N. keep the VM's existing key protector" }))
            $N++; $Detail.Add("  $N. enable the virtual TPM (Enable-VMTPM)")
            if ($Plan.Start) { $N++; $Detail.Add("  $N. start the VM again") }
            elseif ($Plan.Stop) { $Detail.Add('  The VM stays off afterwards (-LeaveOff).') }
            else { $Detail.Add('  The VM was off and stays off.') }
            $Detail.Add('Effect: the guest sees a TPM 2.0 at its next start. The vTPM belongs to this host: moving the VM to another host')
            $Detail.Add("        needs this host's guardian certificates there.")
            $Detail.Add("Undo (VM off): Disable-VMTPM -VMName $(ConvertTo-QuotedName $Vm.Name). Anything sealed to the vTPM, such as a BitLocker TPM protector,")
            $Detail.Add('      then needs its recovery password at the next boot.')
            Confirm-Change -NoConfirm:$NoConfirm -Action "enable the virtual TPM of '$($Vm.Name)' on $($Facts.ComputerName)" -Detail $Detail.ToArray()
            $ConfirmPreference = 'None'
        }

        # 5. Apply, step by step; each one only after the one before it succeeded
        if ($Plan.Stop) {
            if ($PSCmdlet.ShouldProcess($Vm.Name, 'Shut down the VM')) {
                try { Stop-GuestVm $Vm.Id } catch { throw "STOP: '$($Vm.Name)' did not shut down ($($_.Exception.Message)). Shut it down from inside the guest, then run this again. Nothing else was changed." }
                if (-not (Wait-VmOff $Vm.Id $ShutdownTimeoutMinutes)) { throw "STOP: '$($Vm.Name)' was still not off after $ShutdownTimeoutMinutes minutes. Shut it down from inside the guest, then run this again. Nothing else was changed." }
                Add-Result 'PASS' 'Shut down' "'$($Vm.Name)' is off"
            }
            else { Add-Result 'PASS' 'Shut down' "-WhatIf: would shut down '$($Vm.Name)'" }
        }
        if ($Plan.AddKey) {
            if ($PSCmdlet.ShouldProcess($Vm.Name, 'Add a local key protector')) { Set-LocalKeyProtector $Vm.Id; Add-Result 'PASS' 'Key protector' 'local key protector added' }
            else { Add-Result 'PASS' 'Key protector' '-WhatIf: would add a local key protector' }
        }
        else { Add-Result 'PASS' 'Key protector' 'existing one kept' }
        if ($PSCmdlet.ShouldProcess($Vm.Name, 'Enable the virtual TPM')) { Enable-VmTpmDevice $Vm.Id; Add-Result 'PASS' 'vTPM' 'enabled' }
        else { Add-Result 'PASS' 'vTPM' '-WhatIf: would enable it' }
        if ($Plan.Start) {
            if ($PSCmdlet.ShouldProcess($Vm.Name, 'Start the VM')) { Start-GuestVm $Vm.Id; Add-Result 'PASS' 'Start' "'$($Vm.Name)' started" }
            else { Add-Result 'PASS' 'Start' "-WhatIf: would start '$($Vm.Name)'" }
        }
    }

    # 6. Verify from Hyper-V (also when nothing had to change)
    if (-not $WhatIfPreference) {
        $After = @(Get-VmInfo $VMName | Where-Object { $_.Id -eq $Vm.Id })
        if ($After.Count -ne 1) { Add-Result 'FAIL' 'Verify' "'$VMName' ($($Vm.Id)) was not found again" }
        else {
            $A = $After[0]
            if ($A.TpmEnabled) { Add-Result 'PASS' 'Verify vTPM' 'on (Get-VMSecurity: TpmEnabled = True)' } else { Add-Result 'FAIL' 'Verify vTPM' 'off (Get-VMSecurity: TpmEnabled = False)' }
            if ($A.HasKeyProtector) { Add-Result 'PASS' 'Verify key protector' 'present' } else { Add-Result 'FAIL' 'Verify key protector' 'none' }
            if ($Plan -and $Plan.Start) {
                if ($A.State -eq 'Running') { Add-Result 'PASS' 'Verify state' 'Running' } else { Add-Result 'FAIL' 'Verify state' "$($A.State), expected Running" }
            }
            else { Add-Result 'PASS' 'Verify state' $A.State }
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
    if (-not $FailCount -and $Plan -and -not $WhatIfPreference) { Write-Host 'NEXT: in the guest, run Get-Tpm (TpmPresent should be True), then Enable-BitLockerOsDrive.ps1.' -ForegroundColor Yellow }
    $Results | Export-Csv -LiteralPath "$Log.csv" -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Host "Transcript: $Log.log   Results: $Log.csv"
    $StopArgs = @{}
    if ((Get-Command -Name Stop-Transcript).Parameters.ContainsKey('WhatIf')) { $StopArgs['WhatIf'] = $false }
    try { Stop-Transcript @StopArgs | Out-Null } catch { }
}
if ($FailCount) { exit 1 }
exit 0
