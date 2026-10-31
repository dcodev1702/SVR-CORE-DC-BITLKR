# FILE-SRVR-1 run log: domain join and BitLocker with AD key backup

The running log of the FILE-SRVR-1 run, as [`Join-DomainAndBitLocker.ps1`](Join-DomainAndBitLocker.ps1) wrote it, step by step with the full output of each script. The write-up, result and screenshots are in the [README](README.md).

Host **GTR-PRO** (Windows 11 Pro, Hyper-V); guest **FILE-SRVR-1** (Windows Server 2025 Datacenter, **Server Core**, Generation 2 VM). Times are GTR-PRO local time (UTC-07:00), 2026-10-30. Recovery passwords are never written here, only protector IDs.

### 0. Preparation (from Claude Code on GTR-PRO)

- `16:14` Repo downloaded as ZIP (git not installed) to `C:\Users\Lorenzo\Downloads\SVR-CORE-DC-BITLKR` (branch `main`).
- `16:14` Read `servers/README.md`, `scripts/Enable-VmTpm.ps1`, `scripts/Enable-BitLockerOsDrive.ps1`, `scripts/Confirm-Change.ps1`, `scripts/VmTpmGuidance.ps1`, and the PDQ-SRVR / DC25-1 run logs. Nothing in them runs before its own checks pass.
- `16:14` From the repo: domain `skynet-home.local` (SKYNET), DC `DC25-1`, PDQ-SRVR is in `OU=JMSC-Servers,DC=skynet-home,DC=local`, and GPO `JMSC_BitLocker_AD_Backup_Servers` (AD backup required, XTS-AES 256, full-disk) is already linked there. No new GPO needed.
- `16:15` GTR-PRO and the VM use the router (192.168.10.1) for DNS, which does not know `skynet-home.local`. Found DC25-1 by NetBIOS at **192.168.10.100**.
- `16:15` DC25-1 answers DNS for the domain (`_ldap._tcp.dc._msdcs` -> dc25-1:389); TCP 53/88/389/445 open; clock offset vs GTR-PRO +1.06 s. PDQ-SRVR = 192.168.10.103. No DNS record for FILE-SRVR-1 yet.
- `16:16` VM check: vTPM **already enabled** (key protector present), Secure Boot On (MicrosoftWindows), disk `FILE-SRVR-1.vhdx` dynamic 70 GB (19.6 GB used; full-disk encryption will grow it to ~70 GB, host has 810 GB free), no checkpoints. **Server 2025 ISO still in the virtual DVD** - must be ejected (BitLocker refuses with bootable media, 0x80310030).
- `16:16` Earlier today: PowerShell 7.6.9 installed in the VM (`PowerShell.7` endpoint), nested virtualization on, NIC on the `Internet` switch (Wi-Fi), DHCP 192.168.10.104.

### 1. Run started on GTR-PRO

- `16:21:40` elevated PowerShell 7.6.9; VM FILE-SRVR-1; domain skynet-home.local via DC 192.168.10.100
- `16:21:56` **PASS** guest credential works: FILE-SRVR-1\Administrator (PowerShell Direct)
- `16:22:22` **PASS** domain credential works: SKYNET\lorenzo (LDAP bind to 192.168.10.100)

### 2. Target OU (same as PDQ-SRVR)

- `16:22:22` **PASS** PDQ-SRVR is CN=PDQ-SRVR,OU=JMSC-Servers,DC=skynet-home,DC=local -> target OU **OU=JMSC-Servers,DC=skynet-home,DC=local**
- `16:22:22` no computer object for FILE-SRVR-1 yet; the join creates CN=FILE-SRVR-1,OU=JMSC-Servers,DC=skynet-home,DC=local

### 3. Guest before

- `16:22:50` FILE-SRVR-1: domain member False (WORKGROUP); NIC "Ethernet" 192.168.10.104, DNS 192.168.10.1; TPM present True, ready True; Secure Boot True; BitLocker feature Available

### 4. DNS and domain join

- `16:22:53` **PASS** DNS on "Ethernet" set to 192.168.10.100 (was 192.168.10.1); DC locator finds dc25-1.skynet-home.local; LDAP reachable True
- `16:22:55` **PASS** Add-Computer -DomainName skynet-home.local -OUPath "OU=JMSC-Servers,DC=skynet-home,DC=local": succeeded, restart pending

### 5. BitLocker feature

- `16:23:28` Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools: Success=True; RestartNeeded=Yes; ExitCode=SuccessRestartRequired; 2 feature(s): BitLocker Drive Encryption, Enhanced Storage

### 6. Virtual DVD and vTPM (host)

- `16:23:29` **PASS** ejected "D:\operating_systems\windows_isos\Server 2025\en-us_windows_server_2025_updated_march_2026_x64_dvd_8e06425a.iso" from the virtual DVD drive (controller 0:1)
- `16:23:30` Enable-VmTpm.ps1 -VMName FILE-SRVR-1 -NoConfirm output:

