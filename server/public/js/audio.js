// GooglyOriginal web — sound engine. A port of Audio.swift: every cartoon sound effect is
// synthesised at startup (same formulas as the Mac app) and played through a small-room reverb;
// the oom-pah music runs in an AudioWorklet (music-worklet.js) through a medium-room reverb.

import { Noise32, Reso, midiHz, RNG } from './music-worklet.js';

const TAU = 2 * Math.PI;
const { sin, exp, pow, min, max, abs, floor, PI } = Math;
const MAX_VOICES = 24;
const MASTER = 0.9;

// MARK: - Pure synthesis (no WebAudio; testable in node)

/** Port of AudioSystem.make(): render, sanitize NaN, peak-normalise to 0.9, 8 ms tail fade, 1 ms attack fade.
 *  `gen(t)` returns [l, r] when stereo, else a single sample used for both channels (mono()). */
function make(sr, dur, gen, stereo = true) {
  const frames = Math.trunc(dur * sr);
  const L = new Float32Array(frames), R = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    let l, r;
    if (stereo) [l, r] = gen(i / sr); else l = r = gen(i / sr);
    L[i] = Number.isFinite(l) ? l : 0; R[i] = Number.isFinite(r) ? r : 0;
  }
  let peak = 0;
  for (let i = 0; i < frames; i++) peak = max(peak, abs(L[i]), abs(R[i]));
  if (peak > 0.9) { const g = 0.9 / peak; for (let i = 0; i < frames; i++) { L[i] *= g; R[i] *= g; } }
  const fade = min(frames, Math.trunc(0.008 * sr));
  for (let k = 0; k < fade; k++) {
    const g = k / fade;
    L[frames - 1 - k] *= g; R[frames - 1 - k] *= g;
  }
  const fin = min(frames, Math.trunc(0.001 * sr));
  for (let k = 0; k < fin; k++) { const g = k / max(1, fin); L[k] *= g; R[k] *= g; }
  return [L, R];
}

const mono = (sr, dur, gen) => make(sr, dur, gen, false);

const rand = (a, b) => a + (b - a) * Math.random();

/** Variant counts, exactly as Audio.swift `set(name, count)`. */
export const VARIANTS = {
  boing: 3, land: 3, step: 3, collect: 2, ptoo: 3, bonk: 3, honk: 2, squeak: 3, squawk: 2, coo: 2, thud: 2, voice: 12,
};

/**
 * Every sound as a list of [key, () => [L, R]] jobs so buffers can be built progressively.
 * Keys use the Swift naming: variants are "name_i", singles are "name".
 */
