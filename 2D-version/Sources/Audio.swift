import AVFoundation

/// AVAudioEngine graph: the music synth, and a pool of one-shot players for cartoon sound effects.
/// Every sound is synthesised at launch.
final class AudioSystem {
    let engine = AVAudioEngine()
    let format: AVAudioFormat
    let sr: Double
    let music: MusicSynth
    private var players: [AVAudioPlayerNode] = []
    private var speeds: [AVAudioUnitVarispeed] = []
    private var nextPlayer = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var variants: [String: Int] = [:]
    private let queue = DispatchQueue(label: "googly.sfx")
    private(set) var running = false
    private(set) var muted = false

    init(muted: Bool = false) {
        self.muted = muted
        let out = engine.outputNode.outputFormat(forBus: 0)
        sr = out.sampleRate > 0 ? out.sampleRate : 48000
        format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        music = MusicSynth(sampleRate: Float(sr))
        let m = music
        let musicNode = AVAudioSourceNode(format: format) { _, _, frames, abl -> OSStatus in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            m.render(frames: Int(frames), b[0].mData!.assumingMemoryBound(to: Float.self), b[1].mData!.assumingMemoryBound(to: Float.self))
            return noErr
        }
        let room = AVAudioUnitReverb()
        room.loadFactoryPreset(.smallRoom)
        room.wetDryMix = 12
        let mRoom = AVAudioUnitReverb()
        mRoom.loadFactoryPreset(.mediumRoom)
        mRoom.wetDryMix = 14
        let sfxMix = AVAudioMixerNode()
        for n in [musicNode, room, mRoom, sfxMix] as [AVAudioNode] { engine.attach(n) }
        engine.connect(musicNode, to: mRoom, format: format)
        engine.connect(mRoom, to: engine.mainMixerNode, format: format)
        engine.connect(sfxMix, to: room, format: format)
        engine.connect(room, to: engine.mainMixerNode, format: format)
        for _ in 0..<24 {
            let p = AVAudioPlayerNode(), vs = AVAudioUnitVarispeed()
            engine.attach(p); engine.attach(vs)
            engine.connect(p, to: vs, format: format)
            engine.connect(vs, to: sfxMix, format: format)
            players.append(p); speeds.append(vs)
        }
        engine.mainMixerNode.outputVolume = muted ? 0 : 0.9
        buildBuffers()
        do {
            try engine.start()
            for p in players { p.play() }
            running = true
        } catch {
            NSLog("Googly: audio unavailable: \(error)")
        }
    }

    func toggleMute() {
        muted.toggle()
        engine.mainMixerNode.outputVolume = muted ? 0 : 0.9
    }

    /// Plays a one-shot. Names with variants ("bonk") pick one at random.
    func play(_ name: String, volume: Float = 1, rate: Float = 1, jitter: Float = 0.04) {
        guard running, !muted else { return }
        var key = name
        if let n = variants[name] { key = "\(name)_\(Int.random(in: 0..<n))" }
        guard let buf = buffers[key] else { return }
        let v = max(0, min(1.4, volume))
        guard v > 0.004 else { return }
        queue.async {
            let i = self.nextPlayer
            let p = self.players[i]
            self.nextPlayer = (self.nextPlayer + 1) % self.players.count
            self.speeds[i].rate = max(0.25, min(4, rate * (1 + Float.random(in: -jitter...max(jitter, 0.0001)))))
            p.volume = v
            p.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
            if !p.isPlaying { p.play() }
        }
    }

