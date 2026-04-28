# Voice watcher: tail-follows the active transcript JSONL and speaks each new
# assistant text message as soon as it lands, using Piper TTS.
#
# Args:
#   -TranscriptPath  Absolute path to the .jsonl transcript for this session
#   -SessionId       Session UUID (used in lock/wav paths)

param(
    [Parameter(Mandatory = $true)] [string] $TranscriptPath,
    [string] $SessionId = ([guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'SilentlyContinue'

$appHome    = Join-Path $env:USERPROFILE '.claude-voice'
$piperExe   = Join-Path $appHome 'piper\piper.exe'
$voiceModel = Join-Path $appHome 'piper\voices\es_ES-davefx-medium.onnx'
$ttsFlag    = Join-Path $appHome 'tts-active.flag'
$logFile    = Join-Path $env:TEMP "claude-voice-$SessionId.log"
$wavTmp     = Join-Path $env:TEMP "claude-voice-$SessionId.wav"

function Write-Log($msg) {
    "$([datetime]::Now.ToString('HH:mm:ss')) $msg" | Out-File -FilePath $logFile -Append -Encoding UTF8
}

function Strip-Markdown($text) {
    $t = $text
    $t = $t -replace '(?s)```.*?```', ' '
    $t = $t -replace '`([^`]+)`', '$1'
    $t = $t -replace 'https?://\S+', ' '
    $t = $t -replace '[A-Za-z]:\\[^\s"''<>|]+', ' '
    $t = $t -replace '(?<!\w)/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+', ' '
    $t = $t -replace '~/[A-Za-z0-9_./-]+', ' '
    $t = $t -replace '\*\*([^*]+)\*\*', '$1'
    $t = $t -replace '\*([^*]+)\*', '$1'
    $t = $t -replace '~~([^~]+)~~', '$1'
    $t = $t -replace '!\[([^\]]*)\]\([^\)]+\)', '$1'
    $t = $t -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
    $t = $t -replace '(?m)^#{1,6}\s*', ''
    $t = $t -replace '(?m)^>\s*', ''
    $t = $t -replace '(?m)^[-*+]\s+', ''
    $t = $t -replace '(?m)^\d+\.\s+', ''
    $t = $t -replace '\b[A-Za-z0-9_-]+\.[A-Za-z]{2,5}\b', ' '
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

function Speak-Text($text) {
    if (-not $text) { return }
    if ($text.Length -gt 1500) {
        $text = $text.Substring(0, 1500) + '. Respuesta truncada.'
    }
    if (-not (Test-Path -LiteralPath $piperExe)) {
        Write-Log "piper missing: $piperExe"
        return
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $piperExe
        $psi.Arguments = "--model `"$voiceModel`" --output_file `"$wavTmp`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $bytes = $utf8.GetBytes($text)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.BaseStream.Close()
        $proc.WaitForExit()
        if (Test-Path -LiteralPath $wavTmp) {
            New-Item -ItemType File -Path $ttsFlag -Force | Out-Null
            try {
                $player = New-Object System.Media.SoundPlayer $wavTmp
                $player.PlaySync()
                $player.Dispose()
            } finally {
                Remove-Item -LiteralPath $wavTmp -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $ttsFlag -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log "speak error: $_"
        Remove-Item -LiteralPath $ttsFlag -ErrorAction SilentlyContinue
    }
}

# SessionStart fires before Claude Code creates the JSONL. Wait up to 60s.
$waited = 0
while (-not (Test-Path -LiteralPath $TranscriptPath)) {
    if ($waited -ge 60) {
        Write-Log "transcript still not found after 60s: $TranscriptPath"
        exit 1
    }
    Start-Sleep -Seconds 1
    $waited++
}

Write-Log "watcher started for $TranscriptPath (session $SessionId)"

# tail-follow: -Tail 0 starts at end-of-file, only emits new lines.
Get-Content -Wait -Tail 0 -LiteralPath $TranscriptPath -Encoding UTF8 | ForEach-Object {
    $line = $_
    if (-not $line) { return }
    try { $obj = $line | ConvertFrom-Json } catch { return }
    if ($obj.type -ne 'assistant') { return }
    $contents = $obj.message.content
    if (-not $contents) { return }
    $parts = @()
    foreach ($c in $contents) {
        if ($c.type -eq 'text' -and $c.text) { $parts += $c.text }
    }
    if ($parts.Count -eq 0) { return }
    $raw = $parts -join "`n`n"
    $clean = Strip-Markdown $raw
    if (-not $clean) { return }
    Write-Log "speak: $($clean.Substring(0, [Math]::Min(80, $clean.Length)))..."
    Speak-Text $clean
}