export function soundJobs(sr) {
  const fsr = sr;
  const jobs = [];
  const one = (name, fn) => jobs.push([name, fn]);
  const set = (name, count, fn) => { for (let v = 0; v < count; v++) jobs.push([`${name}_${v}`, () => fn(v)]); };
  const M = (dur, gen) => mono(sr, dur, gen);
  const S = (dur, gen) => make(sr, dur, gen);

  // Jump: a rising cartoon spring with a fast wobble.
  set('boing', 3, v => {
    const base = [230, 260, 290][v];
    let ph = 0;
    return M(0.32, t => {
      const f = base * (1 + 1.3 * t / 0.32) * (1 + 0.14 * sin(TAU * 22 * t) * exp(-t * 5));
      ph += f / fsr;
      return (sin(TAU * ph) * 0.7 + sin(TAU * ph * 2) * 0.15) * min(1, t * 200) * exp(-t * 5);
    });
  });
  // Super jump: slide whistle up.
  one('superboing', () => {
    let ph = 0;
    const n = new Noise32(3);
    return M(0.6, t => {
      const f = 380 * pow(5, min(1, t / 0.5));
      ph += f / fsr;
      const env = min(1, t * 30) * (t < 0.5 ? 1 : exp(-(t - 0.5) * 30));
      return (sin(TAU * ph) * 0.6 + n.next() * 0.04) * env;
    });
  });
  // Ground pound: slide whistle down.
  one('pound', () => {
    let ph = 0;
    return M(0.35, t => {
      ph += 1600 * pow(0.25, t / 0.35) / fsr;
      return sin(TAU * ph) * 0.5 * min(1, t * 40);
    });
  });
  // Landing: wet jelly squelch.
  set('land', 3, v => {
    const n = new Noise32(40 + v);
    let lp = 0, ph = 0;
    return M(0.3, t => {
      lp += (n.next() - lp) * 0.08;
      ph += (120 + 60 * sin(TAU * 18 * t)) * (1 - t) / fsr;
      return lp * 2.2 * exp(-t * 20) + sin(TAU * ph) * 0.6 * exp(-t * 14);
    });
  });
  // Footstep: tiny rubbery pat.
  set('step', 3, v => {
    const f = [300, 340, 380][v];
    let ph = 0;
    return M(0.08, t => {
      ph += f * (1 - t * 4) / fsr;
      return sin(TAU * ph) * exp(-t * 60) * 0.7;
    });
  });
  // Collect: two bloops going up.
  set('collect', 2, v => {
    const f0 = v === 0 ? 780 : 880;
    let ph = 0;
    return M(0.2, t => {
      const second = t > 0.07;
      const f = (second ? f0 * 1.5 : f0) * (1 + 0.3 * min(1, (second ? t - 0.07 : t) * 30));
      ph += f / fsr;
      const tt = second ? t - 0.07 : t;
      return (sin(TAU * ph) * 0.6 + ((ph % 1) < 0.5 ? 0.12 : -0.12)) * exp(-tt * 25);
    });
  });
  // Eye: sparkly bell arpeggio.
  one('eye', () => M(1.0, t => {
    let s = 0;
    const ms = [84, 88, 91, 96];
    for (let k = 0; k < 4; k++) {
      const t0 = k * 0.07;
      if (!(t >= t0)) continue;
      const dt = t - t0, f = midiHz(ms[k]);
      s += (sin(TAU * f * dt) + 0.3 * sin(TAU * f * 2.76 * dt) * exp(-dt * 8)) * exp(-dt * 5) * 0.25;
    }
    return s;
  }));
  // Spit: lips + air burst + pop.
  set('ptoo', 3, v => {
    const n = new Noise32(100 + v);
    const rs = new Reso();
    let ph = 0;
    return M(0.22, t => {
      ph += (220 - 400 * t) / fsr;
      const air = rs.run(n.next(), 1300 + v * 200, 2, fsr) * exp(-t * 30) * 2;
      const pop = sin(TAU * ph) * exp(-t * 40) * 0.8;
      const lip = t < 0.03 ? sin(TAU * 90 * t) * 0.6 : 0;
      return air + pop + lip;
    });
  });
  one('pea', () => {
    let ph = 0;
    return M(0.14, t => {
      ph += 1500 * pow(0.3, t / 0.14) / fsr;
      return sin(TAU * ph) * 0.45 * exp(-t * 12);
    });
  });
  // Bonk: woodblock + dropping cartoon tone.
  set('bonk', 3, v => {
    const r1 = new Reso(), r2 = new Reso();
    let ph = 0;
    const k = v * 0.08 + 1;
    return M(0.35, t => {
      const imp = t < 0.0015 ? 1 : 0;
      const wood = r1.run(imp, 520 * k, 18, fsr) * 14 + r2.run(imp, 1240 * k, 14, fsr) * 8;
      ph += (420 - 520 * t) * k / fsr;
      return wood * exp(-t * 20) + sin(TAU * ph) * 0.5 * exp(-t * 11);
    });
  });
  // Hit: eye popping out (a cork), then a sad slide down.
  one('hurt', () => {
    let ph = 0, ph2 = 0;
    const n = new Noise32(9);
    return M(0.8, t => {
      let s = 0;
      if (t < 0.12) {
        ph += (300 + 3000 * t) / fsr;
        s += sin(TAU * ph) * 0.6 * exp(-t * 12) + n.next() * 0.3 * exp(-t * 80);
      }
      if (t > 0.15) {
        const u = t - 0.15;
        ph2 += 900 * pow(0.25, u / 0.6) * (1 + 0.02 * sin(TAU * 7 * u)) / fsr;
        s += sin(TAU * ph2) * 0.45 * min(1, u * 30) * exp(-u * 2.5);
      }
      return s;
    });
  });
  // Clown bike horn.
  set('honk', 2, v => {
    let p1 = 0, p2 = 0;
    const r1 = new Reso(), r2 = new Reso();
    const base = v === 0 ? 415 : 392;
    return M(0.42, t => {
      const bend = 1 - 0.04 * max(0, t - 0.3) / 0.12;
      p1 += base * bend / fsr; if (p1 > 1) p1 -= 1;
      p2 += base * 1.012 * bend / fsr; if (p2 > 1) p2 -= 1;
      const raw = (2 * p1 - 1) + (2 * p2 - 1);
      const s = r1.run(raw, 1100, 3, fsr) * 1.4 + r2.run(raw, 2600, 5, fsr) * 0.8 + raw * 0.15;
      return s * min(1, t * 80) * (t < 0.34 ? 1 : exp(-(t - 0.34) * 40));
    });
  });
  // Rubber duck squeak.
  set('squeak', 3, v => {
    let ph = 0;
    const k = 1 + v * 0.08;
    return M(0.18, t => {
      const u = t / 0.18;
      const f = (1700 + 900 * sin(PI * u)) * k;
      ph += f / fsr;
      const tri = 2 * abs(2 * (ph - floor(ph + 0.5))) - 1;
      return tri * 0.45 * sin(PI * u) * (0.8 + 0.2 * sin(TAU * 60 * t));
    });
  });
  // Chicken: bawk.
  set('squawk', 2, v => {
    let ph = 0;
    const n = new Noise32(55 + v);
    const r1 = new Reso(), r2 = new Reso();
    return M(0.4, t => {
      const u = t / 0.4;
      const f = (600 + 700 * sin(PI * min(1, u * 1.6))) * (1 + 0.05 * n.next());
      ph += f / fsr; if (ph > 1) ph -= 1;
      const raw = (2 * ph - 1) + n.next() * 0.3;
      const s = r1.run(raw, 1300, 3, fsr) + r2.run(raw, 2700, 4, fsr) * 0.7;
      return s * sin(PI * u) * (0.7 + 0.3 * sin(TAU * 35 * t));
    });
  });
  // Trampoline: doyoyoyoing.
  one('tramp', () => {
    let ph = 0;
    return M(0.9, t => {
      const f = (170 + 120 * t) * (1 + 0.28 * sin(TAU * 13 * t) * exp(-t * 2.5));
      ph += f / fsr;
      return (sin(TAU * ph) * 0.6 + sin(TAU * ph * 3.01) * 0.12 * exp(-t * 4)) * min(1, t * 200) * exp(-t * 3);
    });
  });
  // Toilet flush: swirling water, gurgles and the tank refilling.
  one('flush', () => {
    const n = new Noise32(777);
    const r1 = new Reso(), r2 = new Reso();
    let bub = 0, bubF = 400, bubT = 0, lp = 0;
    return S(2.4, t => {
      const e = min(1, t * 6) * (t < 1.4 ? 1 : exp(-(t - 1.4) * 2.5));
      const x = n.next();
      lp += (x - lp) * 0.2;
      const swirl = r1.run(lp, 500 + 350 * sin(TAU * 1.6 * t), 2, fsr) * 1.4 + r2.run(x, 2400, 1.5, fsr) * 0.25;
      bubT -= 1 / fsr;
      if (bubT <= 0) { bubT = rand(0.02, 0.09); bubF = rand(250, 900); bub = 0; }
      bub += 1 / fsr;
      const gurgle = sin(TAU * bubF * (1 + bub * 12) * bub) * exp(-bub * 60) * 0.5;
      const s = (swirl + gurgle * (t > 0.5 ? 1 : 0.3)) * e;
      return [s * (1 + 0.2 * sin(TAU * 1.6 * t)), s * (1 - 0.2 * sin(TAU * 1.6 * t))];
    });
  });
  // Level complete: kazoo fanfare.
  one('win', () => {
    let ph = 0;
    const r1 = new Reso(), r2 = new Reso();
    const notes = [[72, 0, 0.12], [72, 0.14, 0.12], [72, 0.28, 0.12], [76, 0.42, 0.25], [79, 0.7, 0.25], [84, 0.98, 0.7]];
    return M(1.9, t => {
      let f = 0, env = 0;
      for (const n of notes) {
        if (!(t >= n[1] && t < n[1] + n[2] + 0.05)) continue;
        f = midiHz(n[0]) * (1 + 0.012 * sin(TAU * 6 * (t - n[1])));
        env = min(1, (t - n[1]) * 60) * (t < n[1] + n[2] ? 1 : exp(-(t - n[1] - n[2]) * 60));
      }
      if (f === 0) return 0;
      ph += f / fsr; if (ph > 1) ph -= 1;
      const saw = 2 * ph - 1;
      return (r1.run(saw, 700, 3, fsr) + r2.run(saw, 1600, 4, fsr) * 0.7 + saw * 0.1) * env * 0.8;
    });
  });
  // KO: sad trombone.
  one('ko', () => {
    let ph = 0;
    const r1 = new Reso();
    const notes = [[67, 0, 0.35], [66, 0.4, 0.35], [65, 0.8, 0.35], [64, 1.2, 1.1]];
    return M(2.5, t => {
      let f = 0, env = 0, wah = 0;
      for (const n of notes) {
        if (!(t >= n[1] && t < n[1] + n[2] + 0.08)) continue;
        const u = t - n[1];
        const vib = n[0] === 64 ? 0.03 * sin(TAU * 5 * u) * min(1, u * 2) : 0;
        f = midiHz(n[0] - 12) * (1 + vib);
        env = min(1, u * 25) * (u < n[2] ? 1 : exp(-(u - n[2]) * 40));
        wah = 300 + 900 * min(1, u / 0.2);
      }
      if (f === 0) return 0;
      ph += f / fsr; if (ph > 1) ph -= 1;
      const saw = 2 * ph - 1;
      return (r1.run(saw, wah, 2.5, fsr) * 1.2 + saw * 0.1) * env;
    });
  });
  // Enemy popping into confetti: balloon pop + sparkles.
  one('pop', () => {
    const n = new Noise32(31);
    let lp = 0;
    return S(0.6, t => {
      const x = n.next();
      lp += (x - lp) * 0.3;
      let s = (x - lp * 0.5) * exp(-t * 90) * 1.2 + sin(TAU * 90 * t) * exp(-t * 30) * 0.5;
      for (let k = 0; k < 4; k++) {
        const t0 = 0.06 + k * 0.07;
        if (t > t0) s += sin(TAU * midiHz(88 + k * 3) * (t - t0)) * exp(-(t - t0) * 20) * 0.15;
      }
      return [s, s * 0.9];
    });
  });
  // Pigeon coo.
  set('coo', 2, v => {
    let ph = 0;
    return M(0.5, t => {
      const u = t / 0.5;
      const f = (340 + v * 30) * (1 + 0.25 * sin(PI * u));
      ph += f / fsr;
      const am = 0.6 + 0.4 * sin(TAU * 28 * t);
      return (sin(TAU * ph) + 0.3 * sin(TAU * ph * 2)) * am * sin(PI * u) * 0.5;
    });
  });
  one('splat', () => {
    const n = new Noise32(12);
    let lp = 0;
    return M(0.35, t => {
      lp += (n.next() - lp) * (0.3 - t * 0.6);
      return lp * 2.5 * exp(-t * 12) + sin(TAU * 140 * t * (1 - t)) * exp(-t * 25) * 0.4;
    });
  });
  // Toaster: spring pop then a bell ding.
  one('ding', () => {
    let ph = 0;
    return M(1.1, t => {
      ph += (220 + 500 * min(1, t * 12)) / fsr;
      const pop = sin(TAU * ph) * exp(-t * 25) * 0.5;
      const tb = t - 0.08;
      const bell = tb > 0 ? (sin(TAU * 2350 * tb) + 0.4 * sin(TAU * 5870 * tb) * exp(-tb * 6)) * exp(-tb * 3.5) * 0.35 : 0;
      return pop + bell;
    });
  });
  one('whoosh', () => {
    const n = new Noise32(44);
    const r = new Reso();
    return M(0.6, t => {
      const u = t / 0.6;
      return r.run(n.next(), 300 + 1500 * u, 1.5, fsr) * sin(PI * u) * 1.5;
    });
  });
  // Boss landing: a big boom.
  one('stomp', () => {
    const n = new Noise32(88);
    let lp = 0, ph = 0;
    return M(1.3, t => {
      lp += (n.next() - lp) * 0.03;
      ph += (28 + 50 * exp(-t * 8)) / fsr;
      return sin(TAU * ph) * exp(-t * 3) * 1.1 + lp * 3 * exp(-t * 6);
    });
  });
  one('checkpoint', () => M(0.5, t => {
    let s = 0;
    const ms = [72, 76, 79];
    for (let k = 0; k < 3; k++) {
      const t0 = k * 0.08;
      if (!(t > t0)) continue;
      const dt = t - t0;
      const f = midiHz(ms[k]);
      const sq = sin(TAU * f * dt) > 0 ? 1 : -1;
      s += (sq * 0.2 + sin(TAU * f * dt) * 0.3) * exp(-dt * 9);
    }
    return s * 0.6;
  }));
  one('click', () => M(0.05, t => sin(TAU * 1800 * t) * exp(-t * 120) * 0.5));
  // Falling into a pit: descending slide whistle, longer.
  one('whoops', () => {
    let ph = 0;
    return M(1.0, t => {
      ph += 1400 * pow(0.18, t) * (1 + 0.03 * sin(TAU * 6 * t)) / fsr;
      return sin(TAU * ph) * 0.5 * min(1, t * 30) * (t < 0.85 ? 1 : exp(-(t - 0.85) * 30));
    });
  });
  set('thud', 2, v => {
    const r = new Reso();
    const n = new Noise32(70 + v);
    return M(0.15, t => r.run(n.next(), 380 + v * 90, 3, fsr) * exp(-t * 40) * 3);
  });
  one('hop', () => {
    let ph = 0;
    return M(0.18, t => {
      ph += (160 + 300 * t / 0.18) / fsr;
      return sin(TAU * ph) * exp(-t * 14) * 0.5;
    });
  });
  // Gibberish voice: glottal pulses through vowel formants, sometimes with a consonant.
  const vowels = [[800, 1200], [400, 2000], [300, 2300], [500, 900], [350, 700], [650, 1700]];
  set('voice', 12, v => {
    const rr = new RNG(900 + v);
    const [f1, f2] = vowels[v % vowels.length];
    const pitch = rr.range(230, 300);
    const dur = rr.range(0.085, 0.13);
    const consonant = rr.chance(0.6);
    let ph = 0;
    const a = new Reso(), b = new Reso(), c = new Reso();
    const n = new Noise32(5 + v * 7);
    const D = dur;
    return M(dur, t => {
      const u = t / D;
      ph += pitch * (1 + 0.15 * sin(PI * u)) / fsr; if (ph > 1) ph -= 1;
      const pulse = pow(max(0, sin(TAU * ph)), 6) * 2 - 0.3;
      let s = a.run(pulse, f1, 4, fsr) * 1.3 + b.run(pulse, f2, 6, fsr) * 0.8;
      if (consonant && t < 0.02) s += c.run(n.next(), 3500, 2, fsr) * 1.5;
      return s * sin(PI * min(1, u * 1.1)) * 0.9;
    });
  });
  return jobs;
}

