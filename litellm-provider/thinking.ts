/**
 * Thinking-wire translation for the mtplx-class engines (2026-10-28).
 *
 * MEASURED ECONOMICS (rhesadox#2833 round, 36 messages on the pinned
 * speed engine): decode ≈ 7.3 tok/s median, and 27,239 of 34,065 decoded
 * tokens (~80%) were REASONING — the qwen3.8 hybrid thinks by default
 * and the round spent ~52 of 82 request-minutes decoding reasoning.
 * The kernel declared `reasoning: false`, so pi dropped the template's
 * thinking level entirely and the engine reasoned UNBOUNDED.
 *
 * The engine (anthropic-route through LiteLLM) accepts exactly ONE
 * thinking control shape on the openai-completions wire — the anthropic
 * OBJECT:
 *
 *     {"type":"disabled"} | {"type":"enabled","budget_tokens":N}
 *
 * Measured live 2026-10-28: the object bounds/disables reasoning on BOTH
 * served routes (mtplx speed group AND the zai glm-5.3-flash fallback
 * group). Everything else is silently ignored: `reasoning_effort` barely
 * dents it, `enable_thinking`, `chat_template_kwargs`, string `thinking`
 * and numeric budget fields do nothing.
 *
 * pi's ThinkingLevelMap values are STRING-typed, so the objects travel
 * as JSON text in the level map and `before_provider_request` parses
 * them back onto the wire — the whole template knob chain
 * (workflowTemplates.*.agent.thinking → pi --thinking → this rewrite)
 * becomes real for this fleet. Deployment picks the LEVEL
 * (k8s-config, ADR-0011 Amendment); the kernel owns the wire shape.
 */

export type AnthropicThinking =
	| { type: "disabled" }
	| { type: "enabled"; budget_tokens: number };

/** The fleet's level→wire table (boundaries: off is a hard disable). */
export const ANTHROPIC_THINKING_LEVELS: Record<string, AnthropicThinking> = {
	off: { type: "disabled" },
	minimal: { type: "enabled", budget_tokens: 1024 },
	low: { type: "enabled", budget_tokens: 2048 },
	medium: { type: "enabled", budget_tokens: 8192 },
	high: { type: "enabled", budget_tokens: 16384 },
	max: { type: "enabled", budget_tokens: 32768 },
};

/**
 * The ThinkingLevelMap to register per model: each value is the wire
 * object SERIALIZED. pi stringifies nothing itself — the map value is
 * sent verbatim as `params.thinking`, and `deserializeThinking` (the
 * before_provider_request handler) parses the envelope back onto the
 * wire. Unknown levels fall through pi's `?? level` and are left as a
 * bare string — which this engine ignores harmlessly (measured).
 */
export function wireThinkingMap(): Record<string, string> {
	return Object.fromEntries(
		Object.entries(ANTHROPIC_THINKING_LEVELS).map(([level, obj]) => [level, JSON.stringify(obj)]),
	);
}

/**
 * before_provider_request rewrite: a payload whose `thinking` is one of
 * our serialized envelopes gets the parsed object; ANYTHING else
 * (foreign strings, already-object payloads, absent thinking, non-object
 * payloads) passes through UNCHANGED (undefined = keep, the extension
 * contract). A malformed envelope must never take down the request —
 * unparsable values are left alone, never thrown.
 */
export function deserializeThinking(payload: unknown): unknown | undefined {
	if (typeof payload !== "object" || payload === null) return undefined;
	const p = payload as Record<string, unknown>;
	if (typeof p.thinking !== "string" || !p.thinking.startsWith('{"type"')) return undefined;
	try {
		const parsed = JSON.parse(p.thinking) as AnthropicThinking;
		if (
			parsed?.type === "disabled" ||
			(parsed?.type === "enabled" && typeof parsed.budget_tokens === "number" && parsed.budget_tokens > 0)
		) {
			return { ...p, thinking: parsed };
		}
	} catch {
		// malformed envelope — leave the payload untouched
	}
	return undefined;
}
