#!/usr/bin/env bash
# Sync OpenClaw skill repositories into the workspace skills directory.
#
# SKILLS_REPOS: whitespace- or comma-separated list of git URLs. Each may be
# pinned to a ref with a trailing "#<ref>" (branch, tag, or commit), e.g.
#   SKILLS_REPOS="https://github.com/acme/skill-foo#v1.2.0 https://github.com/acme/skill-bar"
#
# Behaviour:
#   - Cloned repos live at $OPENCLAW_MANAGED_SKILLS_DIR/<repo-name>.
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
SKILLS_DIR="${OPENCLAW_MANAGED_SKILLS_DIR:-$HOME/managed-skills}"
mkdir -p "$SKILLS_DIR"

log() { echo "[pull-skills] $*"; }

# Normalise separators (commas -> spaces).
raw="${SKILLS_REPOS:-}"
raw="${raw//,/ }"

# Guard FIRST, before any pruning. An empty/unset SKILLS_REPOS is treated as a
# no-op: we leave existing checkouts intact rather than nuking every managed
# skill. This protects against the variable being accidentally cleared or not
# injected into the container — a missing env var should never silently delete
# data on the volume. To intentionally remove a skill, drop it from a non-empty
# SKILLS_REPOS (handled by the prune pass below) or delete it via SFTP.
if [ -z "${raw// }" ]; then
  log "SKILLS_REPOS empty — leaving any existing skills untouched."
  exit 0
fi

# Collect the desired repo set, keyed by checkout dir name (the repo basename).
declare -A desired_spec   # name -> "url#ref"
have_specs=0              # flag instead of ${#desired_spec[@]}: expanding an
                          # empty associative array trips `set -u` on some bash.
parse_errors=0            # set if any entry is rejected — gates the prune pass so
                          # a single typo can't delete skills not in the survivors.
