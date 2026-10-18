#!/usr/bin/env python3
"""Stardust Textual TUI — Eldir-shaped front-end over the shell CLI.

Layout follows Aegir Eldir (navy header, primary tabs, right sidebar
Queues + Navigation, main content table). Does not reimplement
backup, upgrade, or site logic — shells out to the stardust binary.
Do not run as root.
"""

from __future__ import annotations

import asyncio
import os
import re
import subprocess
import traceback
from datetime import datetime, timezone

UI_LOG = os.environ.get("STARDUST_UI_LOG", "/tmp/stardust-ui.log")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def ui_log(msg: str) -> None:
    """Append one line to the TUI debug log. Never log passwords."""
    try:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(UI_LOG, "a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {msg}\n")
    except OSError:
        pass

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Input,
    Label,
    Log,
    Select,
    Static,
    TabbedContent,
    TabPane,
)
from textual.binding import Binding
from textual.reactive import reactive
from rich.text import Text

STARDUST_BIN = os.environ.get("STARDUST_BIN", "stardust")


def run_stardust(*args: str, timeout: int = 60) -> tuple[int, str]:
    """Capture a short stardust command (list, inventory, log, doctor)."""
    try:
        result = subprocess.run(
            [STARDUST_BIN, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            env={**os.environ, "PYTHONUNBUFFERED": "1"},
        )
        out = (result.stdout or "") + (result.stderr or "")
        return result.returncode, out.strip() or "(no output)"
    except FileNotFoundError:
        return 127, f"{STARDUST_BIN} not found on PATH"
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


async def stream_stardust(app: "StardustApp", *args: str) -> int:
    """Run stardust and write each line to the Output log as it arrives."""
    log = app.query_one("#output", Log)
    ui_log(f"stream start: {' '.join(args)}")
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    if app.sudo_askpass:
        env["STARDUST_SUDO_ASKPASS"] = app.sudo_askpass
        env["SUDO_ASKPASS"] = app.sudo_askpass
    try:
        proc = await asyncio.create_subprocess_exec(
            STARDUST_BIN,
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            stdin=asyncio.subprocess.DEVNULL,
            start_new_session=True,
            env=env,
        )
    except FileNotFoundError:
        emit(app, f"{STARDUST_BIN} not found on PATH")
        return 127
    ui_log(f"stream pid={proc.pid} bin={STARDUST_BIN}")
    emit(app, f"(pid {proc.pid})")
    assert proc.stdout is not None
    while True:
        try:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=15)
        except asyncio.TimeoutError:
            ui_log(f"stream pid={proc.pid} still waiting (no output 15s)")
            emit(app, "(still running — no output for 15s)")
            continue
        if not line:
            break
        text = ANSI.sub("", line.decode(errors="replace")).rstrip("\n")
        ui_log(f"stream: {text}")
        emit(app, text)
    return await proc.wait()


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


def platform_exists(name: str) -> bool:
    """True if the platform directory is on this host. No shell-out."""
    return os.path.isdir(os.path.join("/srv/platforms", name))


def out(log: Log, text: str) -> None:
    """One line each. OK green, WARNING yellow, FAILURE red."""
    for part in re.split(r"[\r\n]+", text):
        if not part:
            continue
        low = part.lower()
        if part.startswith("✗") or any(w in low for w in ("fail", "error", "refused", "not ready", "exit 1", "exit 2")):
            line = Text.assemble(("FAILURE ", "bold red"), (part, "red"))
        elif part.startswith("⚠") or any(w in low for w in ("warn", "warning", "advisory")):
            line = Text.assemble(("WARNING ", "bold yellow"), (part, "yellow"))
        elif part.startswith("✓") or any(w in low for w in (" ok", "ok ", "ready", "success", "exit 0", "deleted", "exists")):
            line = Text.assemble(("OK ", "bold green"), (part, "green"))
        else:
            line = part
        log.write_line(line)


