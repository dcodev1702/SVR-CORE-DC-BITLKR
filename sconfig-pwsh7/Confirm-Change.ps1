# Confirmation gate for scripts that change device or domain configuration. Copy next to the script and dot-source it.
# Windows PowerShell 5.1 and PowerShell 7. ASCII-only.
#   Interactive session:      the change is shown in yellow, then 'Continue? [Y/N]'. Y (or Yes) continues; N (or No) stops with
#                             nothing changed. Any other answer is asked again (3 tries, then stop).
#   -NoConfirm:               no prompt (GPO startup scripts, MECM, scheduled tasks); the change is still shown and transcribed.
#   Non-interactive session:  without -NoConfirm the script stops before changing anything - it never waits for an answer.

# True when a person can answer Read-Host: an interactive desktop session, not started with -NonInteractive, stdin not redirected
function Test-Interactive {
    if (-not [Environment]::UserInteractive) { return $false }
    if (@([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' }).Count -gt 0) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { }
    return $true
}

function Confirm-Change {
    param(
        # What is about to change, e.g. 'ENFORCE policy X v2026.10.24.1 on PAW01'
        [Parameter(Mandatory)][string]$Action,
        # Extra lines: scope, effect, how to undo
        [string[]]$Detail = @(),
        [switch]$NoConfirm
    )
    Write-Host ''
    Write-Host "WARNING: this changes the configuration - $Action" -ForegroundColor Yellow
    foreach ($Line in $Detail) { if ($Line) { Write-Host "  $Line" -ForegroundColor Yellow } }
    if ($NoConfirm) { Write-Host '  -NoConfirm: continuing without a prompt.' -ForegroundColor Yellow; return }
    if (-not (Test-Interactive)) {
        throw 'STOP: this change needs a Y/N confirmation, but the session is non-interactive. Nothing was changed. Run the script in an interactive console, or add -NoConfirm for automation.'
    }
    for ($Try = 1; $Try -le 3; $Try++) {
        $Answer = "$(Read-Host 'Continue? [Y/N]')".Trim()
        if ($Answer -match '^(y|yes)$') { Write-Host '  Confirmed.' -ForegroundColor Yellow; return }
        if ($Answer -match '^(n|no)$') { break }
        Write-Host '  Please answer Y or N.' -ForegroundColor Yellow
    }
    throw 'STOP: not confirmed - nothing was changed.'
}
