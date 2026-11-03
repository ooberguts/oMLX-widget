// Run: node --test tests/
const test = require('node:test');
const assert = require('node:assert');
const L = require('../Resources/limits.js');
const fx = require('./fixtures.json');

const within = (actual, expected, pct, label) =>
  assert.ok(Math.abs(actual - expected) / expected <= pct / 100,
    `${label}: got ${actual}, expected ${expected} (±${pct}%)`);

// Bytes per token and recurrent-state sizes read from the KV blocks oMLX wrote to
// disk (token_count and model_name come from each block's safetensors metadata).
const TQ4 = { enabled: true, bits: 4, skipLast: true };

test('Ornith 9B, fp16 KV: exact', () => {
  const g = L.geometry(fx.ornith_9b);
  assert.strictEqual(g.confidence, 'measured');
  assert.strictEqual(g.fullLayers, 8);
  assert.strictEqual(L.kvModel(g, null).perToken, 32768);        // measured 32,772
  within(L.kvModel(g, null).perToken, 32772, 0.02, 'Ornith');
});

test('Qwen3.8-27B, TurboQuant 4-bit, matches the measured block', () => {
  const g = L.geometry(fx.qwen38_27b);
  assert.strictEqual(g.fullLayers, 16);
  within(L.kvModel(g, TQ4).perToken, 19707, 0.3, '27B KV B/token');
  within(g.stateBytes, 153961616, 0.05, '27B recurrent state');
});

test('Qwen3.6-35B, TurboQuant 4-bit, matches the measured block', () => {
  const g = L.geometry(fx.qwen36_35b);
  assert.strictEqual(g.fullLayers, 10);
  within(L.kvModel(g, TQ4).perToken, 6735, 0.3, '35B KV B/token');
  within(g.stateBytes, 64400064, 0.05, '35B recurrent state');
});

test('TurboQuant leaves the last layer unquantised unless told otherwise', () => {
  const g = L.geometry(fx.qwen38_27b);
  const skip = L.kvModel(g, TQ4).perToken;
  const all = L.kvModel(g, { enabled: true, bits: 4, skipLast: false }).perToken;
  assert.ok(all < skip);
});

test('fewer bits cost less, more bits cost more, always below fp16', () => {
  const g = L.geometry(fx.qwen38_27b);
  const fp16 = L.kvModel(g, null).perToken;
  const cost = b => L.kvModel(g, { enabled: true, bits: b, skipLast: true }).perToken;
  assert.ok(cost(2) < cost(3) && cost(3) < cost(4) && cost(4) < cost(6) && cost(6) < cost(8));
  assert.ok(cost(8) < fp16);
});

test('hybrid models: only full-attention layers grow with context', () => {
  const g = L.geometry(fx.qwen38_27b);
  const a = L.kvBytes(g, TQ4, 1000), b = L.kvBytes(g, TQ4, 2000);
  assert.ok(Math.abs((b - a) - L.kvModel(g, TQ4).perToken * 1000) < 1);
  assert.ok(a > g.stateBytes);                                    // the fixed state is included
});

test('Gemma 4 is reported as an upper bound, not as measured', () => {
  const g = L.geometry(fx.gemma4_26b);
  assert.strictEqual(g.kind, 'sliding');
  assert.strictEqual(g.confidence, 'upper-bound');
  assert.strictEqual(g.fullLayers, 5);
  assert.strictEqual(g.slideLayers, 25);
  // sliding layers stop growing once the window is full
  const a = L.kvBytes(g, null, 1024), b = L.kvBytes(g, null, 100000);
  const slideAt1024 = L.kvModel(g, null).slidePerToken * 1024;
  assert.ok(b - a < L.kvModel(g, null).perToken * 100000 + 1);
  assert.ok(slideAt1024 > 0);
});

