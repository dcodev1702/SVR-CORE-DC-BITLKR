# SVR-CORE-DC-BITLKR — BitLocker recovery keys in Active Directory (Windows Server Core 2025/2022)

> [!NOTE]
> Domain-joined Windows computers can write their **BitLocker recovery passwords and key packages** to **their own computer object in AD DS**. This repository sets that up from a **Server Core 2025 domain controller** with in-box PowerShell only — **no GPMC console, no GUI, no downloads**: one GPO for the clients, a one-time backfill for drives that were encrypted before the GPO existed, and key lookup with `Get-ADObject`. **The domain controller needs no schema extension, no ACL change and no extra role.**

> [!IMPORTANT]
> **Status (2026-10-28): work in progress — not yet run in the lab.** The policy registry value names and values in [section 3](#3-create-the-gpo-server-core-powershell) are checked against `VolumeEncryption.admx` / `.adml` as shipped with Windows. Lab verification against a Server Core 2025 DC, and scripts that wrap these steps, come next ([Roadmap](#roadmap)). Link the GPO to a test OU first.

---

## Contents

1. [How it works](#1-how-it-works)
2. [Prerequisites](#2-prerequisites)
3. [Create the GPO (Server Core, PowerShell)](#3-create-the-gpo-server-core-powershell)
4. [Back up keys of drives that are already encrypted](#4-back-up-keys-of-drives-that-are-already-encrypted)
5. [Encrypt new drives](#5-encrypt-new-drives)
6. [Find a recovery password without a GUI](#6-find-a-recovery-password-without-a-gui)
7. [Who can read the keys](#7-who-can-read-the-keys)
8. [BitLocker on the domain controller itself](#8-bitlocker-on-the-domain-controller-itself)
9. [Troubleshooting](#9-troubleshooting)
- [Roadmap](#roadmap)
- [References](#references)

---

## 1. How it works

1. A GPO enables the *Choose how BitLocker-protected … drives can be recovered* policies on the clients (`HKLM\SOFTWARE\Policies\Microsoft\FVE`).
2. When BitLocker creates a **recovery password** protector, the client writes it to AD DS with its computer account: a child object of class `msFVE-RecoveryInformation` under its own computer object, named `<timestamp>{<recovery password ID>}`.
3. With *Do not enable BitLocker until recovery information is stored to AD DS*, the client will not start encryption if that write fails, so no drive is encrypted without its key in AD.
4. Administrators read the key from AD: `Get-ADObject` on Server Core, or the BitLocker Recovery Password Viewer (RSAT) on a computer with a GUI.

| Attribute on `msFVE-RecoveryInformation` | Content |
|---|---|
| `msFVE-RecoveryPassword` | The 48-digit recovery password. **Confidential attribute** ([section 7](#7-who-can-read-the-keys)). |
| `msFVE-KeyPackage` | Key package (stored with *recovery passwords and key packages*): lets `repair-bde` recover data from a damaged drive. |
| `msFVE-RecoveryGuid` | Recovery password ID — the ID shown on the BitLocker recovery screen. |
| `msFVE-VolumeGuid` | Volume ID. |

**What this does not do**

- It does not encrypt anything. It makes sure that when BitLocker is turned on, the recovery password lands in AD.
- It does not reach back: drives encrypted before the GPO applied keep their keys local until you run the backfill ([section 4](#4-back-up-keys-of-drives-that-are-already-encrypted)).
- It is not Entra ID / Intune escrow (that is `BackupToAAD-BitLockerKeyProtector`).
- *Turn on TPM backup to Active Directory Domain Services* is **not** needed. It is about TPM owner information, not recovery keys, and is deprecated: since Windows 10 1607 Windows no longer keeps the TPM owner password.

---

## 2. Prerequisites

| Item | Detail |
|---|---|
| **Where to run** | A domain controller (every DC has the `ActiveDirectory` and `GroupPolicy` modules; Server Core is fine) or a domain-joined PAW / management computer with RSAT **Group Policy Management** and **Active Directory** tools. Windows PowerShell 5.1, elevated. |
| **Account** | Domain Admin for these steps (create and link a GPO, read the confidential attribute). |
| **Forest** | Schema of Windows Server 2008 or later: `msFVE-RecoveryInformation` has been in the base schema since then, so a Server 2025 forest has it. Check: `Get-ADObject "CN=ms-FVE-RecoveryInformation,$((Get-ADRootDSE).schemaNamingContext)"` |
| **Clients** | Domain-joined Windows 10/11 or Windows Server with a TPM (or vTPM). Windows Server needs the feature first: `Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools -Restart`. A DC must be reachable when the recovery password is created. |
| **OU** | The client computers must sit in an **OU**: a GPO cannot be linked to the default `CN=Computers` container. Move them to an OU, or link the GPO at the domain root. |

---

## 3. Create the GPO (Server Core, PowerShell)

`Set-GPRegistryValue` writes the same `Registry.pol` entries the GPMC editor would. Because the value names match the ADMX, GPMC on a GUI computer shows them as the normal administrative template settings.

```powershell
Import-Module GroupPolicy

$GpoName = 'JMSC_BitLocker_AD_Backup'
$Target  = 'OU=JMSC-WDAC-WRKSTNS,DC=skynet-home,DC=local'     # your client OU, or the domain root
$Key     = 'HKLM\SOFTWARE\Policies\Microsoft\FVE'

$gpo = New-GPO -Name $GpoName -Comment 'BitLocker: escrow recovery passwords and key packages to AD DS'

$values = [ordered]@{
    Recovery                     = 1   # policy Enabled
    ManageDRA                    = 1   # Allow data recovery agent (GPMC default)
    RecoveryPassword             = 2   # 48-digit recovery password: 2 = Allow, 1 = Require, 0 = Do not allow
    RecoveryKey                  = 2   # 256-bit recovery key: same values
    HideRecoveryPage             = 0   # keep the recovery options in the setup wizard
    ActiveDirectoryBackup        = 1   # Save BitLocker recovery information to AD DS
    ActiveDirectoryInfoToStore   = 1   # 1 = recovery passwords and key packages, 2 = recovery passwords only
    RequireActiveDirectoryBackup = 1   # Do not enable BitLocker until recovery information is stored to AD DS
}
foreach ($prefix in 'OS', 'FDV', 'RDV') {     # added 'RDV' for removable drives, see below
    foreach ($v in $values.GetEnumerator()) {
        Set-GPRegistryValue -Guid $gpo.Id -Key $Key -ValueName "$prefix$($v.Key)" -Type DWord -Value $v.Value | Out-Null
    }
}

New-GPLink -Guid $gpo.Id -Target $Target -LinkEnabled Yes

# Check what the GPO holds (24 values: 8 each for OS, FDV and RDV)
Get-GPRegistryValue -Name $GpoName -Key $Key | Sort-Object ValueName | Format-Table ValueName, Value

# Removable drives: BitLocker To Go only once the key is in AD - expect Value 1
Get-GPRegistryValue -Name $GpoName -Key $Key -ValueName RDVRequireActiveDirectoryBackup | Format-Table ValueName, Value
```

| Registry value (`OS…` / `FDV…` / `RDV…`) | GPMC option |
|---|---|
| `OSRecovery` / `FDVRecovery` / `RDVRecovery` | Policy *Choose how BitLocker-protected operating system / fixed / removable drives can be recovered* = **Enabled** |
| `…ManageDRA` | Allow data recovery agent |
| `…RecoveryPassword` | Configure user storage of BitLocker recovery information: **Allow 48-digit recovery password** |
| `…RecoveryKey` | Configure user storage of BitLocker recovery information: **Allow 256-bit recovery key** |
| `…HideRecoveryPage` | Omit recovery options from the BitLocker setup wizard |
| `…ActiveDirectoryBackup` | Save BitLocker recovery information to AD DS for … drives |
| `…ActiveDirectoryInfoToStore` | Configure storage of BitLocker recovery information to AD DS: **Store recovery passwords and key packages** |
| `…RequireActiveDirectoryBackup` | Do not enable BitLocker until recovery information is stored to AD DS for … drives |

> [!WARNING]
> **Removable drives (`RDV`).** Because `'RDV'` is in the prefix list, the loop also sets `RDVRequireActiveDirectoryBackup = 1` (*Do not enable BitLocker until recovery information is stored to AD DS for removable data drives*). BitLocker To Go can then only be turned on while a DC is reachable.

---

## 4. Back up keys of drives that are already encrypted

The GPO acts when a protector is created; it does not upload keys that already exist. On each client (elevated), after the GPO has applied:

```powershell
gpupdate /force

foreach ($vol in Get-BitLockerVolume | Where-Object VolumeStatus -ne 'FullyDecrypted') {
    $vol.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | ForEach-Object {
        Backup-BitLockerKeyProtector -MountPoint $vol.MountPoint -KeyProtectorId $_.KeyProtectorId
    }
}
```

- **A drive with no recovery password** (TPM only): `Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector`. Under the GPO the new password is written to AD as it is created.
- **`manage-bde` equivalent:** `manage-bde -protectors -get C:` for the ID, then `manage-bde -protectors -adbackup C: -id {<ID>}`.
- **Many computers:** run the same block with `Invoke-Command -ComputerName <list>`.

---

## 5. Encrypt new drives

Once the GPO applies, the recovery password is escrowed however BitLocker is turned on (Control Panel, `manage-bde`, PowerShell). A TPM-only drive has **no** recovery password, so there would be nothing to escrow — add the recovery password protector first:

```powershell
Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector   # written to AD now; fails if no DC is reachable
Enable-BitLocker -MountPoint C: -TpmProtector -UsedSpaceOnly
```

---

## 6. Find a recovery password without a GUI

On the DC or the PAW:

```powershell
# All keys stored for one computer, newest last
$pc = Get-ADComputer 'WIN11-PAW-WDAC'
Get-ADObject -SearchBase $pc.DistinguishedName -Filter "objectClass -eq 'msFVE-RecoveryInformation'" `
    -Properties msFVE-RecoveryPassword, whenCreated |
    Sort-Object whenCreated | Select-Object whenCreated, msFVE-RecoveryPassword

# By the first 8 characters of the recovery key ID shown on the recovery screen
Get-ADObject -Filter "objectClass -eq 'msFVE-RecoveryInformation' -and Name -like '*{6F1C2D3E*'" `
    -Properties msFVE-RecoveryPassword | Select-Object DistinguishedName, msFVE-RecoveryPassword
```

**With a GUI:** on a domain-joined Windows 11 computer, install the BitLocker Recovery Password Viewer from an elevated prompt:

```powershell
DISM.exe /Online /Add-Capability /CapabilityName:Rsat.BitLocker.Recovery.Tools~~~~0.0.1.0

# Verify: State : Installed
DISM.exe /Online /Get-CapabilityInfo /CapabilityName:Rsat.BitLocker.Recovery.Tools~~~~0.0.1.0
```

The viewer is an ADUC extension. If ADUC isn't installed yet, add it the same way first: `DISM.exe /Online /Add-Capability /CapabilityName:Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`.

Reopen ADUC; it then shows a **BitLocker Recovery** tab on computer objects and *Find BitLocker recovery password* on the domain. Without Internet access, append `/Source:<Features on Demand media> /LimitAccess`.

> [!NOTE]
> The DISM module cmdlets (`Add-WindowsCapability`, `Get-WindowsCapability`) fail in PowerShell 7 with `Class not registered`. Use `DISM.exe`, which works from any shell, or run the cmdlets from Windows PowerShell 5.1 (`powershell.exe`).

---

## 7. Who can read the keys

- `msFVE-RecoveryPassword` is a **confidential attribute**. By default only Domain Admins can read it; an account without the right sees the object with an empty password.
- **Help desk:** delegate on the client OU — Delegation of Control Wizard → custom task → *msFVE-RecoveryInformation objects* → Full Control. The wizard needs a GUI computer; a PowerShell version for Server Core is on the [Roadmap](#roadmap).

---

## 8. BitLocker on the domain controller itself

Only needed if you also want to encrypt the DC's own drives.

1. **Feature** (Server Core 2025): `Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools -Restart`
2. **TPM.** A Hyper-V Generation 2 VM needs a vTPM. On the host, with the VM shut down: `Set-VMKeyProtector -VMName <vm> -NewLocalKeyProtector; Enable-VMTPM -VMName <vm>`
3. **Escrow.** If the GPO also applies to the DC (link to the *Domain Controllers* OU or the domain root), the DC writes its own key into AD.

> [!CAUTION]
> **A DC is a poor sole keeper of its own key.** If the DC boots into BitLocker recovery, the copy in its own database is out of reach. With more than one DC, another DC holds a replica. With a **single DC** (typical in a lab), keep a copy outside the VM — e.g. the output of `(Get-BitLockerVolume C:).KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword'` in your password vault.

---

## 9. Troubleshooting

| Symptom | Check |
|---|---|
| No `msFVE-RecoveryInformation` object appears | On the client: `gpresult /scope computer /r` lists the GPO; `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\FVE` shows the values; the volume has a `RecoveryPassword` protector; for drives encrypted earlier, the backfill ([section 4](#4-back-up-keys-of-drives-that-are-already-encrypted)) ran. |
| `Add-BitLockerKeyProtector` / `Enable-BitLocker` fails with an AD backup error | No DC reachable — `RequireActiveDirectoryBackup` is doing its job. Fix name resolution / connectivity and retry. |
| `New-GPLink` fails on `CN=Computers` | Containers cannot take GPO links. Use an OU, or the domain root. |
| `Get-ADObject` returns the object but no password | The account cannot read the confidential attribute ([section 7](#7-who-can-read-the-keys)). |
| What did BitLocker do? | `Get-WinEvent -LogName 'Microsoft-Windows-BitLocker/BitLocker Management' -MaxEvents 20` (Event Viewer: *Applications and Services Logs → Microsoft → Windows → BitLocker-API → Management*). |

---

## Roadmap

- [ ] Run sections 3–6 in the lab against a Server Core 2025 DC and record the results here.
- [ ] Script the GPO creation (settings file, `-WhatIf`).
- [ ] Script the backfill for a list of computers.
- [ ] Script key lookup by computer name or recovery key ID.
- [ ] Help-desk delegation from PowerShell (no Delegation of Control Wizard on Server Core).
- [ ] Report: computers with BitLocker on but no recovery password in AD.

---

## References

- Microsoft Learn — [BitLocker recovery overview](https://learn.microsoft.com/windows/security/operating-system-security/data-protection/bitlocker/recovery-overview)
- Microsoft Learn — [BitLocker recovery process](https://learn.microsoft.com/windows/security/operating-system-security/data-protection/bitlocker/recovery-process)
- Microsoft Learn — [Configure BitLocker (policy settings)](https://learn.microsoft.com/windows/security/operating-system-security/data-protection/bitlocker/configure)
- Microsoft Learn — [`Backup-BitLockerKeyProtector`](https://learn.microsoft.com/powershell/module/bitlocker/backup-bitlockerkeyprotector)
- Microsoft Learn — [`Set-GPRegistryValue`](https://learn.microsoft.com/powershell/module/grouppolicy/set-gpregistryvalue)
- Companion repository — [SVR-CORE-DC-APPLKR](https://github.com/dcodev1702/SVR-CORE-DC-APPLKR): AppLocker on Server Core 2025 domain controllers.
