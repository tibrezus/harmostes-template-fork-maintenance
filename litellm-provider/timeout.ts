/**
 * Failover-deadline resolution for the litellm-provider extension
 * (owner directive 2026-11-14: agents are optimized for reactiveness —
 * the local primary is attempted FIRST, but a busy local box must not
 * stall a review round; the shift to the cloud fallback happens VIA a
 * timeout, swiftly).
 *
 * The mechanism rides the SAME request-level params as the fallback
 * chain (LiteLLM proxy):
 *
 *   timeout: <seconds>   — LiteLLM's per-request bound. For a live
 *                          stream this is the wait for the NEXT chunk
 *                          (a silent primary — queued, not streaming —
 *                          dies at the deadline; a healthy stream with
 *                          tokens flowing never trips it).
 *   num_retries: 0       — no sibling/primary re-attempts. The proxy's
 *                          default retries would re-queue the SAME busy
 *                          local box once per retry (deadline ×
 *                          (1 + num_retries)) before ever shifting;
 *                          0 makes the first deadline the shift.
 *
 * The composite fleet contract (kernel ships the logic, the deployment
 * decides the values):
 *
 *   pi http wall (2 min)  — extensions/sol-pi/settings.json
 *                           httpIdleTimeoutMs=120000: undici headers +
 *                           inter-chunk idle at the pi edge. This is the
 *           backstop, not the shift: pi aborting its own HTTP request
 *                           cannot move the proxy to the fallback (a
 *                           fresh pi attempt restarts at the primary).
 *   proxy deadline (100s) — this file's default, overridable via
 *                           LITELLM_PRIMARY_TIMEOUT_S on the worker
 *                           pool. Strictly BELOW the pi wall so the
 *                           proxy shifts and the fallback's first chunk
 *                           arrives inside pi's 2 minutes.
 *   one pi retry          — settings.json retry.provider.maxRetries=1:
 *                           if the whole chain still dies (or the proxy
 *                           itself wedges), pi re-requests exactly once;
 *                           that attempt restarts at the primary.
 *
 * Attached ONLY to models with a wired fallback chain — the deadline is
 * the chain's shift lever; on an unchained model a timeout with nowhere
 * to fail over would just kill the request.
 *
 * Pure and table-tested (timeout.test.ts); the extension body only
 * wires the result. Contract mirrors fallbacks.ts: a semantically-bad
 * override degrades to the default, LOUDLY — never a crash, never a
 * silently-wrong deadline.
 */

/** The baked fleet default: 100s — 20s under pi's 2-minute wall. */
export const DEFAULT_PRIMARY_TIMEOUT_S = 100;

export interface PrimaryTimeout {
  /** 0 = off (no timeout params attached). */
  seconds: number;
  /** Present when the env override was ignored — logged by the caller. */
  warning?: string;
}

/**
 * Parse LITELLM_PRIMARY_TIMEOUT_S. Accepted: unset/empty (default),
 * "0" (off), or a positive integer. Anything else degrades to the
 * default with a reason string.
 */
export function resolvePrimaryTimeout(raw: string | undefined): PrimaryTimeout {
  if (raw === undefined || raw.trim() === "") {
    return { seconds: DEFAULT_PRIMARY_TIMEOUT_S };
  }
  const trimmed = raw.trim();
  if (trimmed === "0") {
    return { seconds: 0 };
  }
  if (!/^\d+$/.test(trimmed)) {
    return {
      seconds: DEFAULT_PRIMARY_TIMEOUT_S,
      warning: `LITELLM_PRIMARY_TIMEOUT_S "${trimmed}" is not 0 or a positive integer — keeping default ${DEFAULT_PRIMARY_TIMEOUT_S}s`,
    };
  }
  const n = Number(trimmed);
  if (n === 0) {
    return { seconds: 0 };
  }
  return { seconds: n };
}
