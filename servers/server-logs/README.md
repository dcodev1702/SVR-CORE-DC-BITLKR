# Server logs

The logs the two scripts wrote during the PDQ-SRVR run ([steps S5, S8 and S9](../README.md#5-what-ran-where-in-order)), copied unchanged from `C:\Logs` on each machine (SHA-256 checked after the copy). Each run writes a transcript (`.log`) and a results table (`.csv`). Times are the machines' clocks, UTC-08:00. None of them contains a recovery password: the scripts never print or log it.

[`FILE-SRVR-1/`](FILE-SRVR-1/) holds the same scripts' logs from the FILE-SRVR-1 run (Windows Server 2025 Server Core) on 2026-10-30 ([write-up](../FILE-SRVR-1/README.md)): `Enable-VmTpm.ps1` on its Hyper-V host GTR-PRO, and `Enable-BitLockerOsDrive.ps1` on FILE-SRVR-1, copied from its `C:\Logs`. Times are those machines' clocks.

| Folder | Files (`.log`, `.csv`) | Step | Ran as | Outcome |
|---|---|---|---|---|
| [`DC25-1/`](DC25-1/) | `Set-BitLockerAdBackupGpo-20261029-233727` | S5, `-WhatIf` | `SKYNET\lorenzo`, `PowerShell.7` endpoint | PASSED with 1 warning (no `VolumeEncryption.admx` in the central store) |
| [`DC25-1/`](DC25-1/) | `Set-BitLockerAdBackupGpo-20261029-233747` | S5, create and link the servers GPO | the same | PASSED with 1 warning; GPO `{42A012F0-…}` created, 36 values and the link verified |
| [`PDQ-SRVR/`](PDQ-SRVR/) | `Enable-BitLockerOsDrive-20261029-234408` | S8, `-WhatIf` | SYSTEM (`SKYNET\PDQ-SRVR$`), one-time scheduled task | PASSED |
| [`PDQ-SRVR/`](PDQ-SRVR/) | `Enable-BitLockerOsDrive-20261029-234433` | S9, turn BitLocker on | the same | PASSED with 1 warning: recovery password "not in AD yet", although BitLocker had written it ([why](../README.md#7-what-the-server-run-showed)) |
| [`FILE-SRVR-1/`](FILE-SRVR-1/) | `Enable-VmTpm-20261030-162329` | FILE-SRVR-1 run, vTPM check on the host GTR-PRO | `GTR-PRO\Lorenzo`, elevated | PASSED; the vTPM was already on, nothing changed |
| [`FILE-SRVR-1/`](FILE-SRVR-1/) | `Enable-BitLockerOsDrive-20261030-162423` | FILE-SRVR-1 run, `-WhatIf` | SYSTEM (`SKYNET\FILE-SRVR-1$`), one-time scheduled task | PASSED |
| [`FILE-SRVR-1/`](FILE-SRVR-1/) | `Enable-BitLockerOsDrive-20261030-162429` | FILE-SRVR-1 run, turn BitLocker on | the same | PASSED with 1 warning: recovery password "not in AD yet", as on PDQ-SRVR; AD had it (event 784, AD object `{76C26316-…}`) |

Two lines in the DC25-1 transcripts look like failures but are expected and handled by the script:

- `TerminatingError(Get-ADDomain): "Could not load file or assembly 'System.ServiceModel.NetFramingBase' …"`: in a PowerShell 7 remoting session the `ActiveDirectory` module cannot load natively. The script catches this and loads it through Windows PowerShell compatibility, as the *Modules* row says.
- `TerminatingError(Get-GPRegistryValue): … "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Policies\Microsoft\FVE" … not found`: the script reads both BitLocker policy keys of the GPO. The servers GPO has no values under the SYSTEM key (no deny-write values), so that key does not exist.
