# GPO backups

Backups of the lab's BitLocker GPOs, made with `Backup-GPO` from the PAW. The scripts and settings files in [`scripts/`](../scripts/) are the source of truth: these folders are snapshots of what they created, for reference and for `Restore-GPO` / `Import-GPO`.

| Folder | GPO | GPO ID | Backup ID | Taken | Linked to in the lab |
|---|---|---|---|---|---|
| [`JMSC_BitLocker_AD_Backup_Servers/`](JMSC_BitLocker_AD_Backup_Servers/) | `JMSC_BitLocker_AD_Backup_Servers`, the **servers** GPO | `{42A012F0-F1B0-41BD-8BCD-AFC976B0B0B5}` | `{61E583DA-6875-48CB-880C-B9237E706BCF}` | 2026-10-30 07:05:36 UTC | `OU=JMSC-Servers` |

## JMSC_BitLocker_AD_Backup_Servers

The servers GPO from [SERVERS.md](../SERVERS.md#4-the-servers-gpo), created by `Set-BitLockerAdBackupGpo.ps1` from [`scripts/BitLockerAdBackupGpo.Servers.json`](../scripts/BitLockerAdBackupGpo.Servers.json): 36 values under `HKLM\SOFTWARE\Policies\Microsoft\FVE` (recovery and AD backup for OS, fixed and removable drives, XTS-AES 256, full encryption, software encryption only, DMA protection when locked, the custom recovery-screen message), and none of the deny-write values. Computer version 36, status `AllSettingsEnabled`.

| File | What it is |
|---|---|
| `JMSC_BitLocker_AD_Backup_Servers.html` | Readable report of every setting (`Get-GPOReport -ReportType Html`). Download it and open it in a browser. |
| `manifest.xml` | Index of the backup (a hidden file). `Import-GPO` and `Restore-GPO` find the backup through it. |
| `{61E583DA-…}\Backup.xml`, `bkupInfo.xml` | The backup itself: GPO ID, domain, permissions, extensions. |
| `{61E583DA-…}\gpreport.xml` | The settings report in XML. |
| `{61E583DA-…}\DomainSysvol\GPO\Machine\registry.pol` | The 36 policy values. SHA-256 `20A6DB7AD4C58B78BB09089E790E7DA929474BC1BF46BBFB261332FF0B971497`, the same file `Set-BitLockerAdBackupGpo.ps1` verified in SYSVOL when it created the GPO. |
| `{61E583DA-…}\DomainSysvol\GPO\GPO.cmt` | The GPO comment. |

Keep the `{61E583DA-…}` folder name as it is: the manifest refers to it by that ID. The backup names the lab domain, its DC and the Domain Admins / Enterprise Admins groups from the GPO's permissions; it holds no recovery passwords or other secrets.

**Use it** (GroupPolicy module; in PowerShell 7, `Import-Module GroupPolicy -SkipEditionCheck` first):

```powershell
# Same domain: put the GPO back as it was at backup time (same GPO ID)
Restore-GPO -BackupId 61E583DA-6875-48CB-880C-B9237E706BCF -Path .\gpo\JMSC_BitLocker_AD_Backup_Servers

# Any domain: copy the settings into a GPO of that name, creating it if needed, then link it
Import-GPO -BackupId 61E583DA-6875-48CB-880C-B9237E706BCF -Path .\gpo\JMSC_BitLocker_AD_Backup_Servers -TargetName 'JMSC_BitLocker_AD_Backup_Servers' -CreateIfNeeded
New-GPLink -Name 'JMSC_BitLocker_AD_Backup_Servers' -Target 'OU=JMSC-Servers,DC=<your>,DC=<domain>' -LinkEnabled Yes
```

Links live on the OU, not in the GPO, so neither command brings them back: link the GPO again with `New-GPLink`. In a new domain, running the script with the settings file does the same and verifies the result.

**Refresh it** after the GPO changes (from a computer with the GroupPolicy module, in the repository folder):

```powershell
$Name = 'JMSC_BitLocker_AD_Backup_Servers'
Backup-GPO -Name $Name -Path ".\gpo\$Name" -Comment 'Lab snapshot from skynet-home.local, created by Set-BitLockerAdBackupGpo.ps1 with BitLockerAdBackupGpo.Servers.json'
Get-GPOReport -Name $Name -ReportType Html -Path ".\gpo\$Name\$Name.html"
```

`Backup-GPO` adds a new `{ID}` folder next to the old one; remove the old folder and its entry in `manifest.xml` (or start from an empty folder) so only one backup remains.
