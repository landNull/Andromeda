# Stardust Textual TUI

Aegir-style full-screen front-end. Replaces the previous Go Bubble Tea TUI.

Launch:
```
stardust ui
```

Requires Python 3.8+.  
If `uv` is on PATH, `stardust ui` runs via `uv run --with textual` (no separate install).  
Otherwise install once with `pip install textual` (or `uv pip install textual`) so the system `python3` can import it.

The TUI does not reimplement Stardust logic. It shells out to the existing `stardust` binary (`list`, `inventory`, `log`, `doctor`, `site-add`, …) and displays the results in a header + right sidebar (queues/navigation) + main tables layout.
