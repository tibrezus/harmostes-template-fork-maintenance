import assert from "node:assert/strict";
import { test } from "node:test";
import { DEFAULT_FALLBACKS, resolveFallbackChains, wiringSummary } from "./fallbacks.ts";

test("no env keeps the default chain", () => {
  const { chains, warning } = resolveFallbackChains(undefined);
  assert.deepEqual(chains, DEFAULT_FALLBACKS);
  assert.equal(warning, undefined);
});

test("empty env keeps the default chain", () => {
  const { chains, warning } = resolveFallbackChains("  ");
  assert.deepEqual(chains, DEFAULT_FALLBACKS);
  assert.equal(warning, undefined);
});

test("valid override replaces the whole map", () => {
  const { chains, warning } = resolveFallbackChains('{"a/b": ["c/d"]}');
  assert.deepEqual(chains, { "a/b": ["c/d"] });
  assert.equal(warning, undefined);
});

test("unparsable JSON degrades loudly to the default", () => {
  const { chains, warning } = resolveFallbackChains("{not json");
  assert.deepEqual(chains, DEFAULT_FALLBACKS);
  assert.match(warning!, /not valid JSON/);
});

// #363: the DEFAULT table's CONTENT is load-bearing (ops review templates
// flipped to speed primary, k8s-config 8c1fb609; this chart's values.yaml
// default still runs flash) — the resolveFallbackChains tests above only
// compare against the DEFAULT_FALLBACKS export itself (they flip silently
// with any edit). The invariant is COMPOSITION, not count: every LIVE
// primary direction must have an entry, because a chain keyed by any other
// primary is inert (applyChains never reaches it). The index.ts header
// drifted exactly this way once (said flash→speed while the code said
// flash→glm) — comments are not a pin.
test("default chain composition covers every live primary (#363, #401 r2)", () => {
  // Three live primaries in this repo: speed (ops review templates),
  // flash (this chart's values.yaml default), glm (cmd/harmostes-agent +
  // harmostes.py --model default). A live primary with no entry would
  // attach no failover at all — the condition #363 was filed to fix.
  assert.deepEqual(DEFAULT_FALLBACKS, {
    "mtplx/anthropic/qwen38-27b-optimized-speed-fp16": ["zai/anthropic/glm-5.3-flash"],
    "mtplx/qwen38-27b-optimized-speed-fp16": ["ali/anthropic/qwen3.8-flash"],
    "ali/anthropic/qwen3.8-flash": ["zai/anthropic/glm-5.3-flash"],
    "ali/anthropic/deepseek-v4.1-flash": ["zai/anthropic/glm-5.3-flash"],
    "ali/anthropic/qwen3.8-max": ["ali/anthropic/qwen3.8-flash"],
    "zai/anthropic/glm-5.3-flash": ["ali/anthropic/qwen3.8-flash"],
  });
  // And ALL FOUR wire over a proxy exposing exactly the four known
  // groups: speed keeps its own 256 KiB window (fallback LARGER — no
  // clamp, no early compaction); flash pays the documented fallback clamp
  // down to glm (128 Ki ctx / 8k out) — the pre-#363 shape, retained on
  // purpose; max nets to flash, which is larger in both dims — no clamp;
  // glm clamps nothing (flash is larger in both dimensions).
  const proxy = new Map([
    ["mtplx/anthropic/qwen38-27b-optimized-speed-fp16", { max_input_tokens: 262144, max_output_tokens: 32768 }],
    ["mtplx/qwen38-27b-optimized-speed-fp16", { max_input_tokens: 262144, max_output_tokens: 32768 }],
    ["ali/anthropic/qwen3.8-flash", { max_input_tokens: 1048576, max_output_tokens: 32768 }],
    ["ali/anthropic/qwen3.8-max", { max_input_tokens: 991808, max_output_tokens: 131072 }],
    ["zai/anthropic/glm-5.3-flash", { max_input_tokens: 131072, max_output_tokens: 8192 }],
  ]);
  const models = [...proxy.entries()].map(([id, m]) => ({ id, ...m }));
  const { annotated, wired, unwiredChains } = applyChains(models, DEFAULT_FALLBACKS, proxy);
  const speed = annotated.find((m) => m.id === "mtplx/qwen38-27b-optimized-speed-fp16")!;
  assert.deepEqual(speed.samplingParams, { fallbacks: ["ali/anthropic/qwen3.8-flash"] });
  assert.equal(speed.contextWindow, 262144); // min(262144, 1048576) = own window
  assert.equal(speed.clampNote, undefined); // no ctx/maxTokens clamp, no early compaction
  const flash = annotated.find((m) => m.id === "ali/anthropic/qwen3.8-flash")!;
  assert.deepEqual(flash.samplingParams, { fallbacks: ["zai/anthropic/glm-5.3-flash"] });
  assert.equal(flash.contextWindow, 131072); // clamped to glm — the retained #373 chain's cost
  assert.match(flash.clampNote!, /ctx 1048576→131072/);
  const glm = annotated.find((m) => m.id === "zai/anthropic/glm-5.3-flash")!;
  assert.deepEqual(glm.samplingParams, { fallbacks: ["ali/anthropic/qwen3.8-flash"] });
  assert.equal(glm.contextWindow, 131072); // own window — flash is larger, no clamp
  assert.equal(glm.clampNote, undefined);
  const max = annotated.find((m) => m.id === "ali/anthropic/qwen3.8-max")!;
  assert.deepEqual(max.samplingParams, { fallbacks: ["ali/anthropic/qwen3.8-flash"] });
  assert.equal(max.contextWindow, 991808); // own ctx — the net (flash) is larger on input
  assert.match(max.clampNote!, /maxTokens 131072→32768/); // fallback clamp: flash's 32k out
  assert.deepEqual(wired.sort(), [
    "ali/anthropic/qwen3.8-flash → zai/anthropic/glm-5.3-flash", // wired entries are primary→fallback summaries
    "ali/anthropic/qwen3.8-max → ali/anthropic/qwen3.8-flash",
    "mtplx/anthropic/qwen38-27b-optimized-speed-fp16 → zai/anthropic/glm-5.3-flash",
    "mtplx/qwen38-27b-optimized-speed-fp16 → ali/anthropic/qwen3.8-flash",
    "zai/anthropic/glm-5.3-flash → ali/anthropic/qwen3.8-flash",
  ]);
  // deepseek-v4.1-flash is in the table but NOT in this proxy map — inert
  // by design (unwired) until the proxy serves it (owner directive).
  assert.deepEqual(unwiredChains, ["ali/anthropic/deepseek-v4.1-flash"]);
});

