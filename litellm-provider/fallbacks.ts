/**
 * Fallback-chain resolution for the litellm-provider extension (#358).
 *
 * Pure and table-tested (the extension body only wires the result): the
 * contract is "a semantically-bad override degrades to the DEFAULT chain,
 * loudly" — never a crash, never a silently-wrong chain (r16-style review
 * of #359: valid JSON with a wrong shape is the accidental-value risk).
 */

// Platform decision (#363): the review primary is the mtplx speed target
// (ops template flip, k8s-config 8c1fb609) — speed → qwen3.8-flash.
// History: speed was demoted 2026-09-08 (#373's rollback — it STALLED at
// long context: an HTTP-level stall at ~20k tokens, nowhere near a window
// boundary, so no window arithmetic prevents it; the honest justification
// for re-promotion is the platform's call that the provider defect is
// resolved — and if it recurs, this chain turns the stall into a mid-run
// failover to flash instead of a dead stream).
//
// The flash → glm entry (#373's chain) is retained deliberately: chains
// are keyed by PRIMARY model id, so a single-entry table silently strips
// failover from every other primary — and this chart's own default
// (chart/values.yaml pr-review) still runs flash. Both live directions
// ship; a key whose primary this proxy does not serve is inert and is
// reported at startup (unwiredChains, below). All ids live in the proxy
// key's scope.
export const DEFAULT_FALLBACKS: Record<string, string[]> = {
  // The fleet's pinned review primary (owner directive 2026-10-25) is the
  // ANTHROPIC-route variant — the #363 key below is a DIFFERENT proxy group
  // (the bare alias), and a chain keyed for one id does not serve the other.
  // The 2026-10-25 outage: every review round died at turn 1 because the
  // live model id had NO wired chain and the upstream hiccuped. Net =
  // glm-5.3-flash (verified live 2026-10-25: healthy at 23k-token contexts,
  // 2.9s) — ali flash is the Token Plan quota-dead group until 2026-10-31
  // (429 Throttling.AllocationQuota, verified), so it must not be the net
  // of a production chain until that reset.
  "mtplx/anthropic/qwen38-27b-optimized-speed-fp16": ["zai/anthropic/glm-5.3-flash"],
  "mtplx/qwen38-27b-optimized-speed-fp16": ["ali/anthropic/qwen3.8-flash"],
  "ali/anthropic/qwen3.8-flash": ["zai/anthropic/glm-5.3-flash"],
  // Night-window primary (owner directive): deepseek-v4.1-flash 16:00-02:00
  // CET with glm-5.3-flash as the all-hours second option. The chain is
  // INERT until the proxy catalog lists the id (unwiredChains below) — the
  // LiteLLM admin must add the model and grant the fleet key access
  // (probe evidence, #507: absent from /v1/models, key not allowed).
  "ali/anthropic/deepseek-v4.1-flash": ["zai/anthropic/glm-5.3-flash"],
  // Night-window primary (owner directive, #536 → -230): qwen3.8-max
  // 16:00-02:00 CET. Proxy-verified served (991,808 in / 131,072 out);
  // unproven on the finalize contract, so its net is flash — the only id
  // with green fleet history on the review round — and flash is larger in
  // both dims, so this chain clamps nothing.
  "ali/anthropic/qwen3.8-max": ["ali/anthropic/qwen3.8-flash"],
  // glm is a live primary too — the --model default of cmd/harmostes-agent
  // and harmostes.py (#401 review r2): without an entry a glm-primary run
  // attaches no failover at all. flash is LARGER in both dimensions, so
  // this entry clamps nothing.
  //
  // Ring note: flash→glm→flash is a cycle at the TABLE level, but LiteLLM
  // request-level fallbacks are one list deep — a failing fallback ENDS
  // the request, and the next attempt restarts at the configured primary.
  // There is no in-request ping-pong; cross-attempt retry storms are the
  // worker's attempt bound, not the chain's.
  "zai/anthropic/glm-5.3-flash": ["ali/anthropic/qwen3.8-flash"],
};

/**
 * Parse a LITELLM_FALLBACKS override: a JSON object whose keys are model ids
 * and whose values are NON-EMPTY ARRAYS of non-empty string model ids.
 * Anything else — unparsable JSON, non-object, non-array values, empty
 * arrays, non-string members — degrades to the default with a reason string
 * (logged by the caller).
 */
// The default must not leak by reference into callers that might normalise
// in place (r18-review P2: a key mutation reached the exported const; the
// #401 review extended it to VALUES — a shallow copy still shares the
// chain arrays, so a push() grew the platform decision). Clone one level
// down: fresh map, fresh arrays.
const copyDefaultChains = (): Record<string, string[]> =>
  Object.fromEntries(Object.entries(DEFAULT_FALLBACKS).map(([k, v]) => [k, [...v]]));

export function resolveFallbackChains(
  raw: string | undefined,
): { chains: Record<string, string[]>; warning?: string } {
  if (raw === undefined || raw.trim() === "") {
    return { chains: copyDefaultChains() };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { chains: copyDefaultChains(), warning: "LITELLM_FALLBACKS is not valid JSON — keeping default chains" };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { chains: copyDefaultChains(), warning: "LITELLM_FALLBACKS is not a JSON object — keeping default chains" };
  }
  const chains: Record<string, string[]> = {};
  for (const [model, chain] of Object.entries(parsed as Record<string, unknown>)) {
    if (!Array.isArray(chain) || chain.length === 0 || !chain.every((id) => typeof id === "string" && id.trim() !== "")) {
      return {
        chains: copyDefaultChains(),
        warning: `LITELLM_FALLBACKS["${model}"] is not a non-empty array of model ids — keeping default chains`,
      };
    }
    chains[model] = chain as string[];
  }
  return { chains };
}

