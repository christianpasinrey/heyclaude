; HeyClaude — Inno Setup script
;
; Builds a single .exe installer that:
;   - Drops the repo contents under %LOCALAPPDATA%\HeyClaude.
;   - Runs install-cli.ps1 to set up Python venv, Piper, voices and hooks.
;   - Registers an entry in "Apps & features" so users can uninstall via
;     the standard Windows UI; uninstall calls uninstall.ps1.
;
; To build:
;   1. Install Inno Setup 6: https://jrsoftware.org/isdl.php
;   2. Open installer.iss in the Inno Setup IDE and press Build, or run
;      "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
;   3. The resulting setup.exe lands in dist\.

#define MyAppName        "HeyClaude"
#define MyAppVersion     "0.1.0"
#define MyAppPublisher   "Christian Pasin Rey"
#define MyAppURL         "https://github.com/christianpasinrey/heyclaude"
#define MyAppExeName     "HeyClaude-Setup"

[Setup]
AppId={{F3B8C0F9-3D6B-4E2D-A86C-3F4B1B1A2C53}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableDirPage=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
OutputDir=dist
OutputBaseFilename={#MyAppExeName}-{#MyAppVersion}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=LICENSE
SetupIconFile=
UninstallDisplayName={#MyAppName}
UninstallFilesDir={app}
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Files]
Source: "install.ps1";          DestDir: "{app}"; Flags: ignoreversion
Source: "install-cli.ps1";      DestDir: "{app}"; Flags: ignoreversion
Source: "uninstall.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "requirements.txt";     DestDir: "{app}"; Flags: ignoreversion
Source: "README.md";            DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE";              DestDir: "{app}"; Flags: ignoreversion
Source: "src\voice_input\*";    DestDir: "{app}\src\voice_input"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "__pycache__,*.pyc"
Source: "src\scripts\*";        DestDir: "{app}\src\scripts";     Flags: ignoreversion recursesubdirs createallsubdirs

[Run]
; The post-install heavy lifting (Python venv, Piper download, voices,
; hooks merge) runs here. We launch a visible console so the user can see
; pip output — the wizard would otherwise look frozen for several minutes.
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\install-cli.ps1"""; \
    WorkingDir: "{app}"; \
    StatusMsg: "Configuring HeyClaude (Python deps, Piper, voices, hooks)…"; \
    Flags: waituntilterminated

[UninstallRun]
Filename: "powershell.exe"; \
    Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"""; \
    WorkingDir: "{app}"; \
    Flags: runhidden waituntilterminated; \
    RunOnceId: "RemoveHeyClaudeUserData"

[Icons]
Name: "{group}\{#MyAppName} dashboard"; Filename: "powershell.exe"; \
    Parameters: "-NoProfile -WindowStyle Hidden -Command ""Start-Process -WindowStyle Hidden -FilePath '%USERPROFILE%\.claude-voice\venv\Scripts\pythonw.exe' -ArgumentList '-m','voice_input' -Verb RunAs"""; \
    Comment: "Launch the HeyClaude voice daemon dashboard"
Name: "{group}\Reinstall {#MyAppName}";  Filename: "{app}\install.ps1"
Name: "{group}\Uninstall {#MyAppName}";  Filename: "{uninstallexe}"
