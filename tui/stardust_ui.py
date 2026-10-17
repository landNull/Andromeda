#!/usr/bin/env python3
"""Stardust Textual TUI — Aegir-style front-end over the shell CLI.

Does not reimplement backup, upgrade, or site logic.
Shells out to the existing `stardust` binary and displays the results.
Do not run as root.
"""

from __future__ import annotations

import asyncio
import os
import subprocess

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Input,
    Label,
    Log,
    Static,
    TabbedContent,
    TabPane,
)
from textual.binding import Binding
from textual.reactive import reactive

STARDUST_BIN = os.environ.get("STARDUST_BIN", "stardust")


def run_stardust(*args: str, timeout: int = 60) -> tuple[int, str]:
    """Run a stardust command and return (exit_code, combined_output)."""
    try:
        result = subprocess.run(
            [STARDUST_BIN, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        out = (result.stdout or "") + (result.stderr or "")
        return result.returncode, out.strip() or "(no output)"
    except FileNotFoundError:
        return 127, f"{STARDUST_BIN} not found on PATH"
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


def parse_inventory(text: str) -> list[dict[str, str]]:
    rows = []
    for line in text.splitlines():
        if not line.startswith("platform="):
            continue
        item: dict[str, str] = {}
        for field in line.split():
            if "=" in field:
                k, v = field.split("=", 1)
                item[k] = v
        if item.get("platform") and item.get("product"):
            rows.append(item)
    return rows


def parse_platforms(text: str) -> list[dict[str, str]]:
    """Best-effort parse of `stardust list` output."""
    plats: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in text.splitlines():
        if line.startswith("platform"):
            parts = line.split()
            name = parts[1] if len(parts) > 1 else "?"
            current = {"name": name, "branch": "", "products": ""}
            for p in parts[2:]:
                if p.startswith("branch="):
                    current["branch"] = p.split("=", 1)[1]
            plats.append(current)
        elif current and line.strip().startswith("products"):
            current["products"] = line.split("products", 1)[-1].strip()
    return plats


class Sidebar(VerticalScroll):
    """Right sidebar: queues + navigation (Aegir Eldir style)."""

    DEFAULT_CSS = """
    Sidebar {
        width: 36;
        dock: right;
        background: $panel;
        border-left: solid $primary;
        padding: 1;
    }
    Sidebar .title {
        text-style: bold;
        color: $accent;
        margin-bottom: 1;
    }
    Sidebar Button {
        width: 100%;
        margin: 0 0 1 0;
    }
    """

    def compose(self) -> ComposeResult:
        yield Label("Queues", classes="title")
        yield Log(id="queues", highlight=True, max_lines=12)
        yield Label("Navigation", classes="title")
        yield Button("Sites", id="nav-sites", variant="primary")
        yield Button("Platforms", id="nav-platforms")
        yield Button("Doctor", id="nav-doctor")
        yield Button("Refresh", id="nav-refresh", variant="success")
        yield Button("Quit", id="nav-quit", variant="error")


class SiteForm(Vertical):
    """Minimal site-add form (shells out; does not reimplement)."""

    DEFAULT_CSS = """
    SiteForm {
        height: auto;
        padding: 1;
        border: solid $primary;
        margin: 1;
    }
    SiteForm Input {
        margin-bottom: 1;
    }
    """

    def compose(self) -> ComposeResult:
        yield Label("Add site (stardust site-add)")
        yield Input(placeholder="Platform", id="form-plat")
        yield Input(placeholder="Product", id="form-prod")
        yield Input(placeholder="Host (optional)", id="form-host")
        yield Button("Create site", id="form-create", variant="success")


class StardustApp(App[None]):
    """Aegir-shaped Textual front-end for Stardust."""

    TITLE = "Stardust"
    SUB_TITLE = "CLI control plane"

    CSS = """
    Screen {
        background: $surface;
    }
    Header {
        background: $primary;
    }
    #main {
        height: 1fr;
        padding: 1;
    }
    DataTable {
        height: 1fr;
    }
    #status {
        dock: bottom;
        height: 1;
        background: $panel;
        color: $text-muted;
        padding: 0 2;
    }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("d", "doctor", "Doctor"),
        Binding("s", "sites", "Sites"),
        Binding("p", "platforms", "Platforms"),
    ]

    status = reactive("ready")

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal():
            with Vertical(id="main"):
                with TabbedContent(id="tabs"):
                    with TabPane("Sites", id="tab-sites"):
                        yield DataTable(id="sites-table", cursor_type="row", zebra_stripes=True)
                        yield SiteForm(id="site-form")
                    with TabPane("Platforms", id="tab-platforms"):
                        yield DataTable(id="platforms-table", cursor_type="row", zebra_stripes=True)
                    with TabPane("Output", id="tab-output"):
                        yield Log(id="output", highlight=True)
            yield Sidebar()
        yield Static("", id="status")
        yield Footer()

    def on_mount(self) -> None:
        sites = self.query_one("#sites-table", DataTable)
        sites.add_columns("Platform", "Product", "Branch", "Backup")
        plats = self.query_one("#platforms-table", DataTable)
        plats.add_columns("Platform", "Branch", "Products")
        self.action_refresh()

    def watch_status(self, value: str) -> None:
        self.query_one("#status", Static).update(value)

    def action_refresh(self) -> None:
        self.status = "refreshing…"
        self.run_worker(self._refresh_all, exclusive=True)

    def action_doctor(self) -> None:
        self.run_worker(self._run_and_show("doctor"), exclusive=True)

    def action_sites(self) -> None:
        self.query_one("#tabs", TabbedContent).active = "tab-sites"

    def action_platforms(self) -> None:
        self.query_one("#tabs", TabbedContent).active = "tab-platforms"

    async def _refresh_all(self) -> None:
        # Queues
        _rc, log_out = await asyncio.to_thread(run_stardust, "log", "8")
        queues = self.query_one("#queues", Log)
        queues.clear()
        for line in log_out.splitlines()[-8:]:
            queues.write(line)

        # Sites from inventory
        _rc, inv = await asyncio.to_thread(run_stardust, "inventory")
        sites = self.query_one("#sites-table", DataTable)
        sites.clear()
        for row in parse_inventory(inv):
            sites.add_row(
                row.get("platform", ""),
                row.get("product", ""),
                row.get("branch", ""),
                row.get("backup", ""),
            )

        # Platforms from list
        _rc, lst = await asyncio.to_thread(run_stardust, "list")
        plats = self.query_one("#platforms-table", DataTable)
        plats.clear()
        for row in parse_platforms(lst):
            plats.add_row(row.get("name", ""), row.get("branch", ""), row.get("products", ""))

        self.status = "ready  (q quit  r refresh  d doctor)"

    async def _run_and_show(self, *args: str) -> None:
        self.status = f"running: stardust {' '.join(args)}"
        rc, out = await asyncio.to_thread(run_stardust, *args)
        output = self.query_one("#output", Log)
        output.clear()
        output.write(f"$ stardust {' '.join(args)}  (exit {rc})\n")
        output.write(out)
        self.query_one("#tabs", TabbedContent).active = "tab-output"
        self.status = f"done (exit {rc})"

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id or ""
        if bid == "nav-quit":
            self.exit()
        elif bid == "nav-refresh":
            self.action_refresh()
        elif bid == "nav-doctor":
            self.action_doctor()
        elif bid == "nav-sites":
            self.action_sites()
        elif bid == "nav-platforms":
            self.action_platforms()
        elif bid == "form-create":
            plat = self.query_one("#form-plat", Input).value.strip()
            prod = self.query_one("#form-prod", Input).value.strip()
            host = self.query_one("#form-host", Input).value.strip()
            if not plat or not prod:
                self.status = "platform and product required"
                return
            args = ["site-add", plat, prod]
            if host:
                args += ["--host", host]
            self.run_worker(self._run_and_show(*args), exclusive=True)


def main() -> None:
    if os.geteuid() == 0 or os.environ.get("SUDO_USER"):
        raise SystemExit("stardust ui: do not run as root or under sudo")
    StardustApp().run()


if __name__ == "__main__":
    main()