// The documented off-switch, pinned (#401 review r2: it had no test at any
// layer, while a PARTIAL override silently strips the platform decision —
// whole-map substitution is the documented semantics, so the protection
// for it is the composition pin above plus the summary log in index.ts
// that distinguishes "none configured" from "configured but none wired").
test("resolveFallbackChains: '{}' is the off-switch — empty chains, no warning", () => {
  const { chains, warning } = resolveFallbackChains("{}");
  assert.deepEqual(chains, {});
  assert.equal(warning, undefined);
});

// The default table is a deliberate SUPERSET of any one proxy's groups
// (#401 review r3): over a 2-group proxy (the chart-default shape, where
// speed is ops-side), exactly the unserved keys (speed, deepseek, max)
// are reported inert and the two served directions still wire — the
// unwired note is expected output, not an alarm.
test("applyChains: a subset proxy reports exactly the unserved key", () => {
  const two = new Map([
    ["ali/anthropic/qwen3.8-flash", { max_input_tokens: 1048576, max_output_tokens: 32768 }],
    ["zai/anthropic/glm-5.3-flash", { max_input_tokens: 131072, max_output_tokens: 8192 }],
  ]);
  const twoModels = [...two.entries()].map(([id, m]) => ({ id, ...m }));
  const { wired, unwiredChains } = applyChains(twoModels, DEFAULT_FALLBACKS, two);
  // insertion order of the default table: the anthropic-route speed
  // primary first, the bare speed alias second, deepseek, max
  assert.deepEqual(unwiredChains, [
    "mtplx/anthropic/qwen38-27b-optimized-speed-fp16",
    "mtplx/qwen38-27b-optimized-speed-fp16",
    "ali/anthropic/deepseek-v4.1-flash",
    "ali/anthropic/qwen3.8-max",
  ]);
  assert.deepEqual(wired.sort(), [
    "ali/anthropic/qwen3.8-flash → zai/anthropic/glm-5.3-flash",
    "zai/anthropic/glm-5.3-flash → ali/anthropic/qwen3.8-flash",
  ]);
});

