#!/usr/bin/env bash
# OpenClaw on Pterodactyl — boot bootstrap.
#
# Runs as the unprivileged `container` user with HOME=/home/container (the
# persistent volume). Generates OpenClaw config from environment variables,
# pulls skills, validates, then hands off to the Gateway in the foreground.
set -uo pipefail

export HOME=/home/container
cd "$HOME"

CONFIG_DIR="$HOME/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/workspace}"
MANAGED_SKILLS_DIR="${OPENCLAW_MANAGED_SKILLS_DIR:-$HOME/managed-skills}"
EGG_DIR="/opt/openclaw-egg"

log() { echo "[openclaw-egg] $*"; }

validate_workspace_path() {
  case "$WORKSPACE" in
    /*) : ;;
    *) log "FATAL: OPENCLAW_WORKSPACE='$WORKSPACE' must be an absolute path."; exit 1 ;;
  esac
  case "$WORKSPACE" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      log "FATAL: OPENCLAW_WORKSPACE contains control characters."
      exit 1
      ;;
  esac
  case "$WORKSPACE" in
    "$HOME"|"$HOME/"|"$CONFIG_DIR"|"$CONFIG_DIR"/*|*/../*|*/..|*/./*|*/.)
      log "FATAL: OPENCLAW_WORKSPACE='$WORKSPACE' must be a dedicated directory inside $HOME, outside $CONFIG_DIR, with no '.' or '..' path segments."
      exit 1
      ;;
    "$HOME"/*) : ;;
    *)
      log "FATAL: OPENCLAW_WORKSPACE='$WORKSPACE' must be inside $HOME."
      exit 1
      ;;
  esac
}

validate_managed_skills_path() {
  case "$MANAGED_SKILLS_DIR" in
    /*) : ;;
    *) log "FATAL: OPENCLAW_MANAGED_SKILLS_DIR='$MANAGED_SKILLS_DIR' must be an absolute path."; exit 1 ;;
  esac
  case "$MANAGED_SKILLS_DIR" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      log "FATAL: OPENCLAW_MANAGED_SKILLS_DIR contains control characters."
      exit 1
      ;;
  esac
  case "$MANAGED_SKILLS_DIR" in
    "$HOME"|"$HOME/"|*/../*|*/..|*/./*|*/.)
      log "FATAL: OPENCLAW_MANAGED_SKILLS_DIR='$MANAGED_SKILLS_DIR' must be a dedicated directory inside $HOME, with no '.' or '..' path segments."
      exit 1
      ;;
    "$WORKSPACE"|"$WORKSPACE"/*)
      log "FATAL: OPENCLAW_MANAGED_SKILLS_DIR='$MANAGED_SKILLS_DIR' must not be inside OPENCLAW_WORKSPACE='$WORKSPACE'."
      exit 1
      ;;
    "$HOME"/*) : ;;
    *)
      log "FATAL: OPENCLAW_MANAGED_SKILLS_DIR='$MANAGED_SKILLS_DIR' must be inside $HOME."
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 0. Safety preflight on the gateway exposure settings. These env vars are the
#    same values the egg substitutes into the gateway --bind/--auth flags, so
#    validating them here catches an unsafe combination before we start.
# ---------------------------------------------------------------------------
BIND="${GATEWAY_BIND:-loopback}"
AUTH="${GATEWAY_AUTH:-none}"
PORT="${SERVER_PORT:-18789}"
validate_workspace_path
validate_managed_skills_path
mkdir -p "$WORKSPACE"
mkdir -p "$MANAGED_SKILLS_DIR"

# These values are expanded into the gateway command line (via $STARTUP / the
# fallback below), so validate them against a strict allowlist here. The egg
# already constrains them, but a plain `docker run` caller does not get that
# validation — never let a value with spaces or shell metacharacters reach exec.
case "$BIND" in
  loopback|lan|tailnet|auto|custom) : ;;
  *) log "FATAL: GATEWAY_BIND='$BIND' must be one of loopback|lan|tailnet|auto|custom."; exit 1 ;;
esac
case "$AUTH" in
  none|token) : ;;
  *) log "FATAL: GATEWAY_AUTH='$AUTH' must be one of none|token."; exit 1 ;;
esac
case "$PORT" in
  ''|*[!0-9]*) log "FATAL: SERVER_PORT='$PORT' is not a positive integer."; exit 1 ;;
esac
# Force base-10 ($((10#…)) avoids an octal misparse of a leading zero) and bound
# to the valid TCP range — a 0 or >65535 port would bind nowhere useful.
if [ "$((10#$PORT))" -lt 1 ] || [ "$((10#$PORT))" -gt 65535 ]; then
  log "FATAL: SERVER_PORT='$PORT' is outside the valid 1-65535 TCP port range."
  exit 1
fi

if [ "$BIND" != "loopback" ] && [ "$AUTH" = "none" ]; then
  log "FATAL: GATEWAY_BIND='$BIND' exposes the gateway beyond loopback while GATEWAY_AUTH='none'."
  log "       Set GATEWAY_AUTH=token (with OPENCLAW_GATEWAY_TOKEN) or keep GATEWAY_BIND=loopback."
  exit 1
fi
if [ "$AUTH" = "token" ] && [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  log "FATAL: GATEWAY_AUTH='token' requires OPENCLAW_GATEWAY_TOKEN to be set."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Baseline config + workspace (first boot only). --non-interactive needs
#    --accept-risk to acknowledge the agent's system access.
# ---------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
  log "First boot: creating baseline config and workspace..."
  # `setup` writes the config/workspace and then probes for a running gateway,
  # which doesn't exist yet — that final health check exits non-zero even though
  # the files were created. Tolerate it and assert the config file afterwards.
  openclaw setup --non-interactive --accept-risk --workspace "$WORKSPACE" || true
  if [ ! -f "$CONFIG_FILE" ]; then
    log "FATAL: 'openclaw setup' did not produce $CONFIG_FILE"
    exit 1
  fi
fi

# Install a channel plugin via its npm package, idempotently. Plugins install
# under ~/.openclaw/npm/projects/ on the persistent volume. We check for the
# plugin's actual entry module (not just the project directory) so a partial or
# failed install is detected and retried instead of being skipped forever.
# Telegram ships bundled with OpenClaw; Discord (and most others) do not.
ensure_plugin_installed() {
  local channel="$1" pkg="$2" entry_glob="$3"
  if compgen -G "$CONFIG_DIR/npm/projects/$entry_glob" >/dev/null 2>&1; then
    log "Channel '${channel}' plugin already installed — skipping download."
    return 0
  fi
  log "Installing '${channel}' plugin (${pkg}) — first boot only, downloads from npm..."
  # A trailing "config changed since last load" notice here is benign; the
  # plugin files still install.
  openclaw plugins install "$pkg" \
    || log "WARN: '${channel}' plugin install reported an error."
  # Verify the entry module actually landed. We only get here when the channel's
  # token is set, so its block is about to be written into the config — a missing
  # plugin would otherwise surface only as a confusing validate/runtime failure
  # later. Fail fast with a clear message instead.
  if ! compgen -G "$CONFIG_DIR/npm/projects/$entry_glob" >/dev/null 2>&1; then
    log "FATAL: '${channel}' plugin entry module not found after install — cannot enable the '${channel}' channel."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 2. Generate the env-driven config patch (every boot in managed mode). We
#    GENERATE here but APPLY in step 2c, after channel plugins are installed —
#    OpenClaw validates a channel's config against its installed plugin, so the
#    Discord block must not be patched in before @openclaw/discord exists.
#    Generation itself is cheap and fails fast on misconfiguration (e.g. a
#    channel token without its owner id), before any slow npm download. The
#    patch is schema-validated and merged recursively on apply, so manual
#    additions under other keys are preserved. Set OPENCLAW_MANAGED_CONFIG=0 to
#    manage config by hand.
# ---------------------------------------------------------------------------
PATCH_FILE=""
if [ "${OPENCLAW_MANAGED_CONFIG:-1}" = "1" ]; then
  log "Generating managed config from environment..."
  PATCH_FILE="$(mktemp)"
  if ! node "$EGG_DIR/config-gen.js" > "$PATCH_FILE"; then
    log "FATAL: failed to generate config patch (see errors above)"
    rm -f "$PATCH_FILE"
    exit 1
  fi
else
  log "OPENCLAW_MANAGED_CONFIG=0 — leaving openclaw.json untouched (managing by hand)."
fi

# ---------------------------------------------------------------------------
# 2b. Install non-bundled channel plugins. Runs while the gateway is stopped (a
#     running gateway rejects config mutations) and BEFORE the config patch is
#     applied, so a channel block is never written before its plugin exists.
# ---------------------------------------------------------------------------
if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
  if ! ensure_plugin_installed discord "@openclaw/discord" \
       "openclaw-discord-*/node_modules/@openclaw/discord/dist/index.js"; then
    rm -f "$PATCH_FILE"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 2c. Apply the generated patch now that any required plugins are present.