test('plain dense models fall back to all-layers KV and say it is an estimate', () => {
  const g = L.geometry({ model_type: 'llama', num_hidden_layers: 32, num_attention_heads: 32,
                         num_key_value_heads: 8, hidden_size: 4096, max_position_embeddings: 8192 });
  assert.strictEqual(g.kind, 'dense');
  assert.strictEqual(g.confidence, 'estimate');
  assert.strictEqual(L.kvModel(g, null).perToken, 2 * 8 * 128 * 2 * 32);   // 131,072 B/token
});

test('unreadable configs give null rather than a wrong number', () => {
  assert.strictEqual(L.geometry(null), null);
  assert.strictEqual(L.geometry({}), null);
  assert.strictEqual(L.geometry({ num_hidden_layers: 4 }), null);
  // a hybrid config missing its linear-attention fields must not be guessed at
  assert.strictEqual(L.geometry({ num_hidden_layers: 4, num_attention_heads: 4, head_dim: 64,
                                  layer_types: ['linear_attention', 'full_attention'] }), null);
});

const GIB = L.GIB;
function base(over) {
  return Object.assign({
    geo: L.geometry(fx.qwen38_27b), tq: TQ4, ctx: 65536, seqs: 1,
    weights: 16.6 * GIB, overhead: 2 * GIB, hot: 1.4 * GIB, others: 0,
    soft: 44.1 * GIB, hard: 47.5 * GIB
  }, over);
}

test('forecast adds the parts and picks a verdict', () => {
  const f = L.forecast(base());
  const sum = Object.values(f.parts).reduce((a, b) => a + b, 0);
  assert.ok(Math.abs(sum - f.total) < 1);
  assert.strictEqual(f.verdict, 'fits');
  assert.strictEqual(L.forecast(base({ weights: 40 * GIB })).verdict, 'tight');   // between soft and hard
  assert.strictEqual(L.forecast(base({ weights: 60 * GIB })).verdict, 'over');
});

test('maxContext: largest context under the limit, monotonic with room', () => {
  const o = base({ geo: L.geometry(fx.ornith_9b), tq: null, weights: 38 * GIB });
  const m = L.maxContext(o, 'soft');
  assert.ok(m > 0 && m < o.geo.native, `scenario must be constrained (got ${m})`);
  assert.ok(L.forecast(Object.assign({}, o, { ctx: m })).total <= o.soft);
  // one block of 1024 past the answer must already be over the limit
  assert.ok(L.forecast(Object.assign({}, o, { ctx: m + 2048 })).total > o.soft);
  const roomier = L.maxContext(Object.assign({}, o, { soft: o.soft + 4 * GIB }), 'soft');
  assert.ok(roomier >= m);
  assert.ok(L.maxContext(o, 'hard') >= m);
});

test('maxContext: capped at the model native context, 0 when weights alone do not fit', () => {
  const small = base({ geo: L.geometry(fx.qwen36_35b), weights: 1 * GIB });
  assert.strictEqual(L.maxContext(small, 'soft'), 262144);
  assert.strictEqual(L.maxContext(base({ weights: 100 * GIB }), 'soft'), 0);
});

test('TurboQuant buys real room on a model that has none', () => {
  // weights large enough that fp16 KV genuinely runs out of room before the native limit
  const o = base({ geo: L.geometry(fx.ornith_9b), tq: null, weights: 38 * GIB });
  const off = L.maxContext(o, 'soft');
  assert.ok(off > 0 && off < o.geo.native, `scenario must be constrained (fp16 max ${off})`);
  const on = L.maxContext(Object.assign({}, o, { tq: TQ4 }), 'soft');
  assert.ok(on > off, `4-bit KV should fit more than fp16 (${on} vs ${off})`);
});

test('withCeiling scales soft and hard together', () => {
  const o = base();
  const w = L.withCeiling(o, 49 * GIB, 54 * GIB);
  assert.ok(Math.abs(w.soft / o.soft - 54 / 49) < 1e-9);
  assert.ok(Math.abs(w.hard / o.hard - 54 / 49) < 1e-9);
});

