"""Paths, constants and runtime tuning.

Everything user-specific is derived from ``USERPROFILE`` so the daemon runs
identically on any Windows account. The state file lives under the standard
Claude Code config dir; everything else (binaries, voice models, venv) lives
under ``~/.claude-voice/``.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

USER_HOME = Path(os.environ.get("USERPROFILE") or os.path.expanduser("~"))
CLAUDE_HOME = USER_HOME / ".claude"
APP_HOME = USER_HOME / ".claude-voice"

# State file shared with the SessionStart / Stop / TTS hooks.
STATE_FILE = CLAUDE_HOME / "voice-state.json"

# TTS gate: while this flag exists the wake-word VAD pauses to avoid
# transcribing our own speech output.
TTS_FLAG = APP_HOME / "tts-active.flag"

LOG_FILE = Path(tempfile.gettempdir()) / "claude-voice-input.log"

# Audio
SAMPLE_RATE = 16000
VAD_CHUNK = 512                                  # silero v6 expects 512 @ 16k
VAD_CHUNK_MS = VAD_CHUNK * 1000 // SAMPLE_RATE   # 32 ms
VAD_THRESHOLD = 0.55
SILENCE_TAIL_MS = 700
PRE_ROLL_MS = 320
MAX_CLIP_S = 14
MIN_CLIP_S = 0.4

# Whisper
WHISPER_MODEL = os.environ.get("CLAUDE_VOICE_MODEL", "large-v3-turbo")
LANG = os.environ.get("CLAUDE_VOICE_LANG", "es")

# Wake-word grace: after a bare wake utterance, the next VAD segment within
# this many seconds is delivered as the command.
WAKE_GRACE_S = 8.0
# How many words can precede the wake keyword and still count as a wake.
WAKE_PREFIX_MAX_WORDS = 3

# UI palette
COL_BG          = "#0f1115"
COL_PANEL       = "#161a21"
COL_CARD        = "#1c2230"
COL_CARD_SEL    = "#2a3a5a"
COL_CARD_HOV    = "#222a3a"
COL_BORDER      = "#2a2f3a"
COL_BORDER_SEL  = "#5aa9ff"
COL_TEXT        = "#e8eaf0"
COL_MUTED       = "#8b93a3"
COL_ACCENT      = "#5aa9ff"
COL_OK          = "#4ec9b0"
COL_WARN        = "#dcdc6e"
COL_ERR         = "#f14c4c"
COL_REC         = "#ff6b6b"
COL_DOT_IDLE    = "#4a4f5c"


def setup_cuda_dll_path() -> None:
    """Add the cuBLAS / cuDNN bin directories shipped by pip wheels to the
    DLL search path. ctranslate2 ignores ``add_dll_directory`` in some
    Windows loading paths so we also prepend to ``PATH``.
    """
    nvidia_root = Path(sys.prefix) / "Lib" / "site-packages" / "nvidia"
    bin_dirs: list[str] = []
    for sub in ("cublas", "cudnn", "cuda_nvrtc"):
        bin_dir = nvidia_root / sub / "bin"
        if bin_dir.is_dir():
            bin_dirs.append(str(bin_dir))
            try:
                os.add_dll_directory(str(bin_dir))
            except Exception:
                pass
    if bin_dirs:
        os.environ["PATH"] = os.pathsep.join(bin_dirs) + os.pathsep + os.environ.get("PATH", "")