/** Builds every SFX buffer synchronously: { key: [Float32Array L, Float32Array R] }. */
export function buildBuffers(sampleRate) {
  const out = {};
  for (const [k, fn] of soundJobs(sampleRate)) out[k] = fn();
  return out;
}

/** Short synthesized room impulse (stereo decaying noise, darkening over time). */
function roomImpulse(ctx, seconds, decay, seed) {
  const sr = ctx.sampleRate, n = Math.max(1, Math.trunc(seconds * sr));
  const buf = ctx.createBuffer(2, n, sr);
  for (let ch = 0; ch < 2; ch++) {
    const d = buf.getChannelData(ch);
    const rnd = new Noise32(seed + ch * 101);
    let lp = 0;
    const pre = Math.trunc(0.004 * sr);
    for (let i = 0; i < n; i++) {
      const t = i / sr;
      const k = 0.6 - 0.45 * (i / n);        // high frequencies die first
      lp += (rnd.next() - lp) * k;
      d[i] = i < pre ? 0 : lp * exp(-t * decay) * (i < pre + 64 ? (i - pre) / 64 : 1);
    }
  }
  return buf;
}

// MARK: - WebAudio engine

export class GameAudio {
  constructor(opts = {}) {
    this._muted = !!opts.muted;
    this.ctx = null;
    this.buffers = new Map();
    this._built = false;
    this._building = false;
    this._voices = [];
    this._musicNode = null;
    this._musicStarting = null;
    this._musicFailed = false;
    this._style = 4;
    this._duck = 1;
    this._musicHasStyle = false;
  }

