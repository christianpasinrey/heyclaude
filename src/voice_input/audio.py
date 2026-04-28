"""Audio capture and voice-activity detection."""
from __future__ import annotations

import threading
from collections import deque

import numpy as np
import sounddevice as sd
import torch

from .config import (
    MAX_CLIP_S,
    PRE_ROLL_MS,
    SAMPLE_RATE,
    SILENCE_TAIL_MS,
    VAD_CHUNK,
    VAD_CHUNK_MS,
    VAD_THRESHOLD,
)


class Recorder:
    """Push-to-talk recorder with explicit ``start()`` / ``stop()``."""

    def __init__(self) -> None:
        self.frames: list[np.ndarray] = []
        self.stream: sd.InputStream | None = None
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            self.frames = []
            self.stream = sd.InputStream(
                samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                callback=self._cb,
            )
            self.stream.start()

    def _cb(self, indata, frames, time_info, status):  # noqa: ARG002
        self.frames.append(indata.copy())

    def stop(self) -> np.ndarray:
        with self._lock:
            if not self.stream:
                return np.zeros(0, dtype=np.float32)
            try:
                self.stream.stop()
                self.stream.close()
            finally:
                self.stream = None
            if not self.frames:
                return np.zeros(0, dtype=np.float32)
            return np.concatenate(self.frames, axis=0).flatten()


class VadGate:
    """Streaming voice-activity gate.

    Feed PCM chunks of ``VAD_CHUNK`` samples (float32, mono, 16 kHz).
    Returns the completed clip when a speech segment ends — after
    ``SILENCE_TAIL_MS`` of trailing silence — or when ``MAX_CLIP_S`` is
    reached. A small pre-roll is kept so the first phoneme is never clipped.
    """

    def __init__(self, model) -> None:
        self.model = model
        self.silence_chunks_threshold = max(1, SILENCE_TAIL_MS // VAD_CHUNK_MS)
        self.max_chunks = (MAX_CLIP_S * 1000) // VAD_CHUNK_MS
        self.preroll_chunks = max(1, PRE_ROLL_MS // VAD_CHUNK_MS)
        self._reset_full()

    def _reset_full(self) -> None:
        self.in_speech = False
        self.silence_count = 0
        self.buffer: list[np.ndarray] = []
        self.preroll: deque[np.ndarray] = deque(maxlen=self.preroll_chunks)
        self._just_started = False

    def consume_just_started(self) -> bool:
        v = self._just_started
        self._just_started = False
        return v

    def feed(self, chunk: np.ndarray) -> np.ndarray | None:
        with torch.no_grad():
            prob = self.model(torch.from_numpy(chunk), SAMPLE_RATE).item()
        is_speech = prob > VAD_THRESHOLD
        if is_speech:
            if not self.in_speech:
                self.buffer.extend(self.preroll)
                self.in_speech = True
                self._just_started = True
            self.buffer.append(chunk)
            self.silence_count = 0
            if len(self.buffer) >= self.max_chunks:
                clip = np.concatenate(self.buffer)
                self._reset_full()
                return clip
        else:
            self.preroll.append(chunk)
            if self.in_speech:
                self.buffer.append(chunk)
                self.silence_count += 1
                if self.silence_count >= self.silence_chunks_threshold:
                    clip = np.concatenate(self.buffer)
                    self._reset_full()
                    return clip
        return None
