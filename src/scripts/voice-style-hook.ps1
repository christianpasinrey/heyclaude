# UserPromptSubmit hook: when the current session is registered as a voice
# session, inject a system reminder so Claude tailors its response for TTS
# playback (conversational, no paths, no markdown structure unless needed).

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

try {
    $stdin = [Console]::In.ReadToEnd()
    if (-not $stdin) { exit 0 }
    $payload = $stdin | ConvertFrom-Json
} catch { exit 0 }

$sid = [string]$payload.session_id
if (-not $sid) { exit 0 }

$stateFile = Join-Path $env:USERPROFILE '.claude\voice-state.json'
if (-not (Test-Path -LiteralPath $stateFile)) { exit 0 }
$state = Get-Content -Raw -LiteralPath $stateFile -ErrorAction SilentlyContinue | ConvertFrom-Json
if (-not $state) { exit 0 }
$me = $state.sessions | Where-Object { $_.id -eq $sid }
if (-not $me) { exit 0 }

$ctx = @"
VOICE MODE ACTIVE — your reply will be played aloud via TTS as well as shown on screen. Adapt the style:
- Conversational, connected sentences. NO long bullet lists, NO tables, NO code blocks unless strictly needed.
- DO NOT speak absolute paths or technical filenames in the main flow — describe instead ("your config folder" rather than the literal path). If a path is essential, put it inside a fenced code block: TTS will skip it but it will still be visible on screen.
- DO NOT echo the command before running it. Narrate the result in natural language.
- Short sentences (max 20-25 words) separated by periods. Avoid nested clauses.
- Closing summaries: 1-2 sentences max.
- Your name in this session is "$($me.name)". The user will address you by that name. If they call another name, assume they're addressing a different session and DO NOT respond.

This guidance does NOT replace the user's global rules; it complements them for audio.
"@

@{
    hookSpecificOutput = @{
        hookEventName     = 'UserPromptSubmit'
        additionalContext = $ctx
    }
} | ConvertTo-Json -Depth 4
