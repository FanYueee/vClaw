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
WORKSPACE="$CONFIG_DIR/workspace"
EGG_DIR="/opt/openclaw-egg"

log() { echo "[openclaw-egg] $*"; }

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

# ---------------------------------------------------------------------------
# 1b. Install non-bundled channel plugins. Telegram ships bundled, but Discord
#     (and most others) must be fetched once via `openclaw plugins install`,
#     which installs into ~/.openclaw/npm on the persistent volume. Must happen
#     while the gateway is stopped (a running gateway rejects config mutations).
# ---------------------------------------------------------------------------
# Install a channel plugin via its npm package, idempotently. Plugins install
# under ~/.openclaw/npm/projects/<dir-glob> on the persistent volume; checking
# for that directory is a fast, deterministic "already installed" signal that
# avoids re-downloading on every restart.
ensure_plugin_installed() {
  local channel="$1" pkg="$2" dir_glob="$3"
  if compgen -G "$CONFIG_DIR/npm/projects/$dir_glob" >/dev/null 2>&1; then
    log "Channel '${channel}' plugin already installed — skipping download."
    return 0
  fi
  log "Installing '${channel}' plugin (${pkg}) — first boot only, downloads from npm..."
  # A trailing "config changed since last load" notice here is benign; the
  # plugin files still install. We re-apply our config patch below regardless.
  openclaw plugins install "$pkg" \
    || log "WARN: '${channel}' plugin install reported an error (continuing)"
}

if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
  ensure_plugin_installed discord "@openclaw/discord" "openclaw-discord-*"
fi

# ---------------------------------------------------------------------------
# 2. Apply env-driven config patch (every boot in managed mode). The patch is
#    schema-validated and merged recursively, so manual additions under other
#    keys are preserved. Set OPENCLAW_MANAGED_CONFIG=0 to manage config by hand.
# ---------------------------------------------------------------------------
if [ "${OPENCLAW_MANAGED_CONFIG:-1}" = "1" ]; then
  log "Applying managed config from environment..."
  if ! node "$EGG_DIR/config-gen.js" | openclaw config patch --stdin; then
    log "FATAL: failed to apply config patch"
    exit 1
  fi
else
  log "OPENCLAW_MANAGED_CONFIG=0 — leaving openclaw.json untouched."
fi

# ---------------------------------------------------------------------------
# 3. Skills: clone/update repos listed in SKILLS_REPOS into workspace/skills.
# ---------------------------------------------------------------------------
bash "$EGG_DIR/pull-skills.sh" || log "skill sync reported errors (continuing)"

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
  CMD=$(eval echo "$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")
else
  CMD="openclaw gateway --port ${SERVER_PORT:-18789} --bind ${GATEWAY_BIND:-loopback} --auth ${GATEWAY_AUTH:-none} --verbose"
fi

log "OpenClaw bootstrap complete — starting gateway."
echo ":/home/container$ ${CMD}"
exec ${CMD}
