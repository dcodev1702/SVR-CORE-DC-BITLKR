# How to give a computer a TPM 2.0, by platform. Shared by Enable-VmTpm.ps1 (on a Hyper-V host) and
# Enable-BitLockerOsDrive.ps1 (in the computer that needs the TPM). Pure functions only: the callers read the SMBIOS
# strings and the Hyper-V guest data themselves. Windows PowerShell 5.1 and PowerShell 7. ASCII-only.

# Display names of the platforms Resolve-VmPlatform returns
$VmPlatformText = @{
    'Hyper-V' = 'Microsoft Hyper-V virtual machine'
    'VMware'  = 'VMware virtual machine (vSphere / ESXi)'
    'KVM'     = 'KVM / QEMU virtual machine (for example Proxmox VE)'
    'Other'   = 'physical computer (or a VM on a hypervisor this script does not recognize)'
}

# 'Hyper-V', 'VMware', 'KVM' or 'Other', from Win32_ComputerSystem (Manufacturer, Model) and Win32_BIOS (Manufacturer,
# SMBIOSBIOSVersion). A Hyper-V VM reports 'Microsoft Corporation' / 'Virtual Machine'; Proxmox VE reports 'QEMU' by default.
function Resolve-VmPlatform([string]$Manufacturer, [string]$Model, [string]$BiosManufacturer, [string]$BiosVersion) {
    $All = '{0}|{1}|{2}|{3}' -f $Manufacturer, $Model, $BiosManufacturer, $BiosVersion
    if ($Manufacturer -match '^\s*Microsoft Corporation' -and $Model -match '^\s*Virtual Machine') { return 'Hyper-V' }
    if ($All -match 'VMware') { return 'VMware' }
    if ($All -match 'QEMU|KVM|Proxmox|OVMF|SeaBIOS|Bochs') { return 'KVM' }
    return 'Other'
}

# A name inside single quotes in a command line someone will paste: double any single quote
function ConvertTo-QuotedName([string]$Name) { "'" + $Name.Replace("'", "''") + "'" }

# The fix in one sentence, for a STOP message (the full steps come from Get-VtpmGuidance)
function Get-VtpmFix([string]$Platform, [string]$VmName = '', [string]$HostName = '') {
    $Vm = if ($VmName) { ConvertTo-QuotedName $VmName } else { "'<VM name>'" }
    switch ($Platform) {
        'Hyper-V' { 'on the Hyper-V host{0}, run .\scripts\Enable-VmTpm.ps1 -VMName {1} (it shuts the VM down, adds the vTPM and starts it again)' -f $(if ($HostName) { " $HostName" } else { '' }), $Vm }
        'VMware'  { 'add a Trusted Platform Module to the VM in vSphere (VM powered off, EFI firmware, hardware version 14 or later, a key provider in vCenter)' }
        'KVM'     { 'add a TPM State (v2.0) to the VM in Proxmox VE, or a TPM 2.0 device on another KVM host, with the VM shut down and OVMF (UEFI) firmware' }
        default   { 'turn the TPM on in the UEFI firmware setup, or, on a virtual machine, add a TPM 2.0 device to it in the hypervisor' }
    }
}

# The steps that give a VM (or computer) on $Platform a TPM 2.0. $VmName and $HostName are optional: when known (a
# Hyper-V guest reports both), the commands name them. Returns the lines to show.
function Get-VtpmGuidance([string]$Platform, [string]$VmName = '', [string]$HostName = '') {
    $Vm = if ($VmName) { ConvertTo-QuotedName $VmName } else { "'<VM name>'" }
    switch ($Platform) {
        'Hyper-V' {
            $Where = if ($HostName) { "On the Hyper-V host $HostName" } else { 'On the Hyper-V host' }
            @(
                "$Where, in an elevated PowerShell, from this repository:"
                "    .\scripts\Enable-VmTpm.ps1 -VMName $Vm"
                '  It checks that the VM is Generation 2, asks Y/N, shuts the VM down if it is running, adds a key protector'
                '  (only if it has none) and the vTPM, starts the VM again and verifies the result.'
                "  By hand, with the VM off: Set-VMKeyProtector -VMName $Vm -NewLocalKeyProtector; Enable-VMTPM -VMName $Vm"
                '  A Generation 1 VM cannot have a vTPM. In Azure, turn on Trusted launch (vTPM) for the VM instead.'
            )
        }
        'VMware' {
            @(
                'In vSphere (vCenter Server 6.7 or later), with the VM powered off:'
                '  1. The VM needs EFI firmware and hardware version 14 or later, and vCenter needs a key provider'
                '     (for example the vSphere Native Key Provider).'
                '  2. Right-click the VM > Edit Settings > Add New Device > Trusted Platform Module > OK, then power it on.'
                "  PowerCLI: Get-VM -Name $Vm | New-VTpm"
            )
        }
        'KVM' {
            @(
                'In Proxmox VE, with the VM shut down:'
                '  1. The VM needs OVMF (UEFI) firmware with an EFI disk.'
                '  2. Hardware > Add > TPM State, version v2.0, or on the Proxmox host: qm set <vmid> -tpmstate0 <storage>:1,version=v2.0'
                '  3. Start the VM.'
                '  Other KVM / QEMU hosts: add a TPM 2.0 device (swtpm emulator) to the VM in the hypervisor, with the VM shut down.'
            )
        }
        default {
            @(
                'On a physical computer: turn the TPM on in the UEFI firmware setup (it may be called TPM, Security Device,'
                '  Intel PTT or AMD fTPM), save, restart, and check Get-Tpm or tpm.msc.'
                'On a virtual machine: add a TPM 2.0 device to it in the hypervisor, with the VM shut down.'
            )
        }
    }
}
