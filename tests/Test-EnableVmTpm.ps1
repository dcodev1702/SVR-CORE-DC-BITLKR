# Unit tests for scripts\Enable-VmTpm.ps1 and scripts\VmTpmGuidance.ps1 with mocks: no VM and no Hyper-V setting is read or
# changed by the script under test. Windows PowerShell 5.1 and PowerShell 7. ASCII-only.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-EnableVmTpm.ps1
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-EnableVmTpm.ps1
param([string]$ScriptPath = '')   # empty = ..\scripts\Enable-VmTpm.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $ScriptPath) { $ScriptPath = Join-Path $Root 'scripts\Enable-VmTpm.ps1' }
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "STOP: $ScriptPath not found." }
$ScriptDir = Split-Path -Parent $ScriptPath
$Work = Join-Path ([IO.Path]::GetTempPath()) ('VmTpmScriptTest-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $Work -ItemType Directory | Out-Null
Write-Host ('Edition {0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)

$Failures = New-Object System.Collections.Generic.List[string]
$Checks = 0
function Assert-That([bool]$Ok, [string]$Name, [string]$Why = '') {
    $script:Checks++
    if ($Ok) { Write-Host "PASS  $Name" -ForegroundColor Green } else { $Failures.Add("$Name : $Why"); Write-Host "FAIL  $Name : $Why" -ForegroundColor Red }
}

# --- 0. Parse and ASCII checks, in this edition ---
foreach ($File in @($ScriptPath, (Join-Path $ScriptDir 'Confirm-Change.ps1'), (Join-Path $ScriptDir 'VmTpmGuidance.ps1'), $PSCommandPath)) {
    $Tokens = $null; $Errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($File, [ref]$Tokens, [ref]$Errors)
    $NonAscii = @([IO.File]::ReadAllBytes($File) | Where-Object { $_ -gt 127 }).Count
    Assert-That ((@($Errors).Count -eq 0) -and $NonAscii -eq 0) "parse + ASCII: $(Split-Path -Leaf $File)" "$(@($Errors).Count) parse error(s), $NonAscii non-ASCII byte(s)"
}

# --- 1. Static: one VM by a mandatory name, never a power-off, the Hyper-V changes only inside the guarded functions ---
$Tokens = $null; $Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$Errors)
$Param = $Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'VMName' }
$Mandatory = @($Param.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' -and $_.Extent.Text -match 'Mandatory' }).Count -gt 0
Assert-That $Mandatory '-VMName is mandatory'
$Source = [IO.File]::ReadAllText($ScriptPath)
Assert-That ($Source -notmatch '-TurnOff') 'Never powers a VM off (-TurnOff does not appear)'
$Changing = @{ 'Stop-VM' = 'Stop-GuestVm'; 'Set-VMKeyProtector' = 'Set-LocalKeyProtector'; 'Enable-VMTPM' = 'Enable-VmTpmDevice'; 'Start-VM' = 'Start-GuestVm' }
foreach ($Cmdlet in $Changing.Keys) {
    $Uses = @($Ast.FindAll({ param($N) $N -is [Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq $Cmdlet }, $true))
    $Inside = @($Uses | Where-Object { $P = $_.Parent; while ($P -and -not ($P -is [Management.Automation.Language.FunctionDefinitionAst])) { $P = $P.Parent }; $P -and $P.Name -eq $Changing[$Cmdlet] })
    Assert-That ($Uses.Count -eq 1 -and $Inside.Count -eq 1) "$Cmdlet only inside $($Changing[$Cmdlet])" "$($Uses.Count) use(s), $($Inside.Count) inside"
}

# --- 2. Pure functions of VmTpmGuidance.ps1 ---
. (Join-Path $ScriptDir 'VmTpmGuidance.ps1')
$Smbios = @(
    ,@('Microsoft Corporation', 'Virtual Machine', 'Microsoft Corporation', 'Hyper-V UEFI Release v4.1', 'Hyper-V', 'Hyper-V VM (PDQ-SRVR, WIN11-PAW-WDAC)')
    ,@('VMware, Inc.', 'VMware7,1', 'VMware, Inc.', 'VMW71.00V', 'VMware', 'VMware VM')
    ,@('VMware, Inc.', 'VMware20,1', 'VMware, Inc.', 'VMW201.00V', 'VMware', 'VMware VM, hardware version 20')
    ,@('QEMU', 'Standard PC (Q35 + ICH9, 2009)', 'EFI Development Kit II / OVMF', '4.2023.08-4', 'KVM', 'Proxmox VE VM with OVMF')
    ,@('QEMU', 'Standard PC (i440FX + PIIX, 1996)', 'SeaBIOS', 'rel-1.16.3', 'KVM', 'Proxmox VE VM with SeaBIOS')
    ,@('Microsoft Corporation', 'Surface Laptop 5', 'Microsoft Corporation', '1.2.3', 'Other', 'Surface: Microsoft, but not a VM')
    ,@('Dell Inc.', 'OptiPlex 7010', 'Dell Inc.', '1.2.3', 'Other', 'physical Dell')
)
foreach ($S in $Smbios) { $Got = Resolve-VmPlatform $S[0] $S[1] $S[2] $S[3]; Assert-That ($Got -eq $S[4]) "Platform: $($S[5]) -> $($S[4])" "got $Got" }
Assert-That ((ConvertTo-QuotedName "Bob's VM") -eq "'Bob''s VM'") 'Quoting: a single quote is doubled'
$G = (Get-VtpmGuidance 'Hyper-V' 'PDQ - Server 2025' 'RYZEN-BEE') -join "`n"
Assert-That ($G -match 'On the Hyper-V host RYZEN-BEE' -and $G.Contains(".\scripts\Enable-VmTpm.ps1 -VMName 'PDQ - Server 2025'")) 'Guidance Hyper-V: host and exact command' $G
$G = (Get-VtpmGuidance 'VMware') -join "`n"
Assert-That ($G.Contains('Trusted Platform Module') -and $G.Contains('New-VTpm') -and $G.Contains('EFI firmware') -and $G.Contains('key provider')) 'Guidance VMware: vSphere device, PowerCLI, EFI, key provider' $G
$G = (Get-VtpmGuidance 'KVM') -join "`n"
Assert-That ($G.Contains('TPM State') -and $G.Contains('-tpmstate0 <storage>:1,version=v2.0') -and $G.Contains('OVMF')) 'Guidance Proxmox: TPM State, qm set, OVMF' $G
$G = (Get-VtpmGuidance 'Other') -join "`n"
Assert-That ($G.Contains('UEFI firmware setup')) 'Guidance other: firmware' $G
foreach ($P in 'Hyper-V', 'VMware', 'KVM', 'Other') { Assert-That ([bool](Get-VtpmFix $P 'x' 'h') -and [bool]$VmPlatformText[$P]) "Fix and display name: $P" }
foreach ($P in 'Hyper-V', 'VMware', 'KVM', 'Other') { $NonAscii = @(([Text.Encoding]::UTF8.GetBytes(((Get-VtpmGuidance $P 'x' 'h') -join '') + (Get-VtpmFix $P 'x' 'h'))) | Where-Object { $_ -gt 127 }).Count; Assert-That ($NonAscii -eq 0) "Guidance text ASCII: $P" }

# --- 3. Harness: real confirmation gate, mocked Hyper-V ---
$Global:VmTpmScriptTestHarness = $true
. (Join-Path $ScriptDir 'Confirm-Change.ps1')

$VmId = '12C9DADD-EC1E-457B-828F-9EAC14A6F7D9'
function Test-Interactive { $Global:M.Interactive }
function Read-Host { param([string]$Prompt) $Global:M.ReadHostCalls++; if ($Global:M.Answers.Count -gt 0) { $Global:M.Answers.Dequeue() } else { '' } }
function Test-IsAdmin { $Global:M.Admin }
function Get-HostFacts { [pscustomobject]$Global:M.Facts }
function Import-HyperVModule { if ($Global:M.ModuleFails) { throw "The specified module 'Hyper-V' was not loaded." }; 'Hyper-V (mock)' }
function Get-VmInfo { param([string]$Name) foreach ($V in $Global:M.Vms) { if ($V.Name -eq $Name) { [pscustomobject]@{ Name = $V.Name; Id = $V.Id; State = $V.State; Generation = $V.Generation; TpmEnabled = $V.TpmEnabled; HasKeyProtector = $V.HasKeyProtector } } } }
function Get-VmNames { @($Global:M.Vms | ForEach-Object { $_.Name } | Sort-Object) }
function Wait-VmOff { param([string]$Id, [int]$Minutes) $Global:M.WaitMinutes = $Minutes; if ($Global:M.WaitOff) { (Find-MockVm $Id).State = 'Off'; return $true }; return $false }
function Find-MockVm([string]$Id) { $Global:M.Vms | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
function Stop-GuestVm { [CmdletBinding()] param([string]$Id) $Global:M.Calls.Add('Stop'); if ($Global:M.StopFails) { throw 'The virtual machine could not be shut down: the shutdown integration service is not available.' } }
function Set-LocalKeyProtector { [CmdletBinding()] param([string]$Id) $Global:M.Calls.Add('AddKey'); (Find-MockVm $Id).HasKeyProtector = $true }
function Enable-VmTpmDevice { [CmdletBinding()] param([string]$Id) $Global:M.Calls.Add('Enable'); if (-not $Global:M.EnableNoop) { (Find-MockVm $Id).TpmEnabled = $true } }
function Start-GuestVm { [CmdletBinding()] param([string]$Id) $Global:M.Calls.Add('Start'); (Find-MockVm $Id).State = 'Running' }

function New-MockVm([string]$Name = 'PDQ - Server 2025', [string]$State = 'Off', [int]$Generation = 2, [bool]$Tpm = $false, [bool]$Key = $false, [string]$Id = $VmId) {
    [pscustomobject]@{ Name = $Name; Id = $Id; State = $State; Generation = $Generation; TpmEnabled = $Tpm; HasKeyProtector = $Key }
}
function Reset-Mock {
    $Global:M = @{
        Interactive = $false; Answers = New-Object System.Collections.Queue; ReadHostCalls = 0; Admin = $true; ModuleFails = $false
        # RYZEN-BEE: a physical Hyper-V host
        Facts = @{ ComputerName = 'RYZEN-BEE'; HyperVService = $true; HyperVModule = $true; Manufacturer = 'Micro-Star International Co., Ltd.'; Model = 'MS-7D75'; BiosManufacturer = 'American Megatrends International, LLC.'; BiosVersion = '1.A0'; GuestVmName = ''; GuestHostName = '' }
        Vms = @((New-MockVm), (New-MockVm -Name 'WIN11-PAW-WDAC' -State 'Running' -Tpm $true -Key $true -Id 'AAAAAAAA-0000-0000-0000-000000000001'))
        WaitOff = $true; WaitMinutes = 0; StopFails = $false; EnableNoop = $false
        Calls = New-Object System.Collections.Generic.List[string]
    }
}
function Set-Answers([string[]]$List) { $Global:M.Interactive = $true; foreach ($A in $List) { $Global:M.Answers.Enqueue($A) } }
function Set-Vm([hashtable]$Props) { foreach ($K in $Props.Keys) { $Global:M.Vms[0].$K = $Props[$K] } }

$CaseNo = 0
# ExpectExit 99 = the script must not start at all (parameter validation)
function Invoke-Case {
    param([string]$Name, [hashtable]$Params = @{}, [scriptblock]$Setup = {}, [int]$ExpectExit = 0, [string]$ExpectCalls = '',
          [string[]]$ExpectText = @(), [int]$ExpectReadHost = -1, [scriptblock]$Extra = $null)
    $script:CaseNo++
    Reset-Mock
    & $Setup
    $LogDir = Join-Path $Work ('case{0:00}' -f $script:CaseNo)
    $P = @{ VMName = 'PDQ - Server 2025'; LogDir = $LogDir }
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

# --- 4. Not a Hyper-V host: say what this computer is, show the steps per platform, change nothing ---
Invoke-Case 'On the PAW (a Hyper-V VM) -> STOP: run it on RYZEN-BEE, steps for Hyper-V, vSphere and Proxmox' -Params $NC -Setup {
    $Global:M.Facts = @{ ComputerName = 'WIN11-PAW-WDAC'; HyperVService = $false; HyperVModule = $true; Manufacturer = 'Microsoft Corporation'; Model = 'Virtual Machine'; BiosManufacturer = 'Microsoft Corporation'; BiosVersion = 'Hyper-V UEFI Release v4.1'; GuestVmName = 'WIN11-PAW-WDAC'; GuestHostName = 'RYZEN-BEE' }
} -ExpectExit 1 -ExpectText 'This computer is not a Hyper-V host: the Hyper-V service (vmms) not found', "Platform: WIN11-PAW-WDAC is a Microsoft Hyper-V virtual machine", "VM 'WIN11-PAW-WDAC' on the Hyper-V host RYZEN-BEE", 'Run it on RYZEN-BEE instead', "Enable-VmTpm.ps1 -VMName 'PDQ - Server 2025'", 'Add New Device > Trusted Platform Module', 'New-VTpm', 'tpmstate0', 'Nothing was changed'
Invoke-Case 'On a VMware VM -> STOP naming VMware, with the vSphere steps' -Params $NC -Setup {
    $Global:M.Facts = @{ ComputerName = 'MGMT01'; HyperVService = $false; HyperVModule = $false; Manufacturer = 'VMware, Inc.'; Model = 'VMware7,1'; BiosManufacturer = 'VMware, Inc.'; BiosVersion = 'VMW71.00V'; GuestVmName = ''; GuestHostName = '' }
} -ExpectExit 1 -ExpectText 'the Hyper-V service (vmms) and the Hyper-V PowerShell module not found', 'it is a VMware virtual machine (vSphere / ESXi)', 'New-VTpm', 'Nothing was changed'
Invoke-Case 'On a Proxmox VM -> STOP naming KVM / Proxmox' -Params $NC -Setup {
    $Global:M.Facts = @{ ComputerName = 'MGMT02'; HyperVService = $false; HyperVModule = $false; Manufacturer = 'QEMU'; Model = 'Standard PC (Q35 + ICH9, 2009)'; BiosManufacturer = 'EFI Development Kit II / OVMF'; BiosVersion = '4.2023.08-4'; GuestVmName = ''; GuestHostName = '' }
} -ExpectExit 1 -ExpectText 'it is a KVM / QEMU virtual machine (for example Proxmox VE)', 'qm set <vmid> -tpmstate0'
Invoke-Case 'Hyper-V module without the Hyper-V service (management tools only) -> STOP' -Params $NC -Setup { $Global:M.Facts.HyperVService = $false } -ExpectExit 1 -ExpectText 'the Hyper-V service (vmms) not found', 'physical computer'

# --- 5. Preconditions ---
Invoke-Case 'Not elevated -> STOP' -Params $NC -Setup { $Global:M.Admin = $false } -ExpectExit 1 -ExpectText 'not elevated'
Invoke-Case 'Hyper-V module does not load -> STOP' -Params $NC -Setup { $Global:M.ModuleFails = $true } -ExpectExit 1 -ExpectText 'could not be loaded'
Invoke-Case 'No VM with that name -> STOP, lists the VMs' -Params @{ NoConfirm = $true; VMName = 'PDQ-SRVR' } -ExpectExit 1 -ExpectText "no VM named 'PDQ-SRVR' on RYZEN-BEE", "'PDQ - Server 2025', 'WIN11-PAW-WDAC'"
Invoke-Case 'Two VMs with that name -> STOP' -Params $NC -Setup { $Global:M.Vms = @((New-MockVm), (New-MockVm -Id 'BBBBBBBB-0000-0000-0000-000000000002')) } -ExpectExit 1 -ExpectText '2 VMs are named'
Invoke-Case 'Generation 1 -> STOP' -Params $NC -Setup { Set-Vm @{ Generation = 1 } } -ExpectExit 1 -ExpectText 'Generation 1 VM', 'Only Generation 2'
Invoke-Case 'Saved -> STOP' -Params $NC -Setup { Set-Vm @{ State = 'Saved' } } -ExpectExit 1 -ExpectText 'saved state'
Invoke-Case 'Paused -> STOP' -Params $NC -Setup { Set-Vm @{ State = 'Paused' } } -ExpectExit 1 -ExpectText 'is paused'
Invoke-Case 'Starting -> STOP' -Params $NC -Setup { Set-Vm @{ State = 'Starting' } } -ExpectExit 1 -ExpectText "is 'Starting'"
Invoke-Case 'Name with a trailing space -> STOP' -Params @{ NoConfirm = $true; VMName = 'PDQ - Server 2025 ' } -ExpectExit 1 -ExpectText 'starts or ends with a space'
Invoke-Case 'Wildcard in -VMName -> rejected before the script runs' -Params @{ NoConfirm = $true; VMName = 'PDQ*' } -ExpectExit 99 -ExpectText 'VMName'

# --- 6. Changes ---
Invoke-Case 'vTPM already on, VM running -> nothing to change, the VM is not touched' -Params $NC -Setup { Set-Vm @{ State = 'Running'; TpmEnabled = $true; HasKeyProtector = $true } } -ExpectReadHost 0 -ExpectText 'already on - nothing to change', 'Verify vTPM', 'Verify state' -Extra { if ($Global:M.Vms[0].State -ne 'Running') { "state is $($Global:M.Vms[0].State)" } }
Invoke-Case 'Off, no key protector -> add one, enable, stays off' -Params $NC -ExpectCalls 'AddKey,Enable' -ExpectText 'local key protector added', 'Verify vTPM', 'TpmEnabled = True', 'Verify key protector', 'The VM was off and stays off' -Extra { if ($Global:M.Vms[0].State -ne 'Off') { "state is $($Global:M.Vms[0].State)" } }
Invoke-Case 'Running (the screenshot case) -> shut down, add key protector, enable, start again' -Params $NC -Setup { Set-Vm @{ State = 'Running' } } -ExpectCalls 'Stop,AddKey,Enable,Start' -ExpectText "'PDQ - Server 2025' is off", 'Verify state Running', 'NEXT: in the guest, run Get-Tpm' -Extra { if ($Global:M.WaitMinutes -ne 10) { "waited $($Global:M.WaitMinutes) min" } }
Invoke-Case 'Running, -LeaveOff -> shut down, enable, stays off' -Params @{ NoConfirm = $true; LeaveOff = $true } -Setup { Set-Vm @{ State = 'Running' } } -ExpectCalls 'Stop,AddKey,Enable' -ExpectText 'stays off afterwards (-LeaveOff)' -Extra { if ($Global:M.Vms[0].State -ne 'Off') { "state is $($Global:M.Vms[0].State)" } }
Invoke-Case 'Existing key protector -> kept, only the vTPM is enabled' -Params $NC -Setup { Set-Vm @{ HasKeyProtector = $true } } -ExpectCalls 'Enable' -ExpectText 'keep the VM''s existing key protector', 'existing one kept'
Invoke-Case '-ShutdownTimeoutMinutes is passed to the wait' -Params @{ NoConfirm = $true; ShutdownTimeoutMinutes = 3 } -Setup { Set-Vm @{ State = 'Running' } } -ExpectCalls 'Stop,AddKey,Enable,Start' -Extra { if ($Global:M.WaitMinutes -ne 3) { "waited $($Global:M.WaitMinutes) min" } }
Invoke-Case 'Shutdown does not finish in time -> STOP, nothing else changed' -Params $NC -Setup { Set-Vm @{ State = 'Running' }; $Global:M.WaitOff = $false } -ExpectExit 1 -ExpectCalls 'Stop' -ExpectText 'still not off after 10 minutes', 'Nothing else was changed'
Invoke-Case 'Shutdown refused by the guest -> STOP, nothing else changed' -Params $NC -Setup { Set-Vm @{ State = 'Running' }; $Global:M.StopFails = $true } -ExpectExit 1 -ExpectCalls 'Stop' -ExpectText 'did not shut down', 'shutdown integration service'
Invoke-Case 'vTPM does not stick -> FAIL' -Params $NC -Setup { $Global:M.EnableNoop = $true } -ExpectExit 1 -ExpectCalls 'AddKey,Enable' -ExpectText 'FAIL Verify vTPM'

# --- 7. Confirmation gate ---
Invoke-Case 'Interactive Y: plan shows shutdown, key protector, vTPM, start, effect, undo' -Setup { Set-Vm @{ State = 'Running' }; Set-Answers 'Y' } -ExpectCalls 'Stop,AddKey,Enable,Start' -ExpectReadHost 1 -ExpectText "enable the virtual TPM of 'PDQ - Server 2025' on RYZEN-BEE", '1. shut the VM down through its guest OS (a normal shutdown, not a power-off', '2. add a local key protector', '3. enable the virtual TPM (Enable-VMTPM)', '4. start the VM again', 'moving the VM to another host', "Undo (VM off): Disable-VMTPM -VMName 'PDQ - Server 2025'"
Invoke-Case 'Interactive N -> STOP, nothing changed, the VM keeps running' -Setup { Set-Vm @{ State = 'Running' }; Set-Answers 'N' } -ExpectExit 1 -ExpectReadHost 1 -ExpectText 'not confirmed' -Extra { if ($Global:M.Vms[0].State -ne 'Running') { "state is $($Global:M.Vms[0].State)" } }
Invoke-Case 'Interactive invalid x3 -> STOP' -Setup { Set-Answers 'maybe', 'x', '' } -ExpectExit 1 -ExpectReadHost 3 -ExpectText 'not confirmed'
Invoke-Case 'Non-interactive without -NoConfirm -> STOP before any change' -Setup { Set-Vm @{ State = 'Running' } } -ExpectExit 1 -ExpectReadHost 0 -ExpectText 'non-interactive'
Invoke-Case 'Already on, interactive -> no prompt' -Setup { Set-Vm @{ TpmEnabled = $true; HasKeyProtector = $true }; Set-Answers 'N' } -ExpectReadHost 0 -ExpectText 'nothing to change'
Invoke-Case '-WhatIf -> plan only, nothing changed' -Params @{ WhatIf = $true } -Setup { Set-Vm @{ State = 'Running' } } -ExpectReadHost 0 -ExpectText "would shut down 'PDQ - Server 2025'", 'would add a local key protector', 'would enable it', 'would start' -Extra { if ($Global:M.Vms[0].State -ne 'Running' -or $Global:M.Vms[0].TpmEnabled) { 'the VM changed' } }

# --- 8. Guard: a real (module) command must never run under the harness (last: it leaves the mocks unusable) ---
function Invoke-GuardCase {
    New-Module -Name FakeRealEnableVmTpmDevice -ScriptBlock { function Enable-VmTpmDevice { param($Id) $Global:M.Calls.Add('REAL') }; Export-ModuleMember -Function Enable-VmTpmDevice } | Import-Module -Scope Local
    try { Invoke-Case 'Guard: module command instead of a mock -> STOP' -Params $NC -ExpectExit 1 -ExpectText 'is not a mock function' }
    finally { Remove-Module -Name FakeRealEnableVmTpmDevice -ErrorAction SilentlyContinue }
}
Invoke-GuardCase

Remove-Variable -Name VmTpmScriptTestHarness -Scope Global
Remove-Item -LiteralPath $Work -Recurse -Force
Write-Host ''
if ($Failures.Count) { Write-Host "FAILED: $($Failures.Count) of $Checks check(s)" -ForegroundColor Red; exit 1 }
Write-Host "PASSED: $Checks checks ($CaseNo script runs)" -ForegroundColor Green
