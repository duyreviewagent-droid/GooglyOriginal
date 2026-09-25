import Foundation

// The music synth runs on the audio thread. The game thread writes `style` and `duck`
// (benign single-word races); render() picks them up at bar lines and smooths them.

@inline(__always) func softClip(_ x: Float) -> Float {
    let c = max(-3, min(3, x))
    return c * (27 + c * c) / (27 + 9 * c * c)
}

struct Noise32 {
    var s: UInt32
    @inline(__always) mutating func next() -> Float {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        return Float(s) / 2_147_483_648.0 - 1
    }
}

@inline(__always) func midiHz(_ m: Float) -> Float { 440 * powf(2, (m - 69) / 12) }

/// Two-pole resonator (band-pass-ish).
struct Reso {
    var y1: Float = 0, y2: Float = 0
    @inline(__always) mutating func run(_ x: Float, f: Float, q: Float, sr: Float) -> Float {
        let w = 2 * Float.pi * min(f, sr * 0.45) / sr
        let r = 1 - w / (2 * q)
        let y = x * (1 - r) * 2 + 2 * r * cosf(w) * y1 - r * r * y2
        y2 = y1; y1 = y
        return y
    }
}

@inline(__always) func equalPan(_ p: Float) -> (Float, Float) {
    let a = (max(-1, min(1, p)) + 1) * .pi / 4
    return (cosf(a) * 1.414, sinf(a) * 1.414)
}

/// A bouncy oom-pah band: tuba, pah chords, kazoo or whistle lead, marimba, kick, clap, woodblock.
final class MusicSynth {
    let sr: Float
    var style = 4
    var duck: Float = 1
    var master: Float = 0.85

    private struct Style {
        var root: Int
        var scale: [Int]
        var bpm: Float
        var prog: [Int]
        var lead: Int          // 0 kazoo, 1 whistle, 2 marimba
        var drums: Float
        var seed: UInt64
    }
    private let styles: [Style] = [
        Style(root: 60, scale: [0, 2, 4, 5, 7, 9, 11], bpm: 132, prog: [0, 3, 4, 0, 0, 5, 3, 4], lead: 0, drums: 1, seed: 11),
        Style(root: 62, scale: [0, 2, 4, 5, 7, 9, 10], bpm: 124, prog: [0, 6, 0, 6, 3, 0, 4, 0], lead: 1, drums: 1, seed: 23),
        Style(root: 57, scale: [0, 2, 3, 5, 7, 9, 10], bpm: 118, prog: [0, 3, 0, 3, 5, 4, 0, 4], lead: 2, drums: 0.8, seed: 37),
        Style(root: 57, scale: [0, 2, 3, 5, 7, 8, 11], bpm: 152, prog: [0, 0, 5, 4, 0, 0, 5, 4], lead: 0, drums: 1.3, seed: 41),
        Style(root: 60, scale: [0, 2, 4, 5, 7, 9, 11], bpm: 108, prog: [0, 5, 3, 4, 0, 5, 3, 4], lead: 2, drums: 0.6, seed: 5),
    ]
    private var cur = -1
    private var st: Style
    private var melody: [[Int]] = []     // per bar, 8 eighths: scale step or -99 rest
    private var counter: [[Int]] = []
    private var stepSamples = 0
    private var samplePos = 0
    private var step = 0
    private var sDuck: Float = 1
    private var fade: Float = 1
    private var pending = -1

    private struct Voice {
        var kind = -1
        var f: Float = 0
        var ph: Float = 0
        var ph2: Float = 0
        var age: Float = 0
        var len: Float = 0
        var amp: Float = 0
        var pan: Float = 0
        var lp: Float = 0
        var r1 = Reso(), r2 = Reso()
        var n = Noise32(s: 1234)
    }
    private var voices = [Voice](repeating: Voice(), count: 28)
    private var vi = 0

    init(sampleRate: Float) {
        sr = sampleRate
        st = styles[4]
        load(4)
    }

