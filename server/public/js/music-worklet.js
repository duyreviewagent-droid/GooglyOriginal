// GooglyOriginal web — music worklet. A port of Synths.swift: DSP helpers plus MusicSynth,
// a step-sequenced oom-pah band (tuba, pah chords, kazoo / whistle / marimba lead, kick, clap,
// woodblock, hat) with 5 styles. The helpers are exported so audio.js (and node tests) can reuse
// them; the processor is only registered when loaded inside an AudioWorkletGlobalScope.

const TAU = 2 * Math.PI;

export function softClip(x) {
  const c = x < -3 ? -3 : x > 3 ? 3 : x;
  return c * (27 + c * c) / (27 + 9 * c * c);
}

/** xorshift32, identical to Swift Noise32. Returns roughly -1..1. */
export class Noise32 {
  constructor(s) { this.s = s >>> 0; }
  next() {
    let s = this.s;
    s = (s ^ (s << 13)) >>> 0;
    s = (s ^ (s >>> 17)) >>> 0;
    s = (s ^ (s << 5)) >>> 0;
    this.s = s;
    return s / 2147483648.0 - 1;
  }
}

export const midiHz = m => 440 * Math.pow(2, (m - 69) / 12);

/** Two-pole resonator (band-pass-ish), identical to Swift Reso. */
export class Reso {
  constructor() { this.y1 = 0; this.y2 = 0; }
  reset() { this.y1 = 0; this.y2 = 0; }
  run(x, f, q, sr) {
    const w = TAU * Math.min(f, sr * 0.45) / sr;
    const r = 1 - w / (2 * q);
    const y = x * (1 - r) * 2 + 2 * r * Math.cos(w) * this.y1 - r * r * this.y2;
    this.y2 = this.y1; this.y1 = y;
    return y;
  }
}

/** Equal-power pan; returns [l, r] (x1.414 so centre is unity). */
export function equalPan(p) {
  const a = (Math.max(-1, Math.min(1, p)) + 1) * Math.PI / 4;
  return [Math.cos(a) * 1.414, Math.sin(a) * 1.414];
}

// splitmix64, exact port of Util.swift RNG (BigInt, so sequences match the Mac app bit for bit).
const M64 = (1n << 64n) - 1n;
export class RNG {
  constructor(seed) { this.s = BigInt(seed) & M64; }
  next() {
    this.s = (this.s + 0x9E3779B97F4A7C15n) & M64;
    let z = this.s;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & M64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & M64;
    return z ^ (z >> 31n);
  }
  float() { return Number(this.next() >> 40n) / 16777216.0; }
  range(a, b) { return Math.fround(a + (b - a) * Math.fround(this.float())); }
  chance(p) { return this.float() < p; }
  int(n) { return Number(this.next() % BigInt(n)); }
}

const STYLES = [
  { root: 60, scale: [0, 2, 4, 5, 7, 9, 11], bpm: 132, prog: [0, 3, 4, 0, 0, 5, 3, 4], lead: 0, drums: 1, seed: 11 },
  { root: 62, scale: [0, 2, 4, 5, 7, 9, 10], bpm: 124, prog: [0, 6, 0, 6, 3, 0, 4, 0], lead: 1, drums: 1, seed: 23 },
  { root: 57, scale: [0, 2, 3, 5, 7, 9, 10], bpm: 118, prog: [0, 3, 0, 3, 5, 4, 0, 4], lead: 2, drums: 0.8, seed: 37 },
  { root: 57, scale: [0, 2, 3, 5, 7, 8, 11], bpm: 152, prog: [0, 0, 5, 4, 0, 0, 5, 4], lead: 0, drums: 1.3, seed: 41 },
  { root: 60, scale: [0, 2, 4, 5, 7, 9, 11], bpm: 108, prog: [0, 5, 3, 4, 0, 5, 3, 4], lead: 2, drums: 0.6, seed: 5 },
];
const TRIAD = [0, 2, 4];
const NEIGH = [-1, 1, -2, 2, 0];
const NVOICES = 28;

