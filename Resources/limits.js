/* limits.js — memory and context-window forecasting for oMLX models.
 *
 * Pure functions with no DOM access: the widget loads this as a plain script
 * and tests/limits.test.js loads it under node.
 *
 * The model of what a context window costs was checked against the KV blocks
 * oMLX had written to disk, which record their model and token count:
 *
 *   Ornith 9B, fp16 KV          measured 32,772 B/token   formula 32,768
 *   Qwen3.6-35B, TurboQuant 4   measured  6,735 B/token   formula within 0.1%
 *   Qwen3.8-27B, TurboQuant 4   measured 19,707 B/token   formula within 0.1%
 *   recurrent state snapshots   within 0.02% of the formula for both Qwen models
 *
 * Only the qwen3_5 family is validated. Other architectures are reported with
 * a lower confidence rather than presented as measured.
 */
(function (root) {
  'use strict';

  var GIB = 1073741824, MIB = 1048576;
  // Bytes TurboQuant adds per K or V vector on top of its b-bit codes
  // (measured 2.09-2.19 at 4 bits on both Qwen models).
  var TQ_OVERHEAD = 2.15;
  var TQ_BITS = [2, 2.5, 3, 3.5, 4, 6, 8];
  // oMLX refuses to launch Hermes below this effective context.
  var HERMES_MIN_CONTEXT = 64000;

  function pos(v) { return (typeof v === 'number' && isFinite(v) && v > 0) ? v : null; }

  /** Cache geometry from a model's config.json, or null if it cannot be read. */
  function geometry(cfg) {
    if (!cfg || typeof cfg !== 'object') return null;
    var t = (cfg.text_config && typeof cfg.text_config === 'object') ? cfg.text_config : cfg;
    var layers = pos(t.num_hidden_layers), heads = pos(t.num_attention_heads);
    if (!layers || !heads) return null;
    var hidden = pos(t.hidden_size);
    var headDim = pos(t.head_dim) || (hidden ? Math.floor(hidden / heads) : null);
    if (!headDim) return null;
    var kvHeads = pos(t.num_key_value_heads) || heads;
    var modelType = String(t.model_type || cfg.model_type || '');
    var types = Array.isArray(t.layer_types) ? t.layer_types : null;

    var g = {
      modelType: modelType, layers: layers, native: pos(t.max_position_embeddings),
      kind: 'dense', confidence: 'estimate', note: 'every layer keeps a growing KV cache',
      fullLayers: layers, headDim: headDim, kvHeads: kvHeads,
      slideLayers: 0, window: 0, slideHeadDim: headDim, slideKvHeads: kvHeads,
      stateBytes: 0
    };

    if (types && types.indexOf('linear_attention') !== -1) {
      var full = types.filter(function (x) { return x === 'full_attention'; }).length;
      var lin = types.length - full;
      var vH = pos(t.linear_num_value_heads), kH = pos(t.linear_num_key_heads);
      var kD = pos(t.linear_key_head_dim), vD = pos(t.linear_value_head_dim);
      var kern = pos(t.linear_conv_kernel_dim);
      if (!(full && vH && kH && kD && vD && kern)) return null;
      var conv = kH * kD * 2 + vH * vD;                       // q, k and v channels
      g.kind = 'hybrid';
      g.fullLayers = full;
      g.stateBytes = lin * (vH * kD * vD * 4 + conv * (kern - 1) * 2);   // fp32 state, bf16 conv
      g.confidence = modelType.indexOf('qwen3_5') === 0 ? 'measured' : 'estimate';
      g.note = full + ' of ' + layers + ' layers keep a growing KV cache; ' + lin +
               ' keep a fixed-size state';
    } else if (types && types.indexOf('sliding_attention') !== -1) {
      var gl = types.filter(function (x) { return x === 'full_attention'; }).length;
      g.kind = 'sliding';
      g.fullLayers = gl || layers;
      g.slideLayers = types.length - gl;
      g.window = pos(t.sliding_window) || 4096;
      g.headDim = pos(t.global_head_dim) || headDim;           // global layers
      g.kvHeads = pos(t.num_global_key_value_heads) || kvHeads;
      g.slideHeadDim = headDim;
      g.slideKvHeads = kvHeads;
      g.confidence = 'upper-bound';
      g.note = 'assumes K and V are stored separately and sliding layers stay unquantised, ' +
               'so the real figure is probably lower';
    }
    return g;
  }

  function perVector(headDim, quantised, bits) {
    return quantised ? headDim * bits / 8 + TQ_OVERHEAD : headDim * 2;
  }

  /** Bytes of KV added per token, plus the parts that do not scale with it. */
  function kvModel(g, tq) {
    var on = !!(tq && tq.enabled);
    var skip = !tq || tq.skipLast !== false;          // oMLX leaves the last layer unquantised
    var nq = on ? Math.max(0, g.fullLayers - (skip ? 1 : 0)) : 0;
    var bits = (tq && tq.bits) || 4;
    var vectors = 2 * g.kvHeads;                       // K and V per KV head
    return {
      perToken: vectors * (nq * perVector(g.headDim, true, bits) +
                           (g.fullLayers - nq) * perVector(g.headDim, false, bits)),
      slidePerToken: g.slideLayers * 2 * g.slideKvHeads * g.slideHeadDim * 2,
      window: g.window,
      state: g.stateBytes
    };
  }

  /** Total cache bytes (KV plus recurrent state) for `seqs` sequences of `ctx` tokens. */
  function kvBytes(g, tq, ctx, seqs) {
    var m = kvModel(g, tq), n = seqs || 1;
    return n * (m.perToken * ctx + m.slidePerToken * Math.min(ctx, m.window || 0) + m.state);
  }

  /**
   * What the planner needs, all in bytes: geo, tq, ctx, seqs, weights,
   * overhead (runtime), hot (hot cache in use), others (other loaded models),
   * soft, hard.
   */
  function forecast(o) {
    var n = o.seqs || 1;
    var state = o.geo.stateBytes * n;
    var kv = kvBytes(o.geo, o.tq, o.ctx, n) - state;
    var parts = {
      weights: o.weights || 0,
      runtime: (o.overhead || 0) + (o.hot || 0),
      others: o.others || 0,
      state: state,
      kv: kv
    };
    var total = parts.weights + parts.runtime + parts.others + parts.state + parts.kv;
    return {
      parts: parts, total: total,
      verdict: total <= o.soft ? 'fits' : (total <= o.hard ? 'tight' : 'over'),
      spareSoft: o.soft - total, spareHard: o.hard - total
    };
  }

  /** Largest context (tokens, floored to 1024) whose forecast stays under `limit`. */
  function maxContext(o, limit) {
    var cap = Math.min(o.geo.native || Infinity, 4194304);
    var lim = o[limit || 'soft'];
    function fits(c) { return forecast(Object.assign({}, o, { ctx: c })).total <= lim; }
    if (!fits(0)) return 0;
    if (fits(cap)) return cap;
    var lo = 0, hi = cap;
    while (hi - lo > 256) {
      var mid = Math.floor((lo + hi) / 2);
      if (fits(mid)) lo = mid; else hi = mid;
    }
    return Math.floor(lo / 1024) * 1024;
  }

  /** The same inputs with the ceiling moved; soft and hard keep their fractions. */
  function withCeiling(o, fromCeiling, toCeiling) {
    var k = toCeiling / fromCeiling;
    return Object.assign({}, o, { soft: o.soft * k, hard: o.hard * k });
  }

  /** Raising iogpu.wired_limit_mb is the only way past Apple's default GPU cap. */
  function wiredLimitMb(totalBytes, reserveGiB) {
    return Math.floor((totalBytes - (reserveGiB == null ? 6 : reserveGiB) * GIB) / MIB);
  }

  /** Which of oMLX's three ceilings is the one limiting you. */
  function binding(sys, memCfg) {
    var pv = (sys && sys.memory_guard_preview) || {};
    var tier = memCfg && memCfg.memory_guard_tier;
    var maxCustom = (pv.custom && pv.custom.ceiling_bytes) || 0;
    if (tier === 'custom') {
      var pinned = ((memCfg.memory_guard_custom_ceiling_gb) || 0) * GIB;
      if (pinned && maxCustom && pinned < maxCustom - GIB / 2) {
        return { kind: 'pinned', pinned: pinned, max: maxCustom };
      }
      return { kind: (pv.custom && pv.custom.binding) || 'metal_cap', pinned: pinned, max: maxCustom };
    }
    return { kind: (pv[tier] && pv[tier].binding) || 'dynamic', max: maxCustom };
  }

  var STOPS = [8192, 16384, 32768, 65536, 98304, 131072, 196608, 262144, 524288, 1048576];
  function ctxStops(native) {
    var s = STOPS.filter(function (x) { return !native || x < native; });
    if (native) s.push(native);
    return s;
  }
  function fmtTok(n) {
    if (n == null) return '—';
    if (n >= 1048576 && n % 1048576 === 0) return (n / 1048576) + 'M';
    if (n >= 1024) return (Math.round(n / 102.4) / 10) + 'K';
    return String(n);
  }

  /**
   * Ways to get more room, each with what it would buy. `o` is the forecast
   * input for the current choice; `m` describes the machine:
   *   ceiling, pinned, maxCustom, staticCeiling, metalCap, wired, cpu, total,
   *   available, footprint, tier
   */
  function advise(o, m) {
    var out = [];
    var base = maxContext(o, 'soft');
    var cur = forecast(o);
    var tq = o.tq || {};

    // Nothing to fix when it fits. Offering to raise limits or change system
    // settings in that case would only nudge people toward risk they don't need.
    if (cur.verdict === 'fits') return out;

    // Is it the model, or just what else is loaded? Judge the model on its own.
    var alone = Object.assign({}, o, { others: 0 });
    var aloneFits = forecast(alone).verdict === 'fits';
    if (o.others > 0 && aloneFits) {
      out.push({ kind: 'unload-others', bytes: o.others, fixes: true });
    }
    if (maxContext(alone, 'soft') === 0) {
      out.push({ kind: 'too-big', over: forecast(Object.assign({}, alone, { ctx: 0 })).total - o.soft });
    }

    // Capping the context only helps if some context actually fits; when the
    // weights alone are over the limit, suggesting "0 tokens" would be nonsense.
    var cap = Math.max(0, Math.min(base, o.geo.native || base));
    var nice = ctxStops(o.geo.native).filter(function (x) { return x <= cap; }).pop() || 0;
    if (nice >= STOPS[0] && nice < o.ctx) {
      out.push({ kind: 'cap-context', ctx: nice, savedBytes:
        kvBytes(o.geo, tq, o.ctx, o.seqs) - kvBytes(o.geo, tq, nice, o.seqs) });
    }
    if (!tq.enabled || (tq.bits || 4) > 4) {
      var t4 = Object.assign({}, o, { tq: { enabled: true, bits: 4, skipLast: true } });
      out.push({ kind: 'turboquant', bits: 4, newMax: maxContext(t4, 'soft'), oldMax: base,
        savedBytes: kvBytes(o.geo, tq, o.ctx, o.seqs) - kvBytes(o.geo, t4.tq, o.ctx, o.seqs) });
    }
    // A lever that cannot change the outcome is not worth offering.
    if (m.maxCustom && m.ceiling && m.maxCustom - m.ceiling > GIB / 2) {
      var up = withCeiling(o, m.ceiling, m.maxCustom);
      var upMax = maxContext(up, 'soft');
      var grow = m.maxCustom - (m.footprint || 0);
      if (upMax > base) {
        out.push({ kind: 'raise-ceiling', to: m.maxCustom, gainBytes: m.maxCustom - m.ceiling,
          newMax: upMax, oldMax: base, squeezes: grow > (m.available || 0) - GIB });
      }
    }
    if (m.staticCeiling && m.metalCap && m.staticCeiling - m.metalCap > GIB / 2) {
      var mb = wiredLimitMb(m.total);
      var newWired = mb * MIB, newCap = Math.min(m.staticCeiling, newWired + (m.cpu || 0));
      var wiredMax = maxContext(withCeiling(o, m.ceiling || newCap, newCap), 'soft');
      if (newCap > m.metalCap + GIB / 2 && wiredMax > base) {
        out.push({ kind: 'wired-limit', mb: mb, newMax: newCap, ctxMax: wiredMax, oldMax: base,
          gainBytes: newCap - m.metalCap, command: 'sudo sysctl iogpu.wired_limit_mb=' + mb });
      }
    }
    if (o.others > 0 && !aloneFits) out.push({ kind: 'unload-others', bytes: o.others, fixes: false });
    return out;
  }

  var api = {
    GIB: GIB, MIB: MIB, TQ_BITS: TQ_BITS, TQ_OVERHEAD: TQ_OVERHEAD, HERMES_MIN_CONTEXT: HERMES_MIN_CONTEXT,
    geometry: geometry, kvModel: kvModel, kvBytes: kvBytes, forecast: forecast,
    maxContext: maxContext, withCeiling: withCeiling, wiredLimitMb: wiredLimitMb,
    binding: binding, ctxStops: ctxStops, fmtTok: fmtTok, advise: advise
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.Limits = api;
})(typeof window !== 'undefined' ? window : globalThis);
