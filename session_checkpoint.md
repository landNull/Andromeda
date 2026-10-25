# Session Checkpoint

**Date:** 2026-10-03 04:15:00 +00:00 (Current Turn Context)

**Current Working Directory:** `/data/data/com.termux/files/home/Apps/Andromeda`

**Current Git Branch:** `devel`

---

## Troubleshooting Gitea Installation Issue

**Problem:** Gitea installation is failing during user creation with the error: `adduser: unrecognized option: group`.

**Details of Failure:**
The `install-andromeda.sh` script attempts to create the `git` user using `adduser` with parameters (`--system --shell /bin/bash --gecos "Git Version Control" --group --disabled-password --home /home/git git`) that are incompatible with the `adduser` version found on the system (which appears to be BusyBox's `adduser`, based on the error output).

**Identified Root Cause:**
The `install-andromeda.sh` script's `detect_os` function incorrectly sets `PKG=apt` for the Alpine Linux system (Termux in this environment often behaves like Alpine or similar minimalist Linux). This leads the `gitea_ensure_user` function to use `adduser` syntax appropriate for Debian-based systems (like those that use `apt`) instead of the correct syntax for Alpine/BusyBox systems.

**Steps Taken So Far:**
1.  Verified `gitea-uninstaller.sh` was pulled and reviewed its content.
2.  Confirmed `install-andromeda.sh` attempts to run the Gitea installation.
3.  Identified that `/usr/local/sbin` was missing and created it.
4.  Re-ran `install-andromeda.sh` with `GITEA_INSTALL=Y`, which then exposed the `adduser` incompatibility.
5.  Reviewed `install-andromeda.sh`'s `detect_os` function.

**Next Immediate Steps:**
1.  **Modify `install-andromeda.sh`:** Adjust the `detect_os` function to correctly identify Alpine Linux and set `PKG=apk`.
2.  **Review `gitea_ensure_user`:** Ensure the logic within `gitea_ensure_user` for `PKG=apk` (or a generic non-apt path) uses `adduser` or `useradd` commands compatible with BusyBox/Alpine.

---
`session_checkpoint.md` created. You can `cat session_checkpoint.md` at any time to review this information.