```text

Status Check                Detail
------ -----                ------
PASS   Hyper-V host         GTR-PRO; Hyper-V 2.0.0.0 in PowerShell Core 7.6.9
PASS   VM                   'FILE-SRVR-1' (3362fb24-37ab-4aed-a7da-5a54b931beaf): Generation 2, Running; vTPM on; key protector present
PASS   Plan                 the vTPM is already on - nothing to change; 'FILE-SRVR-1' stays Running
PASS   Verify vTPM          on (Get-VMSecurity: TpmEnabled = True)
PASS   Verify key protector present
PASS   Verify state         Running


PASSED
Transcript: c:\Users\Lorenzo\code\host-configure\FILE-SRVR-1-evidence\Enable-VmTpm-20261030-162329.log   Results: c:\Users\Lorenzo\code\host-configure\FILE-SRVR-1-evidence\Enable-VmTpm-20261030-162329.csv
```

- `16:23:30` **PASS** Enable-VmTpm.ps1 passed

### 7. Restart: finish the join and the feature install

- `16:23:30` restart requested (domain join and BitLocker feature); previous boot 10/30/2026 4:09:27 PM
- `16:23:43` **PASS** back up, booted 10/30/2026 4:23:39 PM
- `16:24:14` **PASS** domain member True (skynet-home.local); secure channel True; TPM present True, ready True; BitLocker feature Installed, module True
- `16:24:14` **PASS** AD: CN=FILE-SRVR-1,OU=JMSC-Servers,DC=skynet-home,DC=local - same OU as PDQ-SRVR

### 8. Group Policy

- `16:24:21` gpupdate: Updating policy... Computer Policy update has completed successfully.
- `16:24:21` **PASS** JMSC_BitLocker_AD_Backup_Servers applied: True; 36 values under HKLM\SOFTWARE\Policies\Microsoft\FVE (OSActiveDirectoryBackup=1, OSRequireActiveDirectoryBackup=1, EncryptionMethodWithXtsOs=7, OSEncryptionType=1)

### 9. Enable-BitLockerOsDrive.ps1 -WhatIf (as SYSTEM)

- `16:24:21` copied Enable-BitLockerOsDrive.ps1, Confirm-Change.ps1, VmTpmGuidance.ps1 to C:\Windows\Temp\BitLockerOs

```text

Status Check             Detail
------ -----             ------
PASS   Modules           PowerShell Core 7.6.9
PASS   Active Directory  CN=FILE-SRVR-1,OU=JMSC-Servers,DC=skynet-home,DC=local on DC25-1.skynet-home.local; 0 recovery object(s) stored for it
PASS   Policy            AD backup required; encryption method XtsAes256 (EncryptionMethodWithXtsOs = 7)
PASS   TPM               present and ready
PASS   Secure Boot       on
PASS   WinRE             enabled
PASS   Drive             C: FullyDecrypted, None, protection Off, protectors: none
PASS   Optical drives    no disc or ISO loaded
PASS   Recovery password -WhatIf: would add one and confirm it in AD
PASS   Encrypt           -WhatIf: would encrypt with XtsAes256 and a TPM protector


PASSED
Transcript: C:\Logs\Enable-BitLockerOsDrive-20261030-162423.log   Results: C:\Logs\Enable-BitLockerOsDrive-20261030-162423.csv
```

- `16:24:28` **PASS** -WhatIf passed (task result 0)

### 10. Enable-BitLockerOsDrive.ps1 -NoConfirm (as SYSTEM)


