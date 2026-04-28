"""Main Tk application: dashboard + audio loops + transcription worker."""
from __future__ import annotations

import logging
import queue
import threading
import time
import tkinter as tk
from collections import deque
from tkinter import ttk

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel
from pynput import keyboard
from silero_vad import load_silero_vad

from .audio import Recorder, VadGate
from .config import (
    COL_BG,
    COL_DOT_IDLE,
    COL_ERR,
    COL_MUTED,
    COL_OK,
    COL_PANEL,
    COL_REC,
    COL_TEXT,
    COL_WARN,
    LANG,
    LOG_FILE,
    MIN_CLIP_S,
    SAMPLE_RATE,
    TTS_FLAG,
    VAD_CHUNK,
    WAKE_GRACE_S,
    WAKE_PREFIX_MAX_WORDS,
    WHISPER_MODEL,
    setup_cuda_dll_path,
)
from .routing import WAKE_KEYWORD_RE, load_sessions, split_name_prefix
from .ui import SessionCard
from .win32_io import (
    find_window_for_pid,
    force_foreground,
    send_escape,
    type_text_and_enter,
)

logging.basicConfig(
    filename=str(LOG_FILE),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("voice-input")

HOTKEY = keyboard.Key.f12


class VoiceApp:
    def __init__(self) -> None:
        setup_cuda_dll_path()

        self.root = tk.Tk()
        self.root.title("Claude Voice")
        self.root.attributes("-topmost", True)
        self.root.geometry("440x540+40+40")
        self.root.configure(bg=COL_BG)
        self.root.minsize(400, 480)

        self.model: WhisperModel | None = None
        self.vad_model = None
        self.device_label = "loading…"
        self.status_var = tk.StringVar(value="cargando modelos…")
        self.selected_name: str | None = None
        self.sessions: list[dict] = []
        self.cards: dict[str, SessionCard] = {}
        self.transcripts: deque[str] = deque(maxlen=10)
        self.q: queue.Queue[tuple[str, np.ndarray]] = queue.Queue()
        self.recorder = Recorder()
        self._ptt_pressed = False
        self._pending_wake_until = 0.0

        self._build_ui()
        self.root.after(500, self._refresh)

    # --- UI ---

    def _build_ui(self) -> None:
        header = tk.Frame(self.root, bg=COL_BG, padx=16, pady=14)
        header.pack(fill="x")
        self.status_dot = tk.Canvas(header, width=14, height=14, bg=COL_BG,
                                    highlightthickness=0)
        self.status_dot.pack(side="left", padx=(0, 10))
        self._dot_id = self.status_dot.create_oval(2, 2, 12, 12,
                                                   fill=COL_DOT_IDLE, outline="")
        tk.Label(header, textvariable=self.status_var,
                 font=("Segoe UI", 12, "bold"),
                 bg=COL_BG, fg=COL_TEXT).pack(side="left")
        self.device_lbl = tk.Label(header, text="", bg=COL_BG, fg=COL_MUTED,
                                   font=("Segoe UI", 9))
        self.device_lbl.pack(side="right")

        sess_panel = tk.Frame(self.root, bg=COL_PANEL)
        sess_panel.pack(fill="x", padx=14, pady=(0, 10))
        tk.Label(sess_panel, text="AGENTES",
                 font=("Segoe UI", 8, "bold"), bg=COL_PANEL, fg=COL_MUTED
                 ).pack(anchor="w", padx=14, pady=(10, 6))
        self.cards_frame = tk.Frame(sess_panel, bg=COL_PANEL)
        self.cards_frame.pack(fill="x", padx=10, pady=(0, 12))

        trans_panel = tk.Frame(self.root, bg=COL_PANEL)
        trans_panel.pack(fill="both", expand=True, padx=14)
        tk.Label(trans_panel, text="TRANSCRIPCIONES",
                 font=("Segoe UI", 8, "bold"), bg=COL_PANEL, fg=COL_MUTED
                 ).pack(anchor="w", padx=14, pady=(10, 6))
        self.trans_list = tk.Listbox(
            trans_panel, height=8, bg=COL_PANEL, fg=COL_TEXT,
            selectbackground="#37373d", borderwidth=0,
            highlightthickness=0, font=("Segoe UI", 9), activestyle="none",
        )
        self.trans_list.pack(fill="both", expand=True, padx=10, pady=(0, 12))

        footer = tk.Frame(self.root, bg=COL_BG, padx=16, pady=12)
        footer.pack(fill="x")
        tk.Label(footer, text='F12 push-to-talk · di "Claude, …"',
                 bg=COL_BG, fg=COL_MUTED,
                 font=("Segoe UI", 8)).pack(side="left")
        self.stop_btn = tk.Button(
            footer, text="⏹  Stop", bg="#3a1818", fg=COL_TEXT,
            activebackground="#5a2222", activeforeground=COL_TEXT,
            borderwidth=0, padx=14, pady=6,
            font=("Segoe UI", 9, "bold"), cursor="hand2",
            command=self._on_stop,
        )
        self.stop_btn.pack(side="right")

    def _set_status(self, txt: str, color: str) -> None:
        self.status_var.set(txt)
        self.status_dot.itemconfig(self._dot_id, fill=color)

    def _on_card_click(self, name: str | None) -> None:
        if not name:
            return
        self.selected_name = name
        self._refresh_card_selection()

    def _refresh_card_selection(self) -> None:
        for n, c in self.cards.items():
            c.set_selected(n == self.selected_name)

    def _rebuild_cards(self) -> None:
        for c in self.cards.values():
            c.destroy()
        self.cards.clear()
        for w in self.cards_frame.winfo_children():
            w.destroy()
        for col in range(2):
            self.cards_frame.columnconfigure(col, weight=1, uniform="cards")
        for i, sess in enumerate(self.sessions):
            name = sess.get("name") or ""
            if not name:
                continue
            card = SessionCard(self.cards_frame, sess, self._on_card_click)
            card.grid(row=i // 2, column=i % 2, padx=5, pady=5, sticky="ew")
            self.cards[name] = card
        if self.selected_name not in self.cards:
            self.selected_name = next(iter(self.cards), None)
        self._refresh_card_selection()

    def _push_transcript(self, line: str) -> None:
        self.transcripts.appendleft(line)
        self.trans_list.delete(0, "end")
        for t in self.transcripts:
            self.trans_list.insert("end", t)

    def _refresh(self) -> None:
        new_sessions = load_sessions()
        names_changed = (
            [s.get("name") for s in self.sessions]
            != [s.get("name") for s in new_sessions]
        )
        self.sessions = new_sessions
        if names_changed:
            self._rebuild_cards()
        self.device_lbl.configure(text=self.device_label)
        self.root.after(1000, self._refresh)

    def _maybe_clear_pending(self) -> None:
        if self._pending_wake_until and time.time() >= self._pending_wake_until:
            self._pending_wake_until = 0.0
            self._set_status("escuchando…", COL_DOT_IDLE)

    def _on_stop(self) -> None:
        target = next((s for s in self.sessions
                       if s.get("name") == self.selected_name), None)
        if target:
            hwnd = find_window_for_pid(int(target.get("terminal_pid") or 0))
            if hwnd and force_foreground(hwnd):
                time.sleep(0.05)
                send_escape()
                self._set_status(f"⏹ stop {target['name']}", COL_ERR)
                self.root.after(1500, lambda: self._set_status("escuchando…", COL_DOT_IDLE))
                return
        send_escape()
        self._set_status("⏹ stop (foreground)", COL_ERR)
        self.root.after(1500, lambda: self._set_status("escuchando…", COL_DOT_IDLE))

    # --- background ---

    def load_models(self) -> None:
        try:
            self.model = WhisperModel(WHISPER_MODEL, device="cuda",
                                      compute_type="float16")
            self.device_label = "GPU cuda fp16"
        except Exception as e:
            log.warning("cuda load failed: %s", e)
            try:
                self.model = WhisperModel(WHISPER_MODEL, device="cpu",
                                          compute_type="int8")
                self.device_label = "CPU int8"
            except Exception as e2:
                log.exception("whisper load: %s", e2)
                self.device_label = "ERROR"
                self.root.after(0, lambda: self._set_status("error whisper", COL_ERR))
                return
        try:
            self.vad_model = load_silero_vad(onnx=False)
            log.info("silero-vad ready")
        except Exception as e:
            log.exception("vad load: %s", e)
        self.root.after(0, lambda: self._set_status("escuchando…", COL_DOT_IDLE))

    def vad_loop(self) -> None:
        while self.model is None or self.vad_model is None:
            time.sleep(0.2)
        gate = VadGate(self.vad_model)
        log.info("vad loop starting")
        with sd.InputStream(samplerate=SAMPLE_RATE, channels=1,
                            dtype="float32", blocksize=VAD_CHUNK) as stream:
            while True:
                if TTS_FLAG.exists() or self._ptt_pressed:
                    try:
                        stream.read(VAD_CHUNK)
                    except Exception:
                        pass
                    continue
                try:
                    data, _ = stream.read(VAD_CHUNK)
                except Exception as e:
                    log.warning("stream read: %s", e)
                    time.sleep(0.05)
                    continue
                audio = data.flatten()
                if audio.shape[0] != VAD_CHUNK:
                    continue
                clip = gate.feed(audio)
                if gate.consume_just_started():
                    self.root.after(0, lambda: self._set_status("grabando…", COL_REC))
                if clip is not None:
                    if len(clip) >= int(MIN_CLIP_S * SAMPLE_RATE):
                        self.q.put(("wake", clip))
                        self.root.after(0, lambda: self._set_status("transcribiendo…", COL_WARN))
                    else:
                        self.root.after(0, lambda: self._set_status("escuchando…", COL_DOT_IDLE))

    def keyboard_loop(self) -> None:
        def on_press(key):
            if key == HOTKEY and not self._ptt_pressed:
                self._ptt_pressed = True
                try:
                    self.recorder.start()
                    self.root.after(0, lambda: self._set_status("grabando…", COL_REC))
                except Exception as e:
                    log.exception("recorder start: %s", e)

        def on_release(key):
            if key == HOTKEY and self._ptt_pressed:
                self._ptt_pressed = False
                audio = self.recorder.stop()
                self.q.put(("ptt", audio))
                self.root.after(0, lambda: self._set_status("transcribiendo…", COL_WARN))

        with keyboard.Listener(on_press=on_press, on_release=on_release) as l:
            l.join()

    def worker(self) -> None:
        while True:
            kind, audio = self.q.get()
            if audio is None:
                break
            if self.model is None or len(audio) < int(MIN_CLIP_S * SAMPLE_RATE):
                self.root.after(0, lambda: self._set_status("escuchando…", COL_DOT_IDLE))
                continue
            try:
                segments, _ = self.model.transcribe(audio, language=LANG, beam_size=1)
                text = " ".join(s.text.strip() for s in segments).strip()
                log.info("[%s] transcribed: %r", kind, text)

                if kind == "wake":
                    m = WAKE_KEYWORD_RE.search(text)
                    is_wake = bool(m) and len(text[:m.start()].split()) <= WAKE_PREFIX_MAX_WORDS
                    if is_wake:
                        cmd = text[m.end():].strip(" ,.?!")
                        if not cmd:
                            self._pending_wake_until = time.time() + WAKE_GRACE_S
                            self.root.after(0, lambda t=text: self._push_transcript(f"○  {t}"))
                            self.root.after(0, lambda: self._set_status("dime el comando…", COL_WARN))
                            self.root.after(int(WAKE_GRACE_S * 1000) + 200,
                                            self._maybe_clear_pending)
                            continue
                    elif self._pending_wake_until > time.time():
                        cmd = text.strip()
                        self._pending_wake_until = 0.0
                    else:
                        self.root.after(0, lambda t=text: self._push_transcript(f"×  {t}"))
                        self.root.after(0, lambda: self._set_status("escuchando…", COL_DOT_IDLE))
                        continue
                else:
                    cmd = text.strip()

                if not cmd:
                    self.root.after(0, lambda: self._set_status("escuchando…", COL_DOT_IDLE))
                    continue

                clean, target = split_name_prefix(cmd, self.sessions)
                if target is None and self.selected_name:
                    target = next((s for s in self.sessions
                                   if s.get("name") == self.selected_name), None)
                    clean = cmd
                tname = target.get("name") if target else "foreground"

                self.root.after(0, lambda c=clean, n=tname: self._push_transcript(f"→ [{n}] {c}"))

                if not clean:
                    self.root.after(0, lambda: self._set_status("escuchando…", COL_DOT_IDLE))
                    continue

                if target:
                    hwnd = find_window_for_pid(int(target.get("terminal_pid") or 0))
                    if hwnd and force_foreground(hwnd):
                        time.sleep(0.3)
                        type_text_and_enter(clean)
                        self.root.after(0, lambda n=tname: self._set_status(f"enviado → {n}", COL_OK))
                        self.root.after(1500, lambda: self._set_status("escuchando…", COL_DOT_IDLE))
                        continue
                    log.warning("could not focus window for %s", tname)
                time.sleep(0.05)
                type_text_and_enter(clean)
                self.root.after(0, lambda: self._set_status("enviado (foreground)", COL_OK))
                self.root.after(1500, lambda: self._set_status("escuchando…", COL_DOT_IDLE))
            except Exception as e:
                log.exception("worker error: %s", e)
                self.root.after(0, lambda: self._set_status("error: ver log", COL_ERR))
                self.root.after(2500, lambda: self._set_status("escuchando…", COL_DOT_IDLE))

    def run(self) -> None:
        threading.Thread(target=self.load_models, daemon=True).start()
        threading.Thread(target=self.vad_loop, daemon=True).start()
        threading.Thread(target=self.keyboard_loop, daemon=True).start()
        threading.Thread(target=self.worker, daemon=True).start()
        self.root.mainloop()