for spec in $raw; do
  url="${spec%%#*}"
  [ -z "$url" ] && continue
  ref=""
  [ "$spec" != "$url" ] && ref="${spec#*#}"

  # SECURITY: reject option-like url/ref. The values are quoted (so they can't
  # break out of the shell), but git itself parses a leading '-' as an option —
  # a spec such as "--upload-pack=/bin/sh" or "#--option" would be an option
  # injection. Require a real URL and a non-option ref.
  case "$url" in
    -*) log "WARN: skill repo URL '$url' looks like a git option — ignoring."; parse_errors=1; continue ;;
  esac
  # SECURITY: a ref is later passed to `git fetch origin "$ref"`. Beyond a leading
  # '-' (option), reject git refspec/ref metacharacters so it can't be coerced
  # into a refspec (src:dst), a range ('..'), reflog syntax ('@{') or a glob.
  ref_reason=""
  case "$ref" in
    -*)        ref_reason="looks like a git option" ;;
    *:*)       ref_reason="contains ':' (refspec syntax)" ;;
    *..*)      ref_reason="contains '..' (ref range)" ;;
    *@\{*)     ref_reason="contains '@{' (reflog syntax)" ;;
    *' '*|*'~'*|*'^'*|*'?'*|*'*'*|*'['*|*'\'*) ref_reason="contains glob/metacharacters" ;;
  esac
  if [ -n "$ref_reason" ]; then
    log "WARN: skill ref '$ref' (for '$url') $ref_reason — ignoring this repo."
    parse_errors=1; continue
  fi

  name="$(basename -- "$url")"
  name="${name%.git}"
  # SECURITY/SAFETY: 'name' becomes a directory under $SKILLS_DIR and a target of
  # rm -rf below. A spec that resolves to '', '.', '..', or a path-like value
  # could make us delete the skills directory itself (or its parent). Accept only
  # a single, plain path segment.
  case "$name" in
    ""|.|..) log "WARN: skill repo URL '$url' yields an unsafe name '$name' — ignoring."; parse_errors=1; continue ;;
    */*)     log "WARN: skill repo URL '$url' yields a path-like name '$name' — ignoring."; parse_errors=1; continue ;;
  esac
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log "WARN: skill name '$name' (from '$url') has unexpected characters — ignoring."
    parse_errors=1; continue
  fi

  # Two different specs that map to the same checkout dir would collide on disk.
  # Keep the first and warn loudly rather than silently overwriting.
  if [ -n "${desired_spec[$name]+set}" ] && [ "${desired_spec[$name]}" != "$spec" ]; then
    log "WARN: duplicate skill name '$name' from differing specs ('${desired_spec[$name]}' vs '$spec') — keeping the first, ignoring the latter."
    continue
  fi
  desired_spec["$name"]="$spec"
  have_specs=1
done

# If the list was non-empty but nothing valid survived parsing (e.g. a typo, or
# every entry rejected above), do NOT fall through to the prune pass — that would
# delete every managed skill because of a misconfiguration. Treat it like the
# empty case (keep existing skills) but exit non-zero so SKILLS_REQUIRED can flag
# it. To intentionally drop a skill, keep the rest of a valid SKILLS_REPOS list.
if [ "$have_specs" -eq 0 ]; then
  log "WARN: SKILLS_REPOS was set but contained no usable repo specs — leaving existing skills untouched."
  exit 1
fi

status=0

# Prune git-managed skills that are no longer desired. Manual (non-.git) skills
# are preserved. SKIP pruning entirely if any entry failed to parse: with an
# invalid entry dropped, a still-present managed skill could look "no longer
# listed" and be deleted because of a typo. We keep everything and exit non-zero.
if [ "$parse_errors" -ne 0 ]; then
  log "WARN: some SKILLS_REPOS entries were invalid (see warnings) — skipping prune so no skill is deleted by mistake. Fix the entries to re-enable pruning."
  status=1
else
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ -d "$d/.git" ] && [ -z "${desired_spec[$name]+set}" ]; then
      log "Removing managed skill no longer listed in SKILLS_REPOS: $name"
      rm -rf "$d"
    fi
  done
fi
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
    target=""
    if git -C "$dest" fetch --depth 1 origin "${ref:-HEAD}"; then
      # Branch/tag/HEAD (or servers that allow fetching a SHA directly).
      target="FETCH_HEAD"
    elif [ -n "$ref" ] && { git -C "$dest" fetch --unshallow --tags origin 2>/dev/null || git -C "$dest" fetch --tags origin; }; then
      # Many servers reject `fetch origin <sha>`; fall back to a full fetch and
      # resolve the ref (commit SHA, tag, or branch) locally. Existing checkouts
      # are usually --depth 1 (shallow), so --unshallow makes an older pinned
      # commit reachable; it errors on a non-shallow repo, hence the plain
      # --tags fallback. --tags ensures tag refs are present too.
      target="$ref"
    fi
    if [ -n "$target" ]; then
      if ! git -C "$dest" checkout -q --detach "$target"; then
        log "WARN: checkout of '$target' failed for '$name' (keeping existing checkout)"
        status=1
      fi
    else
      log "WARN: fetch failed for '$name' (keeping existing checkout)"
      status=1
    fi
    continue
  fi

  log "Cloning '$name' ${ref:+(ref: $ref)}..."
  # '--' terminates option parsing so a url/ref can never be read as a git flag
  # (belt-and-suspenders on top of the '-*' rejection above). Note: checkout uses
  # no '--' because there `--` would mean "pathspec", not a tree-ish; the ref is
  # already guaranteed non-option by the validation pass.
  if [ -n "$ref" ]; then
    if git clone --depth 1 --branch "$ref" -- "$url" "$dest"; then
      :  # branch/tag clone succeeded
    elif rm -rf "$dest" && git clone -- "$url" "$dest" && git -C "$dest" checkout -q --detach "$ref"; then
      :  # cleaned any partial shallow clone, then full clone + checkout (handles SHAs)
    else
      log "WARN: clone failed for '$name'"
      rm -rf "$dest"   # don't leave a partial dir that blocks future boots
      status=1
    fi
  else
    if ! git clone --depth 1 -- "$url" "$dest"; then
      log "WARN: clone failed for '$name'"
      rm -rf "$dest"
      status=1
    fi
  fi
done

log "Skill sync complete."
exit $status