```text

WARNING: this changes the configuration - turn on BitLocker for C: on FILE-SRVR-1
  Computer: FILE-SRVR-1 (CN=FILE-SRVR-1,OU=JMSC-Servers,DC=skynet-home,DC=local)
  Drive now: C: FullyDecrypted, None, protection Off, protectors: none
    1. add a recovery password; BitLocker writes it to AD when the next step turns encryption on, and does not encrypt if that fails
    2. encrypt with XtsAes256 and a TPM protector (full drive, starting after the restart that tests TPM unlock)
  Effect: no encryption without the recovery password in AD; read it with README section 6.
  Undo: Disable-BitLocker -MountPoint C: (decrypts the drive). The recovery password stays in AD.
  -NoConfirm: continuing without a prompt.

Status Check                    Detail
------ -----                    ------
PASS   Modules                  PowerShell Core 7.6.9
PASS   Active Directory         CN=FILE-SRVR-1,OU=JMSC-Servers,DC=skynet-home,DC=local on DC25-1.skynet-home.local; 0 recovery object(s) stored for it
PASS   Policy                   AD backup required; encryption method XtsAes256 (EncryptionMethodWithXtsOs = 7)
PASS   TPM                      present and ready
PASS   Secure Boot              on
PASS   WinRE                    enabled
PASS   Drive                    C: FullyDecrypted, None, protection Off, protectors: none
PASS   Optical drives           no disc or ISO loaded
PASS   Recovery password        {76C26316-8ED5-4972-9C99-AA17FA53C40C} added; BitLocker writes it to AD when encryption is turned on
PASS   Encrypt                  Enable-BitLocker with XtsAes256 and a TPM protector
WARN   Verify recovery password {76C26316-8ED5-4972-9C99-AA17FA53C40C} is not in AD yet. BitLocker writes it when encryption starts after the restart and does not encrypt without it (RequireActiveDirectoryBackup = 1).
                                Run this script again after the restart to confirm it in AD.
PASS   Verify TPM protector     present
PASS   Verify                   hardware test pending: encryption starts after the restart


PASSED with 1 warning(s)
NEXT: Restart the computer: the hardware test checks that the TPM unlocks the drive, then encryption starts. Run this script again afterwards to confirm the recovery password in AD.
Transcript: C:\Logs\Enable-BitLockerOsDrive-20261030-162429.log   Results: C:\Logs\Enable-BitLockerOsDrive-20261030-162429.csv
```

- `16:25:36` **PASS** Enable-BitLockerOsDrive.ps1 passed (task result 0)

### 11. Restart for the hardware test, then verify

- `16:25:36` restart requested (BitLocker hardware test); previous boot 10/30/2026 4:23:39 PM
- `16:26:34` **PASS** back up, booted 10/30/2026 4:25:45 PM
- `16:26:37` **PASS** C: EncryptionInProgress (14%), XtsAes256, protection Off; protectors: Tpm {A8614725-DADB-4C9F-8A9B-36CE84F57AB8}, RecoveryPassword {76C26316-8ED5-4972-9C99-AA17FA53C40C}
- `16:26:37` **WARN** event 784 (recovery information backed up to AD DS) at 10/30/2026 4:24:32 PM for protector 76c26316-8ed5-4972-9c99-aa17fa53c40c
- `16:26:38` **PASS** AD: 1 recovery object(s) under CN=FILE-SRVR-1,OU=JMSC-Servers,DC=skynet-home,DC=local: 2026-10-30T16:24:30-08:00{76C26316-8ED5-4972-9C99-AA17FA53C40C} - matches the drive's recovery password {76C26316-8ED5-4972-9C99-AA17FA53C40C}

### 12. Clean-up and evidence

- `16:26:38` removed C:\Windows\Temp\BitLockerOs from the guest: True
- `16:26:39` copied 4 BitLocker log file(s) from the guest's C:\Logs to c:\Users\Lorenzo\code\host-configure\FILE-SRVR-1-evidence
- `16:26:39` **PASS** DNS: FILE-SRVR-1.skynet-home.local -> 192.168.10.104

### Done

- `16:26:39` **PASS** all steps passed

### Review (Claude Code, after the run)

- `16:27` The section 11 **WARN** on event 784 is a false alarm in the run script, not in BitLocker: the event stores the protector ID as `76c26316-…` (lower case, no braces) and the script compared it literally with `{76C26316-…}`. It is the same protector, and AD holds its object. Comparison fixed in `Join-DomainAndBitLocker.ps1` for later runs.
- `16:27` `protection Off` while `EncryptionInProgress` is expected; it turns On when C: reaches `FullyEncrypted` (as on PDQ-SRVR). At 16:27:36 the VHDX had grown from 19.6 to 21.4 GB of 70 GB: encryption is running in the background.
- `16:27` Evidence (the run's `FILE-SRVR-1-evidence\` folder, now [`server-logs/FILE-SRVR-1/`](../server-logs/FILE-SRVR-1/)): `Enable-VmTpm-20261030-162329` (.log/.csv, from GTR-PRO) and `Enable-BitLockerOsDrive-20261030-162423` (-WhatIf) / `-162429` (the change) (.log/.csv, copied from FILE-SRVR-1 `C:\Logs`). None contains the recovery password.
- `16:40` Screenshot, ADUC: FILE-SRVR-1 in `JMSC-Servers` next to PDQ-SRVR, one recovery password, Password ID `76C26316-…`, added 2026-10-30 16:24 ([README picture 1](README.md#6-result)).
- `16:44` Screenshot, FILE-SRVR-1 Server Core console: `manage-bde -status C:` reports **Fully Encrypted, 100%, XTS-AES 256, Protection On**; `manage-bde -protectors -get C:` shows TPM `{A8614725-…}` (PCR 7, 11, Secure Boot) and Numerical Password `{76C26316-…}` with backup type **AD backup** ([README picture 2](README.md#6-result)).
