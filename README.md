# HeyClaude

> Voice control for [Claude Code](https://docs.claude.com/claude-code) on Windows.

Talk to multiple Claude sessions, hear their answers, route by name — all 100 % local. No keys, no cloud, no usage caps.

- **TTS streaming**: each Claude response is read aloud as it appears in the transcript, not only at the end of the turn. Voice via [Piper](https://github.com/rhasspy/piper) (`es_ES-davefx-medium` by default).
- **STT push-to-talk**: hold **F12** while you speak; release to transcribe with [faster-whisper](https://github.com/SYSTRAN/faster-whisper) on your GPU and inject the text into the active Claude window.
- **Wake word**: just say *"Claude, …"* (or *"Escucha, …"*). The remainder of the utterance is delivered automatically. Pause after the wake and you have eight seconds to dictate the command.
- **Multi-session routing**: every Claude Code session gets a random name (Michael, Peter, Sarah…) and a card in the dashboard. Click a card or prefix your command with the name to route there. Each session has its own TTS stream — the daemon mutes the mic while it speaks so it never listens to itself.
- **Stop button**: sends Escape to the selected session to interrupt the model.
- **Voice mode prompt**: an optional `UserPromptSubmit` hook nudges Claude to answer in conversational, TTS-friendly prose (no paths, no markdown).

## Requirements

- Windows 10 / 11
- Python 3.10+ (3.12 recommended)
- A microphone
- Optional: NVIDIA GPU with up-to-date drivers — the daemon falls back to CPU automatically.

## Install

The fastest path is the prebuilt installer attached to each [release](https://github.com/christianpasinrey/heyclaude/releases) — download `HeyClaude-Setup-x.y.z.exe`, double-click, follow the wizard.

If you'd rather run it from source:

```powershell
git clone https://github.com/christianpasinrey/heyclaude.git
cd heyclaude
.\install.ps1            # graphical installer (PowerShell + WPF)
# .\install.ps1 -Cli     # text-only mode (good for CI / scripted setups)
```

### Building the .exe yourself

The installer is generated with [Inno Setup 6](https://jrsoftware.org/isdl.php). After installing it:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
```

The signed-or-not `.exe` lands in `dist\`.

The installer:

1. Detects Python (uses the `py` launcher when present).
2. Creates a venv under `~\.claude-voice\venv` and installs the Python deps.
3. Downloads Piper and the chosen voice model into `~\.claude-voice\piper\`.
4. Copies the daemon and the PowerShell hook scripts.
5. Merges the `SessionStart` and `UserPromptSubmit` hooks into `~\.claude\settings.json` without touching anything else.

Open a new Claude Code session: you'll hear a greeting (*"Hola, soy Michael"*) and the **Claude Voice** dashboard window appears. The first launch shows a UAC prompt — the daemon asks for elevation so it can inject text into Claude Code instances that you started "as administrator" too. Subsequent sessions reuse the running daemon.

### Optional install switches

```powershell
# Use a different Piper voice (must exist under rhasspy/piper-voices on HF)
.\install.ps1 -Voice 'es_ES-mls_10246-low'

# Skip the UserPromptSubmit "voice mode" hook (just TTS+STT)
.\install.ps1 -NoStyleHook

# Pin a Piper release
.\install.ps1 -PiperVersion '2023.11.14-2'
```

## Usage

| Action | How |
| --- | --- |
| Push-to-talk | Hold **F12**, speak, release. |
| Wake word | Say *"Claude, abre el archivo …"* or *"Escucha, …"*. |
| Wake then pause | *"Claude."* → up to 8 s to dictate the command. |
| Pick target session | Click the card in the dashboard. |
| Pick target by voice | Prefix the command with the session name: *"Peter, …"*. |
| Interrupt the model | **Stop** button — sends Escape to the selected session. |

State lives in `~\.claude\voice-state.json` (so the hooks can read/write it). Logs:

- Daemon: `%TEMP%\claude-voice-input.log`
- Per-session TTS watcher: `%TEMP%\claude-voice-<sessionId>.log`

## Uninstall

```powershell
.\uninstall.ps1            # keeps voice-state.json
.\uninstall.ps1 -PurgeState
```

## Customising

Most knobs live in `~\.claude-voice\voice_input\config.py`:

- `WHISPER_MODEL` — `tiny` / `base` / `small` / `medium` / `large-v3`.
- `LANG` — Whisper language hint.
- `WAKE_GRACE_S`, `SILENCE_TAIL_MS`, `VAD_THRESHOLD` — gate tuning.
- Colours of the dashboard.

You can also override at launch via env vars:

```powershell
$env:CLAUDE_VOICE_MODEL = 'large-v3'
$env:CLAUDE_VOICE_LANG  = 'en'
```

Restart the daemon after any change.

## How it works

```
┌────────────────────┐     SessionStart hook      ┌──────────────────────┐
│ Claude Code        │───────────────────────────▶│ session-bootstrap.ps1│
│  (per session)     │                            │  • assign random name │
│                    │     Stop / new transcript  │  • register PIDs      │
│                    │       line written         │  • greet via Piper    │
│                    │◀───────────────────────────│  • spawn watcher      │
│                    │                            │  • spawn STT daemon   │
└─────────┬──────────┘                            └──────────┬───────────┘
          │                                                   │
          │ JSONL transcript                                  │
          ▼                                                   ▼
┌────────────────────┐                            ┌──────────────────────┐
│ voice-watcher.ps1  │   Piper TTS                │ voice_input daemon   │
│ (one per session)  │──────────────▶ speakers    │  • Tk dashboard      │
│                    │                            │  • F12 push-to-talk  │
└────────────────────┘                            │  • silero-vad +      │
                                                  │    faster-whisper    │
                                                  │  • SetForegroundWin  │
                                                  │    + Unicode keys    │
                                                  └──────────────────────┘
```

## Troubleshooting

- **No greeting on session start**: verify the hooks were merged in `~\.claude\settings.json` (look for `session-bootstrap.ps1`). Re-run `install.ps1` if missing.
- **Whisper says "cublas64\_12.dll not found"**: re-run `install.ps1` — it installs `nvidia-cublas-cu12` / `nvidia-cudnn-cu12` and adds them to `PATH` from inside the daemon.
- **Wake word never fires**: speak louder or louder/lower `VAD_THRESHOLD` in `config.py`. Whisper transcription is shown in the dashboard with `×` so you can see what it heard.
- **Text routes to the wrong window**: ensure each Claude session is in a **separate Windows Terminal window**, not separate tabs of the same window. Tabs share one Win32 HWND and cannot be addressed individually.
- **Nothing pastes into elevated Claude windows**: the daemon must be elevated too — UIPI blocks keystroke injection from low-IL to high-IL processes. The bootstrap launches it with `-Verb RunAs`; accept the UAC prompt the first time.

## Licence

[MIT](LICENSE).
