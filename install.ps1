<#
.SYNOPSIS
    HeyClaude installer — graphical (WPF) wrapper that runs the same steps as
    install-cli.ps1 with live progress, a log pane and a single Install button.

.PARAMETER Cli
    Skip the GUI and run install-cli.ps1 directly (useful for CI or
    scripted installs).

.PARAMETER PiperVersion
    Piper release tag. Default: 2023.11.14-2.

.PARAMETER Voice
    Piper voice slug. Default: es_ES-davefx-medium.

.PARAMETER NoStyleHook
    Don't install the UserPromptSubmit "voice mode" hook.
#>
[CmdletBinding()]
param(
    [switch]$Cli,
    [string]$PiperVersion = '2023.11.14-2',
    [string]$Voice = 'es_ES-davefx-medium',
    [switch]$NoStyleHook
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cliScript = Join-Path $root 'install-cli.ps1'

if ($Cli) {
    & $cliScript -PiperVersion $PiperVersion -Voice $Voice -NoStyleHook:$NoStyleHook
    return
}

# ---- WPF UI ----------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HeyClaude — Installer"
        Width="640" Height="600"
        WindowStartupLocation="CenterScreen"
        Background="#0f1115"
        FontFamily="Segoe UI" Foreground="#e8eaf0">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="#0f1115"/>
            <Setter Property="Background" Value="#5aa9ff"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#7ab9ff"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#2a2f3a"/>
                                <Setter Property="Foreground" Value="#666"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <TextBlock Text="HeyClaude" FontSize="28" FontWeight="Bold" Foreground="#5aa9ff"/>
            <TextBlock Text="Installer" FontSize="18" Foreground="#8b93a3" Margin="10,8,0,0"/>
        </StackPanel>

        <TextBlock Grid.Row="1" Margin="0,0,0,16"
                   TextWrapping="Wrap" Foreground="#b8bdcc">
            Voice control for Claude Code on Windows. The installer will set up Piper TTS, faster-whisper, the voice daemon, and the SessionStart hook.
        </TextBlock>

        <Border Grid.Row="2" Background="#161a21" CornerRadius="6" Padding="16,12" Margin="0,0,0,12">
            <ItemsControl x:Name="StepsList">
                <ItemsControl.ItemTemplate>
                    <DataTemplate>
                        <StackPanel Orientation="Horizontal" Margin="0,4">
                            <TextBlock Text="{Binding Icon}" FontSize="14" Width="22" Foreground="{Binding Color}"/>
                            <TextBlock Text="{Binding Label}" FontSize="12" Foreground="#dcdcdc"/>
                        </StackPanel>
                    </DataTemplate>
                </ItemsControl.ItemTemplate>
            </ItemsControl>
        </Border>

        <Border Grid.Row="3" Background="#161a21" CornerRadius="6" Padding="2">
            <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto"
                          HorizontalScrollBarVisibility="Auto">
                <TextBlock x:Name="LogText" FontFamily="Consolas" FontSize="11"
                           Foreground="#b8bdcc" Padding="10" TextWrapping="NoWrap"/>
            </ScrollViewer>
        </Border>

        <ProgressBar Grid.Row="4" x:Name="Progress" Height="6" Margin="0,12,0,0"
                     Background="#1c2230" Foreground="#5aa9ff" BorderThickness="0"
                     Minimum="0" Maximum="100" Value="0"/>

        <Grid Grid.Row="5" Margin="0,16,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="StatusText" Grid.Column="0" VerticalAlignment="Center"
                       Foreground="#8b93a3" Text="Ready."/>
            <Button x:Name="InstallButton" Grid.Column="1" Content="Install"
                    Margin="0,0,8,0"/>
            <Button x:Name="CloseButton" Grid.Column="2" Content="Close"
                    Background="#2a2f3a" Foreground="#dcdcdc"/>
        </Grid>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$stepsList    = $window.FindName('StepsList')
$logText      = $window.FindName('LogText')
$logScroll    = $window.FindName('LogScroll')
$progress     = $window.FindName('Progress')
$statusText   = $window.FindName('StatusText')
$installBtn   = $window.FindName('InstallButton')
$closeBtn     = $window.FindName('CloseButton')

# Step list (observable so the UI updates as we mutate them).
$stepDefs = @(
    @{ Key = 'python';   Label = 'Detect Python 3.10+' },
    @{ Key = 'venv';     Label = 'Create virtual environment' },
    @{ Key = 'pip';      Label = 'Install Python dependencies' },
    @{ Key = 'copy';     Label = 'Copy daemon and hook scripts' },
    @{ Key = 'piper';    Label = "Download Piper $PiperVersion" },
    @{ Key = 'voice';    Label = "Download voice $Voice" },
    @{ Key = 'state';    Label = 'Initialize session state' },
    @{ Key = 'hooks';    Label = 'Wire up Claude Code hooks' }
)
$ICON_TODO = [string][char]0x25CB
$stepsObs = New-Object System.Collections.ObjectModel.ObservableCollection[object]
foreach ($s in $stepDefs) {
    $stepsObs.Add([pscustomobject]@{
        Key = $s.Key; Label = $s.Label; Icon = $ICON_TODO; Color = '#666'
    })
}
$stepsList.ItemsSource = $stepsObs

function Set-Step($key, $icon, $color) {
    $idx = -1
    for ($i = 0; $i -lt $stepsObs.Count; $i++) {
        if ($stepsObs[$i].Key -eq $key) { $idx = $i; break }
    }
    if ($idx -lt 0) { return }
    $current = $stepsObs[$idx]
    $stepsObs[$idx] = [pscustomobject]@{
        Key = $current.Key; Label = $current.Label; Icon = $icon; Color = $color
    }
}

function Append-Log($line) {
    $logText.Text = $logText.Text + $line + "`n"
    $logScroll.ScrollToEnd()
}

function Pump-Ui {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action]{ $frame.Continue = $false }
    ) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Run-Install {
    $installBtn.IsEnabled = $false
    $closeBtn.IsEnabled   = $false
    $progress.Value       = 0
    $statusText.Text      = 'Installing…'
    Append-Log "Starting install at $((Get-Date).ToString('HH:mm:ss'))"
    Pump-Ui

    $total = $stepDefs.Count
    $done = 0

    $script:ICON_RUN  = [string][char]0x25D0
    $script:ICON_OK   = [string][char]0x2713
    $script:ICON_FAIL = [string][char]0x2717
    function Bump($key) {
        Set-Step $key $script:ICON_RUN '#dcdc6e'
        $statusText.Text = "Working on: $((($stepsObs | Where-Object Key -eq $key).Label))"
        Pump-Ui
    }
    function Tick($key, [string]$msg = $null) {
        $script:done++
        Set-Step $key $script:ICON_OK '#4ec9b0'
        $progress.Value = [Math]::Min(100, [int](($script:done / $total) * 100))
        if ($msg) { Append-Log ("  " + $script:ICON_OK + " " + $msg) }
        Pump-Ui
    }
    function Bomb($key, [string]$err) {
        Set-Step $key $script:ICON_FAIL '#f14c4c'
        $statusText.Text = 'Failed.'
        Append-Log ("  " + $script:ICON_FAIL + " " + $err)
        $closeBtn.IsEnabled = $true
        throw $err
    }

    try {
        # 1. Python
        Bump 'python'
        $python = $null
        foreach ($cmd in @('py -3', 'python3', 'python')) {
            try {
                $parts = $cmd -split ' '
                $exe = $parts[0]
                $argsList = if ($parts.Length -gt 1) {
                    @($parts[1..($parts.Length - 1)]) + @('-c', 'import sys;print(sys.version_info[:3])')
                } else { @('-c', 'import sys;print(sys.version_info[:3])') }
                $out = & $exe @argsList 2>$null
                if ($LASTEXITCODE -eq 0 -and $out -match '\(\s*(\d+),\s*(\d+)') {
                    $maj = [int]$matches[1]; $min = [int]$matches[2]
                    if ($maj -ge 3 -and $min -ge 10) {
                        $python = $cmd
                        Tick 'python' "$cmd → $out"
                        break
                    }
                }
            } catch {}
        }
        if (-not $python) {
            Bomb 'python' "Python 3.10+ not found. Install it (e.g. winget install Python.Python.3.12) and re-run."
        }

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

        # 2. venv
        Bump 'venv'
        if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\pythonw.exe'))) {
            $pyParts = $python -split ' '
            & $pyParts[0] @($pyParts[1..($pyParts.Length-1)] + @('-m','venv', $venv)) 2>&1 |
                ForEach-Object { Append-Log "  $_" }
            if ($LASTEXITCODE -ne 0) { Bomb 'venv' "venv creation failed" }
            Tick 'venv' "venv created at .claude-voice\venv"
        } else {
            Tick 'venv' "venv already exists, reusing"
        }
        $venvPip = Join-Path $venv 'Scripts\pip.exe'
        $venvPy  = Join-Path $venv 'Scripts\python.exe'

        # 3. pip
        Bump 'pip'
        Append-Log "  Upgrading pip…"
        & $venvPy -m pip install --upgrade pip --quiet 2>&1 |
            ForEach-Object { Append-Log "  $_" }
        Pump-Ui
        $reqFile = Join-Path $root 'requirements.txt'
        Append-Log "  Installing dependencies (this can take a few minutes)…"
        Pump-Ui
        & $venvPip install -r $reqFile 2>&1 |
            ForEach-Object {
                if ($_ -match 'Collecting|Successfully|Downloading|Installing|Requirement|already') {
                    Append-Log "  $_"
                    Pump-Ui
                }
            }
        if ($LASTEXITCODE -ne 0) { Bomb 'pip' "pip install failed (check log)" }
        Tick 'pip' "Python deps installed"

        # 4. copy
        Bump 'copy'
        $srcPy      = Join-Path $root 'src\voice_input'
        $srcScripts = Join-Path $root 'src\scripts'
        if (-not (Test-Path $srcPy))      { Bomb 'copy' "src\voice_input missing" }
        if (-not (Test-Path $srcScripts)) { Bomb 'copy' "src\scripts missing" }
        if (Test-Path $pyTarget) { Remove-Item -Recurse -Force $pyTarget }
        Copy-Item -Recurse -Force $srcPy $pyTarget
        Copy-Item -Force (Join-Path $srcScripts '*.ps1') $scriptsDir
        Tick 'copy' "Daemon and scripts in place"

        # 5. piper
        Bump 'piper'
        $piperExe = Join-Path $piperDir 'piper\piper.exe'
        if (-not (Test-Path -LiteralPath $piperExe)) {
            $url = "https://github.com/rhasspy/piper/releases/download/$PiperVersion/piper_windows_amd64.zip"
            $zip = Join-Path $env:TEMP 'piper_windows_amd64.zip'
            Append-Log "  Downloading $url"
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            Append-Log "  Extracting…"
            Expand-Archive -Path $zip -DestinationPath $piperDir -Force
            Remove-Item $zip -Force
            Tick 'piper' "Piper installed"
        } else {
            Tick 'piper' "Piper already present"
        }

        # 6. voice
        Bump 'voice'
        $onnx = Join-Path $voicesDir "$Voice.onnx"
        $json = "$onnx.json"
        if (-not (Test-Path -LiteralPath $onnx) -or -not (Test-Path -LiteralPath $json)) {
            if ($Voice -notmatch '^([a-z]{2})_([A-Z]{2})-([^-]+)-([a-z_]+)$') {
                Bomb 'voice' "Voice slug must be like 'es_ES-davefx-medium'"
            }
            $lang = $matches[1]; $region = $matches[2]; $vname = $matches[3]; $quality = $matches[4]
            $base = "https://huggingface.co/rhasspy/piper-voices/resolve/main/$lang/${lang}_$region/$vname/$quality"
            Append-Log "  Downloading voice model…"
            Invoke-WebRequest -Uri "$base/$Voice.onnx"      -OutFile $onnx -UseBasicParsing
            Append-Log "  Downloading voice config…"
            Invoke-WebRequest -Uri "$base/$Voice.onnx.json" -OutFile $json -UseBasicParsing
            Tick 'voice' "Voice $Voice downloaded"
        } else {
            Tick 'voice' "Voice already present"
        }

        # 7. state
        Bump 'state'
        if (-not (Test-Path -LiteralPath $stateFile)) {
            @{
                sessions   = @()
                names_pool = @(
                    'Michael','Peter','James','Oliver','Lucas','Liam',
                    'Sarah','Emma','Sophie','Charlotte','Ava','Olivia'
                )
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding UTF8
            Tick 'state' "voice-state.json created"
        } else {
            Tick 'state' "voice-state.json already exists"
        }

        # 8. hooks
        Bump 'hooks'
        $bootstrapCmd = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
                        (Join-Path $scriptsDir 'session-bootstrap.ps1') + '"')
        $styleHookCmd = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
                        (Join-Path $scriptsDir 'voice-style-hook.ps1') + '"')

        if (Test-Path -LiteralPath $settings) {
            $obj = (Get-Content -Raw -LiteralPath $settings) | ConvertFrom-Json
        } else {
            $obj = New-Object PSObject
        }
        if (-not $obj.PSObject.Properties.Match('hooks').Count) {
            $obj | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force
        }
        function Ensure-Slot($evt, $cmd, [bool]$async) {
            if (-not $obj.hooks.PSObject.Properties.Match($evt).Count) {
                $obj.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue @() -Force
            }
            $existing = @($obj.hooks.$evt)
            foreach ($g in $existing) {
                foreach ($h in @($g.hooks)) { if ($h.command -eq $cmd) { return } }
            }
            $newHook = @{ type = 'command'; command = $cmd }
            if ($async) { $newHook.async = $true }
            $existing += @{ hooks = @($newHook) }
            $obj.hooks.$evt = $existing
        }
        Ensure-Slot 'SessionStart' $bootstrapCmd $true
        if (-not $NoStyleHook) { Ensure-Slot 'UserPromptSubmit' $styleHookCmd $false }
        $obj | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $settings -Encoding UTF8
        Tick 'hooks' "Hooks merged in settings.json"

        $statusText.Text = 'Done. Open a new Claude Code session.'
        $progress.Value = 100
        Append-Log ""
        Append-Log "Install complete. Open a NEW Claude Code session — you should hear a"
        Append-Log "greeting and the dashboard window will appear (UAC prompt the first time)."
        $closeBtn.IsEnabled = $true
    } catch {
        $closeBtn.IsEnabled = $true
    }
}

$installBtn.Add_Click({ Run-Install })
$closeBtn.Add_Click({ $window.Close() })

[void]$window.ShowDialog()
