/**
 * Fleet sampling policy (#657): pi's `samplingParamsByThinkingLevel`
 * (1.0.2+) lets a fleet pin sampling per pi thinking level. Harmostes
 * nodes express intent via thinking level (RPC `set_thinking_level`) —
 * mechanical tiers (off/minimal/low) must not inherit creative-default
 * sampling; medium and above keep model defaults (key omitted — pi
 * merges per key, missing levels inherit). Applied uniformly by
 * index.ts at model registration: the ONE choke point every litellm
 * model crosses, immune to proxy routing-table drift.
 */
export const FLEET_SAMPLING_BY_THINKING_LEVEL = {
	off: { temperature: 0.2, top_p: 0.9 },
	minimal: { temperature: 0.2, top_p: 0.9 },
	low: { temperature: 0.2, top_p: 0.9 },
} as const;