/**
 * The wiring summary line's tail: distinguishes "nothing configured" (the
 * '{}' off-switch) from "configured but nothing usable" (typo'd/partial
 * override, group dropped mid-rollout) — the dead-stream symptom becomes a
 * one-glance diagnosis (#401 review r2; pure so the branches are
 * table-tested — index.ts itself is import-gate only).
 */
export function wiringSummary(wired: string[], chains: Record<string, string[]>): string {
  if (wired.length) return ` | fallbacks wired: ${wired.join("; ")}`;
  const keys = Object.keys(chains);
  return keys.length
    ? ` | no fallbacks wired — chains configured for: ${keys.join(", ")}`
    : " | no fallbacks wired — none configured (LITELLM_FALLBACKS='{}' disables all chains)";
}

/** One model's registration-relevant fields after chain application. */

export interface ChainedModel {
  id: string;
  contextWindow: number;
  maxTokens: number;
  /** Present ONLY when a non-empty, fully-resolved chain applies. */
  samplingParams?: Record<string, unknown>;
  /** Set when a chain clamped this model's window (observability, r17 P7b). */
  clampNote?: string;
  /** Fallback ids dropped for not being discovered proxy groups. */
  droppedIds: string[];
}

/**
 * Apply fallback chains to the proxy's discovered model list. Pure: no
 * fetch, no env — the table tests own every branch.
 *
 * Contract (r17-review P4/P7):
 * - an unchained model carries NO samplingParams key (an explicit empty
 *   `fallbacks: []` would OVERRIDE proxy-configured fallbacks — the
 *   opposite of this feature's name, on every model, fleet-wide);
 * - a chained model's ids are filtered to DISCOVERED groups (a router
 *   cannot fail over to a group it does not know); dropped ids surface in
 *   `droppedIds` for the warning log;
 * - a chain that filters to empty attaches nothing (invisible in
 *   `wired` — the caller's summary log distinguishes "none configured"
 *   from "configured but none wired");
 * - chained models register min(primary, fallback) windows so the
 *   post-failover replay fits the fallback group (with a clampNote for
 *   the log).
 */
export function applyChains(
  models: Array<{ id: string; max_input_tokens?: number; max_output_tokens?: number }>,
  chains: Record<string, string[]>,
  byId: Map<string, { max_input_tokens?: number; max_output_tokens?: number }>,
): { wired: string[]; annotated: ChainedModel[]; unwiredChains: string[] } {
  const wired: string[] = [];
  // Chains keyed by a primary this proxy does not serve are INERT — the
  // per-model loop below never reaches them (no droppedIds, no clampNote,
  // no warning). Surface exactly that: keys with NO DISCOVERED PRIMARY.
  // This does NOT cover every inert shape — undiscovered FALLBACK ids
  // surface per-model via droppedIds, an empty-filtering chain attaches
  // nothing, and a served primary with no entry here is invisible to this
  // field (the caller's summary log covers the last two) (#401 review r2).
  const unwiredChains = Object.keys(chains).filter((id) => !byId.has(id));
  const annotated = models.map((model) => {
    const rawChain = chains[model.id];
    const contextWindow = model.max_input_tokens ?? 131072;
    const maxTokens = model.max_output_tokens ?? 8192;
    const out: ChainedModel = { id: model.id, contextWindow, maxTokens, droppedIds: [] };
    // Own-property lookup + shape guard: a proxy model literally named
    // "toString" would otherwise read a FUNCTION off the prototype and
    // crash the extension factory (r18-review P4.3, probe-verified).
    if (!Object.hasOwn(chains, model.id)) return out;
    if (!Array.isArray(rawChain)) return out;

    const chain = [...new Set(rawChain)] // dedupe — a doubled id fails over to the same dead group twice
      .filter((id) => {
        if (id !== model.id && byId.has(id)) return true;
        out.droppedIds.push(id);
        return false;
      });
    if (chain.length === 0) return out; // nothing usable — attach no key at all

    let cw = contextWindow;
    let mt = maxTokens;
    for (const id of chain) {
      const fb = byId.get(id)!;
      if (fb.max_input_tokens && fb.max_input_tokens < cw) cw = fb.max_input_tokens;
      if (fb.max_output_tokens && fb.max_output_tokens < mt) mt = fb.max_output_tokens;
    }
    if (cw < contextWindow || mt < maxTokens) {
      // Report whichever dimension ACTUALLY clamped (r18-review P4.2: a
      // maxTokens-only clamp logged "ctx A→A" — a clamp that did not
      // happen, hiding the one that did).
      const parts: string[] = [];
      if (cw < contextWindow) parts.push(`ctx ${contextWindow}→${cw}`);
      if (mt < maxTokens) parts.push(`maxTokens ${maxTokens}→${mt}`);
      out.clampNote = `${parts.join(", ")} (fallback clamp)`;
      out.contextWindow = cw;
      out.maxTokens = mt;
    }
    out.samplingParams = { fallbacks: chain };
    wired.push(`${model.id} → ${chain.join(", ")}`);
    return out;
  });
  return { wired, annotated, unwiredChains };
}
