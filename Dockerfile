# OpenClaw on Pterodactyl
# A Pterodactyl-compatible image that runs the OpenClaw Gateway in the
# foreground, configured headlessly from environment variables.
#
# Build:
#   docker build --build-arg OPENCLAW_VERSION=latest -t ghcr.io/<you>/openclaw-pterodactyl:latest .
FROM node:24-bookworm-slim

ARG OPENCLAW_VERSION=latest

LABEL org.opencontainers.image.title="OpenClaw on Pterodactyl" \
      org.opencontainers.image.description="Headless OpenClaw Gateway (Discord + Telegram) packaged as a Pterodactyl egg image" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps: tini (PID 1 / signal handling), git (skill repos), ripgrep
# (agent tooling), ca-certificates + curl (TLS / fetches), tzdata (logs).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tini \
        git \
        ripgrep \
        ca-certificates \
        curl \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw globally. Pin the version via build arg / image tag so the
# running version is controlled by the image, not by a runtime npm pull.
RUN npm install -g "openclaw@${OPENCLAW_VERSION}" \
    && npm cache clean --force \
    && openclaw --version

# Pterodactyl convention: an unprivileged "container" user whose home is the
# persistent server volume. OpenClaw stores everything under ~/.openclaw, so by
# setting HOME=/home/container all config / workspace / skills land on the
# volume and survive restarts and image upgrades automatically.
RUN useradd -m -d /home/container -s /bin/bash container
ENV USER=container HOME=/home/container

# Disable ANSI colors. Wings attaches a TTY (so OpenClaw would colorize), but it
# matches the egg's startup-done string by LITERAL substring against the console
# output. Colorized output splits "[gateway] ready" with escape codes so the
# match fails and the server is stuck "starting". Plain output keeps the console
# readable in the panel and lets done-detection work.
ENV NO_COLOR=1 FORCE_COLOR=0

# Egg helper scripts live OUTSIDE /home/container (which gets shadowed by the
# Pterodactyl volume mount at runtime).
COPY docker/ /opt/openclaw-egg/
RUN chmod +x /opt/openclaw-egg/entrypoint.sh /opt/openclaw-egg/pull-skills.sh

USER container
WORKDIR /home/container

# tini reaps zombies and forwards signals (Pterodactyl stops via SIGINT).
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
# Wings injects the egg's startup command as $STARTUP; the entrypoint bootstraps
# config + skills, then evals it. CMD is kept (Wings does not override it).
CMD ["/bin/bash", "/opt/openclaw-egg/entrypoint.sh"]
