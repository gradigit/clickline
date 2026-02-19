#!/usr/bin/env python3
"""clickline configure — Textual TUI for statusline configuration.

Usage:
    python3 configure.py
    python3 configure.py --save-and-exit   # headless save of defaults

Layout:
    ┌──────────────────────────────────────────────────────────────┐
    │  ~/project/src · main·3 ↑1 │ #42 │ ✓ │ Sonnet 4.6          │
    │  45%/200K │ 82% · 45% │ $4                                   │
    ├───── Layout ──────────────────────┬──── Elements ────────────┤
    │  ▶ Path                           │  ☑ Path                  │
    │    Branch                         │  ☑ Branch                │
    │    PR link  [gh]                  │  ☐ Commit                │
    │  ── line break ──                 │  ☑ Model                 │
    │    Context %                      │  ...                     │
    ├───────────────────────────────────┴──────────────────────────┤
    │  s Save  q Quit  ⇧↑↓ Move  n Break  d Del  [ ] Line  ? Help│
    └──────────────────────────────────────────────────────────────┘
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import ClassVar

from rich.text import Text
from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.message import Message
from textual.reactive import reactive
from textual.widgets import (
    Button,
    Footer,
    Header,
    Input,
    Label,
    SelectionList,
    Static,
)
from textual.widgets._selection_list import Selection

# ── Theme system ─────────────────────────────────────────────────────────────
# Each theme has 10 semantic color slots used by the statusline preview.
# TUI chrome (borders, labels) stays neutral gray regardless of theme.
THEMES: dict[str, dict[str, str]] = {
    "catppuccin-mocha": {
        "label": "#6c7086", "sep": "#585b70", "dim": "#45475a",
        "sapphire": "#74c7ec", "lavender": "#b4befe", "mauve": "#cba6f7",
        "gold": "#f9e2af", "green": "#a6e3a1", "peach": "#fab387", "red": "#f38ba8",
    },
    "catppuccin-frappe": {
        "label": "#838ba7", "sep": "#737994", "dim": "#626880",
        "sapphire": "#85c1dc", "lavender": "#babbf1", "mauve": "#ca9ee6",
        "gold": "#e5c890", "green": "#a6d189", "peach": "#ef9f76", "red": "#e78284",
    },
    "catppuccin-latte": {
        "label": "#8c8fa1", "sep": "#acb0be", "dim": "#bcc0cc",
        "sapphire": "#209fb5", "lavender": "#7287fd", "mauve": "#8839ef",
        "gold": "#df8e1d", "green": "#40a02b", "peach": "#fe640b", "red": "#d20f39",
    },
    "dracula": {
        "label": "#6272a4", "sep": "#44475a", "dim": "#44475a",
        "sapphire": "#8be9fd", "lavender": "#bd93f9", "mauve": "#ff79c6",
        "gold": "#f1fa8c", "green": "#50fa7b", "peach": "#ffb86c", "red": "#ff5555",
    },
    "tokyo-night": {
        "label": "#565f89", "sep": "#363f5f", "dim": "#363f5f",
        "sapphire": "#7dcfff", "lavender": "#7aa2f7", "mauve": "#bb9af7",
        "gold": "#e0af68", "green": "#9ece6a", "peach": "#ff9e64", "red": "#f7768e",
    },
    "gruvbox-dark": {
        "label": "#928374", "sep": "#504945", "dim": "#504945",
        "sapphire": "#83a598", "lavender": "#d3869b", "mauve": "#d3869b",
        "gold": "#fabd2f", "green": "#b8bb26", "peach": "#fe8019", "red": "#fb4934",
    },
    "nord": {
        "label": "#4c566a", "sep": "#434c5e", "dim": "#3b4252",
        "sapphire": "#88c0d0", "lavender": "#81a1c1", "mauve": "#b48ead",
        "gold": "#ebcb8b", "green": "#a3be8c", "peach": "#d08770", "red": "#bf616a",
    },
    "solarized-dark": {
        "label": "#586e75", "sep": "#073642", "dim": "#073642",
        "sapphire": "#268bd2", "lavender": "#6c71c4", "mauve": "#d33682",
        "gold": "#b58900", "green": "#859900", "peach": "#cb4b16", "red": "#dc322f",
    },
    "one-dark": {
        "label": "#5c6370", "sep": "#3b4048", "dim": "#3b4048",
        "sapphire": "#56b6c2", "lavender": "#61afef", "mauve": "#c678dd",
        "gold": "#e5c07b", "green": "#98c379", "peach": "#d19a66", "red": "#e06c75",
    },
    "rose-pine": {
        "label": "#6e6a86", "sep": "#393552", "dim": "#393552",
        "sapphire": "#9ccfd8", "lavender": "#c4a7e7", "mauve": "#eb6f92",
        "gold": "#f6c177", "green": "#31748f", "peach": "#ea9a97", "red": "#eb6f92",
    },
}

THEME_NAMES = list(THEMES.keys())

def get_palette(theme: str) -> dict[str, str]:
    """Return palette dict for a theme, falling back to catppuccin-mocha."""
    return THEMES.get(theme, THEMES["catppuccin-mocha"])

# ── Built-in element catalogue ────────────────────────────────────────────────
LINEBREAK = "||"  # sentinel in layout list

@dataclass(frozen=True)
class ElementDef:
    name: str
    label: str
    description: str
    color: str              # Catppuccin key
    show_var: str | None = None   # SHOW_* var, None = always in layout if present
    requires: str = ""            # "gh" or ""
    conditional: bool = False     # only visible when data exists (vim, agent)

BUILTINS: list[ElementDef] = [
    ElementDef("path",    "Path",         "Working directory (clickable)",          "sapphire"),
    ElementDef("branch",  "Branch",       "Git branch → GitHub (+ dirty, ↑↓)",     "green",   "SHOW_BRANCH"),
    ElementDef("commit",  "Commit",       "HEAD short hash → GitHub commit",        "dim",     "SHOW_COMMIT"),
    ElementDef("pr",      "PR link",      "Open PR or New PR link",                 "lavender","SHOW_PR",    "gh"),
    ElementDef("ci",      "CI status",    "GitHub Actions ✓ ✗ ⋯",                 "green",   "SHOW_CI",    "gh"),
    ElementDef("model",   "Model",        "Claude model name → Anthropic docs",     "lavender","SHOW_MODEL"),
    ElementDef("version", "Version",      "Claude Code version → GitHub releases",  "dim",     "SHOW_VERSION"),
    ElementDef("vim",     "VIM mode",     "VIM mode indicator (when active)",       "mauve",   None, "", True),
    ElementDef("agent",   "Agent name",   "Sub-agent name (when agent is running)", "lavender",None, "", True),
    ElementDef("context", "Context %",    "Context window usage and max size",      "gold",    "SHOW_CONTEXT"),
    ElementDef("quota",   "Quota",        "5h + 7d usage with time-until-reset",    "green",   "SHOW_QUOTA"),
    ElementDef("cost",    "Cost",         "Session cost → transcript file",         "gold",    "SHOW_COST"),
]
BUILTIN_NAMES = {e.name for e in BUILTINS}
BY_NAME: dict[str, ElementDef] = {e.name: e for e in BUILTINS}

# Preview placeholder values (what render would show with sample data)
SAMPLES: dict[str, str] = {
    "path":    "~/project/src",
    "branch":  "main·3 ↑1",
    "commit":  "abc1234",
    "pr":      "#42",
    "ci":      "✓",
    "model":   "Sonnet 4.6",
    "version": "v1.3.0",
    "vim":     "VIM N",
    "agent":   "agent",
    "context": "45%/200K",
    "quota":   "82% · 45%",
    "cost":    "$4",
}

# ── Presets ───────────────────────────────────────────────────────────────────
PRESETS: dict[str, dict] = {
    "Minimal": {
        "desc": "Just path + model",
        "layout": ["path", LINEBREAK, "model"],
        "flags": {
            "SHOW_BRANCH": False, "SHOW_DIRTY": True, "SHOW_AHEAD_BEHIND": False,
            "SHOW_COMMIT": False, "SHOW_PR": False, "SHOW_CI": False,
            "SHOW_MODEL": True, "SHOW_VERSION": False,
            "SHOW_CONTEXT": False, "SHOW_QUOTA": False, "SHOW_COST": False,
        },
    },
    "Clean": {
        "desc": "Key info, two lines",
        "layout": ["path", "branch", "model", LINEBREAK, "context", "cost"],
        "flags": {
            "SHOW_BRANCH": True, "SHOW_DIRTY": True, "SHOW_AHEAD_BEHIND": False,
            "SHOW_COMMIT": False, "SHOW_PR": False, "SHOW_CI": False,
            "SHOW_MODEL": True, "SHOW_VERSION": False,
            "SHOW_CONTEXT": True, "SHOW_QUOTA": False, "SHOW_COST": True,
        },
    },
    "Standard": {
        "desc": "Recommended default",
        "layout": ["path", "branch", "pr", "model", LINEBREAK, "context", "quota", "cost"],
        "flags": {
            "SHOW_BRANCH": True, "SHOW_DIRTY": True, "SHOW_AHEAD_BEHIND": False,
            "SHOW_COMMIT": False, "SHOW_PR": True, "SHOW_CI": False,
            "SHOW_MODEL": True, "SHOW_VERSION": False,
            "SHOW_CONTEXT": True, "SHOW_QUOTA": True, "SHOW_COST": True,
        },
    },
    "Developer": {
        "desc": "Git + CI + vim details",
        "layout": [
            "path", "branch", "commit", "pr", "ci", "model", "vim",
            LINEBREAK, "context", "quota", "cost",
        ],
        "flags": {
            "SHOW_BRANCH": True, "SHOW_DIRTY": True, "SHOW_AHEAD_BEHIND": True,
            "SHOW_COMMIT": True, "SHOW_PR": True, "SHOW_CI": True,
            "SHOW_MODEL": True, "SHOW_VERSION": False,
            "SHOW_CONTEXT": True, "SHOW_QUOTA": True, "SHOW_COST": True,
        },
    },
    "Full": {
        "desc": "Everything enabled",
        "layout": [
            "path", "branch", "commit", "pr", "ci", "model", "version", "vim", "agent",
            LINEBREAK, "context", "quota", "cost",
        ],
        "flags": {
            "SHOW_BRANCH": True, "SHOW_DIRTY": True, "SHOW_AHEAD_BEHIND": True,
            "SHOW_COMMIT": True, "SHOW_PR": True, "SHOW_CI": True,
            "SHOW_MODEL": True, "SHOW_VERSION": True,
            "SHOW_CONTEXT": True, "SHOW_QUOTA": True, "SHOW_COST": True,
        },
    },
}

# ── Config dataclasses ────────────────────────────────────────────────────────
CONF_PATH   = Path.home() / ".claude" / "clickline.conf"
CUSTOM_PATH = Path.home() / ".claude" / "clickline-custom.json"

@dataclass
class CustomItem:
    name:      str
    label:     str
    color:     str = "dim"    # Catppuccin key
    cmd:       str = ""       # shell command → dynamic value (empty = static label)
    link:      str = ""       # OSC-8 URL (may contain {dir}, {branch})
    cache_ttl: int = 30       # seconds to cache cmd output
    condition: str = ""       # shell cmd; must exit 0 to show item

@dataclass
class Config:
    show_flags: dict[str, bool] = field(default_factory=lambda: {
        "SHOW_BRANCH": True, "SHOW_DIRTY": True, "SHOW_AHEAD_BEHIND": False,
        "SHOW_COMMIT": False, "SHOW_PR": True, "SHOW_CI": False,
        "SHOW_MODEL": True, "SHOW_VERSION": False, "SHOW_CONTEXT": True,
        "SHOW_QUOTA": True, "SHOW_COST": True,
    })
    leading_newline:  bool = False
    theme:            str  = "catppuccin-mocha"
    layout:           list[str] = field(default_factory=lambda: [
        "path", "branch", "commit", "pr", "ci", "model", "version", "vim", "agent",
        LINEBREAK,
        "context", "quota", "cost",
    ])
    branch_max_chars: int  = 25
    path_segments:    int  = 2
    path_link_target: str  = "finder"
    pr_cache_ttl:     int  = 60
    ci_cache_ttl:     int  = 30
    quota_cache_ttl:  int  = 60
    custom_items:     dict[str, CustomItem] = field(default_factory=dict)

    # ── load ────────────────────────────────────────────────────────────────
    @classmethod
    def load(cls) -> "Config":
        cfg = cls()
        if CONF_PATH.exists():
            for raw_line in CONF_PATH.read_text().splitlines():
                line = re.sub(r"\s+#.*$", "", raw_line).strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key, val = key.strip(), val.strip()
                if key in cfg.show_flags:
                    cfg.show_flags[key] = val.lower() == "true"
                elif key == "LEADING_NEWLINE":
                    cfg.leading_newline = val.lower() == "true"
                elif key == "THEME":
                    cfg.theme = val if val in THEMES else "catppuccin-mocha"
                elif key == "LAYOUT":
                    items: list[str] = []
                    for tok in val.split():
                        items.append(LINEBREAK if tok == "|" else tok)
                    cfg.layout = items
                elif key == "BRANCH_MAX_CHARS":
                    cfg.branch_max_chars = int(val) if val.isdigit() else 25
                elif key == "PATH_SEGMENTS":
                    cfg.path_segments = int(val) if val.isdigit() else 2
                elif key == "PATH_LINK_TARGET":
                    cfg.path_link_target = val
                elif key == "PR_CACHE_TTL":
                    cfg.pr_cache_ttl = int(val) if val.isdigit() else 60
                elif key == "CI_CACHE_TTL":
                    cfg.ci_cache_ttl = int(val) if val.isdigit() else 30
                elif key == "QUOTA_CACHE_TTL":
                    cfg.quota_cache_ttl = int(val) if val.isdigit() else 60
        if CUSTOM_PATH.exists():
            try:
                raw = json.loads(CUSTOM_PATH.read_text())
                for name, data in raw.items():
                    cfg.custom_items[name] = CustomItem(name=name, **data)
            except (json.JSONDecodeError, TypeError):
                pass
        return cfg

    # ── save ────────────────────────────────────────────────────────────────
    def save(self) -> None:
        CONF_PATH.parent.mkdir(parents=True, exist_ok=True)
        layout_str = " ".join("|" if t == LINEBREAK else t for t in self.layout)
        out = [
            "# clickline config — managed by configure.py",
            "# Run:  python3 ~/.claude/clickline-configure.py  to edit",
            "# Changes take effect on the next Claude Code response",
            "",
            "# ── Features ──────────────────────────────────────────────────────────────────",
        ]
        for k, v in self.show_flags.items():
            out.append(f"{k}={'true' if v else 'false'}")
        out.append(f"LEADING_NEWLINE={'true' if self.leading_newline else 'false'}")
        out.append(f"LAYOUT={layout_str}")
        out.append(f"THEME={self.theme}")
        out += [
            "",
            "# ── Options ───────────────────────────────────────────────────────────────────",
            f"BRANCH_MAX_CHARS={self.branch_max_chars}",
            f"PATH_SEGMENTS={self.path_segments}",
            f"PATH_LINK_TARGET={self.path_link_target}",
            f"PR_CACHE_TTL={self.pr_cache_ttl}",
            f"CI_CACHE_TTL={self.ci_cache_ttl}",
            f"QUOTA_CACHE_TTL={self.quota_cache_ttl}",
            "",
        ]
        CONF_PATH.write_text("\n".join(out))
        if self.custom_items:
            CUSTOM_PATH.write_text(json.dumps(
                {n: {k: v for k, v in vars(item).items() if k != "name"}
                 for n, item in self.custom_items.items()},
                indent=2
            ) + "\n")

# ── Preview renderer ──────────────────────────────────────────────────────────
def build_preview(cfg: Config) -> Text:
    """Build a Rich Text preview that looks like the real statusline bar."""
    P = get_palette(cfg.theme)
    sep   = Text(" │ ", style="#444444")
    dot   = Text(" · ", style="#444444")
    lines_of_text: list[Text] = []
    current: Text = Text()
    first_on_line = True
    prev = ""

    def color_for(name: str) -> str:
        if name in BY_NAME:
            return P.get(BY_NAME[name].color, "#cccccc")
        if name in cfg.custom_items:
            return P.get(cfg.custom_items[name].color, "#444444")
        return "#cccccc"

    def sample_for(name: str) -> str:
        if name in SAMPLES:
            return SAMPLES[name]
        if name in cfg.custom_items:
            return cfg.custom_items[name].label
        return name

    def elem_enabled(name: str) -> bool:
        if name not in BY_NAME:
            return True
        e = BY_NAME[name]
        if e.show_var and not cfg.show_flags.get(e.show_var, True):
            return False
        if e.conditional:
            return False
        return True

    for tok in cfg.layout:
        if tok == LINEBREAK:
            lines_of_text.append(current)
            current = Text()
            first_on_line = True
            prev = ""
            continue

        if not elem_enabled(tok):
            prev = tok
            continue

        val = sample_for(tok)
        clr = color_for(tok)

        if not first_on_line:
            if tok == "branch" and prev == "path":
                current.append_text(dot)
            else:
                current.append_text(sep)

        if tok == "context":
            current.append(val.split("/")[0], style=f"bold {P['gold']}")
            current.append("/" + val.split("/")[1] if "/" in val else "", style="#444444")
        elif tok == "quota":
            parts = val.split(" · ")
            current.append(parts[0], style=f"bold {P['green']}")
            if len(parts) > 1:
                current.append_text(dot)
                current.append(parts[1], style=f"bold {P['peach']}")
        elif tok == "model":
            current.append(val, style=f"bold {clr}")
        elif tok == "cost":
            current.append(val, style=f"bold {P['gold']}")
        elif tok == "branch":
            current.append(val, style=clr)
        else:
            current.append(val, style=clr)

        first_on_line = False
        prev = tok

    lines_of_text.append(current)

    # Mock Claude Code output above the statusline.
    dim = "#555555"
    result = Text()
    result.append("  I'll update the configuration for you.\n\n", style=dim)
    result.append("  \u2713 ", style="#a6e3a1")
    result.append("Config saved to ~/.claude/clickline.conf\n\n", style=dim)

    # Statusline bar.
    for i, lt in enumerate(lines_of_text):
        if i > 0:
            result.append("\n")
        result.append(" ")
        result.append_text(lt)
    return result

# ── Pacing mascot (Claude Code figure in preview) ────────────────────────────
class PacingMascot(Static):
    """The Claude Code mascot pacing back and forth with rotating tip bubbles."""

    TIPS = [
        "Try a preset!",
        "Shift+arrows reorder",
        "[ ] switch lines",
        "Space toggles",
        "Press s to save",
        "Tab switches panes",
        "Press o for options",
    ]

    # Mascot colors (from Claude Code CLI)
    _SPARK = "#b4befe"   # lavender — sparkle
    _STEM  = "#6c7086"   # gray — antenna stem
    _HAT   = "#b4befe"   # lavender — upper pyramid
    _BODY  = "#fab387"   # peach — main body + feet

    # Static body lines: (text, style)
    _LINES = [
        ("    \u273b", None),         # sparkle (colored separately)
        ("    |", _STEM),
        ("   \u259f\u2588\u2599", _HAT),
        (" \u2590\u259b\u2588\u2588\u2588\u259c\u258c", _BODY),
        ("\u259d\u259c\u2588\u2588\u2588\u2588\u2588\u259b\u2598", _BODY),
    ]

    # Feet walk frames (subtle waddle)
    _FEET = [
        ("  \u2598\u2598 \u259d\u259d", _BODY),   # stance 0: normal
        (" \u2598\u2598  \u259d\u259d", _BODY),    # stance 1: stride
    ]

    _RANGE = 20   # chars of horizontal travel
    _FPS   = 3    # 3 frames per second

    DEFAULT_CSS = """
    PacingMascot {
        height: 6;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._pos = 2
        self._dir = 1
        self._step = 0
        self._tip = 0

    def on_mount(self) -> None:
        self.set_interval(1.0 / self._FPS, self._tick)
        self.set_interval(5.0, self._next_tip)

    def _tick(self) -> None:
        self._pos += self._dir
        self._step = (self._step + 1) % 2
        if self._pos >= self._RANGE:
            self._dir = -1
        elif self._pos <= 2:
            self._dir = 1
        self.refresh()

    def _next_tip(self) -> None:
        self._tip = (self._tip + 1) % len(self.TIPS)

    def render(self) -> Text:
        tip = self.TIPS[self._tip]
        pad = " " * self._pos
        result = Text()

        for i, (line, style) in enumerate(self._LINES):
            result.append(pad)
            if i == 0:
                # Sparkle line — color the ✻, append speech bubble
                result.append(line, style=self._SPARK)
                result.append(f"  \u201c{tip}\u201d", style="#444444")
            else:
                result.append(line, style=style)
            result.append("\n")

        # Feet (animated waddle)
        feet_text, feet_style = self._FEET[self._step]
        result.append(pad)
        result.append(feet_text, style=feet_style)

        return result


# ── LayoutEditor widget ───────────────────────────────────────────────────────
class LayoutEditor(Static, can_focus=True):
    """Keyboard-driven reorderable list with line-break management."""

    BINDINGS: ClassVar = [
        Binding("up,k",            "move_cursor(-1)",    "Up",        show=False),
        Binding("down,j",          "move_cursor(1)",     "Down",      show=False),
        Binding("shift+up,K",      "reorder(-1)",        "Shift+Up Move up",   show=True),
        Binding("shift+down,J",    "reorder(1)",         "Shift+Down Move down", show=True),
        Binding("left_square_bracket",  "cross_line(-1)", "[ Prev line", show=True),
        Binding("right_square_bracket", "cross_line(1)",  "] Next line", show=True),
        Binding("n",             "insert_linebreak",   "n Line break",  show=True),
        Binding("d,delete",      "remove_item",        "d Remove",      show=True),
    ]

    class Changed(Message):
        def __init__(self, layout: list[str]) -> None:
            super().__init__()
            self.layout = layout

    items:  reactive[list[str]] = reactive(list, layout=True)
    cursor: reactive[int]       = reactive(0,    layout=True)

    def __init__(self, layout: list[str], **kwargs) -> None:
        super().__init__(**kwargs)
        self.items  = list(layout)
        self.cursor = 0

    # ── rendering ──────────────────────────────────────────────────────────
    def render(self) -> Text:
        P = get_palette(self.app.cfg.theme) if hasattr(self, "app") and hasattr(self.app, "cfg") else get_palette("catppuccin-mocha")
        text = Text()
        for i, tok in enumerate(self.items):
            focused = i == self.cursor
            prefix = "› " if focused else "  "

            if tok == LINEBREAK:
                bar = "─" * 20
                style = ("#666666" if focused else "#333333")
                text.append(f"{prefix}{bar} line break {bar}\n", style=style)
            else:
                if tok in BY_NAME:
                    e = BY_NAME[tok]
                    label = e.label
                    clr = P.get(e.color, "#cccccc")
                    req = f"  {e.requires}" if e.requires else ""
                else:
                    label = tok
                    clr = "#888888"
                    req = "  custom"

                if focused:
                    text.append(prefix, style="#cccccc")
                    text.append(label, style=f"bold {clr}")
                    text.append(f"{req}\n", style="#666666")
                else:
                    text.append(prefix, style="#333333")
                    text.append(label, style=clr)
                    text.append(f"{req}\n", style="#444444")

        if not self.items:
            text.append("  (empty)\n", style="#444444")
        return text

    # ── actions ────────────────────────────────────────────────────────────
    def action_move_cursor(self, delta: int) -> None:
        if not self.items:
            return
        self.cursor = max(0, min(len(self.items) - 1, self.cursor + delta))
        self.refresh()

    def action_reorder(self, delta: int) -> None:
        i = self.cursor
        j = i + delta
        if not (0 <= j < len(self.items)):
            return
        items = list(self.items)
        items[i], items[j] = items[j], items[i]
        self.items  = items
        self.cursor = j
        self.refresh()
        self.post_message(self.Changed(items))

    def action_cross_line(self, delta: int) -> None:
        """Move the element across the nearest line break (up or down)."""
        i = self.cursor
        items = list(self.items)
        if items[i] == LINEBREAK:
            return

        # Find the adjacent line break in the given direction
        if delta > 0:
            # Move element to after the next line break
            try:
                lb = next(j for j in range(i + 1, len(items)) if items[j] == LINEBREAK)
            except StopIteration:
                return  # no line break ahead — append a new one
            elem = items.pop(i)
            items.insert(lb, elem)  # insert after the linebreak
            self.cursor = lb
        else:
            # Move element to before the previous line break
            try:
                lb = next(j for j in range(i - 1, -1, -1) if items[j] == LINEBREAK)
            except StopIteration:
                return  # no line break behind
            elem = items.pop(i)
            items.insert(lb, elem)  # insert before the linebreak
            self.cursor = lb

        self.items = items
        self.refresh()
        self.post_message(self.Changed(items))

    def action_insert_linebreak(self) -> None:
        i = self.cursor
        items = list(self.items)
        if items[i] == LINEBREAK:
            return  # don't double-insert
        items.insert(i + 1, LINEBREAK)
        self.items  = items
        self.cursor = i + 1
        self.refresh()
        self.post_message(self.Changed(items))

    def action_remove_item(self) -> None:
        if not self.items:
            return
        items = list(self.items)
        items.pop(self.cursor)
        self.cursor = max(0, min(self.cursor, len(items) - 1))
        self.items  = items
        self.refresh()
        self.post_message(self.Changed(items))

    def add_element(self, name: str) -> None:
        """Add an element at the end (called from library toggle)."""
        if name in self.items:
            return
        items = list(self.items)
        items.append(name)
        self.items  = items
        self.cursor = len(items) - 1
        self.refresh()
        self.post_message(self.Changed(items))

    def remove_element(self, name: str) -> None:
        """Remove all occurrences of name (called from library toggle)."""
        items = [t for t in self.items if t != name]
        self.cursor = max(0, min(self.cursor, len(items) - 1))
        self.items  = items
        self.refresh()
        self.post_message(self.Changed(items))

# ── Custom item creation dialog ───────────────────────────────────────────────
class CustomItemDialog(Container):
    """Inline form for adding a custom statusline item."""

    class Submitted(Message):
        def __init__(self, item: CustomItem) -> None:
            super().__init__()
            self.item = item

    class Cancelled(Message):
        pass

    DEFAULT_CSS = """
    CustomItemDialog {
        height: auto;
        background: #161616;
        border: solid #333333;
        padding: 1 2;
        margin: 1;
    }
    CustomItemDialog Label {
        margin-bottom: 0;
        color: #666666;
    }
    CustomItemDialog Input {
        margin-bottom: 1;
        background: #252525;
        color: #cccccc;
        border: solid #333333;
    }
    CustomItemDialog Input:focus {
        border: solid #555555;
    }
    CustomItemDialog Button {
        margin-right: 1;
    }
    CustomItemDialog #ci-ok {
        background: #333333;
        color: #cccccc;
        border: none;
    }
    CustomItemDialog #ci-ok:hover {
        background: #444444;
    }
    CustomItemDialog #ci-cancel {
        background: #252525;
        color: #666666;
        border: none;
    }
    CustomItemDialog #ci-cancel:hover {
        background: #333333;
    }
    """

    def compose(self) -> ComposeResult:
        yield Label("Custom item name (identifier, no spaces):")
        yield Input(placeholder="e.g. kube-ctx",  id="ci-name")
        yield Label("Display label:")
        yield Input(placeholder="e.g. ⎈ k8s-prod", id="ci-label")
        yield Label("Shell command (optional — output used as label):")
        yield Input(placeholder="e.g. kubectl config current-context", id="ci-cmd")
        yield Label("Color (sapphire/lavender/mauve/gold/green/peach/red/dim):")
        yield Input(placeholder="dim", id="ci-color")
        yield Label("Link URL (optional, may contain {dir} {branch}):")
        yield Input(placeholder="https://...", id="ci-link")
        with Horizontal():
            yield Button("Add", variant="primary", id="ci-ok")
            yield Button("Cancel", id="ci-cancel")

    @on(Button.Pressed, "#ci-ok")
    def _ok(self) -> None:
        name  = self.query_one("#ci-name",  Input).value.strip()
        label = self.query_one("#ci-label", Input).value.strip()
        color = self.query_one("#ci-color", Input).value.strip() or "dim"
        cmd   = self.query_one("#ci-cmd",   Input).value.strip()
        link  = self.query_one("#ci-link",  Input).value.strip()
        if not name or not name.replace("-", "").replace("_", "").isalnum():
            self.query_one("#ci-name", Input).focus()
            return
        if not label:
            self.query_one("#ci-label", Input).value = name
            label = name
        self.post_message(self.Submitted(
            CustomItem(name=f"custom_{name}", label=label, color=color, cmd=cmd, link=link)
        ))

    @on(Button.Pressed, "#ci-cancel")
    def _cancel(self) -> None:
        self.post_message(self.Cancelled())

# ── Options form ──────────────────────────────────────────────────────────────
class OptionsPanel(Container):
    """Collapsible options panel for non-layout settings."""

    DEFAULT_CSS = """
    OptionsPanel {
        height: auto;
        background: #161616;
        border: solid #2a2a2a;
        padding: 1 2;
        margin: 0 0 1 0;
        display: none;
    }
    OptionsPanel.visible { display: block; }
    OptionsPanel Label {
        color: #666666;
    }
    OptionsPanel Input {
        width: 12;
        background: #252525;
        color: #cccccc;
        border: solid #333333;
    }
    OptionsPanel Input:focus {
        border: solid #555555;
    }
    OptionsPanel Horizontal {
        height: auto;
        margin-bottom: 1;
        align: left middle;
    }
    """

    def compose(self) -> ComposeResult:
        with Horizontal():
            yield Label("Branch max chars: ")
            yield Input("25", id="opt-branch-max", type="integer")
            yield Label("  Path segments: ")
            yield Input("2",  id="opt-path-segs",  type="integer")
        with Horizontal():
            yield Label("Path click opens: ")
            yield Input("finder", id="opt-path-target")
            yield Label("  Leading newline: ")
            yield Input("false", id="opt-leading-nl")
        with Horizontal():
            yield Label("Cache TTLs (PR / CI / Quota): ")
            yield Input("60", id="opt-pr-ttl",    type="integer")
            yield Input("30", id="opt-ci-ttl",    type="integer")
            yield Input("60", id="opt-quota-ttl", type="integer")

    def load(self, cfg: Config) -> None:
        self.query_one("#opt-branch-max",  Input).value = str(cfg.branch_max_chars)
        self.query_one("#opt-path-segs",   Input).value = str(cfg.path_segments)
        self.query_one("#opt-path-target", Input).value = cfg.path_link_target
        self.query_one("#opt-leading-nl",  Input).value = "true" if cfg.leading_newline else "false"
        self.query_one("#opt-pr-ttl",    Input).value = str(cfg.pr_cache_ttl)
        self.query_one("#opt-ci-ttl",    Input).value = str(cfg.ci_cache_ttl)
        self.query_one("#opt-quota-ttl", Input).value = str(cfg.quota_cache_ttl)

    def apply(self, cfg: Config) -> None:
        def _int(eid: str, default: int) -> int:
            v = self.query_one(eid, Input).value.strip()
            return int(v) if v.isdigit() else default
        cfg.branch_max_chars  = _int("#opt-branch-max",  25)
        cfg.path_segments     = _int("#opt-path-segs",    2)
        cfg.path_link_target  = self.query_one("#opt-path-target", Input).value.strip() or "finder"
        cfg.leading_newline   = self.query_one("#opt-leading-nl",  Input).value.strip().lower() == "true"
        cfg.pr_cache_ttl      = _int("#opt-pr-ttl",   60)
        cfg.ci_cache_ttl      = _int("#opt-ci-ttl",   30)
        cfg.quota_cache_ttl   = _int("#opt-quota-ttl",60)

# ── Main application ──────────────────────────────────────────────────────────
class ClicklineApp(App[None]):

    CSS = """
    Screen {
        background: #1a1a1a;
    }

    Header {
        background: #141414;
        color: #888888;
        dock: top;
        height: 1;
    }

    Footer {
        background: #141414;
        color: #444444;
    }
    Footer > .footer--key {
        background: #252525;
        color: #aaaaaa;
    }
    Footer > .footer--description {
        color: #666666;
    }

    /* ── Preview bar (top, full width) ── */
    #preview-bar {
        height: auto;
        max-height: 16;
        background: #111111;
        padding: 0 1;
        border-bottom: solid #2a2a2a;
    }
    #mascot {
        height: 6;
    }
    #preview-text {
        color: #cccccc;
    }

    /* ── Preset bar ── */
    #preset-bar {
        height: auto;
        background: #141414;
        padding: 0 1;
        border-bottom: solid #2a2a2a;
        layout: horizontal;
    }
    #preset-label {
        color: #555555;
        width: auto;
        padding: 0 1 0 0;
    }
    .preset-btn {
        min-width: 12;
        height: 1;
        background: #252525;
        color: #888888;
        border: none;
        margin: 0 0 0 1;
    }
    .preset-btn:hover {
        background: #333333;
        color: #cccccc;
    }
    .preset-btn:focus {
        background: #333333;
        color: #cccccc;
    }

    /* ── Theme bar ── */
    #theme-bar {
        height: auto;
        background: #141414;
        padding: 0 1;
        border-bottom: solid #2a2a2a;
        layout: horizontal;
        overflow-x: auto;
    }
    #theme-label {
        color: #555555;
        width: auto;
        padding: 0 1 0 0;
    }
    .theme-btn {
        min-width: 16;
        height: 1;
        background: #252525;
        color: #888888;
        border: none;
        margin: 0 0 0 1;
    }
    .theme-btn:hover {
        background: #333333;
        color: #cccccc;
    }
    .theme-btn:focus {
        background: #333333;
        color: #cccccc;
    }
    .theme-btn.active {
        background: #333333;
        color: #cccccc;
    }

    /* ── Two-pane editor area ── */
    #main-row {
        height: 1fr;
        layout: horizontal;
    }

    /* ── Layout editor (left, wider) ── */
    #pane-editor {
        width: 1fr;
        background: #1a1a1a;
        border-right: solid #2a2a2a;
        padding: 0 1;
        overflow-y: auto;
    }
    #editor-label {
        color: #555555;
        margin-bottom: 0;
    }
    #editor-widget {
        height: auto;
    }

    /* ── Element library (right, narrower) ── */
    #pane-library {
        width: 30;
        min-width: 24;
        background: #161616;
        padding: 0 1;
    }
    #library-label {
        color: #555555;
        margin-bottom: 0;
    }

    SelectionList {
        background: #161616;
        border: none;
        height: 1fr;
    }
    SelectionList:focus {
        border: none;
    }

    /* ── Custom item button ── */
    #btn-add-custom {
        margin-top: 1;
        width: 100%;
        background: #252525;
        color: #666666;
        border: none;
        min-height: 1;
        height: 1;
    }
    #btn-add-custom:hover {
        background: #333333;
        color: #888888;
    }
    #btn-add-custom:focus {
        background: #333333;
        color: #888888;
    }
    """

    BINDINGS: ClassVar = [
        Binding("s",      "save",           "s Save"),
        Binding("q",      "quit",           "q Quit"),
        Binding("ctrl+s", "save",           "Save",    show=False),
        Binding("p",      "focus_presets",  "p Presets"),
        Binding("t",      "focus_themes",   "t Themes"),
        Binding("o",      "toggle_options", "o Options"),
        Binding("c",      "add_custom",     "c Custom"),
        Binding("tab",    "focus_next",     "Tab Switch pane", show=True),
        Binding("shift+tab", "focus_previous", show=False),
        Binding("escape", "cancel_dialog",  show=False),
        Binding("question_mark", "help",    "? Help"),
    ]

    def __init__(self, cfg: Config) -> None:
        super().__init__()
        self.cfg = cfg

    # ── compose ────────────────────────────────────────────────────────────
    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)

        # ── Options panel (hidden by default) ────────────────────────────
        yield OptionsPanel(id="options-panel")

        # ── Preview bar (full width, top) ────────────────────────────────
        with Container(id="preview-bar"):
            yield PacingMascot(id="mascot")
            yield Static(build_preview(self.cfg), id="preview-text")

        # ── Preset bar ───────────────────────────────────────────────────
        with Horizontal(id="preset-bar"):
            yield Label("PRESETS", id="preset-label")
            for name, info in PRESETS.items():
                yield Button(
                    f"{name}",
                    id=f"preset-{name.lower()}",
                    classes="preset-btn",
                    tooltip=info["desc"],
                )

        # ── Theme bar ─────────────────────────────────────────────────────
        with Horizontal(id="theme-bar"):
            yield Label("THEME", id="theme-label")
            for tname in THEME_NAMES:
                classes = "theme-btn active" if tname == self.cfg.theme else "theme-btn"
                yield Button(
                    tname,
                    id=f"theme-{tname}",
                    classes=classes,
                )

        # ── Two-pane editor area ─────────────────────────────────────────
        with Horizontal(id="main-row"):

            # Left: layout editor (wider)
            with ScrollableContainer(id="pane-editor"):
                yield Label("LAYOUT  \u2502  \u2191\u2193 navigate  Shift+\u2191\u2193 reorder  n break  d delete", id="editor-label")
                yield LayoutEditor(self.cfg.layout, id="editor-widget")

            # Right: element library (narrower)
            with Vertical(id="pane-library"):
                yield Label("ELEMENTS  \u2502  Space toggle", id="library-label")
                yield self._build_library()
                yield Button("+ Custom element", id="btn-add-custom")

        yield Footer()

    def _build_library(self) -> SelectionList[str]:
        in_layout = set(self.cfg.layout)
        selections: list[Selection] = []
        for e in BUILTINS:
            checked = e.name in in_layout
            req = f" [[{e.requires}]]" if e.requires else ""
            cond = " [[conditional]]" if e.conditional else ""
            label = f"{e.label}{req}{cond}"
            selections.append(Selection(label, e.name, checked))
        for item in self.cfg.custom_items.values():
            checked = item.name in in_layout
            selections.append(Selection(f"{item.label} [[custom]]", item.name, checked))
        return SelectionList[str](*selections, id="library")

    # ── on_mount ────────────────────────────────────────────────────────
    def on_mount(self) -> None:
        self.query_one("#options-panel", OptionsPanel).load(self.cfg)
        self.query_one("#editor-widget", LayoutEditor).focus()
        self.title = "clickline configurator"
        self.sub_title = str(CONF_PATH)
        self.notify(
            "Try a preset (p) or customise below. Press s to save.",
            title="Welcome",
            timeout=5,
        )

    # ── react to layout changes ──────────────────────────────────────────
    @on(LayoutEditor.Changed)
    def _layout_changed(self, event: LayoutEditor.Changed) -> None:
        self.cfg.layout = event.layout
        self._sync_library_to_layout()
        self._refresh_preview()

    def _sync_library_to_layout(self) -> None:
        """Keep library checkboxes in sync after layout editor changes."""
        in_layout = set(self.cfg.layout)
        lib = self.query_one("#library", SelectionList)
        for opt in lib.options:
            val = opt.value
            if val in in_layout:
                lib.select(val)
            else:
                lib.deselect(val)

    @on(SelectionList.SelectionToggled, "#library")
    def _library_toggled(self, event: SelectionList.SelectionToggled) -> None:
        name = event.selection.value
        editor = self.query_one("#editor-widget", LayoutEditor)
        if name in event.selection_list.selected:
            editor.add_element(name)
        else:
            editor.remove_element(name)
        self.cfg.layout = editor.items
        self._refresh_preview()

    def _refresh_preview(self) -> None:
        self.query_one("#preview-text", Static).update(build_preview(self.cfg))

    # ── actions ──────────────────────────────────────────────────────────
    def action_save(self) -> None:
        opts = self.query_one("#options-panel", OptionsPanel)
        if "visible" in opts.classes:
            opts.apply(self.cfg)
        self.cfg.save()
        self.notify(f"Saved to {CONF_PATH}", title="Config saved", timeout=3)

    def action_quit(self) -> None:
        self.exit()

    def action_toggle_options(self) -> None:
        opts = self.query_one("#options-panel", OptionsPanel)
        opts.toggle_class("visible")

    def action_add_custom(self) -> None:
        if self.query("#custom-dialog"):
            return
        dialog = CustomItemDialog(id="custom-dialog")
        self.query_one("#pane-editor").mount(dialog)
        dialog.query_one("#ci-name", Input).focus()

    def action_cancel_dialog(self) -> None:
        for d in self.query("#custom-dialog"):
            d.remove()
        self.query_one("#editor-widget", LayoutEditor).focus()

    def action_focus_presets(self) -> None:
        """Focus the first preset button."""
        try:
            first = self.query_one("#preset-bar .preset-btn", Button)
            first.focus()
        except Exception:
            pass

    def action_focus_themes(self) -> None:
        """Focus the first theme button."""
        try:
            first = self.query_one("#theme-bar .theme-btn", Button)
            first.focus()
        except Exception:
            pass

    def action_help(self) -> None:
        self.notify(
            "Tab / Shift+Tab  switch panes\n"
            "Space            toggle in library\n"
            "\u2191\u2193 / k j         cursor\n"
            "Shift+\u2191\u2193 / K J   reorder element\n"
            "[ ]              move across lines\n"
            "n                insert line break\n"
            "d / Delete       remove element\n"
            "p                presets\n"
            "o                options panel\n"
            "c                custom item\n"
            "s                save\n"
            "q                quit",
            title="Keyboard shortcuts",
            timeout=15,
        )

    # ── preset handling ──────────────────────────────────────────────────
    @on(Button.Pressed, ".preset-btn")
    def _preset_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id or ""
        # Extract preset name from id like "preset-standard"
        key = btn_id.replace("preset-", "")
        for name in PRESETS:
            if name.lower() == key:
                self._apply_preset(name)
                return

    def _apply_preset(self, name: str) -> None:
        preset = PRESETS[name]
        self.cfg.layout = list(preset["layout"])
        self.cfg.show_flags.update(preset["flags"])
        # Update editor widget
        editor = self.query_one("#editor-widget", LayoutEditor)
        editor.items = list(self.cfg.layout)
        editor.cursor = 0
        editor.refresh()
        # Sync library checkboxes
        self._sync_library_to_layout()
        self._refresh_preview()
        self.notify(f"Loaded \"{name}\" preset \u2014 press s to save", timeout=4)
        # Return focus to editor
        editor.focus()

    # ── theme handling ────────────────────────────────────────────────────
    @on(Button.Pressed, ".theme-btn")
    def _theme_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id or ""
        theme_name = btn_id.replace("theme-", "", 1)
        if theme_name in THEMES:
            self.cfg.theme = theme_name
            # Update active class on theme buttons
            for btn in self.query(".theme-btn"):
                btn.remove_class("active")
            event.button.add_class("active")
            self._refresh_preview()
            # Re-render layout editor to reflect new theme colors
            self.query_one("#editor-widget", LayoutEditor).refresh()
            self.notify(f"Theme: {theme_name} — press s to save", timeout=4)

    # ── + Custom button click ────────────────────────────────────────────
    @on(Button.Pressed, "#btn-add-custom")
    def _btn_add_custom(self, _: Button.Pressed) -> None:
        self.action_add_custom()

    # ── custom item dialog handlers ──────────────────────────────────────
    @on(CustomItemDialog.Submitted)
    def _custom_submitted(self, event: CustomItemDialog.Submitted) -> None:
        item = event.item
        self.cfg.custom_items[item.name] = item
        lib = self.query_one("#library", SelectionList)
        lib.add_option(Selection(f"{item.label} [[custom]]", item.name, True))
        editor = self.query_one("#editor-widget", LayoutEditor)
        editor.add_element(item.name)
        self.action_cancel_dialog()
        self.notify(f"Added '{item.label}' — press s to save", timeout=5)

    @on(CustomItemDialog.Cancelled)
    def _custom_cancelled(self, _: CustomItemDialog.Cancelled) -> None:
        self.action_cancel_dialog()


# ── Entry point ───────────────────────────────────────────────────────────────
def main() -> None:
    cfg = Config.load()
    if "--save-and-exit" in sys.argv:
        cfg.save()
        print(f"Config saved to {CONF_PATH}")
        return
    ClicklineApp(cfg).run()

if __name__ == "__main__":
    main()
