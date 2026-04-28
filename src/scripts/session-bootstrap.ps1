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
# Lock file alone is unreliable: a previous-version daemon may run with a
# different command line, or the lock may be stale. Probe for any python /
# pythonw process whose command line invokes voice_input or the legacy
# voice-input.py script.
$alreadyRunning = $false
$existing = Get-CimInstance Win32_Process `
    -Filter "Name='pythonw.exe' OR Name='python.exe'" `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and (
            $_.CommandLine -match 'voice_input' -or
            $_.CommandLine -match 'voice-input\.py'
        )
    }
if ($existing) {
    $alreadyRunning = $true
    ($existing | Select-Object -First 1).ProcessId |
        Out-File -FilePath $lockFile -Encoding ASCII -Force
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