function newVoice() {
  return { kind: -1, f: 0, ph: 0, ph2: 0, age: 0, len: 0, amp: 0, pl: 1, pr: 1, lp: 0,
           r1: new Reso(), r2: new Reso(), n: new Noise32(1234) };
}

/** A bouncy oom-pah band. Set `style` (0..4) and `duck` (0..1); render() handles the crossfade. */
export class MusicSynth {
  constructor(sampleRate) {
    this.sr = sampleRate;
    this.style = 4;
    this.duck = 1;
    this.master = 0.85;
    this.cur = -1;
    this.st = STYLES[4];
    this.melody = [];
    this.counter = [];
    this.stepSamples = 0;
    this.samplePos = 0;
    this.step = 0;
    this.sDuck = 1;
    this.fade = 1;
    this.pending = -1;
    this.voices = Array.from({ length: NVOICES }, newVoice);
    this.vi = 0;
    this.load(4);
  }

  load(s) {
    this.cur = s;
    const st = this.st = STYLES[Math.max(0, Math.min(STYLES.length - 1, s))];
    this.stepSamples = Math.trunc(this.sr * 60 / st.bpm / 4);
    const r = new RNG(st.seed);
    // phrase A (4 bars) and B (4 bars) of eighth notes built from chord tones and neighbours
    const phrase = () => {
      const bars = [];
      let last = 4;
      for (let b = 0; b < 4; b++) {
        const bar = [];
        for (let e = 0; e < 8; e++) {
          const chord = st.prog[b % st.prog.length];
          if (e % 2 === 1 && r.chance(0.35)) { bar.push(-99); continue; }
          if (b === 3 && e >= 6) { bar.push(-99); continue; }
          let note;
          if (e % 4 === 0) { const t = TRIAD[r.int(3)]; note = chord + t + (r.chance(0.5) ? 7 : 0); }
          else note = last + NEIGH[r.int(5)];
          note = Math.max(0, Math.min(13, note));
          bar.push(note);
          last = note;
        }
        bars.push(bar);
      }
      return bars;
    };
    const A = phrase(), B = phrase();
    const A2 = A.slice();
    const p3 = st.prog[3];
    A2[3] = [p3 + 7, -99, p3 + 4, -99, p3 + 2, -99, 7, -99];
    this.melody = [...A, ...B, ...A2, ...B];
    this.counter = [];
    for (let i = 0; i < 8; i++) {
      const row = [];
      for (let j = 0; j < 16; j++) row.push(r.chance(0.55) ? r.int(3) : -1);
      this.counter.push(row);
    }
    this.step = 0;
    this.samplePos = 0;
  }

  noteMidi(deg, octave) {
    const st = this.st, n = st.scale.length;
    const o = Math.floor(deg / n);
    const d = ((deg % n) + n) % n;
    return st.root + st.scale[d] + 12 * (o + octave);
  }

  trigger(kind, midi, len, amp, pan = 0) {
    const v = this.voices[this.vi];
    v.kind = kind; v.f = midiHz(midi); v.ph = 0; v.ph2 = 0; v.age = 0;
    v.len = len; v.amp = amp; v.lp = 0;
    const a = (Math.max(-1, Math.min(1, pan)) + 1) * Math.PI / 4;
    v.pl = Math.cos(a) * 1.414; v.pr = Math.sin(a) * 1.414;
    v.r1.reset(); v.r2.reset();
    v.n.s = (Math.imul(this.vi, 2654435761 | 0) + 17) >>> 0;
    this.vi = (this.vi + 1) % NVOICES;
  }

