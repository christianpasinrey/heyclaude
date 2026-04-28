# SessionStart hook: registers the session in voice-state.json (assigning a
# random name, capturing terminal_pid), launches the TTS watcher in the
# background, and ensures the STT daemon is running (one instance per user,
# elevated so it can SendInput into elevated Claude windows too).

$ErrorActionPreference = 'SilentlyContinue'

$payload = $null
try {
    $stdin = [Console]::In.ReadToEnd()
    if ($stdin) { $payload = $stdin | ConvertFrom-Json }
} catch {}

if (-not $payload -or -not $payload.transcript_path -or -not $payload.session_id) {
    exit 0
}

$sessionId      = [string]$payload.session_id
$transcriptPath = [string]$payload.transcript_path

$appHome    = Join-Path $env:USERPROFILE '.claude-voice'
$scriptsDir = Join-Path $appHome 'scripts'
$pyDir      = Join-Path $appHome 'voice_input'
$venvPy     = Join-Path $appHome 'venv\Scripts\pythonw.exe'
$lockFile   = Join-Path $appHome 'voice-input.lock'

# 1. Register session and play greeting (synchronous so name+pid land before
#    the TTS watcher reads state).
& (Join-Path $scriptsDir 'session-init.ps1') `
    -SessionId $sessionId `
    -TranscriptPath $transcriptPath | Out-Null

# 2. Launch TTS watcher (one per session, hidden, detached).
Start-Process -WindowStyle Hidden -FilePath powershell.exe -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass',
    '-File', (Join-Path $scriptsDir 'voice-watcher.ps1'),
    '-TranscriptPath', $transcriptPath,
    '-SessionId', $sessionId
) | Out-Null

# 3. Ensure STT daemon is running (single instance, shared across sessions).
$alreadyRunning = $false
if (Test-Path $lockFile) {
    $oldPid = Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($oldPid -match '^\d+$') {
        $proc = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
        if ($proc) { $alreadyRunning = $true }
    }
}
if (-not $alreadyRunning -and (Test-Path -LiteralPath $venvPy)) {
    # Run elevated so we can SendInput into elevated Claude Code instances.
    # UIPI blocks keystroke injection from a non-elevated process to an
    # elevated window. The first launch shows a UAC prompt; subsequent
    # sessions reuse the running daemon.
    $proc = Start-Process -WindowStyle Hidden -Verb RunAs -PassThru `
        -FilePath $venvPy `
        -ArgumentList @('-m', 'voice_input') `
        -WorkingDirectory $appHome
    if ($proc) {
        $proc.Id | Out-File -FilePath $lockFile -Encoding ASCII -Force
    }
}
