"""Tkinter widgets — session card with click-to-select."""
from __future__ import annotations

import tkinter as tk
from typing import Callable

from .config import (
    COL_BORDER,
    COL_CARD,
    COL_CARD_HOV,
    COL_CARD_SEL,
    COL_DOT_IDLE,
    COL_MUTED,
    COL_OK,
    COL_TEXT,
)


class SessionCard(tk.Frame):
    """Click-to-select card representing one Claude Code session."""

    def __init__(self, parent, session: dict, on_click: Callable[[str], None]):
        super().__init__(parent, bg=COL_CARD, highlightthickness=2,
                         highlightbackground=COL_BORDER, padx=14, pady=12,
                         cursor="hand2")
        self.session = session
        self.on_click = on_click
        self.selected = False

        self.dot = tk.Canvas(self, width=12, height=12, bg=COL_CARD,
                             highlightthickness=0)
        self._dot_id = self.dot.create_oval(1, 1, 11, 11, fill=COL_DOT_IDLE,
                                            outline="")
        self.dot.grid(row=0, column=0, padx=(0, 10), sticky="w")

        self.name_lbl = tk.Label(self, text=session.get("name", "?"),
                                 font=("Segoe UI", 13, "bold"),
                                 bg=COL_CARD, fg=COL_TEXT)
        self.name_lbl.grid(row=0, column=1, sticky="w")

        self.badge = tk.Label(self, text="", font=("Segoe UI", 8, "bold"),
                              bg=COL_CARD, fg=COL_OK)
        self.badge.grid(row=0, column=2, sticky="e", padx=(8, 0))

        self.meta_lbl = tk.Label(
            self, text=f"term {session.get('terminal_pid','?')}",
            font=("Consolas", 8), bg=COL_CARD, fg=COL_MUTED,
        )
        self.meta_lbl.grid(row=1, column=1, columnspan=2, sticky="w",
                           pady=(3, 0))

        self.columnconfigure(1, weight=1)

        for w in (self, self.dot, self.name_lbl, self.meta_lbl, self.badge):
            w.bind("<Button-1>", self._on_click)
            w.bind("<Enter>", self._on_enter)
            w.bind("<Leave>", self._on_leave)

    def _apply_bg(self, bg: str) -> None:
        self.configure(bg=bg)
        self.dot.configure(bg=bg)
        self.name_lbl.configure(bg=bg)
        self.meta_lbl.configure(bg=bg)
        self.badge.configure(bg=bg)

    def _on_click(self, _evt) -> None:
        self.on_click(self.session.get("name"))

    def _on_enter(self, _evt) -> None:
        if not self.selected:
            self._apply_bg(COL_CARD_HOV)

    def _on_leave(self, _evt) -> None:
        if not self.selected:
            self._apply_bg(COL_CARD)

    def set_selected(self, sel: bool) -> None:
        self.selected = sel
        if sel:
            self._apply_bg(COL_CARD_SEL)
            self.configure(highlightbackground=COL_OK,
                           highlightcolor=COL_OK)
            self.dot.itemconfig(self._dot_id, fill=COL_OK)
            self.name_lbl.configure(fg="#ffffff")
            self.badge.configure(text="● ACTIVO", fg=COL_OK)
        else:
            self._apply_bg(COL_CARD)
            self.configure(highlightbackground=COL_BORDER,
                           highlightcolor=COL_BORDER)
            self.dot.itemconfig(self._dot_id, fill=COL_DOT_IDLE)
            self.name_lbl.configure(fg=COL_TEXT)
            self.badge.configure(text="")
