#!/bin/sh
# lib/andromeda-git.sh — git template prompting for bare git setup

# Prompts for ANDROMEDA_GIT_TEMPLATE without Gitea-specific logic.
prompt_andromeda_git_template() {
  if [ "${LOCALHOST:-0}" -ne 1 ] && [ "${ROLE:-}" != devel ]; then
    return 0
  fi
  # If already configured, skip prompting
  for f in "${HOME:-}/.andromeda.conf" /etc/andromeda.conf; do
    [ -f "$f" ] || continue
    val=$(sed -n 's/^ANDROMEDA_GIT_TEMPLATE=//p' "$f" | tail -n 1)
    case $val in
      ''|*YOURORG*|*git.example*) ;;
      *)
        echo "git template already set — skip prompt"
        return 0
        ;;
    esac
  done

  echo "Note: The Andromeda Git template helps 'andromeda platform-add' clone projects."
  echo "You can set ANDROMEDA_GIT_TEMPLATE in /etc/andromeda.conf manually later."

  if [ "${DRYRUN:-0}" -eq 1 ]; then
    echo "+ prompt ANDROMEDA_GIT_TEMPLATE"
    return 0
  fi

  if [ ! -t 0 ]; then
    echo "no TTY — not prompting for git template"
    return 0
  fi

  # Default values for bare git setup
  host_def="localhost"
  owner_def="git" # Assuming a default "git" user or general ownership for bare repos

  host=$(install_prompt "Git host or IP for bare repositories (e.g., localhost or 127.0.0.1)" "$host_def" \
    "This is the host or IP address where your bare Git repositories are served.\nFor 'git daemon', this is often 'localhost' or '127.0.0.1'.\nFor SSH, it would be the server's hostname or IP." \
    "Needed: the host for your bare Git repos (e.g., localhost).")

  if [ -z "$host" ]; then
    echo "No host provided — leaving ANDROMEDA_GIT_TEMPLATE empty."
    return 0
  fi

  owner=$(install_prompt "Base directory/prefix for repositories (e.g., 'var/git' if /var/git/repo.git)" "" \
    "For git daemon, repositories are usually directly under the base-path (e.g., '/var/git/repo.git').\nIf using SSH, you might specify a user or a subdirectory within the user's home." \
    "Optional: a prefix for repository paths (e.g., 'myprojects' for ssh://user@host/myprojects/repo.git). Empty for direct repo names.")

  tpl="git://${host}/${owner:+\$owner/}%s.git" # Handles optional owner/prefix
  if [ -n "$owner" ]; then
    tpl="git://${host}/$owner/%s.git"
  else
    tpl="git://${host}/%s.git"
  fi

  dest=/etc/andromeda.conf
  if [ -f "$dest" ] && grep -q '^ANDROMEDA_GIT_TEMPLATE=' "$dest"; then
    run_root sed -i "s|^ANDROMEDA_GIT_TEMPLATE=.*|ANDROMEDA_GIT_TEMPLATE=$tpl|" "$dest"
  elif [ -f "$dest" ]; then
    run_root sh -c "printf 'ANDROMEDA_GIT_TEMPLATE=%s\n' '$tpl' >> '$dest'"
  else
    echo "Warning: $dest missing — please manually set ANDROMEDA_GIT_TEMPLATE=$tpl"
    return 0
  fi
  echo "Wrote ANDROMEDA_GIT_TEMPLATE=$tpl to $dest"
}
