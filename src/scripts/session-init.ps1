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
$piperExe   = Join-Path $appHome 'piper\piper\piper.exe'
$voicesDir  = Join-Path $appHome 'piper\voices'
$ttsFlag    = Join-Path $appHome 'tts-active.flag'

$DefaultMaleNames = @(
    'Michael','Peter','James','Oliver','Lucas','Liam','Daniel','Henry','William','Benjamin',
    'Alexander','Jacob','Noah','Ethan','Mason','Logan','Aiden','Jackson','Sebastian','Owen',
    'Ryan','David','Adrian','Tomas','Diego','Pablo','Mateo','Hugo','Marco','Andres',
    'Carlos','Javier','Fernando','Felipe','Nicolas','Joaquin','Ignacio','Vincent','Anton','Maxime',
    'Leo','Theo','Jules','Arthur','Hiroshi','Akira','Kenji','Takeshi','Ravi','Arjun'
)
$DefaultFemaleNames = @(
    'Sarah','Emma','Sophie','Charlotte','Ava','Olivia','Mia','Lucia','Isabella','Amelia',
    'Harper','Evelyn','Abigail','Emily','Sofia','Avery','Ella','Madison','Scarlett','Victoria',
    'Aria','Grace','Chloe','Camila','Penelope','Riley','Layla','Lillian','Nora','Zoe',
    'Mila','Aurora','Hazel','Violet','Aubrey','Hannah','Lily','Addison','Eleanor','Stella',
    'Natalie','Carmen','Marta','Elena','Yuki','Sakura','Aisha','Priya','Anya','Beatrice'
)
$DefaultVoiceMale   = 'es_ES-davefx-medium'
$DefaultVoiceFemale = 'es_ES-mls_10246-low'

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
    @{
        sessions     = @()
        male_names   = $DefaultMaleNames
        female_names = $DefaultFemaleNames
        voice_male   = $DefaultVoiceMale
        voice_female = $DefaultVoiceFemale
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding UTF8
}
$state = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
foreach ($pair in @(
    @{ Name='male_names';   Value=$DefaultMaleNames },
    @{ Name='female_names'; Value=$DefaultFemaleNames },
    @{ Name='voice_male';   Value=$DefaultVoiceMale },
    @{ Name='voice_female'; Value=$DefaultVoiceFemale }
)) {
    if (-not $state.PSObject.Properties.Match($pair.Name).Count) {
        $state | Add-Member -NotePropertyName $pair.Name -NotePropertyValue $pair.Value -Force
    }
}

$existing = $state.sessions | Where-Object { $_.id -eq $SessionId }
if ($existing) {
    $name = $existing.name
    $gender = if ($existing.PSObject.Properties.Match('gender').Count) { $existing.gender } `
              elseif ($state.female_names -contains $name) { 'F' } else { 'M' }
    $existing.transcript_path = $TranscriptPath
    $existing | Add-Member -NotePropertyName claude_pid   -NotePropertyValue $ClaudePid   -Force
    $existing | Add-Member -NotePropertyName terminal_pid -NotePropertyValue $TerminalPid -Force
    $existing | Add-Member -NotePropertyName gender       -NotePropertyValue $gender      -Force
} else {
    $usedNames = @($state.sessions | ForEach-Object { $_.name })
    # 50/50 male/female; if one pool is exhausted, fall back to the other.
    $maleAvail   = @($state.male_names   | Where-Object { $usedNames -notcontains $_ })
    $femaleAvail = @($state.female_names | Where-Object { $usedNames -notcontains $_ })
    if ($maleAvail.Count -eq 0 -and $femaleAvail.Count -eq 0) {
        $maleAvail = @($state.male_names); $femaleAvail = @($state.female_names)
    }
    $pickFemale = if ($femaleAvail.Count -eq 0) { $false }
                  elseif ($maleAvail.Count -eq 0) { $true }
                  else { (Get-Random -Minimum 0 -Maximum 2) -eq 1 }
    if ($pickFemale) { $name = $femaleAvail | Get-Random; $gender = 'F' }
    else             { $name = $maleAvail   | Get-Random; $gender = 'M' }

    $newSession = [pscustomobject]@{
        id              = $SessionId
        name            = $name
        gender          = $gender
        transcript_path = $TranscriptPath
        claude_pid      = $ClaudePid
        terminal_pid    = $TerminalPid
        registered_at   = (Get-Date).ToString('o')
    }
    $state.sessions = @($state.sessions) + $newSession
}
$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8

$voiceSlug  = if ($gender -eq 'F') { $state.voice_female } else { $state.voice_male }
$voiceModel = Join-Path $voicesDir "$voiceSlug.onnx"

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