  _ensureContext() {
    if (this.ctx) return true;
    try {
      const AC = globalThis.AudioContext || globalThis.webkitAudioContext;
      if (!AC) return false;
      const ctx = new AC({ latencyHint: 'interactive' });
      this.ctx = ctx;
      this.master = ctx.createGain();
      this.master.gain.value = this._muted ? 0 : MASTER;
      this.master.connect(ctx.destination);
      this.sfxBus = this._reverbBus(0.12, roomImpulse(ctx, 0.45, 9, 17));      // like smallRoom, 12% wet
      this.musicBus = this._reverbBus(0.14, roomImpulse(ctx, 0.9, 5.5, 29));   // like mediumRoom, 14% wet
      return true;
    } catch (e) {
      console.warn('Googly: audio unavailable:', e);
      this.ctx = null;
      return false;
    }
  }

  _reverbBus(wet, impulse) {
    const ctx = this.ctx;
    const input = ctx.createGain();
    const dry = ctx.createGain(); dry.gain.value = 1 - wet;
    const wetG = ctx.createGain(); wetG.gain.value = wet;
    const conv = ctx.createConvolver();
    conv.normalize = true;
    conv.buffer = impulse;
    input.connect(dry); dry.connect(this.master);
    input.connect(conv); conv.connect(wetG); wetG.connect(this.master);
    return input;
  }