// The summary branches are table-tested here because index.ts itself is
// import-gate only (its factory returns early without LITELLM_URL).
test("wiringSummary: wired / configured-but-unwired / off-switch", () => {
  assert.equal(
    wiringSummary(["a → b"], { "a": ["b"] }),
    " | fallbacks wired: a → b",
  );
  assert.equal(
    wiringSummary([], { "mtplx/x": ["ali/y"], "ali/y": ["zai/z"] }),
    " | no fallbacks wired — chains configured for: mtplx/x, ali/y",
  );
  assert.equal(
    wiringSummary([], {}),
    " | no fallbacks wired — none configured (LITELLM_FALLBACKS='{}' disables all chains)",
  );
});

// A chain keyed by a primary the proxy does not serve must SURFACE, not
// vanish silently into "no fallbacks wired" (#401 review, pillar 7).
test("applyChains: chain keys with an undiscovered primary are reported inert", () => {
  const served = new Map([
    ["mtplx/qwen38-27b-optimized-speed-fp16", { max_input_tokens: 262144, max_output_tokens: 32768 }],
    ["ali/anthropic/qwen3.8-flash", { max_input_tokens: 1048576, max_output_tokens: 32768 }],
  ]);
  const servedModels = [...served.entries()].map(([id, m]) => ({ id, ...m }));
  const { wired, unwiredChains } = applyChains(servedModels, {
    "mtplx/qwen38-27b-optimized-speed-fp16": ["ali/anthropic/qwen3.8-flash"],
    "ghost/group": ["mtplx/qwen38-27b-optimized-speed-fp16"],
  }, served);
  assert.deepEqual(unwiredChains, ["ghost/group"]); // the proxy does not serve it
  assert.deepEqual(wired, ["mtplx/qwen38-27b-optimized-speed-fp16 → ali/anthropic/qwen3.8-flash"]);
});

test("JSON array (not object) degrades to the default", () => {
  const { chains, warning } = resolveFallbackChains('["a/b"]');
  assert.deepEqual(chains, DEFAULT_FALLBACKS);
  assert.match(warning!, /not a JSON object/);
});

const malformedShapes = ['{"a/b": "c/d"}', '{"a/b": []}', '{"a/b": [null]}', '{"a/b": [42]}', '{"a/b": [""]}'];
for (const raw of malformedShapes) {
  test(`semantically-bad value ${raw} degrades to the default`, () => {
    const { chains, warning } = resolveFallbackChains(raw);
    assert.deepEqual(chains, DEFAULT_FALLBACKS);
    assert.match(warning!, /not a non-empty array/);
  });
}
import { applyChains } from "./fallbacks.ts";

const proxy = new Map([
  ["ali/anthropic/qwen3.8-flash", { max_input_tokens: 1048576, max_output_tokens: 32768 }],
  ["mtplx/qwen38-27b-optimized-speed-fp16", { max_input_tokens: 262144, max_output_tokens: 32768 }],
  ["zai/anthropic/glm-5.3-flash", { max_input_tokens: 131072, max_output_tokens: 8192 }],
]);
const models = [
  { id: "ali/anthropic/qwen3.8-flash", max_input_tokens: 1048576, max_output_tokens: 32768 },
  { id: "zai/anthropic/glm-5.3-flash", max_input_tokens: 131072 },
];

test("applyChains: unchained model carries NO fallbacks key (an explicit [] overrides proxy config)", () => {
  const { annotated, wired } = applyChains(models, {}, proxy);
  const glm = annotated.find((m) => m.id === "zai/anthropic/glm-5.3-flash")!;
  assert.equal(glm.samplingParams, undefined);
  assert.equal(wired.length, 0);
});

