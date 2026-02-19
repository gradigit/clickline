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

# ── Catppuccin Mocha ──────────────────────────────────────────────────────────
PALETTE = {
    # accents
    "sapphire":  "#74c7ec",
    "lavender":  "#b4befe",
    "blue":      "#89b4fa",
    "mauve":     "#cba6f7",
    "pink":      "#f5c2e7",
    "gold":      "#f9e2af",
    "green":     "#a6e3a1",
    "teal":      "#94e2d5",
    "peach":     "#fab387",
    "red":       "#f38ba8",
    "flamingo":  "#f2cdcd",
    "rosewater": "#f5e0dc",
    # neutrals
    "text":      "#cdd6f4",
    "subtext1":  "#bac2de",
    "subtext0":  "#a6adc8",
    "overlay2":  "#9399b2",
    "overlay1":  "#7f849c",
    "overlay0":  "#6c7086",
    "surface2":  "#585b70",
    "surface1":  "#45475a",
    "surface0":  "#313244",
    "base":      "#1e1e2e",
    "mantle":    "#181825",
    "crust":     "#11111b",
    # semantic aliases used by render code
    "dim":       "#45475a",
    "sep":       "#585b70",
    "label":     "#6c7086",
}

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
    P = PALETTE
    sep   = Text(" │ ", style=P["surface2"])
    dot   = Text(" · ", style=P["surface2"])
    lines_of_text: list[Text] = []
    current: Text = Text()
    first_on_line = True
    prev = ""

    def color_for(name: str) -> str:
        if name in BY_NAME:
            return P.get(BY_NAME[name].color, P["text"])
        if name in cfg.custom_items:
            return P.get(cfg.custom_items[name].color, P["dim"])
        return P["text"]

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
            current.append("/" + val.split("/")[1] if "/" in val else "", style=P["surface2"])
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

    # Render as bare statusline text — no "Line N:" labels.
    # Each line gets a leading space for padding, just like the real statusline.
    result = Text()
    for i, lt in enumerate(lines_of_text):
        if i > 0:
            result.append("\n")
        result.append(" ", style=P["base"])
        result.append_text(lt)
    return result