    private func load(_ s: Int) {
        cur = s
        st = styles[max(0, min(styles.count - 1, s))]
        stepSamples = Int(sr * 60 / st.bpm / 4)
        var r = RNG(st.seed)
        // phrase A (4 bars) and B (4 bars) of eighth notes built from chord tones and neighbours
        func phrase() -> [[Int]] {
            var bars: [[Int]] = []
            var last = 4
            for b in 0..<4 {
                var bar: [Int] = []
                for e in 0..<8 {
                    let chord = st.prog[b % st.prog.count]
                    if e % 2 == 1 && r.chance(0.35) { bar.append(-99); continue }
                    if b == 3 && e >= 6 { bar.append(-99); continue }
                    var note: Int
                    if e % 4 == 0 { note = chord + [0, 2, 4][r.int(3)] + (r.chance(0.5) ? 7 : 0) }
                    else { note = last + [-1, 1, -2, 2, 0][r.int(5)] }
                    note = max(0, min(13, note))
                    bar.append(note)
                    last = note
                }
                bars.append(bar)
            }
            return bars
        }
        let A = phrase(), B = phrase()
        var A2 = A
        A2[3] = [st.prog[3] + 7, -99, st.prog[3] + 4, -99, st.prog[3] + 2, -99, 7, -99]
        melody = A + B + A2 + B
        counter = (0..<8).map { _ in (0..<16).map { _ in r.chance(0.55) ? r.int(3) : -1 } }
        step = 0
        samplePos = 0
    }

    private func noteMidi(_ deg: Int, octave: Int) -> Float {
        let n = st.scale.count
        let o = Int(floor(Double(deg) / Double(n)))
        let d = ((deg % n) + n) % n
        return Float(st.root + st.scale[d] + 12 * (o + octave))
    }

    private func trigger(_ kind: Int, _ midi: Float, len: Float, amp: Float, pan: Float = 0) {
        var v = Voice()
        v.kind = kind
        v.f = midiHz(midi)
        v.len = len
        v.amp = amp
        v.pan = pan
        v.n = Noise32(s: UInt32(truncatingIfNeeded: vi &* 2654435761 &+ 17))
        voices[vi] = v
        vi = (vi + 1) % voices.count
    }

    private func onStep() {
        let bars = melody.count
        let bar = (step / 16) % bars
        let s = step % 16
        let chord = st.prog[bar % st.prog.count]
        let beatLen = 60 / st.bpm
        let d = st.drums
        if s % 4 == 0 {
            let beat = s / 4
            if beat == 0 || beat == 2 {
                let deg = beat == 0 ? chord : chord + 4
                trigger(0, noteMidi(deg, octave: -2), len: beatLen * 0.7, amp: 0.55)
                trigger(4, 0, len: 0.3, amp: 0.55 * d)
            } else {
                for (k, off) in [0, 2, 4].enumerated() {
                    trigger(1, noteMidi(chord + off, octave: 0), len: beatLen * 0.28, amp: 0.1, pan: Float(k - 1) * 0.4)
                }
                trigger(5, 0, len: 0.2, amp: 0.3 * d)
            }
        }
        if s % 4 == 2 { trigger(6, 0, len: 0.1, amp: 0.16 * d, pan: 0.3) }
        if d > 1.1 && s % 2 == 1 { trigger(7, 0, len: 0.05, amp: 0.08, pan: -0.3) }
        if s % 2 == 0 {
            let row = melody[bar]
            let e = s / 2
            let n = row[e]
            if n > -50 {
                var l: Float = 1
                var k = e + 1
                while k < 8 && row[k] <= -50 && l < 3 { l += 1; k += 1 }
                let kind = st.lead == 0 ? 2 : st.lead == 1 ? 8 : 3
                trigger(kind, noteMidi(n, octave: kind == 3 ? 1 : 0), len: beatLen * 0.5 * l * 0.85, amp: kind == 3 ? 0.28 : kind == 2 ? 0.09 : 0.22)
            }
        }
        // marimba counter line on 16ths
        if st.lead != 2 {
            let c = counter[bar % 8][s]
            if c >= 0 && (bar / 8) % 2 == 1 {
                trigger(3, noteMidi(chord + [0, 2, 4][c], octave: 1), len: 0.3, amp: 0.1, pan: 0.5)
            }
        }
        step += 1
    }