def emit(app: "StardustApp", text: str) -> None:
    """Write to the log modal if it is open, and always to the Output tab."""
    screen = app.screen
    if isinstance(screen, LogModal):
        out(screen.query_one("#modal-log", Log), text)
    out(app.query_one("#output", Log), text)


def set_progress(app: "StardustApp", done: int, total: int, label: str) -> None:
    """Progress bar in the log modal, if it is open."""
    width = 20
    filled = int(width * done / total) if total else 0
    bar = "#" * filled + "-" * (width - filled)
    text = f"[{bar}] {done}/{total} {label}"
    screen = app.screen
    if isinstance(screen, LogModal):
        screen.query_one("#log-progress", Static).update(text)


async def spin(app: "StardustApp", label: str, stop: asyncio.Event) -> None:
    """Animate the status line until stop is set."""
    frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    i = 0
    while not stop.is_set():
        app.status = f"{frames[i % len(frames)]} {label}"
        i += 1
        await asyncio.sleep(0.12)


class LogModal(ModalScreen[None]):
    """Scrolling command log over the form. X in the upper right closes it."""

    DEFAULT_CSS = """
    LogModal {
        align: center middle;
    }
    LogModal #log-box {
        width: 92%;
        height: 86%;
        border: solid $primary;
        background: $surface;
        padding: 0 1 1 1;
    }
    LogModal #log-head {
        height: 3;
        padding: 0 1;
    }
    LogModal #log-x {
        dock: right;
        width: 5;
        min-width: 5;
    }
    LogModal Log {
        height: 1fr;
        border: solid $panel;
    }
    """

    def __init__(self, title: str) -> None:
        super().__init__()
        self.log_title = title

    def compose(self) -> ComposeResult:
        with Vertical(id="log-box"):
            with Horizontal(id="log-head"):
                yield Label(self.log_title)
                yield Button("x", id="log-x", variant="error")
            yield Static("[--------------------] 0/3 waiting", id="log-progress")
            yield Log(id="modal-log", highlight=True)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "log-x":
            self.dismiss()


class SudoModal(ModalScreen[str | None]):
    """Ask for the sudo password. Never logged. Empty dismisses."""

    DEFAULT_CSS = """
    SudoModal {
        align: center middle;
    }
    SudoModal Vertical {
        width: 50;
        height: auto;
        padding: 1 2;
        border: solid $primary;
        background: $panel;
    }
    SudoModal Input {
        margin: 1 0;
    }
    """

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("sudo password")
            yield Label("For host commands only. Bee is not a login.")
            yield Input(placeholder="password", password=True, id="sudo-pass")
            yield Button("OK", id="sudo-ok", variant="primary")
            yield Button("Cancel", id="sudo-cancel")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "sudo-ok":
            self.dismiss(self.query_one("#sudo-pass", Input).value)
        else:
            self.dismiss(None)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value)


class MigrateModal(ModalScreen[str | None]):
    """Pick promote target. devel -> test, or test -> live."""

    DEFAULT_CSS = """
    MigrateModal {
        align: center middle;
    }
    MigrateModal Vertical {
        width: 40;
        height: auto;
        padding: 1 2;
        border: solid $primary;
        background: $panel;
    }
    MigrateModal Button {
        margin: 0 0 1 0;
    }
    """

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Migrate platform")
            yield Button("devel → test", id="mig-test", variant="primary")
            yield Button("test → live", id="mig-live", variant="warning")
            yield Button("Cancel", id="mig-cancel")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "mig-test":
            self.dismiss("test")
        elif event.button.id == "mig-live":
            self.dismiss("live")
        else:
            self.dismiss(None)


class DeleteConfirmModal(ModalScreen[bool]):
    """First confirm: Yes or Cancel."""

    DEFAULT_CSS = """
    DeleteConfirmModal { align: center middle; }
    DeleteConfirmModal Vertical {
        width: 48; height: auto; padding: 1 2;
        border: solid $error; background: $panel;
    }
    DeleteConfirmModal Button { margin: 0 0 1 0; }
    """

    def __init__(self, plat: str, prod: str) -> None:
        super().__init__()
        self.plat = plat
        self.prod = prod

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(f"Delete site {self.plat}/{self.prod}?")
            yield Button("Yes", id="del-yes", variant="error")
            yield Button("Cancel", id="del-cancel")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "del-yes")