test("applyChains: chained model gets the chain and the min-window clamp", () => {
  const { annotated, wired } = applyChains(models, {
    "ali/anthropic/qwen3.8-flash": ["mtplx/qwen38-27b-optimized-speed-fp16"],
  }, proxy);
  const flash = annotated.find((m) => m.id === "ali/anthropic/qwen3.8-flash")!;
  assert.deepEqual(flash.samplingParams, { fallbacks: ["mtplx/qwen38-27b-optimized-speed-fp16"] });
  assert.equal(flash.contextWindow, 262144); // min(1048576, 262144) — the replay must fit
  assert.match(flash.clampNote!, /fallback clamp/);
  assert.equal(wired.length, 1);
});

test("applyChains: unknown fallback ids are dropped, partial chains stay wired", () => {
  const { annotated, wired } = applyChains(models, {
    "ali/anthropic/qwen3.8-flash": ["mtplx/gone", "mtplx/qwen38-27b-optimized-speed-fp16"],
  }, proxy);
  const flash = annotated.find((m) => m.id === "ali/anthropic/qwen3.8-flash")!;
  assert.deepEqual(flash.samplingParams, { fallbacks: ["mtplx/qwen38-27b-optimized-speed-fp16"] });
  assert.deepEqual(flash.droppedIds, ["mtplx/gone"]);
  assert.equal(wired.length, 1); // r17 failure mode: wired must not read unwired
});

test("applyChains: a chain that filters to empty attaches nothing", () => {
  const { annotated, wired } = applyChains(models, {
    "ali/anthropic/qwen3.8-flash": ["mtplx/gone"],
  }, proxy);
  const flash = annotated.find((m) => m.id === "ali/anthropic/qwen3.8-flash")!;
  assert.equal(flash.samplingParams, undefined);
  assert.deepEqual(flash.droppedIds, ["mtplx/gone"]);
  assert.equal(wired.length, 0);
});

test("applyChains: self-chain (a→a) is dropped entirely — no failing-over to the group that just failed", () => {
  const { annotated, wired } = applyChains(models, {
    "ali/anthropic/qwen3.8-flash": ["ali/anthropic/qwen3.8-flash"],
  }, proxy);
  const flash = annotated.find((m) => m.id === "ali/anthropic/qwen3.8-flash")!;
  assert.equal(flash.samplingParams, undefined);
  assert.deepEqual(flash.droppedIds, ["ali/anthropic/qwen3.8-flash"]);
  assert.equal(wired.length, 0);
});

test("applyChains: duplicate fallback ids are deduped", () => {
  const { annotated } = applyChains(models, {
    "ali/anthropic/qwen3.8-flash": ["mtplx/qwen38-27b-optimized-speed-fp16", "mtplx/qwen38-27b-optimized-speed-fp16"],
  }, proxy);
  const flash = annotated.find((m) => m.id === "ali/anthropic/qwen3.8-flash")!;
  assert.deepEqual(flash.samplingParams, { fallbacks: ["mtplx/qwen38-27b-optimized-speed-fp16"] });
});

test("applyChains: prototype-named models (toString) read own properties only", () => {
  // A proxy model literally named "toString" with NO own chain entry must
  // read `undefined` (own-property lookup), not the inherited function —
  // r18-review P4.3: Array.isArray(function) is false, so the old code
  // crashed rawChain.filter inside the factory and killed every agent run.
  const models2 = [{ id: "toString", max_input_tokens: 1000 }];
  const { annotated, wired } = applyChains(models2, {}, proxy);
  assert.equal(annotated[0].samplingParams, undefined);
  assert.equal(wired.length, 0);
  // And an OWN "toString" chain still wires normally (own-key lookup wins).
  const { annotated: own, wired: wiredOwn } = applyChains(models2, { toString: ["zai/anthropic/glm-5.3-flash"] }, proxy);
  assert.deepEqual(own[0].samplingParams, { fallbacks: ["zai/anthropic/glm-5.3-flash"] });
  assert.equal(wiredOwn.length, 1);
});