    /// Peak and NaN check of every buffer plus 30 s of every music style (for --autotest).
    func selfCheck() -> Bool {
        var bad: [String] = []
        for (k, b) in buffers.sorted(by: { $0.key < $1.key }) {
            var peak: Float = 0
            let L = b.floatChannelData![0]
            for i in 0..<Int(b.frameLength) { if !L[i].isFinite { peak = .nan; break }; peak = max(peak, abs(L[i])) }
            if !(peak > 0.005 && peak < 1.6) { bad.append("\(k)=\(peak)") }
        }
        print(bad.isEmpty ? "PASS sfx buffers (\(buffers.count))" : "FAIL sfx buffers: \(bad.joined(separator: ", "))")
        let n = 1024
        let L = UnsafeMutablePointer<Float>.allocate(capacity: n), R = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { L.deallocate(); R.deallocate() }
        var ok = bad.isEmpty
        for style in 0..<5 {
            let mus = MusicSynth(sampleRate: Float(sr))
            mus.style = style
            var pk: Float = 0, rms: Double = 0, count = 0
            for _ in 0..<Int(30 * sr) / n {
                mus.render(frames: n, L, R)
                for i in 0..<n { let a = abs(L[i]); pk = max(pk, a.isFinite ? a : 99); rms += Double(L[i] * L[i]); count += 1 }
            }
            let good = pk < 1.05 && pk > 0.05
            ok = ok && good
            print(String(format: "%@ music style %d peak %.2f rms %.3f", good ? "PASS" : "FAIL", style, pk, sqrt(rms / Double(count))))
        }
        return ok
    }

    // MARK: Synthesis

