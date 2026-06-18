#!/usr/bin/env node
/*
 * Emits an OpenClaw config patch (JSON, a valid JSON5 subset) on stdout, built
 * from environment variables. Piped into `openclaw config patch --stdin`, which
 * validates against the schema and merges recursively.
 *
 * Patch merge semantics (from `openclaw config patch`): objects merge, arrays
 * and scalars replace, and `null` DELETES a path. We therefore emit explicit
 * `null` for every optional key that is not currently requested, so clearing an
 * env var actually removes stale config (channels, fallbacks, owners, etc.)
 * rather than leaving previously-applied values behind.
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

const errors = [];
const warn = (msg) => process.stderr.write(`[config-gen] WARNING: ${msg}\n`);
const fail = (msg) => {
  errors.push(msg);
  process.stderr.write(`[config-gen] ERROR: ${msg}\n`);
};

// ---- LLM provider (DeepSeek-style OpenAI-compatible endpoint by default) ----
// This egg defines exactly ONE provider block (LLM_PROVIDER_ID). The model id
// is taken verbatim from the env — it may itself contain slashes (e.g. an
// OpenRouter id like "deepseek/deepseek-chat"). The full model ref is always
// "<providerId>/<modelId>"; we never treat a slash in the model id as a
// different, undefined provider.
const providerId = env.LLM_PROVIDER_ID || 'deepseek';
const baseUrl = env.LLM_BASE_URL || 'https://api.deepseek.com/v1';
const primaryId = env.MODEL_PRIMARY || 'deepseek-chat';
const fallbackIds = list(env.MODEL_FALLBACKS).map((m) =>
  // Tolerate a user accidentally prefixing the model with the provider id.
  m.startsWith(`${providerId}/`) ? m.slice(providerId.length + 1) : m
);
const ctx = int(env.MODEL_CONTEXT_WINDOW, 128000);
const maxTok = int(env.MODEL_MAX_TOKENS, 8192);

// ---- Validate inputs (defense-in-depth) ----
// The egg's variable rules already constrain these, but config-gen can also run
// from a plain `docker run` without that layer. Catch obviously-broken values
// here so the failure is a clear message rather than a downstream schema error.
if (!/^[A-Za-z0-9._-]+$/.test(providerId)) {
  fail(`LLM_PROVIDER_ID '${providerId}' must match [A-Za-z0-9._-]+ (it is a config key and the model-ref prefix).`);
}
if (!/^https?:\/\//i.test(baseUrl)) {
  fail(`LLM_BASE_URL '${baseUrl}' must be an http(s) URL.`);
}
if (!primaryId || /[\s\u0000-\u001f]/.test(primaryId)) {
  fail('MODEL_PRIMARY must be a non-empty model id with no whitespace or control characters.');
}
if (!(ctx > 0)) {
  fail(`MODEL_CONTEXT_WINDOW must be a positive integer (got '${env.MODEL_CONTEXT_WINDOW}').`);
}
if (!(maxTok > 0)) {
  fail(`MODEL_MAX_TOKENS must be a positive integer (got '${env.MODEL_MAX_TOKENS}').`);
}

const ref = (modelId) => `${providerId}/${modelId}`;

const modelIds = [...new Set([primaryId, ...fallbackIds])];
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

const provider = {
  baseUrl,
  apiKey: '${LLM_API_KEY}',
  api: 'openai-completions',
  models: modelDefs,
  // null => delete any previously-set compat block when no longer requested.
  compat: bool(env.MODEL_REQUIRES_REASONING_CONTENT)
    ? { requiresReasoningContentOnAssistantMessages: true }
    : null,
};

const patch = {
  // Enforce local gateway mode so `openclaw gateway` starts without
  // --allow-unconfigured.
  gateway: { mode: 'local' },

  agents: {
    defaults: {
      model: {
        primary: ref(primaryId),
        // null => delete stale fallbacks when MODEL_FALLBACKS is cleared.
        fallbacks: fallbackIds.length ? fallbackIds.map(ref) : null,
      },
    },
  },

  models: {
    mode: 'merge',
    providers: { [providerId]: provider },
  },

  // Default to deletion; each enabled channel overwrites its key below.
  channels: { telegram: null, discord: null },
};

// ---- Channels (enabled only when a bot token is present) ----
// A channel with a bot token but no owner id is a misconfiguration: it would
// start an allowlist channel that nobody is authorized to use. Fail fast so the
// operator fixes it instead of running a half-open bot.
const owners = [];

if (env.TELEGRAM_BOT_TOKEN) {
  const tgOwner = (env.OWNER_TG_ID || '').trim();
  if (!tgOwner) {
    fail('TELEGRAM_BOT_TOKEN is set but OWNER_TG_ID is empty. Set your numeric Telegram user ID (required for the allowlist), or unset the token to disable Telegram.');
  } else if (!/^\d+$/.test(tgOwner)) {
    fail(`OWNER_TG_ID '${env.OWNER_TG_ID}' must be a numeric Telegram user ID (digits only).`);
  } else {
    // botToken omitted on purpose: OpenClaw falls back to the TELEGRAM_BOT_TOKEN
    // env var for the default account. Allowlist avoids interactive pairing.
    patch.channels.telegram = {
      enabled: true,
      dmPolicy: 'allowlist',
      allowFrom: [tgOwner],
    };
    owners.push(`telegram:${tgOwner}`);
  }
}

if (env.DISCORD_BOT_TOKEN) {
  const dcOwner = (env.OWNER_DISCORD_ID || '').trim();
  if (!dcOwner) {
    fail('DISCORD_BOT_TOKEN is set but OWNER_DISCORD_ID is empty. Set your numeric Discord user ID (required for the allowlist), or unset the token to disable Discord.');
  } else if (!/^\d+$/.test(dcOwner)) {
    fail(`OWNER_DISCORD_ID '${env.OWNER_DISCORD_ID}' must be a numeric Discord user ID (digits only).`);
  } else {
    patch.channels.discord = {
      enabled: true,
      dmPolicy: 'allowlist',
      token: { source: 'env', provider: 'default', id: 'DISCORD_BOT_TOKEN' },
      allowFrom: [`discord:${dcOwner}`],
    };
    owners.push(`discord:${dcOwner}`);
  }
}

if (!patch.channels.telegram && !patch.channels.discord && !errors.length) {
  warn('No channel enabled: set TELEGRAM_BOT_TOKEN and/or DISCORD_BOT_TOKEN (each with its owner ID).');
}

// Owner-scoped commands: replace with the current owner set, or delete it.
patch.commands = { ownerAllowFrom: owners.length ? owners : null };

if (errors.length) {
  process.stderr.write(`[config-gen] Refusing to emit config due to ${errors.length} error(s) above.\n`);
  process.exit(1);
}

process.stdout.write(JSON.stringify(patch, null, 2));