test("applyChains: maxTokens-only clamp is reported as such", () => {
  const proxy2 = new Map([
    ["ali/anthropic/qwen3.8-flash", { max_input_tokens: 1048576, max_output_tokens: 32768 }],
    ["small-out", { max_input_tokens: 1048576, max_output_tokens: 4096 }],
  ]);
  const { annotated } = applyChains(models, {
    "ali/anthropic/qwen3.8-flash": ["small-out"],
  }, proxy2);
  const flash = annotated.find((m) => m.id === "ali/anthropic/qwen3.8-flash")!;
  assert.match(flash.clampNote!, /maxTokens 32768→4096/);
  assert.doesNotMatch(flash.clampNote!, /ctx 1048576→1048576/);
});

test("resolveFallbackChains: the default does not leak by reference", () => {
  const { chains } = resolveFallbackChains(undefined);
  (chains as Record<string, unknown>)["injected"] = ["x"];
  const { chains: again } = resolveFallbackChains(undefined);
  assert.equal(Object.keys(again).length, Object.keys(DEFAULT_FALLBACKS).length);
  // And on the WARNING paths too (#401 review, pillar 8): they returned
  // DEFAULT_FALLBACKS itself, so an in-place normalisation could grow the
  // exported platform decision. Mutate a value ARRAY, not just a key —
  // the shallow copy must cover the map, values are read-only by contract.
  const { chains: degraded } = resolveFallbackChains("{not json");
  (degraded["mtplx/qwen38-27b-optimized-speed-fp16"] as string[]).push("injected");
  const { chains: after } = resolveFallbackChains("{not json");
  // Compare against the EXPECTED literal, not the export: with the leak,
  // `after` IS the mutated export and deepEqual(x, x) is trivially true.
  assert.deepEqual(after, {
    "mtplx/anthropic/qwen38-27b-optimized-speed-fp16": ["zai/anthropic/glm-5.3-flash"],
    "mtplx/qwen38-27b-optimized-speed-fp16": ["ali/anthropic/qwen3.8-flash"],
    "ali/anthropic/qwen3.8-flash": ["zai/anthropic/glm-5.3-flash"],
    "ali/anthropic/deepseek-v4.1-flash": ["zai/anthropic/glm-5.3-flash"],
    "ali/anthropic/qwen3.8-max": ["ali/anthropic/qwen3.8-flash"],
    "zai/anthropic/glm-5.3-flash": ["ali/anthropic/qwen3.8-flash"],
  });
});

test("the night-window primary (owner directive) carries the glm-5.3-flash second option", () => {
	// deepseek-v4.1-flash 16:00-02:00 CET is the night first option; its
	// chain must name glm-5.3-flash (the all-hours second option). The
	// chain is inert until the proxy catalog lists the id — this assert
	// keeps the INTENT in the table so the admin-side model addition
	// activates it without a code change.
	assert.deepEqual(DEFAULT_FALLBACKS["ali/anthropic/deepseek-v4.1-flash"], [
		"zai/anthropic/glm-5.3-flash",
	]);
	// The CURRENT night primary (owner correction, #536 → -230):
	// qwen3.8-max nets to flash — the proven finalizer on this contract,
	// and larger than max in both dims, so the chain clamps nothing.
	assert.deepEqual(DEFAULT_FALLBACKS["ali/anthropic/qwen3.8-max"], [
		"ali/anthropic/qwen3.8-flash",
	]);
});

test("DEFAULT_FALLBACKS: the fleet's pinned review primary (the anthropic-route mtplx id) has a wired chain — the 2026-10-25 outage class", async () => {
	// The outage: the template pinned mtplx/anthropic/... while the baked table
	// keyed only the bare alias — the live primary ran with NO fallbacks, so
	// an upstream hiccup was fatal. The table must carry a chain for the id
	// the fleet actually pins, and its net must NOT be a quota-dead group.
	const { chains } = resolveFallbackChains(undefined);
	const live = "mtplx/anthropic/qwen38-27b-optimized-speed-fp16";
	assert.ok(Array.isArray(chains[live]) && chains[live].length > 0, `no chain wired for the live primary ${live}`);
	for (const net of chains[live]) {
		assert.notEqual(net, "ali/anthropic/qwen3.8-flash", "the ali flash net is quota-dead until 2026-10-31 — it must not be a production net");
	}
});