    private func make(_ dur: Double, _ gen: (Float) -> (Float, Float)) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(dur * sr)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        let L = b.floatChannelData![0], R = b.floatChannelData![1]
        let fsr = Float(sr)
        for i in 0..<Int(frames) {
            let (l, r) = gen(Float(i) / fsr)
            L[i] = l.isFinite ? l : 0; R[i] = r.isFinite ? r : 0
        }
        var peak: Float = 0
        for i in 0..<Int(frames) { peak = max(peak, abs(L[i]), abs(R[i])) }
        if peak > 0.9 { let g = 0.9 / peak; for i in 0..<Int(frames) { L[i] *= g; R[i] *= g } }
        let fade = min(Int(frames), Int(0.008 * sr))
        for k in 0..<fade {
            let g = Float(k) / Float(fade)
            L[Int(frames) - 1 - k] *= g; R[Int(frames) - 1 - k] *= g
        }
        let fin = min(Int(frames), Int(0.001 * sr))
        for k in 0..<fin { let g = Float(k) / Float(max(1, fin)); L[k] *= g; R[k] *= g }
        return b
    }

    private func mono(_ dur: Double, _ gen: (Float) -> Float) -> AVAudioPCMBuffer { make(dur) { t in let s = gen(t); return (s, s) } }

    private func set(_ name: String, _ count: Int, _ gen: (Int) -> AVAudioPCMBuffer) {
        variants[name] = count
        for i in 0..<count { buffers["\(name)_\(i)"] = gen(i) }
    }

    private func buildBuffers() {
        let tau: Float = 2 * .pi
        let fsr = Float(sr)

        // Jump: a rising cartoon spring with a fast wobble.
        set("boing", 3) { v in
            let base: Float = [230, 260, 290][v]
            var ph: Float = 0
            return mono(0.32) { t in
                let f = base * (1 + 1.3 * t / 0.32) * (1 + 0.14 * sinf(tau * 22 * t) * expf(-t * 5))
                ph += f / fsr
                return (sinf(tau * ph) * 0.7 + sinf(tau * ph * 2) * 0.15) * min(1, t * 200) * expf(-t * 5)
            }
        }
        // Super jump: slide whistle up.
        buffers["superboing"] = {
            var ph: Float = 0
            var n = Noise32(s: 3)
            return mono(0.6) { t in
                let f = 380 * powf(5, min(1, t / 0.5))
                ph += f / fsr
                let env = min(1, t * 30) * (t < 0.5 ? 1 : expf(-(t - 0.5) * 30))
                return (sinf(tau * ph) * 0.6 + n.next() * 0.04) * env
            }
        }()
        // Ground pound: slide whistle down.
        buffers["pound"] = {
            var ph: Float = 0
            return mono(0.35) { t in
                ph += 1600 * powf(0.25, t / 0.35) / fsr
                return sinf(tau * ph) * 0.5 * min(1, t * 40)
            }
        }()
        // Landing: wet jelly squelch.
        set("land", 3) { v in
            var n = Noise32(s: UInt32(40 + v))
            var lp: Float = 0
            var ph: Float = 0
            return mono(0.3) { t in
                lp += (n.next() - lp) * 0.08
                ph += (120 + 60 * sinf(tau * 18 * t)) * (1 - t) / fsr
                return (lp * 2.2 * expf(-t * 20) + sinf(tau * ph) * 0.6 * expf(-t * 14))
            }
        }
        // Footstep: tiny rubbery pat.
        set("step", 3) { v in
            let f: Float = [300, 340, 380][v]
            var ph: Float = 0
            return mono(0.08) { t in
                ph += f * (1 - t * 4) / fsr
                return sinf(tau * ph) * expf(-t * 60) * 0.7
            }
        }
        // Collect: two bloops going up.
        set("collect", 2) { v in
            let f0: Float = v == 0 ? 780 : 880
            var ph: Float = 0
            return mono(0.2) { t in
                let second = t > 0.07
                let f = (second ? f0 * 1.5 : f0) * (1 + 0.3 * min(1, (second ? t - 0.07 : t) * 30))
                ph += f / fsr
                let tt = second ? t - 0.07 : t
                return (sinf(tau * ph) * 0.6 + (ph.truncatingRemainder(dividingBy: 1) < 0.5 ? 0.12 : -0.12)) * expf(-tt * 25)
            }
        }
        // Eye: sparkly bell arpeggio.
        buffers["eye"] = mono(1.0) { t in
            var s: Float = 0
            for (k, m) in [84, 88, 91, 96].enumerated() {
                let t0 = Float(k) * 0.07
                guard t >= t0 else { continue }
                let dt = t - t0, f = midiHz(Float(m))
                s += (sinf(tau * f * dt) + 0.3 * sinf(tau * f * 2.76 * dt) * expf(-dt * 8)) * expf(-dt * 5) * 0.25
            }
            return s
        }
        // Spit: lips + air burst + pop.
        set("ptoo", 3) { v in
            var n = Noise32(s: UInt32(100 + v))
            var rs = Reso()
            var ph: Float = 0
            return mono(0.22) { t in
                ph += (220 - 400 * t) / fsr
                let air = rs.run(n.next(), f: 1300 + Float(v) * 200, q: 2, sr: fsr) * expf(-t * 30) * 2
                let pop = sinf(tau * ph) * expf(-t * 40) * 0.8
                let lip = t < 0.03 ? sinf(tau * 90 * t) * 0.6 : 0
                return air + pop + lip
            }
        }
        buffers["pea"] = {
            var ph: Float = 0
            return mono(0.14) { t in
                ph += 1500 * powf(0.3, t / 0.14) / fsr
                return sinf(tau * ph) * 0.45 * expf(-t * 12)
            }
        }()
        // Bonk: woodblock + dropping cartoon tone.
        set("bonk", 3) { v in
            var r1 = Reso(), r2 = Reso()
            var ph: Float = 0
            let k = Float(v) * 0.08 + 1
            return mono(0.35) { t in
                let imp: Float = t < 0.0015 ? 1 : 0
                let wood = r1.run(imp, f: 520 * k, q: 18, sr: fsr) * 14 + r2.run(imp, f: 1240 * k, q: 14, sr: fsr) * 8
                ph += (420 - 520 * t) * k / fsr
                return wood * expf(-t * 20) + sinf(tau * ph) * 0.5 * expf(-t * 11)
            }
        }
        // Hit: eye popping out (a cork), then a sad slide down.
        buffers["hurt"] = {
            var ph: Float = 0, ph2: Float = 0
            var n = Noise32(s: 9)
            return mono(0.8) { t in
                var s: Float = 0
                if t < 0.12 {
                    ph += (300 + 3000 * t) / fsr
                    s += sinf(tau * ph) * 0.6 * expf(-t * 12) + n.next() * 0.3 * expf(-t * 80)
                }
                if t > 0.15 {
                    let u = t - 0.15
                    ph2 += 900 * powf(0.25, u / 0.6) * (1 + 0.02 * sinf(tau * 7 * u)) / fsr
                    s += sinf(tau * ph2) * 0.45 * min(1, u * 30) * expf(-u * 2.5)
                }
                return s
            }
        }()
        // Clown bike horn.
        set("honk", 2) { v in
            var p1: Float = 0, p2: Float = 0
            var r1 = Reso(), r2 = Reso()
            let base: Float = v == 0 ? 415 : 392
            return mono(0.42) { t in
                let bend = 1 - 0.04 * max(0, t - 0.3) / 0.12
                p1 += base * bend / fsr; if p1 > 1 { p1 -= 1 }
                p2 += base * 1.012 * bend / fsr; if p2 > 1 { p2 -= 1 }
                let raw = (2 * p1 - 1) + (2 * p2 - 1)
                let s = r1.run(raw, f: 1100, q: 3, sr: fsr) * 1.4 + r2.run(raw, f: 2600, q: 5, sr: fsr) * 0.8 + raw * 0.15
                return s * min(1, t * 80) * (t < 0.34 ? 1 : expf(-(t - 0.34) * 40))
            }
        }
        // Rubber duck squeak.
        set("squeak", 3) { v in
            var ph: Float = 0
            let k = 1 + Float(v) * 0.08
            return mono(0.18) { t in
                let u = t / 0.18
                let f = (1700 + 900 * sinf(.pi * u)) * k
                ph += f / fsr
                let tri = 2 * abs(2 * (ph - floorf(ph + 0.5))) - 1
                return tri * 0.45 * sinf(.pi * u) * (0.8 + 0.2 * sinf(tau * 60 * t))
            }
        }
        // Chicken: bawk.
        set("squawk", 2) { v in
            var ph: Float = 0
            var n = Noise32(s: UInt32(55 + v))
            var r1 = Reso(), r2 = Reso()
            return mono(0.4) { t in
                let u = t / 0.4
                let f = (600 + 700 * sinf(.pi * min(1, u * 1.6))) * (1 + 0.05 * n.next())
                ph += f / fsr; if ph > 1 { ph -= 1 }
                let raw = (2 * ph - 1) + n.next() * 0.3
                let s = r1.run(raw, f: 1300, q: 3, sr: fsr) + r2.run(raw, f: 2700, q: 4, sr: fsr) * 0.7
                return s * sinf(.pi * u) * (0.7 + 0.3 * sinf(tau * 35 * t))
            }
        }
        // Trampoline: doyoyoyoing.
        buffers["tramp"] = {
            var ph: Float = 0
            return mono(0.9) { t in
                let f = (170 + 120 * t) * (1 + 0.28 * sinf(tau * 13 * t) * expf(-t * 2.5))
                ph += f / fsr
                return (sinf(tau * ph) * 0.6 + sinf(tau * ph * 3.01) * 0.12 * expf(-t * 4)) * min(1, t * 200) * expf(-t * 3)
            }
        }()
        // Toilet flush: swirling water, gurgles and the tank refilling.
        buffers["flush"] = {
            var n = Noise32(s: 777)
            var r1 = Reso(), r2 = Reso()
            var bub: Float = 0, bubF: Float = 400, bubT: Float = 0
            var lp: Float = 0
            return make(2.4) { t in
                let e = min(1, t * 6) * (t < 1.4 ? 1 : expf(-(t - 1.4) * 2.5))
                let x = n.next()
                lp += (x - lp) * 0.2
                let swirl = r1.run(lp, f: 500 + 350 * sinf(tau * 1.6 * t), q: 2, sr: fsr) * 1.4 + r2.run(x, f: 2400, q: 1.5, sr: fsr) * 0.25
                bubT -= 1 / fsr
                if bubT <= 0 { bubT = Float.random(in: 0.02...0.09); bubF = Float.random(in: 250...900); bub = 0 }
                bub += 1 / fsr
                let gurgle = sinf(tau * bubF * (1 + bub * 12) * bub) * expf(-bub * 60) * 0.5
                let s = (swirl + gurgle * (t > 0.5 ? 1 : 0.3)) * e
                return (s * (1 + 0.2 * sinf(tau * 1.6 * t)), s * (1 - 0.2 * sinf(tau * 1.6 * t)))
            }
        }()
        // Level complete: kazoo fanfare.
        buffers["win"] = {
            var ph: Float = 0
            var r1 = Reso(), r2 = Reso()
            let notes: [(Float, Float, Float)] = [(72, 0, 0.12), (72, 0.14, 0.12), (72, 0.28, 0.12), (76, 0.42, 0.25), (79, 0.7, 0.25), (84, 0.98, 0.7)]
            return mono(1.9) { t in
                var f: Float = 0, env: Float = 0
                for n in notes where t >= n.1 && t < n.1 + n.2 + 0.05 {
                    f = midiHz(n.0) * (1 + 0.012 * sinf(tau * 6 * (t - n.1)))
                    env = min(1, (t - n.1) * 60) * (t < n.1 + n.2 ? 1 : expf(-(t - n.1 - n.2) * 60))
                }
                if f == 0 { return 0 }
                ph += f / fsr; if ph > 1 { ph -= 1 }
                let saw = 2 * ph - 1
                return (r1.run(saw, f: 700, q: 3, sr: fsr) + r2.run(saw, f: 1600, q: 4, sr: fsr) * 0.7 + saw * 0.1) * env * 0.8
            }
        }()
        // KO: sad trombone.
        buffers["ko"] = {
            var ph: Float = 0
            var r1 = Reso()
            let notes: [(Float, Float, Float)] = [(67, 0, 0.35), (66, 0.4, 0.35), (65, 0.8, 0.35), (64, 1.2, 1.1)]
            return mono(2.5) { t in
                var f: Float = 0, env: Float = 0, wah: Float = 0
                for n in notes where t >= n.1 && t < n.1 + n.2 + 0.08 {
                    let u = t - n.1
                    let vib: Float = n.0 == 64 ? 0.03 * sinf(tau * 5 * u) * min(1, u * 2) : 0
                    f = midiHz(n.0 - 12) * (1 + vib)
                    env = min(1, u * 25) * (u < n.2 ? 1 : expf(-(u - n.2) * 40))
                    wah = 300 + 900 * min(1, u / 0.2)
                }
                if f == 0 { return 0 }
                ph += f / fsr; if ph > 1 { ph -= 1 }
                let saw = 2 * ph - 1
                return (r1.run(saw, f: wah, q: 2.5, sr: fsr) * 1.2 + saw * 0.1) * env
            }
        }()
        // Enemy popping into confetti: balloon pop + sparkles.
        buffers["pop"] = {
            var n = Noise32(s: 31)
            var lp: Float = 0
            return make(0.6) { t in
                let x = n.next()
                lp += (x - lp) * 0.3
                var s = (x - lp * 0.5) * expf(-t * 90) * 1.2 + sinf(tau * 90 * t) * expf(-t * 30) * 0.5
                for k in 0..<4 {
                    let t0 = 0.06 + Float(k) * 0.07
                    if t > t0 { s += sinf(tau * midiHz(Float(88 + k * 3)) * (t - t0)) * expf(-(t - t0) * 20) * 0.15 }
                }
                return (s, s * 0.9)
            }
        }()
        // Pigeon coo.
        set("coo", 2) { v in
            var ph: Float = 0
            return mono(0.5) { t in
                let u = t / 0.5
                let f = (340 + Float(v) * 30) * (1 + 0.25 * sinf(.pi * u))
                ph += f / fsr
                let am = 0.6 + 0.4 * sinf(tau * 28 * t)
                return (sinf(tau * ph) + 0.3 * sinf(tau * ph * 2)) * am * sinf(.pi * u) * 0.5
            }
        }
        buffers["splat"] = {
            var n = Noise32(s: 12)
            var lp: Float = 0
            return mono(0.35) { t in
                lp += (n.next() - lp) * (0.3 - t * 0.6)
                return lp * 2.5 * expf(-t * 12) + sinf(tau * 140 * t * (1 - t)) * expf(-t * 25) * 0.4
            }
        }()
        // Toaster: spring pop then a bell ding.
        buffers["ding"] = {
            var ph: Float = 0
            return mono(1.1) { t in
                ph += (220 + 500 * min(1, t * 12)) / fsr
                let pop = sinf(tau * ph) * expf(-t * 25) * 0.5
                let tb = t - 0.08
                let bell = tb > 0 ? (sinf(tau * 2350 * tb) + 0.4 * sinf(tau * 5870 * tb) * expf(-tb * 6)) * expf(-tb * 3.5) * 0.35 : 0
                return pop + bell
            }
        }()
        buffers["whoosh"] = {
            var n = Noise32(s: 44)
            var r = Reso()
            return mono(0.6) { t in
                let u = t / 0.6
                return r.run(n.next(), f: 300 + 1500 * u, q: 1.5, sr: fsr) * sinf(.pi * u) * 1.5
            }
        }()
        // Boss landing: a big boom.
        buffers["stomp"] = {
            var n = Noise32(s: 88)
            var lp: Float = 0, ph: Float = 0
            return mono(1.3) { t in
                lp += (n.next() - lp) * 0.03
                ph += (28 + 50 * expf(-t * 8)) / fsr
                return sinf(tau * ph) * expf(-t * 3) * 1.1 + lp * 3 * expf(-t * 6)
            }
        }()
        buffers["checkpoint"] = mono(0.5) { t in
            var s: Float = 0
            for (k, m) in [72, 76, 79].enumerated() {
                let t0 = Float(k) * 0.08
                guard t > t0 else { continue }
                let dt = t - t0
                let f = midiHz(Float(m))
                let sq: Float = sinf(tau * f * dt) > 0 ? 1 : -1
                s += (sq * 0.2 + sinf(tau * f * dt) * 0.3) * expf(-dt * 9)
            }
            return s * 0.6
        }
        buffers["click"] = mono(0.05) { t in sinf(tau * 1800 * t) * expf(-t * 120) * 0.5 }
        // Falling into a pit: descending slide whistle, longer.
        buffers["whoops"] = {
            var ph: Float = 0
            return mono(1.0) { t in
                ph += 1400 * powf(0.18, t) * (1 + 0.03 * sinf(tau * 6 * t)) / fsr
                return sinf(tau * ph) * 0.5 * min(1, t * 30) * (t < 0.85 ? 1 : expf(-(t - 0.85) * 30))
            }
        }()
        set("thud", 2) { v in
            var r = Reso()
            var n = Noise32(s: UInt32(70 + v))
            return mono(0.15) { t in r.run(n.next(), f: 380 + Float(v) * 90, q: 3, sr: fsr) * expf(-t * 40) * 3 }
        }
        buffers["hop"] = {
            var ph: Float = 0
            return mono(0.18) { t in
                ph += (160 + 300 * t / 0.18) / fsr
                return sinf(tau * ph) * expf(-t * 14) * 0.5
            }
        }()
        // Gibberish voice: glottal pulses through vowel formants, sometimes with a consonant.
        let vowels: [(Float, Float)] = [(800, 1200), (400, 2000), (300, 2300), (500, 900), (350, 700), (650, 1700)]
        set("voice", 12) { v in
            var rr = RNG(UInt64(900 + v))
            let (f1, f2) = vowels[v % vowels.count]
            let pitch: Float = rr.range(230, 300)
            let dur = Double(rr.range(0.085, 0.13))
            let consonant = rr.chance(0.6)
            var ph: Float = 0
            var a = Reso(), b = Reso(), c = Reso()
            var n = Noise32(s: UInt32(5 + v * 7))
            let D = Float(dur)
            return mono(dur) { t in
                let u = t / D
                ph += pitch * (1 + 0.15 * sinf(.pi * u)) / fsr; if ph > 1 { ph -= 1 }
                let pulse = powf(max(0, sinf(tau * ph)), 6) * 2 - 0.3
                var s = a.run(pulse, f: f1, q: 4, sr: fsr) * 1.3 + b.run(pulse, f: f2, q: 6, sr: fsr) * 0.8
                if consonant && t < 0.02 { s += c.run(n.next(), f: 3500, q: 2, sr: fsr) * 1.5 }
                return s * sinf(.pi * min(1, u * 1.1)) * 0.9
            }
        }
    }
}