  onStep() {
    const st = this.st;
    const bars = this.melody.length;
    const bar = Math.floor(this.step / 16) % bars;
    const s = this.step % 16;
    const chord = st.prog[bar % st.prog.length];
    const beatLen = 60 / st.bpm;
    const d = st.drums;
    if (s % 4 === 0) {
      const beat = s / 4;
      if (beat === 0 || beat === 2) {
        const deg = beat === 0 ? chord : chord + 4;
        this.trigger(0, this.noteMidi(deg, -2), beatLen * 0.7, 0.55);
        this.trigger(4, 0, 0.3, 0.55 * d);
      } else {
        for (let k = 0; k < 3; k++) {
          this.trigger(1, this.noteMidi(chord + TRIAD[k], 0), beatLen * 0.28, 0.1, (k - 1) * 0.4);
        }
        this.trigger(5, 0, 0.2, 0.3 * d);
      }
    }
    if (s % 4 === 2) this.trigger(6, 0, 0.1, 0.16 * d, 0.3);
    if (d > 1.1 && s % 2 === 1) this.trigger(7, 0, 0.05, 0.08, -0.3);
    if (s % 2 === 0) {
      const row = this.melody[bar];
      const e = s / 2;
      const n = row[e];
      if (n > -50) {
        let l = 1, k = e + 1;
        while (k < 8 && row[k] <= -50 && l < 3) { l += 1; k += 1; }
        const kind = st.lead === 0 ? 2 : st.lead === 1 ? 8 : 3;
        this.trigger(kind, this.noteMidi(n, kind === 3 ? 1 : 0), beatLen * 0.5 * l * 0.85,
          kind === 3 ? 0.28 : kind === 2 ? 0.09 : 0.22);
      }
    }
    // marimba counter line on 16ths
    if (st.lead !== 2) {
      const c = this.counter[bar % 8][s];
      if (c >= 0 && Math.floor(bar / 8) % 2 === 1) {
        this.trigger(3, this.noteMidi(chord + TRIAD[c], 1), 0.3, 0.1, 0.5);
      }
    }
    this.step += 1;
  }

