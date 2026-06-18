#!/usr/bin/env bash
# Clone/update OpenClaw skill repositories into the workspace skills directory.
#
# SKILLS_REPOS: whitespace- or comma-separated list of git URLs. Each may be
# pinned to a ref with a trailing "#<ref>" (branch, tag, or commit), e.g.
#   SKILLS_REPOS="https://github.com/acme/skill-foo#v1.2.0 https://github.com/acme/skill-bar"
#
# Repos are cloned into ~/.openclaw/workspace/skills/<repo-name>. A repo may
# contain a SKILL.md at its root (single skill) or multiple skill subdirectories.
set -uo pipefail

export HOME=/home/container
SKILLS_DIR="$HOME/.openclaw/workspace/skills"
mkdir -p "$SKILLS_DIR"

log() { echo "[pull-skills] $*"; }

raw="${SKILLS_REPOS:-}"
if [ -z "${raw// }" ]; then
  log "SKILLS_REPOS empty — no skill repos to sync."
  exit 0
fi

# Normalise separators (commas/newlines -> spaces).
raw="${raw//,/ }"

status=0
for spec in $raw; do
  url="${spec%%#*}"
  ref=""
  [ "$spec" != "$url" ] && ref="${spec#*#}"
  [ -z "$url" ] && continue

  name="$(basename "$url")"
  name="${name%.git}"
  dest="$SKILLS_DIR/$name"

  if [ -d "$dest/.git" ]; then
    log "Updating $name ..."
    git -C "$dest" fetch --depth 1 origin "${ref:-HEAD}" 2>&1 \
      && git -C "$dest" checkout -q FETCH_HEAD 2>&1 \
      || { log "WARN: update failed for $name"; status=1; }
  else
    log "Cloning $name ${ref:+(ref: $ref)} ..."
    if [ -n "$ref" ]; then
      git clone --depth 1 --branch "$ref" "$url" "$dest" 2>&1 \
        || git clone "$url" "$dest" 2>&1 && git -C "$dest" checkout -q "$ref" 2>&1 \
        || { log "WARN: clone failed for $name"; status=1; }
    else
      git clone --depth 1 "$url" "$dest" 2>&1 \
        || { log "WARN: clone failed for $name"; status=1; }
    fi
  fi
done

log "Skill sync complete."
exit $status