test('wired limit command matches the 64 GB figure oMLX itself suggests', () => {
  assert.strictEqual(L.wiredLimitMb(64 * GIB), 59392);
  assert.strictEqual(L.wiredLimitMb(32 * GIB), 26624);
});

test('binding names the real limit', () => {
  const sys = { memory_guard_preview: {
    custom:   { ceiling_bytes: 54.7 * GIB, binding: 'metal_cap' },
    balanced: { ceiling_bytes: 44.0 * GIB, binding: 'dynamic' } } };
  assert.strictEqual(L.binding(sys, { memory_guard_tier: 'custom', memory_guard_custom_ceiling_gb: 49 }).kind, 'pinned');
  assert.strictEqual(L.binding(sys, { memory_guard_tier: 'custom', memory_guard_custom_ceiling_gb: 54.7 }).kind, 'metal_cap');
  assert.strictEqual(L.binding(sys, { memory_guard_tier: 'balanced' }).kind, 'dynamic');
});

test('context stops and labels', () => {
  assert.deepStrictEqual(L.ctxStops(262144).slice(-2), [196608, 262144]);
  assert.strictEqual(L.fmtTok(262144), '256K');
  assert.strictEqual(L.fmtTok(98304), '96K');
  assert.strictEqual(L.fmtTok(1048576), '1M');
});

test('advise: offers the levers that apply and omits the ones that do not', () => {
  const o = base({ geo: L.geometry(fx.ornith_9b), tq: null, weights: 38 * GIB, ctx: 262144 });
  assert.notStrictEqual(L.forecast(o).verdict, 'fits', 'scenario must actually be over the limit');
  const m = { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, staticCeiling: 62 * GIB, metalCap: 54.7 * GIB,
              cpu: 2.84 * GIB, total: 64 * GIB, available: 7 * GIB, footprint: 41 * GIB };
  const kinds = L.advise(o, m).map(x => x.kind);
  assert.ok(kinds.includes('cap-context'));
  assert.ok(kinds.includes('turboquant'));
  assert.ok(kinds.includes('raise-ceiling'));
  assert.ok(kinds.includes('wired-limit'));
  const wired = L.advise(o, m).find(x => x.kind === 'wired-limit');
  assert.strictEqual(wired.command, 'sudo sysctl iogpu.wired_limit_mb=59392');

  // already quantised, comfortably within the limit, ceiling already maxed: nothing to suggest
  const calm = base({ ctx: 8192 });
  const none = L.advise(calm, Object.assign({}, m, { ceiling: 54.7 * GIB, metalCap: 62 * GIB }))
                .map(x => x.kind);
  assert.deepStrictEqual(none, []);
});

test('advise: when it fits, offers nothing — even if the ceiling could be raised', () => {
  const fits = base({ ctx: 8192 });
  assert.strictEqual(L.forecast(fits).verdict, 'fits');
  // plenty of theoretical room to raise limits, but no reason to
  const m = { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, staticCeiling: 62 * GIB, metalCap: 54.7 * GIB,
              cpu: 2.84 * GIB, total: 64 * GIB, available: 30 * GIB, footprint: 20 * GIB };
  assert.deepStrictEqual(L.advise(fits, m), []);
});

test('advise: tight and over both get suggestions', () => {
  const m = { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, available: 30 * GIB, footprint: 20 * GIB, total: 64 * GIB };
  const tight = base({ weights: 40 * GIB });
  assert.strictEqual(L.forecast(tight).verdict, 'tight');
  assert.ok(L.advise(tight, m).length > 0);
  const over = base({ weights: 60 * GIB });
  assert.strictEqual(L.forecast(over).verdict, 'over');
  assert.ok(L.advise(over, m).length > 0);
});