  /** Renders `frames` samples into L and R (Float32Arrays). */
  render(frames, L, R) {
    const sr = this.sr, inv = 1 / sr;
    if (this.style !== this.cur && this.pending !== this.style) this.pending = this.style;
    const dT = this.duck, mT = this.master;
    const voices = this.voices;
    const sin = Math.sin, exp = Math.exp, min = Math.min;
    for (let i = 0; i < frames; i++) {
      if (this.pending >= 0) {
        this.fade -= inv * 3;
        if (this.fade <= 0) { this.load(this.pending); this.pending = -1; }
      } else if (this.fade < 1) this.fade = min(1, this.fade + inv * 2);
      if (this.samplePos <= 0) { this.onStep(); this.samplePos = this.stepSamples; }
      this.samplePos -= 1;
      this.sDuck += (dT - this.sDuck) * 0.0003;
      let l = 0, r = 0;
      for (let k = 0; k < NVOICES; k++) {
        const v = voices[k];
        if (v.kind < 0) continue;
        v.age += inv;
        const a = v.age;
        let s = 0;
        switch (v.kind) {
          case 0: { // tuba: filtered saw with a blatty attack
            const f = v.f * (1 - 0.05 * exp(-a * 40));
            v.ph += f * inv; if (v.ph > 1) v.ph -= 1;
            const saw = 2 * v.ph - 1;
            const cut = 0.04 + 0.12 * exp(-a * 12);
            v.lp += (saw - v.lp) * cut;
            const env = min(1, a * 120) * (a < v.len ? 1 : exp(-(a - v.len) * 30));
            s = (v.lp * 1.6 + sin(TAU * v.ph) * 0.5) * env;
            if (a > v.len + 0.25) v.kind = -1;
            break;
          }
          case 1: { // pah chord: pulse, short
            v.ph += v.f * inv; if (v.ph > 1) v.ph -= 1;
            const p = v.ph < 0.3 ? 1 : -0.43;
            v.lp += (p - v.lp) * 0.18;
            s = v.lp * min(1, a * 300) * exp(-a * 16);
            if (a > 0.5) v.kind = -1;
            break;
          }
          case 2: { // kazoo: buzzy saw through two formants, with vibrato
            const vib = 1 + 0.012 * sin(TAU * 5.5 * a) * min(1, a * 5);
            v.ph += v.f * vib * inv; if (v.ph > 1) v.ph -= 1;
            const saw = 2 * v.ph - 1 + v.n.next() * 0.15;
            const f1 = v.r1.run(saw, 650, 3, sr), f2 = v.r2.run(saw, 1500, 4, sr);
            const env = min(1, a * 60) * (a < v.len ? 1 : exp(-(a - v.len) * 25));
            s = (f1 * 0.9 + f2 * 0.7 + saw * 0.12) * env;
            if (a > v.len + 0.3) v.kind = -1;
            break;
          }
          case 3: // marimba
            v.ph += v.f * inv; if (v.ph > 1) v.ph -= 1;
            s = (sin(TAU * v.ph) + 0.35 * sin(TAU * v.ph * 4) * exp(-a * 40)) * exp(-a * 7) * min(1, a * 800);
            if (a > 0.9) v.kind = -1;
            break;
          case 4: // kick
            v.ph += (45 + 110 * exp(-a * 28)) * inv;
            s = sin(TAU * v.ph) * exp(-a * 11) * 1.2;
            if (a > 0.4) v.kind = -1;
            break;
          case 5: { // clap
            const x = v.n.next();
            const burst = (a < 0.012 || (a > 0.02 && a < 0.03)) ? 1 : 0.5;
            s = v.r1.run(x, 1600, 1.2, sr) * exp(-a * 22) * 2 * burst;
            if (a > 0.3) v.kind = -1;
            break;
          }
          case 6: // woodblock
            s = v.r1.run(a < 0.002 ? 1 : 0, 1100, 25, sr) * 8 * exp(-a * 50);
            if (a > 0.15) v.kind = -1;
            break;
          case 7: { // hat
            const x = v.n.next();
            v.lp += (x - v.lp) * 0.5;
            s = (x - v.lp) * exp(-a * 70);
            if (a > 0.08) v.kind = -1;
            break;
          }
          case 8: { // whistle / ocarina
            const vib = 1 + 0.008 * sin(TAU * 6 * a) * min(1, a * 4);
            v.ph += v.f * vib * inv; if (v.ph > 1) v.ph -= 1;
            const breath = v.r1.run(v.n.next(), v.f * 2, 6, sr) * 0.3;
            const env = min(1, a * 40) * (a < v.len ? 1 : exp(-(a - v.len) * 20));
            s = (sin(TAU * v.ph) + 0.12 * sin(TAU * v.ph * 2) + breath) * env;
            if (a > v.len + 0.3) v.kind = -1;
            break;
          }
          default: v.kind = -1;
        }
        l += s * v.amp * v.pl;
        r += s * v.amp * v.pr;
      }
      const g = mT * this.sDuck * this.fade * 0.55;
      L[i] = softClip(l * g);
      R[i] = softClip(r * g);
    }
  }
}

// Only inside an AudioWorkletGlobalScope.
if (typeof registerProcessor === 'function' && typeof AudioWorkletProcessor === 'function') {
  class GooglyMusicProcessor extends AudioWorkletProcessor {
    constructor() {
      super();
      this.synth = new MusicSynth(sampleRate);
      this.spare = new Float32Array(128);
      this.port.onmessage = e => {
        const d = e.data || {};
        if (typeof d.style === 'number' && isFinite(d.style)) this.synth.style = Math.max(0, Math.min(4, Math.round(d.style)));
        if (typeof d.duck === 'number' && isFinite(d.duck)) this.synth.duck = Math.max(0, Math.min(1, d.duck));
        if (typeof d.master === 'number' && isFinite(d.master)) this.synth.master = Math.max(0, Math.min(1.5, d.master));
      };
    }
    process(inputs, outputs) {
      const out = outputs[0];
      if (!out || !out[0]) return true;
      const L = out[0];
      let R = out[1];
      if (!R) { if (this.spare.length < L.length) this.spare = new Float32Array(L.length); R = this.spare; }
      this.synth.render(L.length, L, R);
      return true;
    }
  }
  registerProcessor('googly-music', GooglyMusicProcessor);
}
