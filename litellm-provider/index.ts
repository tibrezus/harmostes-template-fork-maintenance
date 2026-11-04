/**
 * LiteLLM Proxy provider extension for pi.
 *
 * Registers all models exposed by a LiteLLM proxy as the "litellm" provider.
 * LiteLLM is an OpenAI-compatible router/gateway, so every model uses the
 * openai-completions streaming API.
 *
 * Required env vars (injected by the harmostes controller from the
 * harmostes-litellm-token secret):
 *
 *   LITELLM_URL      e.g. https://litellm.example.com
 *   LITELLM_API_KEY  the proxy's master key or virtual key
 *
 * Models are referenced as litellm/<model-id>, e.g. litellm/zai/anthropic/glm-5.3-flash.
 * The <model-id> is passed verbatim to LiteLLM's /v1/chat/completions endpoint,
 * which routes it to the correct upstream provider.
 *
 * Model discovery is dynamic: the extension fetches /v1/models at startup so
 * new models added to the proxy are available immediately without rebuilding
 * the worker image.
 *
 * Fallbacks (#358): models with a configured fallback chain carry LiteLLM's
 * request-level `fallbacks` param (via Model.samplingParams) — when the
 * primary model group fails mid-run, the proxy's router fails over to the
 * fallback group and the agent's stream continues instead of dying. Default
 * chains: mtplx/qwen38-27b-optimized-speed-fp16 → ali/anthropic/qwen3.8-flash
 * and ali/anthropic/qwen3.8-flash → zai/anthropic/glm-5.3-flash (every live
 * primary direction carries an entry — chains are keyed by primary, and an
 * entry for any other primary would be inert; #363, #401 review). Override with
 * LITELLM_FALLBACKS, a JSON object
 * mapping model id → array of fallback ids — resolved by fallbacks.ts, which
 * degrades to the default chain on any semantically-bad value. NOTE the
 * naming boundary: on the proxy, ids are BARE group names (mtplx/...);
 * harmostes-side model strings carry the litellm/ provider prefix
 * (litellm/mtplx/...).
 *
 * Honest limits (r16/r17/r18 reviews — the canonical statement; the code
 * points here instead of restating it): (1) LITELLM_FALLBACKS is delivered
 * to agents via jobEnvAllowlist (worker/dispatch.go) from the pool pod's
 * env — set it on the worker Deployment. `LITELLM_FALLBACKS='{}'` DISABLES
 * all chains (the off-switch); unset keeps the default. (2) A run that
 * failed over is indistinguishable from a healthy run here (same --model
 * string); attribute via the proxy's router logs, which record the serving
 * group per request. (3) Chained models register min(primary, fallback)
 * windows so the post-failover replay fits the fallback group — a real
 * capacity cost on every healthy run, taken for correctness — pi compacts
 * at window−reserve, so a chain whose fallback has a SMALLER window pulls
 * the primary's budget down. Per-direction, for the CURRENT table: speed
 * → flash none (min = speed's own 256 KiB); glm → flash none (flash is
 * larger in both dimensions); flash → glm is the costly one — ~8× ctx
 * clamp (1 MiB→128 KiB) PLUS a 4× output clamp (32k→8k tokens), retained
 * on purpose because flash is this chart's default primary and glm is its
 * only other served group (the historical flash→speed direction cost ~4×,
 * 1 MiB→256 KiB — smaller than what we ship today).
 * The alternative, clamping only the fallback and letting the first
 * over-long replay 400, was considered and rejected: it trades a clean
 * early compaction for a dead stream exactly when the primary is already
 * down. (4) The clamp
 * is not transitive: a proxy-side chain hanging off the fallback group is
 * invisible here. Chains are keyed by PRIMARY model id: an entry for a
 * model this proxy does not serve is inert (reported at startup,
 * unwiredChains = keys with no discovered primary; undiscovered fallback
 * ids and empty-filtering chains surface via droppedIds / the wiring
 * summary instead). The default table carries an entry for every live
 * primary direction (speed, flash, glm); a LITELLM_FALLBACKS override
 * REPLACES the whole map — '{}' is the off-switch. (5) A failover moves
 * the whole review context to a
 * DIFFERENT upstream group — chains are Deployment-env-settable, so the
 * trust boundary for review payloads is whoever can edit that Deployment.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { applyChains, resolveFallbackChains, wiringSummary } from "./fallbacks.ts";
import { FLEET_SAMPLING_BY_THINKING_LEVEL } from "./sampling.ts";
import { deserializeThinking, wireThinkingMap } from "./thinking.ts";

export default async function (pi: ExtensionAPI) {
  const rawUrl = process.env.LITELLM_URL;
  const apiKey = process.env.LITELLM_API_KEY;

  if (!rawUrl) {
    console.error("[litellm-provider] LITELLM_URL not set — provider not registered");
    return;
  }
  if (!apiKey) {
    console.error("[litellm-provider] LITELLM_API_KEY not set — provider not registered");
    return;
  }

  // Normalise: strip trailing slash for clean URL composition.
  const baseUrl = rawUrl.replace(/\/+$/, "");

  let models: Array<{ id: string; max_input_tokens?: number; max_output_tokens?: number }>;
  try {
    const resp = await fetch(`${baseUrl}/v1/models`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    if (!resp.ok) {
      console.error(`[litellm-provider] /v1/models returned ${resp.status} ${resp.statusText}`);
      return;
    }
    const payload = (await resp.json()) as {
      data: Array<{ id: string; max_input_tokens?: number; max_output_tokens?: number }>;
    };
    models = payload.data ?? [];
  } catch (err) {
    console.error(`[litellm-provider] failed to fetch models from ${baseUrl}/v1/models: ${err}`);
    return;
  }

  if (models.length === 0) {
    console.error("[litellm-provider] proxy returned 0 models — provider not registered");
    return;
  }

  // Fallback chains (#358): model id → LiteLLM request-level `fallbacks`.
  // Resolution/validation is pure and table-tested (fallbacks.ts); a
  // semantically-bad LITELLM_FALLBACKS degrades to the default chain loudly.
  // NOTE: the env is read in the worker IMAGE (piargs loads this extension for
  // every agent) — reaching the override from a deployment means setting it on
  // the worker Deployment/env template, not per-Job.
  const { chains: fallbacks, warning } = resolveFallbackChains(process.env.LITELLM_FALLBACKS);
  if (warning) {
    console.error(`[litellm-provider] ${warning}`);
  }
  const byId = new Map(models.map((m) => [m.id, m]));

  const { wired, annotated, unwiredChains } = applyChains(models, fallbacks, byId);
  if (unwiredChains.length > 0) {
    // Expected on any proxy that serves a SUBSET of the live primaries
    // (the default table is deliberately a superset — honest-limits (4)):
    // a note, not an alarm. The alarm-shaped case is the wiring summary
    // below ("no fallbacks wired").
    console.error(`[litellm-provider] note: default-table primary not served by this proxy (chain inert): ${unwiredChains.join(", ")}`);
  }

  pi.registerProvider("litellm", {
    name: "LiteLLM Proxy",
    baseUrl: `${baseUrl}/v1`,
    apiKey: "$LITELLM_API_KEY",
    api: "openai-completions",
    authHeader: true,
    // All chain math is pure and table-tested (fallbacks.ts:applyChains) —
    // the wiring below only translates the result into provider config.
    models: annotated.map((model) => ({
      id: model.id,
      name: model.id,
      // The hybrid engines on this proxy (qwen3.8-class) REASON BY DEFAULT
      // and unboundedly when undeclared — measured on the pinned speed
      // group: 80% of decoded tokens were reasoning at ~7.3 tok/s (see
      // thinking.ts for the numbers). Declaring reasoning lets pi carry
      // the template's thinking level; string-thinking + the wire map
      // translate it into the ONE shape these routes honor (the anthropic
      // object — reasoning_effort, enable_thinking and chat_template_kwargs
      // were all measured inert). thinking.ts owns the table.
      reasoning: true,
      thinkingLevelMap: wireThinkingMap(),
      input: ["text" as const],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: model.contextWindow,
      maxTokens: model.maxTokens,
      // LiteLLM's request-level failover: when this model group fails, the
      // proxy retries the chain server-side and the stream never breaks.
      // ABSENT on unchained models — an explicit `fallbacks: []` would
      // override proxy-configured fallbacks with "none", fleet-wide
      // (r17-review P4.1: observed live via a stubbed /v1/models).
      samplingParams: model.samplingParams,
      // Fleet sampling policy (#657, pi 1.0.2+): mechanical tiers get
      // deterministic-lean sampling; medium+ inherit model defaults (the
      // key is absent there). Applied UNIFORMLY at registration — the
      // models are discovered dynamically from the proxy, so per-id
      // entries in a baked models.json would drift with the routing
      // table; the one choke point every litellm model crosses is here.
      // OpenAI-completions-class only (pi ignores it elsewhere).
      samplingParamsByThinkingLevel: FLEET_SAMPLING_BY_THINKING_LEVEL,
      compat: {
        // LiteLLM proxies upstream providers; use the broadest-compatible flags.
        supportsDeveloperRole: false,
        maxTokensField: "max_tokens",
        // pi serializes the level through ThinkingLevelMap verbatim (a JSON
        // string — pi's map is string-typed); before_provider_request below
        // parses the envelope back onto the wire.
        thinkingFormat: "string-thinking",
      },
    })),
  });

  // The wire rewrite: string envelopes from the level map become the
  // anthropic thinking objects these routes honor. Pure and table-tested
  // (thinking.ts / thinking.test.ts); anything that isn't our envelope
  // passes through untouched.
  pi.on("before_provider_request", (event) => deserializeThinking(event.payload));

  for (const model of annotated) {
    for (const id of model.droppedIds) {
      console.error(`[litellm-provider] WARNING: fallback "${id}" (for ${model.id}) is not a known proxy group — dropped`);
    }
    if (model.clampNote) {
      console.error(`[litellm-provider] ${model.id}: ${model.clampNote}`);
    }
  }
  // Honest wiring log: applyChains reports the chains actually ATTACHED —
  // fully-resolved (primary known, every fallback id a discovered group)
  // and non-empty. Anything else is "no fallbacks wired" for that model.
  console.error(
    `[litellm-provider] registered ${models.length} model(s): ${models.map((m) => m.id).join(", ")}` +
      wiringSummary(wired, fallbacks),
  );
}