class DeleteTypeModal(ModalScreen[bool]):
    """Second confirm: must type DELETE."""

    DEFAULT_CSS = """
    DeleteTypeModal { align: center middle; }
    DeleteTypeModal Vertical {
        width: 52; height: auto; padding: 1 2;
        border: solid $error; background: $panel;
    }
    DeleteTypeModal Input { margin: 1 0; }
    DeleteTypeModal Button { margin: 0 0 1 0; }
    """

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Are you sure you want to delete?")
            yield Label("Type DELETE in the field, then Confirm.")
            yield Input(placeholder="DELETE", id="del-word")
            yield Button("Confirm", id="del-confirm", variant="error")
            yield Button("Cancel", id="del-cancel")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id != "del-confirm":
            self.dismiss(False)
            return
        word = self.query_one("#del-word", Input).value.strip()
        self.dismiss(word == "DELETE")


class SiteForm(Vertical):
    """Create-site form. Maps to stardust site-add PLATFORM PRODUCT [--host]."""

    DEFAULT_CSS = """
    SiteForm {
        height: auto;
        padding: 1;
        border: solid $primary;
        margin: 0 0 1 0;
    }
    SiteForm Input {
        margin-bottom: 1;
    }
    """

    def compose(self) -> ComposeResult:
        yield Label("Create Site")
        yield Input(placeholder="Platform", id="form-plat")
        yield Input(placeholder="Site Name", id="form-prod")
        yield Input(placeholder="Host (optional, defaults to SiteName.devel)", id="form-host")
        yield Button("Create Site", id="form-create", variant="success")


