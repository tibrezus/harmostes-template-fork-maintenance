import assert from "node:assert/strict";
import { test } from "node:test";
import { DEFAULT_PRIMARY_TIMEOUT_S, resolvePrimaryTimeout } from "./timeout.ts";

test("resolvePrimaryTimeout: unset env keeps the baked default (100s — 20s under pi's 2-minute wall)", () => {
  assert.deepEqual(resolvePrimaryTimeout(undefined), { seconds: DEFAULT_PRIMARY_TIMEOUT_S });
  assert.deepEqual(resolvePrimaryTimeout(""), { seconds: DEFAULT_PRIMARY_TIMEOUT_S });
  assert.deepEqual(resolvePrimaryTimeout("   "), { seconds: DEFAULT_PRIMARY_TIMEOUT_S });
});

test("resolvePrimaryTimeout: '0' is the off-switch (no timeout params attached)", () => {
  assert.deepEqual(resolvePrimaryTimeout("0"), { seconds: 0 });
  // "00" is the same integer — tolerated, not an error (the knob is a
  // number, not a string grammar).
  assert.deepEqual(resolvePrimaryTimeout("00"), { seconds: 0 });
});

test("resolvePrimaryTimeout: a positive integer overrides (whitespace tolerated)", () => {
  assert.deepEqual(resolvePrimaryTimeout("45"), { seconds: 45 });
  assert.deepEqual(resolvePrimaryTimeout(" 30 "), { seconds: 30 });
  assert.deepEqual(resolvePrimaryTimeout("1"), { seconds: 1 });
});

test("resolvePrimaryTimeout: a malformed value degrades to the default, loudly — never a crash", () => {
  // The fallbacks.ts contract, applied to the deadline: semantically-bad
  // override → default + reason string, so a typo can't silently disable
  // the reactiveness lever OR wedge the extension factory.
  for (const bad of ["abc", "-5", "1.5", "1e3", "0x10", "10s", "true", "0x0"]) {
    const r = resolvePrimaryTimeout(bad);
    assert.equal(r.seconds, DEFAULT_PRIMARY_TIMEOUT_S, bad);
    assert.equal(typeof r.warning, "string", bad);
  }
});

test("DEFAULT_PRIMARY_TIMEOUT_S is strictly under pi's 2-minute HTTP wall", () => {
  // The invariant the whole design rests on (owner directive 2026-11-14):
  // the proxy must shift BEFORE pi aborts, so the failover's first chunk
  // lands inside the wall. The wall itself lives in
  // extensions/sol-pi/settings.json (httpIdleTimeoutMs 120000) — this pin
  // is the extension-side half of that contract.
  assert.ok(DEFAULT_PRIMARY_TIMEOUT_S < 120, `default deadline ${DEFAULT_PRIMARY_TIMEOUT_S}s must be < 120s`);
});
