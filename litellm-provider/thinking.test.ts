import assert from "node:assert/strict";
import { test } from "node:test";
import { ANTHROPIC_THINKING_LEVELS, deserializeThinking, wireThinkingMap } from "./thinking.ts";

test("every level's map value is the exact wire object, serialized", () => {
	const map = wireThinkingMap();
	assert.deepEqual(Object.keys(map).sort(), Object.keys(ANTHROPIC_THINKING_LEVELS).sort());
	for (const [level, obj] of Object.entries(ANTHROPIC_THINKING_LEVELS)) {
		assert.deepEqual(JSON.parse(map[level]), obj, `level ${level}`);
	}
	// off is a hard disable — the deployment must be able to switch
	// reasoning OFF, not merely shrink it
	assert.deepEqual(ANTHROPIC_THINKING_LEVELS.off, { type: "disabled" });
	// budgets are positive and ordered
	const budgets = ["minimal", "low", "medium", "high", "max"].map(
		(l) => (ANTHROPIC_THINKING_LEVELS[l] as { budget_tokens: number }).budget_tokens,
	);
	for (let i = 1; i < budgets.length; i++) assert.ok(budgets[i] > budgets[i - 1]);
});

test("deserializeThinking parses our envelope onto the wire", () => {
	const map = wireThinkingMap();
	const out = deserializeThinking({ model: "group", thinking: map.low, messages: [] });
	assert.notEqual(out, undefined);
	assert.deepEqual((out as { thinking: object }).thinking, { type: "enabled", budget_tokens: 2048 });
	const off = deserializeThinking({ thinking: map.off });
	assert.deepEqual((off as { thinking: object }).thinking, { type: "disabled" });
});

test("deserializeThinking leaves foreign payloads untouched", () => {
	// foreign string (a bare level name — some other provider's dialect)
	assert.equal(deserializeThinking({ thinking: "high" }), undefined);
	// already an object (someone upstream set it)
	assert.equal(deserializeThinking({ thinking: { type: "disabled" } }), undefined);
	// absent thinking
	assert.equal(deserializeThinking({ model: "g" }), undefined);
	// non-object payload
	assert.equal(deserializeThinking("nope"), undefined);
	assert.equal(deserializeThinking(null), undefined);
});

test("a malformed envelope never throws and never corrupts", () => {
	assert.equal(deserializeThinking({ thinking: '{"type"' }), undefined);
	assert.equal(deserializeThinking({ thinking: '{"type":"explode"}' }), undefined);
	assert.equal(deserializeThinking({ thinking: '{"type":"enabled","budget_tokens":-5}' }), undefined);
	assert.equal(deserializeThinking({ thinking: '{"type":"enabled"}' }), undefined);
});

test("a rewritten payload preserves every other field", () => {
	const map = wireThinkingMap();
	const payload = {
		model: "some-group",
		messages: [{ role: "user", content: "hi" }],
		stream: true,
		thinking: map.medium,
	};
	const out = deserializeThinking(payload) as Record<string, unknown>;
	assert.equal(out.model, "some-group");
	assert.equal(out.stream, true);
	assert.deepEqual(out.messages, payload.messages);
});
