# Assigns a name to a Claude Code session, registers it in voice-state.json,
# and speaks a greeting via Piper.
#
# Args:
#   -SessionId       Claude session UUID
#   -TranscriptPath  Absolute path to the .jsonl transcript

param(
    [Parameter(Mandatory = $true)] [string] $SessionId,
    [Parameter(Mandatory = $true)] [string] $TranscriptPath
)

$ErrorActionPreference = 'SilentlyContinue'

$claudeHome = Join-Path $env:USERPROFILE '.claude'
$appHome    = Join-Path $env:USERPROFILE '.claude-voice'
$stateFile  = Join-Path $claudeHome 'voice-state.json'
$piperExe   = Join-Path $appHome 'piper\piper.exe'
$voiceModel = Join-Path $appHome 'piper\voices\es_ES-davefx-medium.onnx'
$ttsFlag    = Join-Path $appHome 'tts-active.flag'

# Walk up the process tree to capture:
#   $ClaudePid    -> claude.exe / node.exe (the agent process)
#   $TerminalPid  -> first ancestor with a real Win32 main window
$ClaudePid = 0
$TerminalPid = 0
$cur = $PID
for ($i = 0; $i -lt 14 -and $cur; $i++) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
    if (-not $proc) { break }
    if ($ClaudePid -le 0 -and $proc.Name -match '^(claude|node)\.exe$') {
        $ClaudePid = $proc.ProcessId
    }
    $procObj = Get-Process -Id $cur -ErrorAction SilentlyContinue
    if ($procObj -and $procObj.MainWindowHandle -ne 0) {
        $TerminalPid = $cur
        break
    }
    $cur = $proc.ParentProcessId
}

# Load state, dedup by session id. Always refresh PIDs/transcript on call.
if (-not (Test-Path -LiteralPath $stateFile)) {
    @{ sessions = @(); names_pool = @(
        'Michael','Peter','James','Oliver','Lucas','Liam',
        'Sarah','Emma','Sophie','Charlotte','Ava','Olivia'
    )} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding UTF8
}
$state = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
if (-not $state.names_pool) {
    $state | Add-Member -NotePropertyName names_pool -NotePropertyValue @(
        'Michael','Peter','James','Oliver','Lucas','Liam',
        'Sarah','Emma','Sophie','Charlotte','Ava','Olivia'
    ) -Force
}
$existing = $state.sessions | Where-Object { $_.id -eq $SessionId }
if ($existing) {
    $name = $existing.name
    $existing.transcript_path = $TranscriptPath
    $existing | Add-Member -NotePropertyName claude_pid   -NotePropertyValue $ClaudePid   -Force
    $existing | Add-Member -NotePropertyName terminal_pid -NotePropertyValue $TerminalPid -Force
} else {
    $usedNames = @($state.sessions | ForEach-Object { $_.name })
    $available = @($state.names_pool | Where-Object { $usedNames -notcontains $_ })
    if ($available.Count -eq 0) { $available = $state.names_pool }
    $name = $available | Get-Random
    $newSession = [pscustomobject]@{
        id              = $SessionId
        name            = $name
        transcript_path = $TranscriptPath
        claude_pid      = $ClaudePid
        terminal_pid    = $TerminalPid
        registered_at   = (Get-Date).ToString('o')
    }
    $state.sessions = @($state.sessions) + $newSession
}
$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8

# Greeting via Piper, unless Piper isn't installed (silent skip).
if ((Test-Path -LiteralPath $piperExe) -and (Test-Path -LiteralPath $voiceModel)) {
    $wavTmp = Join-Path $env:TEMP "claude-greet-$SessionId.wav"
    $greeting = "Hola, soy $name."
    try {
        # UTF-8 stdin to preserve accents.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $piperExe
        $psi.Arguments = "--model `"$voiceModel`" --output_file `"$wavTmp`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $bytes = $utf8.GetBytes($greeting)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Close()
        $proc.WaitForExit()
        if (Test-Path -LiteralPath $wavTmp) {
            New-Item -ItemType File -Path $ttsFlag -Force | Out-Null
            $player = New-Object System.Media.SoundPlayer $wavTmp
            $player.PlaySync()
            $player.Dispose()
            Remove-Item -LiteralPath $wavTmp -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ttsFlag -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

Write-Output $name
