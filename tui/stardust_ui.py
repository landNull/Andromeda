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
import subprocess

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
    Static,
    TabbedContent,
    TabPane,
)
from textual.binding import Binding
from textual.reactive import reactive

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
            env=env,
        )
    except FileNotFoundError:
        log.write(f"{STARDUST_BIN} not found on PATH")
        return 127
    assert proc.stdout is not None
    while True:
        line = await proc.stdout.readline()
        if not line:
            break
        log.write(line.decode(errors="replace").rstrip("\n"))
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
    """True if `stardust list` shows this platform."""
    _rc, text = run_stardust("list")
    for row in parse_platforms(text):
        if row.get("name") == name:
            return True
    return False


def queue_mark(line: str) -> str:
    """Aegir-style status prefix: green ok, red fail, plain otherwise."""
    low = line.lower()
    if " fail" in low or " error" in low or line.strip().endswith(" 1"):
        return "[red]✗[/] " + line
    if " ok" in low or line.strip().endswith(" 0"):
        return "[green]✓[/] " + line
    return "  " + line


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
            yield Label("sudo password (for stardust-priv / bee)")
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
        path = tempfile.mktemp(prefix="stardust-askpass-")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/sh\nprintf '%s\\n' " + repr(password) + "\n")
        os.chmod(path, 0o700)
        self.sudo_askpass = path

    def clear_sudo_askpass(self) -> None:
        if self.sudo_askpass and os.path.exists(self.sudo_askpass):
            try:
                os.remove(self.sudo_askpass)
            except OSError:
                pass
        self.sudo_askpass = ""

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical(id="main"):
            with TabbedContent(id="tabs"):
                    with TabPane("Sites", id="tab-sites"):
                        yield SiteForm(id="site-form")
                        yield DataTable(id="sites-table", cursor_type="row", zebra_stripes=True)
                        with Horizontal(id="site-actions"):
                            yield Button("Backup", id="act-backup")
                            yield Button("Check", id="act-check")
                            yield Button("Disable", id="act-disable")
                            yield Button("Enable", id="act-enable")
                            yield Button("Migrate", id="act-migrate", variant="warning")
                            yield Button("Delete", id="act-delete", variant="error")
                    with TabPane("Platforms", id="tab-platforms"):
                        yield DataTable(id="platforms-table", cursor_type="row", zebra_stripes=True)
                    with TabPane("Output", id="tab-output"):
                        yield Button("Back to Sites", id="nav-sites-from-out", variant="primary")
                        yield Log(id="output", highlight=True)
        yield Static("", id="status")
        yield Footer()

    def on_mount(self) -> None:
        sites = self.query_one("#sites-table", DataTable)
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
        for row in parse_inventory(inv):
            sites.add_row(
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
        output.write(f"$ stardust {' '.join(args)}")
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
        log.write(f"queue: create site {plat}/{prod}")
        log.write("  1. ensure platform")
        log.write("  2. health check")
        log.write("  3. create site")
        log.write("")

        if not platform_exists(plat):
            log.write(f"--- step 1: stardust platform-add {plat}")
            self.status = f"queue 1/3: platform-add {plat}"
            rc = await stream_stardust(self, "platform-add", plat)
            log.write(f"(platform-add exit {rc})")
            if rc != 0:
                self.status = f"queue stopped: platform-add exit {rc}"
                tabs.active = "tab-output"
                return
        else:
            log.write(f"--- step 1: platform {plat} already exists")

        if not platform_exists(plat):
            log.write(f"queue stopped: platform {plat} still missing — site-add would fail")
            self.status = "queue stopped: platform not ready"
            tabs.active = "tab-output"
            return

        log.write("--- step 2: stardust doctor (advisory)")
        self.status = "queue 2/3: doctor"
        rc = await stream_stardust(self, "doctor")
        if rc == 0:
            log.write("doctor: READY — host can take the site")
        else:
            log.write(
                f"doctor: NOT READY (exit {rc}) — shown above; "
                "continuing because the platform exists. "
                "Fix host issues separately if site-add fails."
            )
        log.write(f"(doctor exit {rc})")

        site_args = ["site-add", plat, prod]
        if host:
            site_args += ["--host", host]
        log.write(f"--- step 3: stardust {' '.join(site_args)}")
        self.status = f"queue 3/3: site-add {plat}/{prod}"
        rc = await stream_stardust(self, *site_args)
        log.write(f"(site-add exit {rc})")
        self.status = f"queue done (exit {rc})"
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
        self.query_one("#output", Log).write(f"\n(exit {rc})")
        self.status = f"done (exit {rc})"
        tabs.active = "tab-output"

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id == "sites-table":
            row = event.data_table.get_row(event.row_key)
            self.selected_prod = str(row[0])
            self.selected_plat = str(row[1])
            self.status = f"selected {self.selected_plat}/{self.selected_prod}"
        elif event.data_table.id == "platforms-table":
            row = event.data_table.get_row(event.row_key)
            self.selected_plat = str(row[0])
            self.selected_prod = ""
            self.status = f"selected platform {self.selected_plat}"

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
                self._queue_create(plat, prod, host)
            else:
                def on_pass(pw: str | None) -> None:
                    if not pw:
                        self.status = "sudo password required"
                        return
                    self.set_sudo_askpass(pw)
                    self._queue_create(plat, prod, host)
                self.push_screen(SudoModal(), on_pass)
        elif bid == "act-backup":
            self._act_on_selected("site-backup")
        elif bid == "act-check":
            self._act_on_selected("site-check")
        elif bid == "act-disable":
            self._act_on_selected("site-disable")
        elif bid == "act-enable":
            self._act_on_selected("site-enable")
        elif bid == "act-migrate":
            if not self.selected_plat:
                self.status = "select a site or platform row first"
                return
            def on_to(target: str | None) -> None:
                if not target:
                    self.status = "migrate cancelled"
                    return
                self._start_cmd("promote", self.selected_plat, "--to", target)
            self.push_screen(MigrateModal(), on_to)
        elif bid == "act-delete":
            plat, prod = self._current_site()
            if not plat or not prod:
                self.status = "select a site row first (click the row, then Delete)"
                return
            self.selected_plat, self.selected_prod = plat, prod
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
                    start_delete()

                self.call_later(self.push_screen, SudoModal(), on_pass)

            def on_yes(yes: bool) -> None:
                if not yes:
                    self.status = "delete cancelled"
                    return
                self.call_later(self.push_screen, DeleteTypeModal(), on_typed)

            self.push_screen(DeleteConfirmModal(plat, prod), on_yes)

    def _queue_create(self, plat: str, prod: str, host: str) -> None:
        self.status = f"queued: {plat}/{prod}"
        self.query_one("#tabs", TabbedContent).active = "tab-output"
        self.run_worker(
            self._create_site_queue(plat, prod, host),
            exclusive=False,
            group="cmd",
        )


def main() -> None:
    if os.geteuid() == 0 or os.environ.get("SUDO_USER"):
        raise SystemExit("stardust ui: do not run as root or under sudo")
    StardustApp().run()


if __name__ == "__main__":
    main()