  /** Call from a user gesture. Resumes the context, builds buffers, starts the music. Safe to call repeatedly. */
  async unlock() {
    if (!this._ensureContext()) return;
    const ctx = this.ctx;
    if (!this._building) { this._building = true; this._buildProgressively(); }
    try { if (ctx.state !== 'running') await ctx.resume(); } catch (e) { /* blocked; try again next gesture */ }
    await this._startMusic();
  }

  _buildProgressively() {
    const ctx = this.ctx;
    const jobs = soundJobs(ctx.sampleRate);
    let i = 0;
    const tick = () => {
      const t0 = performance.now();
      while (i < jobs.length && performance.now() - t0 < 12) {
        const [key, fn] = jobs[i++];
        try {
          const [L, R] = fn();
          const b = ctx.createBuffer(2, Math.max(1, L.length), ctx.sampleRate);
          b.copyToChannel(L, 0); b.copyToChannel(R, 1);
          this.buffers.set(key, b);
        } catch (e) { console.warn('Googly: sound', key, 'failed:', e); }
      }
      if (i < jobs.length) setTimeout(tick, 0); else this._built = true;
    };
    tick();
  }

  async _startMusic() {
    if (this._musicNode || this._musicFailed) return;
    if (this._musicStarting) return this._musicStarting;
    const ctx = this.ctx;
    this._musicStarting = (async () => {
      try {
        if (!ctx.audioWorklet || typeof AudioWorkletNode === 'undefined') throw new Error('AudioWorklet unsupported');
        await ctx.audioWorklet.addModule(new URL('./music-worklet.js', import.meta.url));
        const node = new AudioWorkletNode(ctx, 'googly-music', {
          numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [2],
        });
        node.onprocessorerror = e => console.warn('Googly: music worklet error', e);
        node.port.postMessage({ style: this._style, duck: this._duck });
        node.connect(this.musicBus);
        this._musicNode = node;
      } catch (e) {
        this._musicFailed = true;
        console.warn('Googly: music unavailable:', e);
      } finally {
        this._musicStarting = null;
      }
    })();
    return this._musicStarting;
  }