class StardustApp(App[None]):
    """Eldir-shaped Textual front-end for Stardust."""

    TITLE = "Stardust"
    SUB_TITLE = "aegir-style"

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
        min-height: 6;
    }
    #site-actions {
        height: auto;
        margin: 1 0 0 0;
    }
    #site-actions Button {
        margin-right: 1;
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
    selected_plat = reactive("")
    selected_prod = reactive("")
    sudo_askpass = ""
    sudo_secret = ""
    checked: set[tuple[str, str]] = set()

    def sudo_nopasswd(self) -> bool:
        try:
            r = subprocess.run(
                ["sudo", "-n", "true"],
                capture_output=True,
                timeout=5,
                check=False,
            )
            return r.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False

    def set_sudo_askpass(self, password: str) -> None:
        import tempfile
        secret = tempfile.mktemp(prefix="stardust-sudo-")
        path = tempfile.mktemp(prefix="stardust-askpass-")
        with open(secret, "w", encoding="utf-8") as fh:
            fh.write(password)
            if not password.endswith("\n"):
                fh.write("\n")
        os.chmod(secret, 0o600)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/sh\ncat " + repr(secret) + "\n")
        os.chmod(path, 0o700)
        self.sudo_askpass = path
        self.sudo_secret = secret
        ui_log(f"askpass written {path}")

    def clear_sudo_askpass(self) -> None:
        for path in (self.sudo_askpass, self.sudo_secret):
            if path and os.path.exists(path):
                try:
                    os.remove(path)
                except OSError:
                    pass
        self.sudo_askpass = ""
        self.sudo_secret = ""

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical(id="main"):
            with TabbedContent(id="tabs"):
                    with TabPane("Sites", id="tab-sites"):
                        yield SiteForm(id="site-form")
                        yield DataTable(id="sites-table", cursor_type="row", zebra_stripes=True)
                        yield Select(
                            [
                                ("Backup", "backup"),
                                ("Check", "check"),
                                ("Disable", "disable"),
                                ("Enable", "enable"),
                                ("Migrate", "migrate"),
                                ("Delete", "delete"),
                            ],
                            prompt="Actions",
                            id="site-actions",
                        )
                    with TabPane("Platforms", id="tab-platforms"):
                        yield DataTable(id="platforms-table", cursor_type="row", zebra_stripes=True)
                    with TabPane("Output", id="tab-output"):
                        yield Button("Back to Sites", id="nav-sites-from-out", variant="primary")
                        yield Log(id="output", highlight=True)
        yield Static("", id="status")
        yield Footer()

    def on_mount(self) -> None:
        sites = self.query_one("#sites-table", DataTable)
        sites.add_column("Sel", width=5)
        sites.add_columns("Site", "Platform", "Branch", "Backup")
        plats = self.query_one("#platforms-table", DataTable)
        plats.add_columns("Platform", "Branch", "Sites")
        self.action_refresh()

    def watch_status(self, value: str) -> None:
        self.query_one("#status", Static).update(value)

    def action_refresh(self) -> None:
        self.status = "refreshing…"
        self.run_worker(self._refresh_all, exclusive=True)

    def action_doctor(self) -> None:
        self._start_cmd("doctor")

    def action_sites(self) -> None:
        self.query_one("#tabs", TabbedContent).active = "tab-sites"

    def action_platforms(self) -> None:
        self.query_one("#tabs", TabbedContent).active = "tab-platforms"

    async def _refresh_all(self) -> None:
        _rc, inv = await asyncio.to_thread(run_stardust, "inventory")
        sites = self.query_one("#sites-table", DataTable)
        sites.clear()
        self.checked.clear()
        for row in parse_inventory(inv):
            sites.add_row(
                "[ ]",
                row.get("product", ""),
                row.get("platform", ""),
                row.get("branch", ""),
                row.get("backup", ""),
            )

        _rc, lst = await asyncio.to_thread(run_stardust, "list")
        plats = self.query_one("#platforms-table", DataTable)
        plats.clear()
        for row in parse_platforms(lst):
            plats.add_row(row.get("name", ""), row.get("branch", ""), row.get("products", ""))

        self.status = "ready  (s sites  p platforms  d doctor  r refresh  q quit)"

    def _start_cmd(self, *args: str) -> None:
        self.status = f"starting: stardust {' '.join(args)}"
        output = self.query_one("#output", Log)
        output.clear()
        out(output, f"$ stardust {' '.join(args)}")
        self.query_one("#tabs", TabbedContent).active = "tab-output"
        self.run_worker(self._run_and_show(*args), exclusive=False, group="cmd")

    async def _create_site_queue(self, plat: str, prod: str, host: str) -> None:
        """Aegir-style queue: platform first, then site.

        A site cannot exist outside a platform. Steps:
          1. platform-add if missing; stop only if the platform is still absent
          2. doctor — advisory (host-wide; NOT READY does not block)
          3. site-add
        """
        tabs = self.query_one("#tabs", TabbedContent)
        log = self.query_one("#output", Log)
        tabs.active = "tab-output"
        log.clear()
        emit(self, f"create site {plat}/{prod}" + (f" host={host}" if host else ""))
        emit(self, "a site cannot exist without a platform")
        emit(self, "")
        set_progress(self, 0, 3, "starting")

        stop = asyncio.Event()
        self.run_worker(spin(self, f"1/3 checking platform {plat}", stop), exclusive=False)
        emit(self, f"[1/3] ensure platform {plat}")
        emit(self, f"  looking for /srv/platforms/{plat}")
        exists = platform_exists(plat)
        stop.set()
        if not exists:
            emit(self, f"  platform {plat} is not on this host")
            emit(self, f"  running: stardust platform-add {plat}")
            self.status = f"1/3 platform-add {plat}"
            rc = await stream_stardust(self, "platform-add", plat)
            if rc != 0:
                emit(self, f"✗ platform-add failed (exit {rc})")
                set_progress(self, 0, 3, "failed")
                self.status = f"✗ queue stopped: platform-add exit {rc}"
                return
            emit(self, f"✓ platform {plat} created")
        else:
            emit(self, f"✓ platform {plat} already exists")
            emit(self, "  another site on this platform is allowed")
        set_progress(self, 1, 3, "platform ready")

        if not platform_exists(plat):
            emit(self, f"✗ platform {plat} still missing — site-add would fail")
            set_progress(self, 1, 3, "failed")
            self.status = "✗ queue stopped: platform not ready"
            return

        # Doctor is host-wide and does not decide whether a site may be added.
        # Skip it when the platform is already here so site-add actually runs.
        emit(self, "")
        emit(self, "[2/3] health check skipped — platform is already on this host")
        set_progress(self, 2, 3, "ready for site-add")

        site_args = ["site-add", plat, prod]
        if host:
            site_args += ["--host", host]
        stop = asyncio.Event()
        self.run_worker(spin(self, f"3/3 site-add {plat}/{prod}", stop), exclusive=False)
        emit(self, "")
        emit(self, f"[3/3] create site {plat}/{prod}")
        emit(self, f"  running: stardust {' '.join(site_args)}")
        self.status = f"3/3 site-add {plat}/{prod}"
        rc = await stream_stardust(self, *site_args)
        stop.set()
        if rc == 0:
            emit(self, f"✓ site {plat}/{prod} created")
            set_progress(self, 3, 3, "done")
            self.status = f"✓ created {plat}/{prod}"
        else:
            emit(self, f"✗ site-add failed (exit {rc})")
            set_progress(self, 2, 3, "failed")
            self.status = f"✗ site-add exit {rc}"
        tabs.active = "tab-output"
        if rc == 0:
            self.query_one("#form-plat", Input).value = ""
            self.query_one("#form-prod", Input).value = ""
            self.query_one("#form-host", Input).value = ""
            self.action_refresh()

    async def _run_and_show(self, *args: str) -> None:
        tabs = self.query_one("#tabs", TabbedContent)
        tabs.active = "tab-output"
        self.status = f"running: stardust {' '.join(args)}"
        await asyncio.sleep(0)
        tabs.active = "tab-output"
        rc = await stream_stardust(self, *args)
        out(self.query_one("#output", Log), f"(exit {rc})")
        self.status = f"done (exit {rc})"
        tabs.active = "tab-output"

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id != "sites-table":
            return
        table = event.data_table
        row = table.get_row(event.row_key)
        prod, plat = str(row[1]), str(row[2])
        key = (plat, prod)
        if key in self.checked:
            self.checked.discard(key)
            mark = "[ ]"
        else:
            self.checked.add(key)
            mark = "[X]"
        table.update_cell(event.row_key, table.ordered_columns[0].key, mark)
        self.status = f"checked {len(self.checked)}: {plat}/{prod}"

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.select.id != "site-actions" or event.value is Select.BLANK:
            return
        action = str(event.value)
        event.select.clear()
        if not self.checked:
            self.status = "check a site first"
            return
        plat, prod = next(iter(self.checked))
        self.selected_plat, self.selected_prod = plat, prod
        if action == "backup":
            self._start_cmd("site-backup", plat, prod)
        elif action == "check":
            self._start_cmd("site-check", plat, prod)
        elif action == "disable":
            self._start_cmd("site-disable", plat, prod)
        elif action == "enable":
            self._start_cmd("site-enable", plat, prod)
        elif action == "migrate":
            def on_to(target: str | None) -> None:
                if not target:
                    self.status = "migrate cancelled"
                    return
                self._start_cmd("promote", plat, "--to", target)
            self.push_screen(MigrateModal(), on_to)
        elif action == "delete":
            self._confirm_delete(plat, prod)

    def _current_site(self) -> tuple[str, str]:
        """Platform and site from the highlighted Sites row, or last selection."""
        try:
            table = self.query_one("#sites-table", DataTable)
            if table.row_count and table.cursor_row is not None:
                row = table.get_row_at(table.cursor_row)
                return str(row[1]), str(row[0])
        except Exception:  # noqa: BLE001
            pass
        return self.selected_plat, self.selected_prod

    def _act_on_selected(self, verb: str) -> None:
        if not self.selected_plat or not self.selected_prod:
            self.status = "select a site row first"
            return
        self._start_cmd(verb, self.selected_plat, self.selected_prod)
        if not self.selected_plat or not self.selected_prod:
            self.status = "select a site row first"
            return
        self._start_cmd(verb, self.selected_plat, self.selected_prod)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id or ""
        if bid == "nav-quit":
            self.exit()
        elif bid == "nav-refresh":
            self.action_refresh()
        elif bid == "nav-doctor":
            self.action_doctor()
        elif bid in ("nav-sites", "nav-sites-from-out"):
            self.action_sites()
        elif bid == "nav-platforms":
            self.action_platforms()
        elif bid == "form-create":
            plat = self.query_one("#form-plat", Input).value.strip()
            prod = self.query_one("#form-prod", Input).value.strip()
            host = self.query_one("#form-host", Input).value.strip()
            if not plat or not prod:
                self.status = "platform and site name required"
                return
            if self.sudo_nopasswd() or self.sudo_askpass:
                self._open_log_and_queue(plat, prod, host)
            else:
                def on_pass(pw: str | None) -> None:
                    ui_log("sudo modal dismissed")
                    if not pw:
                        ui_log("sudo password empty")
                        self.status = "sudo password required"
                        return
                    ui_log("sudo password received, writing askpass")
                    self.set_sudo_askpass(pw)
                    ui_log(f"askpass={self.sudo_askpass}")
                    self.call_later(self._open_log_and_queue, plat, prod, host)
                self.push_screen(SudoModal(), on_pass)

    def _confirm_delete(self, plat: str, prod: str) -> None:
        self.status = f"delete? {plat}/{prod}"

        def start_delete() -> None:
            self.call_later(self._start_cmd, "site-delete", plat, prod)

        def on_typed(ok: bool) -> None:
            if not ok:
                self.status = "delete cancelled (type DELETE to confirm)"
                return
            if self.sudo_nopasswd() or self.sudo_askpass:
                start_delete()
                return

            def on_pass(pw: str | None) -> None:
                if not pw:
                    self.status = "sudo password required"
                    return
                self.set_sudo_askpass(pw)
                self.call_later(start_delete)

            self.call_later(self.push_screen, SudoModal(), on_pass)

        def on_yes(yes: bool) -> None:
            if not yes:
                self.status = "delete cancelled"
                return
            self.call_later(self.push_screen, DeleteTypeModal(), on_typed)

        self.push_screen(DeleteConfirmModal(plat, prod), on_yes)

    async def _queue_create_later(self, plat: str, prod: str, host: str) -> None:
        """Wait until the modal is gone, then run the create queue."""
        ui_log(f"queue worker start {plat}/{prod}")
        await asyncio.sleep(0.3)
        ui_log("queue worker after sleep")
        try:
            await self._create_site_queue(plat, prod, host)
            ui_log("queue worker finished")
        except Exception:
            ui_log("queue worker exception:\n" + traceback.format_exc())
            self.status = f"error — see {UI_LOG}"

    def _open_log_and_queue(self, plat: str, prod: str, host: str) -> None:
        """Pop the scrolling log over the form, then run the create queue."""
        self.status = f"queued: {plat}/{prod}"
        self.push_screen(LogModal(f"Create {plat}/{prod}"))
        self.run_worker(
            self._queue_create_later(plat, prod, host),
            exclusive=False,
            group="cmd",
        )


def main() -> None:
    if os.geteuid() == 0 or os.environ.get("SUDO_USER"):
        raise SystemExit("stardust ui: do not run as root or under sudo")
    StardustApp().run()


if __name__ == "__main__":
    main()
