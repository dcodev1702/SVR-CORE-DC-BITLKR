# sconfig-pwsh7 — SConfig option 15 opens PowerShell 7 (Windows Server Core 2025)

> [!NOTE]
> On Server Core, SConfig option 15 (*Exit to command line (PowerShell)*) drops you into **Windows PowerShell 5.1**. `Set-PwshDefaultShell.ps1` makes it drop into **PowerShell 7** instead. SConfig still opens at sign-in, and `exit` in PowerShell 7 brings SConfig back, just as `exit` does by default. The script writes one file and changes nothing else (it only adds PowerShell 7 to `PATH` if it is missing).

**Verified 2026-10-28** on DC25-1 (Windows Server 2025 Datacenter, Server Core, build 26100.33650, PowerShell 7.6.9 MSI): console sign-in → option 15 → `$PSVersionTable` shows `PSEdition Core`, `PSVersion 7.6.9`.

| File | Purpose |
|---|---|
| `Set-PwshDefaultShell.ps1` | Checks the server, writes the hook, verifies it, logs everything. `-Revert` removes it. |
| `Confirm-Change.ps1` | Yellow `Continue? [Y/N]` gate used by the script. Must sit in the same folder. |

---

## 1. How it works

The Server Core sign-in shell is started by `servercoreshell.exe` from `HKLM\SOFTWARE\Microsoft\ServerCore\Shell Launcher` (`shell = servercoreshelllaunch.bat`). That batch file runs:

```
powershell.exe -noExit -Command "Invoke-SConfigLogon"
```

SConfig option 15 returns to that Windows PowerShell session (`-noExit`). The script writes the Windows PowerShell **all-users profile**, `C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1`, which loads in that session before SConfig opens:

```powershell
# Managed by Set-PwshDefaultShell.ps1. Remove it with: Set-PwshDefaultShell.ps1 -Revert
# Server Core sign-in session only (powershell.exe -noExit -Command "Invoke-SConfigLogon"): when SConfig option 15
# returns and the Windows PowerShell prompt would appear, start PowerShell 7 in this window instead. 'exit' in
# PowerShell 7 ends the session, and the Server Core shell launcher starts SConfig again.
# Every other Windows PowerShell session is left alone.
if ([Environment]::CommandLine -match '(?i)\s-noExit\s+-Command\s+"?Invoke-SConfigLogon"?\s*$' -and (Test-Path -LiteralPath 'C:\Program Files\PowerShell\7\pwsh.exe')) {
    function global:prompt {
        try {
            $Psi = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList 'C:\Program Files\PowerShell\7\pwsh.exe', '-NoLogo'
            $Psi.UseShellExecute = $false
            [System.Diagnostics.Process]::Start($Psi).WaitForExit()
        }
        finally { [Environment]::Exit(0) }
    }
}
```

- **Only the sign-in session.** The hook acts only when the command line ends with `-noExit -Command "Invoke-SConfigLogon"`. Every other Windows PowerShell session (scripts, scheduled tasks, `sconfig` typed later) evaluates one `-match` and carries on as before.
- **When.** It replaces `prompt` for that session. The first time the 5.1 prompt would appear (after option 15) it starts PowerShell 7 in the same console window and waits. When PowerShell 7 exits, the 5.1 session exits too, the shell launcher restarts the sign-in shell, and SConfig opens again.
- **Why `Process.Start` and not `&`.** PowerShell collects a `prompt` function's output as the prompt text, so `& pwsh` would pipe PowerShell 7's output into a string and the console would stay blank. While PowerShell 7 runs, the 5.1 host is blocked in `WaitForExit()`; `finally` ends it once PowerShell 7 exits.

---

## 2. Requirements

| Item | Detail |
|---|---|
| **Server** | Windows Server 2025 (build 26100 or later), **Server Core** installation. Member server or domain controller. |
| **PowerShell 7** | `C:\Program Files\PowerShell\7\pwsh.exe` (or pass `-PwshPath`), signed by Microsoft. The MSI is Microsoft's recommended package for Windows Server and adds itself to `PATH`: [Install PowerShell 7 on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows). |
| **Execution policy** | Windows PowerShell 5.1 effective policy `RemoteSigned` (the Windows Server default), `Unrestricted` or `Bypass`. Under `AllSigned` or `Restricted` the unsigned profile would not run, so the script stops. |
| **Session** | Elevated, on the server itself (console, RDP, `Enter-PSSession` or `Invoke-Command`). Windows PowerShell 5.1 or PowerShell 7. |

---

## 3. Run it

On the server, elevated, from this folder:

```powershell
.\Set-PwshDefaultShell.ps1 -WhatIf      # plan only - nothing changes
.\Set-PwshDefaultShell.ps1              # shows the change in yellow, then asks Continue? [Y/N]
.\Set-PwshDefaultShell.ps1 -NoConfirm   # no prompt, for automation
```

A non-interactive session without `-NoConfirm` stops before changing anything.

From a PAW, with the repository as the current folder:

