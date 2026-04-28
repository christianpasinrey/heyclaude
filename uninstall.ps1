<#
.SYNOPSIS
    Removes Claude Voice from the current Windows account.

.DESCRIPTION
    - Stops the running daemon (if any).
    - Removes our hook entries from ~/.claude/settings.json.
    - Deletes %USERPROFILE%\.claude-voice (binaries, venv, voice models).
    - Optionally deletes ~/.claude/voice-state.json with -PurgeState.

.PARAMETER PurgeState
    Also delete voice-state.json (otherwise kept so reinstall preserves
    session names).
#>
[CmdletBinding()]
param([switch]$PurgeState)

$ErrorActionPreference = 'Continue'

function Info($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "✓ $m" -ForegroundColor Green }

$appHome    = Join-Path $env:USERPROFILE '.claude-voice'
$claudeHome = Join-Path $env:USERPROFILE '.claude'
$settings   = Join-Path $claudeHome 'settings.json'
$stateFile  = Join-Path $claudeHome 'voice-state.json'
$lockFile   = Join-Path $appHome 'voice-input.lock'
$scriptsDir = Join-Path $appHome 'scripts'

Write-Host ""
Write-Host "== Claude Voice uninstaller ==" -ForegroundColor Cyan
Write-Host ""

# 1. Kill daemon
if (Test-Path -LiteralPath $lockFile) {
    $oldPid = Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPid -match '^\d+$') {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
    }
}
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*voice_input*' -or $_.CommandLine -like '*voice-input.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*voice-watcher.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Ok "Stopped daemon and watchers"

# 2. Strip hooks from settings.json
if (Test-Path -LiteralPath $settings) {
    try {
        $raw = Get-Content -Raw -LiteralPath $settings
        $obj = $raw | ConvertFrom-Json
        if ($obj.hooks) {
            foreach ($evt in @('SessionStart','UserPromptSubmit')) {
                if ($obj.hooks.PSObject.Properties.Match($evt).Count) {
                    $kept = @()
                    foreach ($g in @($obj.hooks.$evt)) {
                        $hooksLeft = @()
                        foreach ($h in @($g.hooks)) {
                            if ($h.command -notlike "*$scriptsDir*") {
                                $hooksLeft += $h
                            }
                        }
                        if ($hooksLeft.Count -gt 0) {
                            $g.hooks = $hooksLeft
                            $kept += $g
                        }
                    }
                    if ($kept.Count -gt 0) {
                        $obj.hooks.$evt = $kept
                    } else {
                        $obj.hooks.PSObject.Properties.Remove($evt)
                    }
                }
            }
            if ($obj.hooks.PSObject.Properties.Count -eq 0) {
                $obj.PSObject.Properties.Remove('hooks')
            }
        }
        $obj | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $settings -Encoding UTF8
        Ok "Removed hooks from settings.json"
    } catch {
        Write-Host "! Could not edit settings.json: $_" -ForegroundColor Yellow
    }
}

# 3. Remove app home
if (Test-Path -LiteralPath $appHome) {
    Remove-Item -Recurse -Force -LiteralPath $appHome -ErrorAction SilentlyContinue
    Ok "Removed .claude-voice"
}

# 4. Optionally purge state
if ($PurgeState -and (Test-Path -LiteralPath $stateFile)) {
    Remove-Item -Force -LiteralPath $stateFile
    Ok "Removed voice-state.json"
} elseif (Test-Path -LiteralPath $stateFile) {
    Info "Kept voice-state.json (use -PurgeState to remove)"
}

Write-Host ""
Write-Host "== Done ==" -ForegroundColor Green
Write-Host ""
