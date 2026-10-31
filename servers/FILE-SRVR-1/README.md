# BitLocker recovery keys in AD on a Server Core member server (FILE-SRVR-1)

> [!NOTE]
> How the lab's **FILE-SRVR-1**, a **Windows Server 2025 Datacenter Server Core** VM, was joined to `skynet-home.local` in the same OU as [PDQ-SRVR](../README.md) (`JMSC-Servers`) and got BitLocker on its operating system drive, with the recovery password stored in AD DS before encryption started. It uses the same scripts and the same servers GPO as PDQ-SRVR. What differs: FILE-SRVR-1 started outside the domain and has no desktop, so every step ran from its Hyper-V host over PowerShell Direct, driven by one script, [`Join-DomainAndBitLocker.ps1`](Join-DomainAndBitLocker.ps1). Lab run: 2026-10-30, 16:21 to 16:27 host time (UTC-07:00).

**Result.** C: is `FullyEncrypted` with XTS-AES 256, protection On, with a TPM protector and recovery password `{76C26316-8ED5-4972-9C99-AA17FA53C40C}`. AD holds exactly one recovery object for FILE-SRVR-1: `2026-10-30T16:24:30-08:00{76C26316-…}`.

---

## Contents

1. [Machines](#1-machines)
2. [Starting point](#2-starting-point)
3. [What the server needs](#3-what-the-server-needs)
4. [How it ran](#4-how-it-ran)
5. [What ran where, in order](#5-what-ran-where-in-order)
6. [Result](#6-result)
7. [What this run showed](#7-what-this-run-showed)
8. [Check BitLocker on the server](#8-check-bitlocker-on-the-server)
9. [Logs and files](#9-logs-and-files)

---

## 1. Machines

| Machine | Role | Shell |
|---|---|---|
| **GTR-PRO** | Windows 11 Pro, Hyper-V host of FILE-SRVR-1. Not domain-joined. Every step was started here. | PowerShell 7.6.9, elevated |
| **FILE-SRVR-1** | Windows Server 2025 Datacenter, **Server Core** (no Desktop Experience). Hyper-V Generation 2 VM `FILE-SRVR-1`: 8 vCPUs, 8 GB static memory, one 70 GB dynamic VHDX. The server being joined and encrypted. | Windows PowerShell 5.1 over PowerShell Direct from GTR-PRO, and SYSTEM for the BitLocker script |
| **DC25-1** | Server Core 2025 domain controller of `skynet-home.local`, 192.168.10.100. Nothing changed on it: the servers GPO already existed. | none used |
| **PDQ-SRVR** | The reference: FILE-SRVR-1 goes into its OU. | none used |

---

## 2. Starting point

A read-only check from GTR-PRO found a fresh workgroup server:

| Item | Before the run |
|---|---|
| Domain | none (`WORKGROUP`) |
| Network | DHCP 192.168.10.104 on the `Internet` switch; DNS 192.168.10.1, the router, which does not know `skynet-home.local` |
| TPM and Secure Boot | vTPM already on (local key protector); Secure Boot on (`MicrosoftWindows` template) |
| BitLocker | feature not installed; C: `FullyDecrypted` |
| Virtual DVD | the Server 2025 install ISO still loaded |
| PowerShell 7 | 7.6.9 already installed (MSI copied in over PowerShell Direct); `PowerShell.7` endpoint registered |

GTR-PRO uses the same router for DNS, so it could not find the domain either. DC25-1 answered by NetBIOS at 192.168.10.100, and from there everything checked out: DNS (`_ldap._tcp.dc._msdcs.skynet-home.local` points to `dc25-1:389`), TCP 53, 88, 389 and 445, and a clock offset of +1 s.

---

## 3. What the server needs

| Where | What | Done with | Used for |
|---|---|---|---|
| FILE-SRVR-1 | DNS pointing at DC25-1 | `Set-DnsClientServerAddress` on its NIC | the DC locator, the join, Group Policy |
| FILE-SRVR-1 | Membership in `JMSC-Servers` | `Add-Computer -OUPath`, with the OU read from PDQ-SRVR's computer object | the servers GPO, which applies by OU |
| FILE-SRVR-1 | `BitLocker` feature and module | `Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools`, no restart. On Server Core this is 2 features ([section 7](#7-what-this-run-showed)) | `Enable-BitLockerOsDrive.ps1` |
| FILE-SRVR-1 | vTPM | already there; [`Enable-VmTpm.ps1`](../../scripts/Enable-VmTpm.ps1) on GTR-PRO confirmed it and changed nothing | the TPM protector |
| FILE-SRVR-1 | No bootable media | the ISO ejected on GTR-PRO (`Set-VMDvdDrive -Path $null`) | BitLocker refuses to turn on with it (0x80310030) |
| FILE-SRVR-1 | PowerShell 7.6.9 | installed before the run | running `Enable-BitLockerOsDrive.ps1` as SYSTEM, as on PDQ-SRVR |
| GTR-PRO | `Hyper-V` module, PowerShell 7.6.9 | in-box with Hyper-V | PowerShell Direct, `Enable-VmTpm.ps1` |
| DC25-1 | `JMSC_BitLocker_AD_Backup_Servers`, linked to `JMSC-Servers` | already created for PDQ-SRVR ([servers GPO](../README.md#4-the-servers-gpo)) | AD backup required, XTS-AES 256, full-disk encryption |

---

## 4. How it ran

GTR-PRO is not in the domain, and FILE-SRVR-1 was not either, so there was no WinRM path between them. **PowerShell Direct** needs none: it reaches the guest over the Hyper-V VM bus with the guest's own administrator account, before and after the join, without network, WinRM or firewall rules. One script on GTR-PRO drove every step:

```powershell
# On GTR-PRO, in an elevated PowerShell 7 window. It asks for FILE-SRVR-1's local administrator
# and a domain admin, and stores neither.
.\Join-DomainAndBitLocker.ps1 -VMName FILE-SRVR-1 -RepoScripts <repo>\scripts `
    -RunLog .\run-log.md -EvidenceDir <folder for the script logs>
```

The script checks both credentials before it changes anything, checks the current state before each step (a second run skips what is done), stops at the first failed check, and appends every step and every script's output to [`run-log.md`](run-log.md). As on PDQ-SRVR, `Enable-BitLockerOsDrive.ps1` itself ran on the server as SYSTEM through a one-time scheduled task, so its AD lookups use the computer account ([why](../README.md#7-what-the-server-run-showed)).

---

## 5. What ran where, in order

| # | Time | Ran on | Step | Result |
|---|---|---|---|---|
| F1 | 16:21 | GTR-PRO | check the credentials: PowerShell Direct as `FILE-SRVR-1\Administrator`, LDAP bind to DC25-1 as `SKYNET\lorenzo` | both work |
| F2 | 16:22 | GTR-PRO, reading AD | read PDQ-SRVR's computer object; look for an existing FILE-SRVR-1 object | target `OU=JMSC-Servers,DC=skynet-home,DC=local`; no FILE-SRVR-1 object yet |
| F3 | 16:22 | FILE-SRVR-1 | DNS to 192.168.10.100; `Add-Computer -DomainName skynet-home.local -OUPath 'OU=JMSC-Servers,DC=skynet-home,DC=local'` | the DC locator finds `dc25-1`; joined, restart pending |
| F4 | 16:23 | FILE-SRVR-1 | `Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools` | `SuccessRestartRequired`, 2 features |
| F5 | 16:23 | GTR-PRO | eject the ISO; `Enable-VmTpm.ps1 -VMName FILE-SRVR-1 -NoConfirm` | the vTPM was already on: nothing to change |
| F6 | 16:23 | FILE-SRVR-1 | restart | back after 13 s; domain member, secure channel OK, BitLocker feature installed; object `CN=FILE-SRVR-1,OU=JMSC-Servers,…` |
| F7 | 16:24 | FILE-SRVR-1 | `gpupdate /target:computer /force`; `gpresult /scope computer /r` | `JMSC_BitLocker_AD_Backup_Servers` applied; 36 values in `HKLM\SOFTWARE\Policies\Microsoft\FVE` |
| F8 | 16:24 | FILE-SRVR-1, as SYSTEM | `Enable-BitLockerOsDrive.ps1 -WhatIf` | every check PASS |
| F9 | 16:24 | FILE-SRVR-1, as SYSTEM | `Enable-BitLockerOsDrive.ps1 -NoConfirm` | recovery password `{76C26316-…}` added, BitLocker on; event 784 at 16:24:32. PASSED with the same "not in AD yet" warning as PDQ-SRVR |
| F10 | 16:25 | FILE-SRVR-1 | restart for the hardware test | back at 16:25:45; `EncryptionInProgress`, XTS-AES 256 |
| F11 | 16:26 | GTR-PRO, reading AD | look for recovery objects under the computer object | exactly one, matching `{76C26316-…}` |
| F12 | 16:26 | FILE-SRVR-1, GTR-PRO | remove the copied scripts from the server; copy its logs from `C:\Logs`; check DNS | done; `FILE-SRVR-1.skynet-home.local` resolves to 192.168.10.104 |
| F13 | 16:44 | FILE-SRVR-1 console | `manage-bde -status C:` | Fully Encrypted, 100%, Protection On (picture 2) |

Times are GTR-PRO's clock. The full output of every step is in [`run-log.md`](run-log.md).

---

## 6. Result

| Check | Where | Result |
|---|---|---|
| Domain and OU | FILE-SRVR-1, AD | member of `skynet-home.local`, secure channel OK; `CN=FILE-SRVR-1,OU=JMSC-Servers,DC=skynet-home,DC=local`, next to PDQ-SRVR |
| Group Policy | FILE-SRVR-1 | `JMSC_BitLocker_AD_Backup_Servers` applied; no new GPO was needed |
| `manage-bde -status C:` | FILE-SRVR-1 console | Fully Encrypted, 100%, XTS-AES 256, Protection On, protectors TPM and Numerical Password (picture 2) |
| Protectors | FILE-SRVR-1 | TPM `{A8614725-DADB-4C9F-8A9B-36CE84F57AB8}` (PCR 7, 11, Secure Boot); recovery password `{76C26316-8ED5-4972-9C99-AA17FA53C40C}`, backup type AD backup |
| BitLocker events | FILE-SRVR-1 | 784, recovery information backed up to AD DS, at 16:24:32 for `{76C26316-…}` |
| Recovery objects under `CN=FILE-SRVR-1` | AD, read from GTR-PRO | exactly one: `2026-10-30T16:24:30-08:00{76C26316-…}` |
| BitLocker Recovery tab | ADUC | the same entry (picture 1) |

![Active Directory Users and Computers, OU JMSC-Servers holding FILE-SRVR-1 and PDQ-SRVR; FILE-SRVR-1 Properties, BitLocker Recovery tab: one entry dated 2026-10-30 16:24 with Password ID 76C26316-8ED5-4972-9C99-AA17FA53C40C; Details show the recovery password (redacted), Computer FILE-SRVR-1.skynet-home.local, Date 2026-10-30 16:24:30 -0800 and the same Password ID](../../images/FILE-SRVR/FILE-SRVR-1-ENABLED-BTL-1-REDACTED.png)

*1. ADUC: FILE-SRVR-1 sits in `JMSC-Servers` with PDQ-SRVR, and its BitLocker Recovery tab holds the one recovery password the run added, Password ID `76C26316-…`. The recovery password is redacted in this screenshot.*

![Virtual Machine Connection to FILE-SRVR-1 on GTR-PRO, Server Core console: manage-bde -status C: shows Size 69.00 GB, Conversion Status Fully Encrypted, Percentage Encrypted 100.0%, Encryption Method XTS-AES 256, Protection Status Protection On, Key Protectors TPM and Numerical Password; manage-bde -protectors -get C: shows TPM ID {A8614725-DADB-4C9F-8A9B-36CE84F57AB8} with PCR Validation Profile 7, 11 (uses Secure Boot), and Numerical Password ID {76C26316-8ED5-4972-9C99-AA17FA53C40C} with the password redacted and Backup type AD backup](../../images/FILE-SRVR/FILE-SRVR-1-ENABLED-BTL-2-REDACTED.png)

*2. The same result on FILE-SRVR-1's Server Core console, through Hyper-V's Virtual Machine Connection: C: is **Fully Encrypted** with XTS-AES 256 and **Protection On**, and the recovery password protector `{76C26316-…}` reports backup type **AD backup**. The password line is redacted in this screenshot.*

---

## 7. What this run showed

- **Server Core installs only the BitLocker feature itself.** The same `Install-WindowsFeature` command that gave PDQ-SRVR (Desktop Experience) 11 features gave FILE-SRVR-1 two: BitLocker Drive Encryption and Enhanced Storage. The Recovery Password Viewer and the AD DS snap-ins are GUI tools. Read the recovery password from a management computer (ADUC, or [README section 6](../../README.md#6-find-a-recovery-password-without-a-gui)), and check the drive on the server with `manage-bde` or `Get-BitLockerVolume` ([section 8](#8-check-bitlocker-on-the-server)): Server Core has no Control Panel.
- **PowerShell Direct covers a server that is not in the domain yet.** It worked before the join, when there was no WinRM trust, and after it, with the same local administrator account. Nothing had to be opened on the network.
- **Join straight into the OU.** `Add-Computer -OUPath` created the computer object in `JMSC-Servers`, so the servers GPO applied at the first Group Policy refresh after the restart. There was no object to move and no GPO to change.
- **DNS has to point at the DC.** The router does not serve `skynet-home.local`, so the server's DNS now points at DC25-1, which also answers its other lookups. Its address still comes from DHCP; a reservation or a static address keeps its DNS record stable.
- **Eject the install ISO first.** The Server 2025 ISO was still in the VM's DVD drive, and BitLocker refuses to turn on while bootable media is present (0x80310030). `Enable-BitLockerOsDrive.ps1` checks for it before any change.
- **Full-disk encryption fills a dynamic VHDX.** The servers GPO requires full-disk encryption (`OSEncryptionType` = 1), so BitLocker writes every sector and the 70 GB dynamic VHDX grows to its full size on the host (19.6 GB before). Plan the host's free space for it.
- **The same SYSTEM warning as PDQ-SRVR.** The SYSTEM run reported the recovery password as "not in AD yet", because the computer account cannot read its own recovery objects. Event 784 on the server and an admin LDAP read from GTR-PRO both confirmed it was in AD ([why](../README.md#7-what-the-server-run-showed)).
- **Event 784 writes the ID differently.** The event holds the protector ID in lower case without braces (`76c26316-…`), while BitLocker and AD show `{76C26316-…}`. Compare them normalized; the first version of the run script compared them literally and logged a false warning, since fixed.

---

## 8. Check BitLocker on the server

On FILE-SRVR-1's console, which is already elevated on Server Core. These run in both cmd and PowerShell ([servers README section 9](../README.md#9-check-bitlocker-on-the-server) explains each field):

```powershell
# Conversion status, percentage encrypted, method, protection, protector types
manage-bde -status C:

# The same from the BitLocker module
Get-BitLockerVolume -MountPoint C: | Format-List MountPoint, VolumeStatus, EncryptionPercentage, EncryptionMethod, ProtectionStatus, KeyProtector

# Each protector with its ID
manage-bde -protectors -get C:

# Event 784: recovery information backed up to AD DS; the fourth field is the protector ID
Get-WinEvent -LogName 'Microsoft-Windows-BitLocker/BitLocker Management' | Where-Object Id -eq 784 | Select-Object -First 1 TimeCreated, @{n='ProtectorId';e={$_.Properties[3].Value}}
```

> [!WARNING]
> `manage-bde -protectors -get C:` also prints the 48-digit recovery password. Run it where no one else can read the screen, and keep its output out of logs and tickets.

FILE-SRVR-1 when finished: Fully Encrypted, 100%, XTS-AES 256, Protection On, protectors TPM `{A8614725-…}` and Numerical Password `{76C26316-…}`. Protection reads Off while the drive is still encrypting.

From GTR-PRO, without signing in to the server (elevated; PowerShell Direct asks for FILE-SRVR-1's administrator credential):

```powershell
Invoke-Command -VMName FILE-SRVR-1 -Credential (Get-Credential) -ScriptBlock { manage-bde -status C: }
```

---

## 9. Logs and files

| File | What |
|---|---|
| [`run-log.md`](run-log.md) | the running log: every step with its time and result, and the full output of `Enable-VmTpm.ps1` and both `Enable-BitLockerOsDrive.ps1` runs |
| [`Join-DomainAndBitLocker.ps1`](Join-DomainAndBitLocker.ps1) | the script that drove the run from GTR-PRO |
| [`../server-logs/FILE-SRVR-1/`](../server-logs/FILE-SRVR-1/) | the transcripts (`.log`) and results tables (`.csv`) of the three script runs ([index](../server-logs/README.md)) |
| [`../../images/FILE-SRVR/`](../../images/FILE-SRVR/) | the two screenshots above, recovery password redacted |

None of them contains the recovery password.