  /** Plays a one-shot. Names with variants ("bonk") pick one at random. */
  play(name, volume = 1, rate = 1, jitter = 0.04) {
    const ctx = this.ctx;
    if (!ctx || this._muted || ctx.state !== 'running') return;
    let key = name;
    const nv = VARIANTS[name];
    if (nv) key = `${name}_${Math.floor(Math.random() * nv)}`;
    const buf = this.buffers.get(key);
    if (!buf) return;
    const v = max(0, min(1.4, +volume || 0));
    if (!(v > 0.004)) return;
    const j = +jitter || 0;
    const r = max(0.25, min(4, (+rate || 1) * (1 + rand(-j, max(j, 0.0001)))));
    try {
      const src = ctx.createBufferSource();
      src.buffer = buf;
      src.playbackRate.value = r;
      const g = ctx.createGain();
      g.gain.value = v;
      src.connect(g); g.connect(this.sfxBus);
      const voice = { src, g };
      src.onended = () => {
        const i = this._voices.indexOf(voice);
        if (i >= 0) this._voices.splice(i, 1);
        try { g.disconnect(); } catch (e) { /* already gone */ }
      };
      this._voices.push(voice);
      while (this._voices.length > MAX_VOICES) {
        const old = this._voices.shift();
        try { old.src.onended = null; old.src.stop(); old.g.disconnect(); } catch (e) { /* ignore */ }
      }
      src.start();
    } catch (e) { /* ignore a failed one-shot */ }
  }

  /** 0..4, the MusicSynth styles. The worklet fades out, loads the new tune and fades back in. */
  setMusic(style) {
    const s = Math.max(0, Math.min(4, Math.round(+style || 0)));
    this._style = s;
    if (this._musicNode) this._musicNode.port.postMessage({ style: s });
  }

  /** 0..1 music duck target (smoothed inside the worklet). */
  setDuck(x) {
    const d = Math.max(0, Math.min(1, Number.isFinite(+x) ? +x : 1));
    if (d === this._duck) return;
    this._duck = d;
    if (this._musicNode) this._musicNode.port.postMessage({ duck: d });
  }

  toggleMute() {
    this._muted = !this._muted;
    if (this.ctx && this.master) {
      const g = this.master.gain, now = this.ctx.currentTime;
      g.cancelScheduledValues(now);
      g.setValueAtTime(g.value, now);
      g.linearRampToValueAtTime(this._muted ? 0 : MASTER, now + 0.02);
    }
    return this._muted;
  }

  get muted() { return this._muted; }
  get ready() { return this._built && !!this.ctx && this.ctx.state === 'running'; }
}
