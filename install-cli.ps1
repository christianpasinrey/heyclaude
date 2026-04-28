<#
.SYNOPSIS
    Installs Claude Voice on Windows.

.DESCRIPTION
    - Verifies Python 3.10+ is available (uses the py launcher when found).
    - Creates a venv under %USERPROFILE%\.claude-voice\venv and installs deps.
    - Downloads Piper TTS and the es_ES-davefx-medium voice.
    - Copies the voice_input package and PowerShell hook scripts into place.
    - Merges the SessionStart and UserPromptSubmit hooks into Claude Code's
      ~/.claude/settings.json without overwriting existing entries.

.PARAMETER PiperVersion
    Piper release tag to download. Default: 2023.11.14-2.

.PARAMETER Voice
    Piper voice slug. Default: es_ES-davefx-medium.

.PARAMETER NoStyleHook
    Skip the UserPromptSubmit "voice mode" style hook (just install TTS+STT).
#>
[CmdletBinding()]
param(
    [string]$PiperVersion = '2023.11.14-2',
    [string]$Voice = 'es_ES-davefx-medium',
    [switch]$NoStyleHook
)

$ErrorActionPreference = 'Stop'

function Info($m)  { Write-Host "  $m" -ForegroundColor Cyan }
function Ok($m)    { Write-Host "✓ $m" -ForegroundColor Green }
function Warn($m)  { Write-Host "! $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "✗ $m" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "== Claude Voice installer ==" -ForegroundColor Cyan
Write-Host ""

# ---- 1. Resolve Python ------------------------------------------------------
$python = $null
foreach ($cmd in @('py -3', 'python3', 'python')) {
    try {
        $parts = $cmd -split ' '
        $exe = $parts[0]
        $argsList = if ($parts.Length -gt 1) { @($parts[1..($parts.Length - 1)]) + @('-c', 'import sys;print(sys.version_info[:3])') } else { @('-c', 'import sys;print(sys.version_info[:3])') }
        $out = & $exe @argsList 2>$null
        if ($LASTEXITCODE -eq 0 -and $out -match '\(\s*(\d+),\s*(\d+)') {
            $major = [int]$matches[1]; $minor = [int]$matches[2]
            if ($major -ge 3 -and $minor -ge 10) {
                $python = $cmd
                Ok "Found Python: $cmd ($out)"
                break
            }
        }
    } catch {}
}
if (-not $python) {
    Fail "Python 3.10+ not found. Install from python.org or 'winget install Python.Python.3.12' and re-run."
}

# ---- 2. Create app dirs -----------------------------------------------------
$appHome    = Join-Path $env:USERPROFILE '.claude-voice'
$claudeHome = Join-Path $env:USERPROFILE '.claude'
$venv       = Join-Path $appHome 'venv'
$piperDir   = Join-Path $appHome 'piper'
$voicesDir  = Join-Path $piperDir 'voices'
$pyTarget   = Join-Path $appHome 'voice_input'
$scriptsDir = Join-Path $appHome 'scripts'
$stateFile  = Join-Path $claudeHome 'voice-state.json'
$settings   = Join-Path $claudeHome 'settings.json'

New-Item -ItemType Directory -Force -Path $appHome, $piperDir, $voicesDir, $scriptsDir, $claudeHome | Out-Null
Ok "Directories ready"

# ---- 3. Create venv ---------------------------------------------------------
if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\pythonw.exe'))) {
    Info "Creating virtual environment…"
    $pyParts = $python -split ' '
    & $pyParts[0] @($pyParts[1..($pyParts.Length-1)] + @('-m','venv', $venv)) | Out-Null
    if (-not $?) { Fail "venv creation failed" }
} else {
    Info "venv exists, reusing"
}
$venvPip = Join-Path $venv 'Scripts\pip.exe'
$venvPy  = Join-Path $venv 'Scripts\python.exe'
$venvPyw = Join-Path $venv 'Scripts\pythonw.exe'

# ---- 4. Install Python deps -------------------------------------------------
Info "Upgrading pip…"
& $venvPy -m pip install --upgrade pip --quiet
$reqFile = Join-Path $PSScriptRoot 'requirements.txt'
if (-not (Test-Path $reqFile)) { Fail "requirements.txt not found next to install.ps1" }
Info "Installing Python deps (this takes a few minutes the first time)…"
& $venvPip install -r $reqFile
if ($LASTEXITCODE -ne 0) { Fail "pip install failed" }
Ok "Python deps installed"

# ---- 5. Copy voice_input package and scripts -------------------------------
$srcPy      = Join-Path $PSScriptRoot 'src\voice_input'
$srcScripts = Join-Path $PSScriptRoot 'src\scripts'
if (-not (Test-Path $srcPy))      { Fail "Missing src\voice_input next to install.ps1" }
if (-not (Test-Path $srcScripts)) { Fail "Missing src\scripts next to install.ps1" }