    func render(frames: Int, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>) {
        let tau = 2 * Float.pi, inv = 1 / sr
        if style != cur && pending != style { pending = style }
        let dT = duck, mT = master
        for i in 0..<frames {
            if pending >= 0 {
                fade -= inv * 3
                if fade <= 0 { load(pending); pending = -1 }
            } else if fade < 1 { fade = min(1, fade + inv * 2) }
            if samplePos <= 0 { onStep(); samplePos = stepSamples }
            samplePos -= 1
            sDuck += (dT - sDuck) * 0.0003
            var l: Float = 0, r: Float = 0
            for k in 0..<voices.count where voices[k].kind >= 0 {
                var v = voices[k]
                v.age += inv
                let a = v.age
                var s: Float = 0
                switch v.kind {
                case 0: // tuba: filtered saw with a blatty attack
                    let f = v.f * (1 - 0.05 * expf(-a * 40))
                    v.ph += f * inv; if v.ph > 1 { v.ph -= 1 }
                    let saw = 2 * v.ph - 1
                    let cut = 0.04 + 0.12 * expf(-a * 12)
                    v.lp += (saw - v.lp) * cut
                    let env = min(1, a * 120) * (a < v.len ? 1 : expf(-(a - v.len) * 30))
                    s = (v.lp * 1.6 + sinf(tau * v.ph) * 0.5) * env
                    if a > v.len + 0.25 { v.kind = -1 }
                case 1: // pah chord: pulse, short
                    v.ph += v.f * inv; if v.ph > 1 { v.ph -= 1 }
                    let p: Float = v.ph < 0.3 ? 1 : -0.43
                    v.lp += (p - v.lp) * 0.18
                    s = v.lp * min(1, a * 300) * expf(-a * 16)
                    if a > 0.5 { v.kind = -1 }
                case 2: // kazoo: buzzy saw through two formants, with vibrato
                    let vib = 1 + 0.012 * sinf(tau * 5.5 * a) * min(1, a * 5)
                    v.ph += v.f * vib * inv; if v.ph > 1 { v.ph -= 1 }
                    let saw = 2 * v.ph - 1 + v.n.next() * 0.15
                    let f1 = v.r1.run(saw, f: 650, q: 3, sr: sr), f2 = v.r2.run(saw, f: 1500, q: 4, sr: sr)
                    let env = min(1, a * 60) * (a < v.len ? 1 : expf(-(a - v.len) * 25))
                    s = (f1 * 0.9 + f2 * 0.7 + saw * 0.12) * env
                    if a > v.len + 0.3 { v.kind = -1 }
                case 3: // marimba
                    v.ph += v.f * inv; if v.ph > 1 { v.ph -= 1 }
                    s = (sinf(tau * v.ph) + 0.35 * sinf(tau * v.ph * 4) * expf(-a * 40)) * expf(-a * 7) * min(1, a * 800)
                    if a > 0.9 { v.kind = -1 }
                case 4: // kick
                    v.ph += (45 + 110 * expf(-a * 28)) * inv
                    s = sinf(tau * v.ph) * expf(-a * 11) * 1.2
                    if a > 0.4 { v.kind = -1 }
                case 5: // clap
                    let x = v.n.next()
                    let burst: Float = (a < 0.012 || (a > 0.02 && a < 0.03)) ? 1 : 0.5
                    s = v.r1.run(x, f: 1600, q: 1.2, sr: sr) * expf(-a * 22) * 2 * burst
                    if a > 0.3 { v.kind = -1 }
                case 6: // woodblock
                    s = v.r1.run(a < 0.002 ? 1 : 0, f: 1100, q: 25, sr: sr) * 8 * expf(-a * 50)
                    if a > 0.15 { v.kind = -1 }
                case 7: // hat
                    let x = v.n.next()
                    v.lp += (x - v.lp) * 0.5
                    s = (x - v.lp) * expf(-a * 70)
                    if a > 0.08 { v.kind = -1 }
                case 8: // whistle / ocarina
                    let vib = 1 + 0.008 * sinf(tau * 6 * a) * min(1, a * 4)
                    v.ph += v.f * vib * inv; if v.ph > 1 { v.ph -= 1 }
                    let breath = v.r1.run(v.n.next(), f: v.f * 2, q: 6, sr: sr) * 0.3
                    let env = min(1, a * 40) * (a < v.len ? 1 : expf(-(a - v.len) * 20))
                    s = (sinf(tau * v.ph) + 0.12 * sinf(tau * v.ph * 2) + breath) * env
                    if a > v.len + 0.3 { v.kind = -1 }
                default: v.kind = -1
                }
                let (pl, pr) = equalPan(v.pan)
                l += s * v.amp * pl
                r += s * v.amp * pr
                voices[k] = v
            }
            let g = mT * sDuck * fade * 0.55
            L[i] = softClip(l * g)
            R[i] = softClip(r * g)
        }
    }
}