```powershell
$s   = New-PSSession -ComputerName <server>
$dir = Invoke-Command -Session $s { (New-Item -Path (Join-Path $env:TEMP 'sconfig-pwsh7') -ItemType Directory -Force).FullName }
Copy-Item -Path .\sconfig-pwsh7\*.ps1 -Destination $dir -ToSession $s
Invoke-Command -Session $s { & (Join-Path $using:dir 'Set-PwshDefaultShell.ps1') -NoConfirm }
Remove-PSSession $s
```

**Check:** sign out and back in (console or RDP), choose **15**, run `$PSVersionTable`. `PSEdition` is `Core`. Sessions that were signed in before the change keep the old behavior until they sign out.

| Parameter | Effect |
|---|---|
| `-PwshPath <path>` | `pwsh.exe` to start. Default: `%ProgramFiles%\PowerShell\7\pwsh.exe`. |
| `-LogDir <folder>` | Transcript, results and backups. Default: `%SystemDrive%\Logs`. |
| `-Revert` | Back up and delete the profile this script wrote. `PATH` is left as it is. |
| `-NoConfirm` | Skip the Y/N prompt (the change is still printed and logged). |
| `-WhatIf` | Show the plan without changing anything. |

---

## 4. What the script checks and changes

Any failed check stops the script with `STOP: <what is wrong>. <what to do>. Nothing was changed.` and exit code 1.

| Check | Stops when |
|---|---|
| Elevation | The session is not elevated. |
| Operating system | Client OS, not Server Core, or older than build 26100. |
| `pwsh.exe` | Missing; Authenticode signature not *Valid* by Microsoft Corporation; writable by Everyone, Authenticated Users, Users or Interactive (file or folder); does not report version 7 or later. |
| Execution policy | Windows PowerShell 5.1 would not run an unsigned profile. |
| Profile folder | Writable by Everyone, Authenticated Users, Users or Interactive. |
| Existing `profile.ps1` | It exists and was not written by this script (no `# Managed by Set-PwshDefaultShell.ps1` first line): it is left alone. |

**Changes**, after the Y/N gate:

- Writes `profile.ps1` (or replaces an older version this script wrote, after a backup), re-reads it to verify the content, records its SHA-256, and checks its permissions.
- Appends `C:\Program Files\PowerShell\7\` to the machine `PATH` only if it is missing, after exporting the `Environment` key. `REG_EXPAND_SZ` stays `REG_EXPAND_SZ`.
- Re-running it when everything is in place changes nothing and does not prompt.

**Evidence** in the log folder: `Set-PwshDefaultShell-<time>.log` (transcript), `.csv` (PASS / FAIL rows), and backups (`-profile.ps1.bak`, `-Environment.reg`).

---

## 5. Undo

```powershell
.\Set-PwshDefaultShell.ps1 -Revert
```

Or delete `C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1`. Option 15 returns to Windows PowerShell 5.1 from the next sign-in.

---

## 6. Notes

- **`sconfig` from PowerShell 7** resolves to `C:\Windows\System32\sconfig.cmd`, which runs SConfig in Windows PowerShell. Option 15 there returns to the same PowerShell 7 window.
- **SConfig auto-launch off** (`Set-SConfig -AutoLaunch $false`): `Invoke-SConfigLogon` returns at once, so sign-in should go straight to PowerShell 7. This follows from SConfig's code and was not tested.
- **Ctrl+C in PowerShell 7** should not disturb the waiting Windows PowerShell session, which is blocked in `WaitForExit()`. Designed for, not tested.
- **PowerShell 7 missing:** the guard's `Test-Path` fails and option 15 returns to Windows PowerShell 5.1, as before.
- **Remoting** does not load profiles, so `Enter-PSSession` is unaffected. For a PowerShell 7 remote session use `Enter-PSSession <server> -ConfigurationName PowerShell.7` (the endpoint the MSI registers).

### Why not change the sign-in shell itself?

`HKLM\SOFTWARE\Microsoft\ServerCore\Shell Launcher` and `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\AlternateShells\AvailableShells` are owned by `NT SERVICE\TrustedInstaller`; Administrators and SYSTEM can only read them. Changing the shell there means taking ownership of OS-protected keys, which servicing may reset. The all-users profile folder is writable by Administrators and survives updates.

---

## Testing

- **Unit tests with mocks** (42 cases, in Windows PowerShell 5.1 and PowerShell 7.6.9): every confirmation path (Y, Yes, N, three invalid answers, non-interactive, `-NoConfirm`, `-WhatIf`), every STOP check, `PATH` handling, `-Revert`, verification failures, and a guard that refuses to run real commands under the harness. Also the generated profile byte-for-byte, its parse, and the guard pattern against the sign-in command line and six command lines it must ignore.
- **On DC25-1:** runs that must not change anything (non-interactive without `-NoConfirm`, `-WhatIf` from Windows PowerShell 5.1 and PowerShell 7) left the server unchanged; the hook was exercised in a real `powershell.exe -noExit`; the real run passed; a second run reported *already as wanted*; a console sign-in and option 15 opened PowerShell 7.6.9.

## References

- [Install PowerShell 7 on Windows](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows) (Microsoft Learn)
- [Configure Server Core with SConfig](https://learn.microsoft.com/windows-server/administration/server-core/server-core-sconfig) (Microsoft Learn)
- [about_Profiles](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_profiles) (Microsoft Learn)