if (Test-Path $pyTarget) { Remove-Item -Recurse -Force $pyTarget }
Copy-Item -Recurse -Force $srcPy $pyTarget
Copy-Item -Force (Join-Path $srcScripts '*.ps1') $scriptsDir
Ok "Package + scripts copied to .claude-voice"

# ---- 6. Download Piper ------------------------------------------------------
$piperExe = Join-Path $piperDir 'piper\piper.exe'
if (-not (Test-Path -LiteralPath $piperExe)) {
    $url = "https://github.com/rhasspy/piper/releases/download/$PiperVersion/piper_windows_amd64.zip"
    $zip = Join-Path $env:TEMP 'piper_windows_amd64.zip'
    Info "Downloading Piper $PiperVersion…"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Info "Extracting Piper…"
    Expand-Archive -Path $zip -DestinationPath $piperDir -Force
    Remove-Item $zip -Force
    Ok "Piper installed"
} else {
    Info "Piper already present"
}

# ---- 7. Download voice model -----------------------------------------------
$onnx = Join-Path $voicesDir "$Voice.onnx"
$json = "$onnx.json"
if (-not (Test-Path -LiteralPath $onnx) -or -not (Test-Path -LiteralPath $json)) {
    # Voice slug parses as <lang>_<region>-<name>-<quality>
    if ($Voice -notmatch '^([a-z]{2})_([A-Z]{2})-([^-]+)-([a-z_]+)$') {
        Fail "Voice slug must look like 'es_ES-davefx-medium'"
    }
    $lang = $matches[1]; $region = $matches[2]; $vname = $matches[3]; $quality = $matches[4]
    $base = "https://huggingface.co/rhasspy/piper-voices/resolve/main/$lang/${lang}_$region/$vname/$quality"
    Info "Downloading voice $Voice…"
    Invoke-WebRequest -Uri "$base/$Voice.onnx"      -OutFile $onnx -UseBasicParsing
    Invoke-WebRequest -Uri "$base/$Voice.onnx.json" -OutFile $json -UseBasicParsing
    Ok "Voice $Voice downloaded"
} else {
    Info "Voice already present"
}

# ---- 8. Initial state file --------------------------------------------------
if (-not (Test-Path -LiteralPath $stateFile)) {
    @{
        sessions   = @()
        names_pool = @(
            'Michael','Peter','James','Oliver','Lucas','Liam',
            'Sarah','Emma','Sophie','Charlotte','Ava','Olivia'
        )
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding UTF8
    Ok "Created voice-state.json"
} else {
    Info "voice-state.json already exists"
}

# ---- 9. Merge hooks into Claude Code settings.json --------------------------
function Merge-Hooks([object]$root) {
    if (-not $root.PSObject.Properties.Match('hooks').Count) {
        $root | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force
    }
    $hooks = $root.hooks

    $bootstrapCmd  = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
                     (Join-Path $scriptsDir 'session-bootstrap.ps1') + '"')
    $styleHookCmd  = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
                     (Join-Path $scriptsDir 'voice-style-hook.ps1') + '"')

    function Ensure-HookSlot($eventName, $command, [bool]$async) {
        if (-not $hooks.PSObject.Properties.Match($eventName).Count) {
            $hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @() -Force
        }
        $existing = @($hooks.$eventName)
        # Skip if our command is already wired up.
        foreach ($g in $existing) {
            foreach ($h in @($g.hooks)) {
                if ($h.command -eq $command) { return }
            }
        }
        $newHook = @{ type = 'command'; command = $command }
        if ($async) { $newHook.async = $true }
        $existing += @{ hooks = @($newHook) }
        $hooks.$eventName = $existing
    }

    Ensure-HookSlot -eventName 'SessionStart' -command $bootstrapCmd -async $true
    if (-not $NoStyleHook) {
        Ensure-HookSlot -eventName 'UserPromptSubmit' -command $styleHookCmd -async $false
    }
}

if (Test-Path -LiteralPath $settings) {
    Info "Merging hooks into existing settings.json…"
    $raw = Get-Content -Raw -LiteralPath $settings
    $obj = $raw | ConvertFrom-Json
} else {
    Info "Creating settings.json with hooks…"
    $obj = New-Object PSObject
}
Merge-Hooks $obj
$obj | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $settings -Encoding UTF8
Ok "Hooks installed in settings.json"

# ---- 10. Done ---------------------------------------------------------------
Write-Host ""
Write-Host "== Done ==" -ForegroundColor Green
Write-Host ""
Write-Host "Open a NEW Claude Code session. You should hear a greeting and the"
Write-Host "Claude Voice dashboard window will appear (UAC prompt the first time —"
Write-Host "it asks for elevation so the daemon can inject text into other"
Write-Host "elevated Claude Code windows). Hold F12 to talk, or just say"
Write-Host "'Claude, ...'."
Write-Host ""
