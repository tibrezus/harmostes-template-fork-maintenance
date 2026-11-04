import assert from "node:assert/strict";
import { test } from "node:test";
import { FLEET_SAMPLING_BY_THINKING_LEVEL } from "./sampling.ts";

// #657: mechanical tiers are deterministic-lean; reasoning tiers inherit.
test("fleet sampling policy pins low tiers and leaves reasoning tiers to model defaults", () => {
	assert.deepEqual(
		Object.keys(FLEET_SAMPLING_BY_THINKING_LEVEL).sort(),
		["low", "minimal", "off"],
	);
	for (const level of ["off", "minimal", "low"] as const) {
		assert.deepEqual(FLEET_SAMPLING_BY_THINKING_LEVEL[level], { temperature: 0.2, top_p: 0.9 });
	}
	assert.equal("medium" in FLEET_SAMPLING_BY_THINKING_LEVEL, false);
	assert.equal("high" in FLEET_SAMPLING_BY_THINKING_LEVEL, false);
});