test('raise-ceiling warns when the extra would squeeze the rest of the system', () => {
  const o = base({ weights: 40 * GIB, ctx: 262144 });
  assert.notStrictEqual(L.forecast(o).verdict, 'fits', 'scenario must be over the limit');
  const squeezed = L.advise(o, { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, available: 2 * GIB, footprint: 41 * GIB })
                    .find(x => x.kind === 'raise-ceiling');
  const roomy = L.advise(o, { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, available: 30 * GIB, footprint: 41 * GIB })
                    .find(x => x.kind === 'raise-ceiling');
  assert.strictEqual(squeezed.squeezes, true);
  assert.strictEqual(roomy.squeezes, false);
});

test('advise: never suggests a context of zero when the weights alone are over the limit', () => {
  const o = base({ weights: 60 * GIB });
  assert.strictEqual(L.maxContext(o, 'soft'), 0);
  const m = { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, available: 30 * GIB, footprint: 20 * GIB, total: 64 * GIB };
  const kinds = L.advise(o, m).map(x => x.kind);
  assert.ok(kinds.includes('too-big'), 'the model itself is the problem and should say so');
  assert.ok(L.advise(o, m).find(x => x.kind === 'too-big').over > 0);
  assert.ok(!kinds.includes('cap-context'), 'a context cap cannot help here');
  // 60 GB of weights cannot fit under even the maximum 54.7 GB ceiling, so raising it is not offered
  assert.ok(!kinds.includes('raise-ceiling'), 'a raise that cannot help should not be offered');
});

test('advise: a suggested context cap really does fit', () => {
  const o = base({ weights: 40 * GIB, ctx: 262144 });
  const cap = L.advise(o, { ceiling: 49 * GIB }).find(x => x.kind === 'cap-context');
  assert.ok(cap && cap.ctx >= 8192 && cap.ctx < 262144);
  assert.notStrictEqual(L.forecast(Object.assign({}, o, { ctx: cap.ctx })).verdict, 'over');
  assert.ok(L.forecast(Object.assign({}, o, { ctx: cap.ctx })).total <= o.soft, 'cap must be under the soft limit');
});

test('advise: when another loaded model is the cause, say so first and do not blame this one', () => {
  // 17 GB of weights fits easily on its own; a 36 GB neighbour is what pushes it over
  const o = base({ weights: 17 * GIB, others: 36 * GIB, ctx: 65536 });
  assert.notStrictEqual(L.forecast(o).verdict, 'fits');
  assert.strictEqual(L.forecast(Object.assign({}, o, { others: 0 })).verdict, 'fits');
  const m = { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, available: 30 * GIB, footprint: 40 * GIB, total: 64 * GIB };
  const a = L.advise(o, m);
  assert.strictEqual(a[0].kind, 'unload-others');
  assert.strictEqual(a[0].fixes, true);
  assert.ok(!a.some(x => x.kind === 'too-big'), 'the model fits alone, so it is not too big');
});

test('advise: never offers a ceiling raise that cannot help', () => {
  // demand far beyond even the maximum ceiling
  const o = base({ weights: 17 * GIB, others: 70 * GIB });
  const m = { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, staticCeiling: 62 * GIB, metalCap: 54.7 * GIB,
              cpu: 2.84 * GIB, total: 64 * GIB, available: 30 * GIB, footprint: 40 * GIB };
  const kinds = L.advise(o, m).map(x => x.kind);
  assert.ok(!kinds.includes('raise-ceiling'));
  assert.ok(!kinds.includes('wired-limit'));
  assert.ok(kinds.includes('unload-others'));
});

test('advise: a ceiling raise that does help reports the context it buys', () => {
  const o = base({ weights: 40 * GIB, ctx: 262144 });
  const r = L.advise(o, { ceiling: 49 * GIB, maxCustom: 54.7 * GIB, available: 30 * GIB, footprint: 40 * GIB })
              .find(x => x.kind === 'raise-ceiling');
  assert.ok(r && r.newMax > r.oldMax, 'raise must increase the context that fits');
});