# ── LayoutEditor widget ───────────────────────────────────────────────────────
class LayoutEditor(Static, can_focus=True):
    """Keyboard-driven reorderable list with line-break management."""

    BINDINGS: ClassVar = [
        Binding("up,k",            "move_cursor(-1)",    "Up",        show=False),
        Binding("down,j",          "move_cursor(1)",     "Down",      show=False),
        Binding("shift+up,K",      "reorder(-1)",        "⇧↑ Move",  show=True),
        Binding("shift+down,J",    "reorder(1)",         "⇧↓ Move",  show=True),
        Binding("left_square_bracket",  "cross_line(-1)", "[ Line",   show=True),
        Binding("right_square_bracket", "cross_line(1)",  "] Line",   show=True),
        Binding("n",             "insert_linebreak",   "Break",      show=True),
        Binding("d,delete",      "remove_item",        "Del",        show=True),
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
        P = PALETTE
        text = Text()
        for i, tok in enumerate(self.items):
            focused = i == self.cursor
            prefix = "▶ " if focused else "  "

            if tok == LINEBREAK:
                bar = "─" * 24
                style = (f"bold {P['peach']}" if focused else P["dim"])
                text.append(f"{prefix}{bar} ↵ line break {bar}\n", style=style)
            else:
                if tok in BY_NAME:
                    e = BY_NAME[tok]
                    label = e.label
                    clr = P.get(e.color, P["text"])
                    req = f"  [{e.requires}]" if e.requires else ""
                else:
                    label = tok
                    clr = P["mauve"]
                    req = "  [custom]"

                bg   = " on " + P["surface1"] if focused else ""
                style = f"bold {clr}{bg}" if focused else clr
                text.append(f"{prefix}", style=P["sep"] if not focused else "bold white")
                text.append(f"{label}{req}\n", style=style)

        if not self.items:
            text.append("  (empty — add elements from the library)\n", style=P["dim"])
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
        background: #181825;
        border: tall #cba6f7 40%;
        padding: 1 2;
        margin: 1;
    }
    CustomItemDialog Label {
        margin-bottom: 0;
        color: #a6adc8;
    }
    CustomItemDialog Input {
        margin-bottom: 1;
        background: #313244;
        color: #cdd6f4;
        border: tall #45475a;
    }
    CustomItemDialog Input:focus {
        border: tall #cba6f7;
    }
    CustomItemDialog Button {
        margin-right: 1;
    }
    CustomItemDialog #ci-ok {
        background: #cba6f7;
        color: #1e1e2e;
        border: none;
    }
    CustomItemDialog #ci-ok:hover {
        background: #b4befe;
    }
    CustomItemDialog #ci-cancel {
        background: #313244;
        color: #a6adc8;
        border: none;
    }
    CustomItemDialog #ci-cancel:hover {
        background: #45475a;
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
        background: #181825;
        border: tall #45475a;
        padding: 1 2;
        margin: 0 0 1 0;
        display: none;
    }
    OptionsPanel.visible { display: block; }
    OptionsPanel Label {
        color: #a6adc8;
    }
    OptionsPanel Input {
        width: 12;
        background: #313244;
        color: #cdd6f4;
        border: tall #45475a;
    }
    OptionsPanel Input:focus {
        border: tall #cba6f7;
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
        background: #1e1e2e;
    }

    Header {
        background: #181825;
        color: #cba6f7;
        dock: top;
        height: 1;
    }

    Footer {
        background: #181825;
        color: #585b70;
    }
    Footer > .footer--key {
        background: #313244;
        color: #cba6f7;
    }
    Footer > .footer--description {
        color: #a6adc8;
    }

    /* ── Preview bar (top, full width) ── */
    #preview-bar {
        height: auto;
        max-height: 6;
        background: #11111b;
        padding: 1 2;
        border-bottom: solid #313244;
    }
    #preview-label {
        color: #45475a;
        text-style: bold;
        margin-bottom: 0;
    }
    #preview-text {
        color: #cdd6f4;
    }

    /* ── Two-pane editor area ── */
    #main-row {
        height: 1fr;
        layout: horizontal;
    }

    /* ── Layout editor (left, wider) ── */
    #pane-editor {
        width: 1fr;
        background: #1e1e2e;
        border-right: solid #313244;
        padding: 1 2;
        overflow-y: auto;
    }
    #pane-editor:focus-within {
        border-right: solid #45475a;
    }
    #editor-label {
        color: #6c7086;
        text-style: bold;
        margin-bottom: 1;
    }
    #editor-widget {
        height: auto;
    }
    #editor-widget:focus {
        background: #1e1e2e;
    }

    /* ── Element library (right, narrower) ── */
    #pane-library {
        width: 30;
        min-width: 24;
        background: #181825;
        padding: 1 1;
    }
    #pane-library:focus-within {
        background: #181825;
    }
    #library-label {
        color: #6c7086;
        text-style: bold;
        margin-bottom: 1;
    }

    SelectionList {
        background: #181825;
        border: none;
        height: 1fr;
    }
    SelectionList:focus {
        border: none;
    }
    SelectionList > .selection-list--button {
        color: #cdd6f4;
    }

    /* ── Custom item button ── */
    #btn-add-custom {
        margin-top: 1;
        width: 100%;
        background: #313244;
        color: #cba6f7;
        border: none;
        min-height: 1;
        height: 1;
    }
    #btn-add-custom:hover {
        background: #45475a;
        color: #b4befe;
    }
    #btn-add-custom:focus {
        background: #45475a;
    }
    """

    BINDINGS: ClassVar = [
        Binding("s",      "save",           "Save"),
        Binding("q",      "quit",           "Quit"),
        Binding("ctrl+s", "save",           "Save",    show=False),
        Binding("o",      "toggle_options", "Options"),
        Binding("c",      "add_custom",     "Custom"),
        Binding("tab",    "focus_next",     show=False),
        Binding("shift+tab", "focus_previous", show=False),
        Binding("escape", "cancel_dialog",  show=False),
        Binding("question_mark", "help",    "?Help"),
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
            yield Label("PREVIEW", id="preview-label")
            yield Static(build_preview(self.cfg), id="preview-text")

        # ── Two-pane editor area ─────────────────────────────────────────
        with Horizontal(id="main-row"):

            # Left: layout editor (wider)
            with ScrollableContainer(id="pane-editor"):
                yield Label("LAYOUT", id="editor-label")
                yield LayoutEditor(self.cfg.layout, id="editor-widget")

            # Right: element library (narrower)
            with Vertical(id="pane-library"):
                yield Label("ELEMENTS", id="library-label")
                yield self._build_library()
                yield Button("+ Custom", id="btn-add-custom")

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
        self.title = "clickline"
        self.sub_title = str(CONF_PATH)

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

    def action_help(self) -> None:
        self.notify(
            "Tab / Shift+Tab  switch panes\n"
            "Space            toggle in library\n"
            "↑↓ / k j         cursor\n"
            "Shift+↑↓ / K J   reorder element\n"
            "[ ]              move across lines\n"
            "n                insert line break\n"
            "d / Delete       remove element\n"
            "o                options panel\n"
            "c                custom item\n"
            "s                save\n"
            "q                quit",
            title="Keyboard shortcuts",
            timeout=15,
        )

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
