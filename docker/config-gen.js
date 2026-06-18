#!/usr/bin/env node
/*
 * Emits an OpenClaw config patch (JSON, a valid JSON5 subset) on stdout, built
 * from environment variables. Piped into `openclaw config patch --stdin`, which
 * validates against the schema and merges recursively.
 *
 * Secrets are NOT written into the patch:
 *   - provider apiKey uses ${LLM_API_KEY} substitution (resolved at config load)
 *   - Telegram bot token comes from the TELEGRAM_BOT_TOKEN env fallback
 *   - Discord bot token is referenced via a SecretRef to DISCORD_BOT_TOKEN
 */
'use strict';

const env = process.env;
const bool = (v, d = false) => (v == null ? d : /^(1|true|yes|on)$/i.test(v));
const list = (v) => (v || '').split(',').map((s) => s.trim()).filter(Boolean);
const int = (v, d) => {
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : d;
};

// ---- LLM provider (DeepSeek-style OpenAI-compatible endpoint by default) ----
const providerId = env.LLM_PROVIDER_ID || 'deepseek';
const baseUrl = env.LLM_BASE_URL || 'https://api.deepseek.com/v1';
const primaryId = env.MODEL_PRIMARY || 'deepseek-chat';
const fallbackIds = list(env.MODEL_FALLBACKS);
const ctx = int(env.MODEL_CONTEXT_WINDOW, 128000);
const maxTok = int(env.MODEL_MAX_TOKENS, 8192);

const ref = (id) => (id.includes('/') ? id : `${providerId}/${id}`);
const localId = (id) => (id.includes('/') ? id.split('/').slice(1).join('/') : id);

// One model definition per distinct local model id we reference.
const modelIds = [...new Set([primaryId, ...fallbackIds].map(localId))];
const modelDefs = modelIds.map((id) => ({
  id,
  name: id,
  // DeepSeek's reasoner ("R1") models expose reasoning; flag by name heuristic.
  reasoning: /reason|r1|think/i.test(id),
  input: ['text'],
  contextWindow: ctx,
  maxTokens: maxTok,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
}));

const patch = {
  // Enforce local gateway mode so `openclaw gateway` starts without
  // --allow-unconfigured.
  gateway: { mode: 'local' },

  agents: {
    defaults: {
      model: {
        primary: ref(primaryId),
        ...(fallbackIds.length ? { fallbacks: fallbackIds.map(ref) } : {}),
      },
    },
  },

  models: {
    mode: 'merge',
    providers: {
      [providerId]: {
        baseUrl,
        apiKey: '${LLM_API_KEY}',
        api: 'openai-completions',
        models: modelDefs,
        ...(bool(env.MODEL_REQUIRES_REASONING_CONTENT)
          ? { compat: { requiresReasoningContentOnAssistantMessages: true } }
          : {}),
      },
    },
  },

  channels: {},
};

// ---- Channels (enabled only when a bot token is present) ----
const owners = [];

if (env.TELEGRAM_BOT_TOKEN) {
  // botToken omitted on purpose: OpenClaw falls back to the TELEGRAM_BOT_TOKEN
  // env var for the default account. Allowlist avoids interactive pairing.
  const tg = { enabled: true, dmPolicy: 'allowlist' };
  if (env.OWNER_TG_ID) {
    tg.allowFrom = [env.OWNER_TG_ID];
    owners.push(`telegram:${env.OWNER_TG_ID}`);
  } else {
    warn('TELEGRAM_BOT_TOKEN set but OWNER_TG_ID is empty — nobody is allowlisted to DM the bot.');
  }
  patch.channels.telegram = tg;
}

if (env.DISCORD_BOT_TOKEN) {
  const dc = {
    enabled: true,
    dmPolicy: 'allowlist',
    token: { source: 'env', provider: 'default', id: 'DISCORD_BOT_TOKEN' },
  };
  if (env.OWNER_DISCORD_ID) {
    dc.allowFrom = [`discord:${env.OWNER_DISCORD_ID}`];
    owners.push(`discord:${env.OWNER_DISCORD_ID}`);
  } else {
    warn('DISCORD_BOT_TOKEN set but OWNER_DISCORD_ID is empty — nobody is allowlisted to DM the bot.');
  }
  patch.channels.discord = dc;
}

if (!patch.channels.telegram && !patch.channels.discord) {
  warn('No channel enabled: set TELEGRAM_BOT_TOKEN and/or DISCORD_BOT_TOKEN.');
}

// Owner-scoped commands require explicit owner identities.
if (owners.length) {
  patch.commands = { ownerAllowFrom: owners };
}

function warn(msg) {
  process.stderr.write(`[config-gen] WARNING: ${msg}\n`);
}

process.stdout.write(JSON.stringify(patch, null, 2));