# ---------------------------------------------------------------------------
if [ -n "$PATCH_FILE" ]; then
  log "Applying managed config..."
  if ! openclaw config patch --stdin < "$PATCH_FILE"; then
    log "FATAL: failed to apply config patch (see errors above)"
    rm -f "$PATCH_FILE"
    exit 1
  fi
  rm -f "$PATCH_FILE"
fi

# ---------------------------------------------------------------------------
# 3. Skills: clone/update repos listed in SKILLS_REPOS into workspace/skills.
# ---------------------------------------------------------------------------
if ! bash "$EGG_DIR/pull-skills.sh"; then
  if [ "${SKILLS_REQUIRED:-0}" = "1" ]; then
    log "FATAL: skill sync failed and SKILLS_REQUIRED=1 (see the [pull-skills] warnings above)."
    exit 1
  fi
  log "skill sync reported errors (continuing; set SKILLS_REQUIRED=1 to make this fatal)."
fi

# ---------------------------------------------------------------------------
# 4. Validate before starting so misconfig fails fast in the console.
# ---------------------------------------------------------------------------
log "Validating configuration..."
if ! openclaw config validate; then
  log "FATAL: configuration is invalid (see errors above)"
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Start the Gateway. Wings provides the egg startup command via $STARTUP
#    ({{VAR}} -> ${VAR}); fall back to a sane default for plain `docker run`.
# ---------------------------------------------------------------------------
if [ -n "${STARTUP:-}" ]; then
  # Pterodactyl convention: expand {{VAR}} -> ${VAR} and eval the admin-defined
  # startup line. The variables it references (PORT/BIND/AUTH) are allowlisted in
  # the preflight above. Word-splitting on the result is intentional — it turns
  # the line into argv — so this path can only run the egg's startup template.
  CMD=$(eval echo "$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")
  # If $STARTUP referenced an unset variable, the expansion can be empty or just
  # whitespace; an unquoted `exec` on that would silently succeed and the gateway
  # would never start. Strip ALL whitespace (space/tab/newline) to detect it.
  if [ -z "${CMD//[[:space:]]/}" ]; then
    log "FATAL: \$STARTUP expanded to an empty command — check it and that its {{variables}} are set."
    exit 1
  fi
  log "OpenClaw bootstrap complete — starting gateway."
  echo ":/home/container\$ ${CMD}"
  exec ${CMD}
else
  # No $STARTUP (e.g. a plain `docker run`): build argv directly from the
  # validated values so quoting and word-splitting can never be subverted.
  log "OpenClaw bootstrap complete — starting gateway."
  echo ":/home/container\$ openclaw gateway --port ${PORT} --bind ${BIND} --auth ${AUTH} --verbose"
  exec openclaw gateway --port "$PORT" --bind "$BIND" --auth "$AUTH" --verbose
fi
