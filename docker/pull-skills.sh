#!/usr/bin/env bash
# Sync OpenClaw skill repositories into the workspace skills directory.
#
# SKILLS_REPOS: whitespace- or comma-separated list of git URLs. Each may be
# pinned to a ref with a trailing "#<ref>" (branch, tag, or commit), e.g.
#   SKILLS_REPOS="https://github.com/acme/skill-foo#v1.2.0 https://github.com/acme/skill-bar"
#
# Behaviour:
#   - Cloned repos live at ~/.openclaw/workspace/skills/<repo-name>.
#   - Repos removed from SKILLS_REPOS are pruned (only git-managed checkouts;
#     skills uploaded by hand via SFTP have no .git and are left untouched).
#   - If an existing checkout's origin differs from the configured URL (basename
#     collision), it is re-cloned.
#   - Partial / non-git directories are cleaned and re-cloned instead of being
#     skipped forever.
#
# SECURITY: unpinned repos track the remote's mutable HEAD and are re-pulled on
# every restart — pin to a tag or commit (#<ref>) for anything you depend on.
set -uo pipefail

export HOME=/home/container
SKILLS_DIR="$HOME/.openclaw/workspace/skills"
mkdir -p "$SKILLS_DIR"

log() { echo "[pull-skills] $*"; }

# Normalise separators (commas -> spaces) and collect the desired repo set.
raw="${SKILLS_REPOS:-}"
raw="${raw//,/ }"

declare -A desired_spec   # name -> "url#ref"
for spec in $raw; do
  url="${spec%%#*}"
  [ -z "$url" ] && continue
  name="$(basename "$url")"
  name="${name%.git}"
  desired_spec["$name"]="$spec"
done

# Prune git-managed skills that are no longer desired. Manual (non-.git) skills
# are preserved.
for d in "$SKILLS_DIR"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  if [ -d "$d/.git" ] && [ -z "${desired_spec[$name]+set}" ]; then
    log "Removing managed skill no longer listed in SKILLS_REPOS: $name"
    rm -rf "$d"
  fi
done

if [ -z "${raw// }" ]; then
  log "SKILLS_REPOS empty — no skill repos to sync."
  exit 0
fi

status=0
for name in "${!desired_spec[@]}"; do
  spec="${desired_spec[$name]}"
  url="${spec%%#*}"
  ref=""
  [ "$spec" != "$url" ] && ref="${spec#*#}"
  dest="$SKILLS_DIR/$name"

  # Reset the destination if it isn't a clean git checkout of the right origin.
  if [ -e "$dest" ] && [ ! -d "$dest/.git" ]; then
    log "WARN: '$name' exists but is not a git checkout — replacing."
    rm -rf "$dest"
  elif [ -d "$dest/.git" ]; then
    existing_origin="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
    if [ "$existing_origin" != "$url" ]; then
      log "WARN: '$name' origin changed ('$existing_origin' -> '$url') — re-cloning."
      rm -rf "$dest"
    fi
  fi

  if [ -d "$dest/.git" ]; then
    log "Updating '$name' ${ref:+(ref: $ref)}..."
    if git -C "$dest" fetch --depth 1 origin "${ref:-HEAD}"; then
      if ! git -C "$dest" checkout -q --detach FETCH_HEAD; then
        log "WARN: checkout failed for '$name' (keeping existing checkout)"
        status=1
      fi
    else
      log "WARN: fetch failed for '$name' (keeping existing checkout)"
      status=1
    fi
    continue
  fi

  log "Cloning '$name' ${ref:+(ref: $ref)}..."
  if [ -n "$ref" ]; then
    if git clone --depth 1 --branch "$ref" "$url" "$dest"; then
      :  # branch/tag clone succeeded
    elif git clone "$url" "$dest" && git -C "$dest" checkout -q "$ref"; then
      :  # fell back to full clone + checkout (handles commit SHAs)
    else
      log "WARN: clone failed for '$name'"
      rm -rf "$dest"   # don't leave a partial dir that blocks future boots
      status=1
    fi
  else
    if ! git clone --depth 1 "$url" "$dest"; then
      log "WARN: clone failed for '$name'"
      rm -rf "$dest"
      status=1
    fi
  fi
done

log "Skill sync complete."
exit $status
