import SpriteKit

/// A dumb bot that holds right, hops over things and spits at enemies (for --demo and the autotest),
/// plus the physics self-test.
extension Game {
    /// Bot for one player: runs right, hops obstacles, spits at enemies, teleports when left behind.
    func demoActions(_ s: Slot) -> Actions {
        var a = Actions()
        let b = s.body
        var c = Player.Controls()
        c.move = V2(1, clampf((Float(s.index) * 60 - 90 - b.c.z) / 150, -0.6, 0.6))
        if goalVisible && abs(level.goal.x - b.c.x) < 700 {
            // home in on the golden toilet
            let d = level.goal - b.c
            c.move = V2(d.x, d.z).norm
            if (boss.map { !$0.dead } ?? false) { c.move = V2(0, 0) }
        }
        if s.demoBack > 0 {
            s.demoBack -= 1.0 / 60
            c.move.x = -1
            if s.demoBack <= 0 { s.demoHold = 0.95 }
            a.ctl = c
            return a
        }
        if s.demoHold > 0 {
            s.demoHold -= 1.0 / 60
            c.squish = s.demoHold > 0.05 && b.grounded
            c.move = .zero
            a.ctl = c
            return a
        }
        let f = b.c.x + 75, z = b.c.z
        let wall = world.solidAt(V3(f, b.c.y - 20, z)) || world.solidAt(V3(f, b.c.y + 20, z))
        let tall = world.solidAt(V3(f, b.c.y + 120, z))
        let below = world.groundBelow(b.c.x + 120, z, b.c.y + 40)
        let pit = below == nil || below! < b.bottom - 120
        let fanAhead = world.fans.contains { b.c.x + 150 > $0.lo.x && b.c.x < $0.lo.x }
        if b.grounded {
            let roof = world.solidAt(V3(b.c.x, b.c.y + 150, z)) || world.solidAt(V3(b.c.x + 40, b.c.y + 150, z))
            if wall && tall && roof { s.demoBack = 0.6 }
            else if wall && tall { s.demoHold = 0.95 }
            else if wall || (pit && !fanAhead) { a.jumpPressed = true }
            else if Float.random(in: 0...1) < 0.004 { a.jumpPressed = true }
        }
        if b.inFan { c.move.x = b.c.y > 560 ? 1 : 0.2 }
        a.ctl = c
        a.fire = demoTarget(s) != nil && Float.random(in: 0...1) < 0.12
        a.teleport = s.behind && Float.random(in: 0...1) < 0.05
        return a
    }

    func demoTarget(_ s: Slot) -> V3? {
        enemies.filter { !$0.dead && abs($0.pos.x - s.body.c.x) < 650 && abs($0.pos.y - s.body.c.y) < 400 }
            .min { ($0.pos - s.body.c).len < ($1.pos - s.body.c).len }?.pos
    }

    // MARK: Self-test

    func autotest() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool, _ info: String) {
            print((cond ? "PASS " : "FAIL ") + name + "  " + info)
            ok = ok && cond
        }
        let w = World()
        w.solids = [Solid([V2(-3000, -700), V2(3000, -700), V2(3000, 0), V2(-3000, 0)], z0: -3000, z1: 3000, kind: .ground)]
        let p = Player()
        p.setEyes(2)
        let h: Float = 1.0 / 240
        func run(_ secs: Float, _ ctl: Player.Controls, track: ((Player) -> Void)? = nil) {
            var c = ctl
            for i in 0..<Int(secs / h) {
                var ev: [Player.Event] = []
                if i > 0 { c.jump = false }
                p.step(h, c, w, events: &ev)
                if i % 4 == 0 { p.frame(h * 4, world: w, t: Float(i) * h) }
                track?(p)
            }
        }
        func finite() -> Bool { p.x.allSatisfy { $0.x.isFinite && $0.y.isFinite } }

        p.place(at: V3(0, 80, 0))
        run(2, .init())
        check("rests upright", abs(p.bottom) < 6 && p.upright > 0.99 && finite(), String(format: "bottom %.1f upright %.3f", p.bottom, p.upright))

        var ctl = Player.Controls(); ctl.jump = true
        var peak: Float = -1e9
        run(1.4, ctl) { peak = max(peak, $0.bottom) }
        check("jump height", peak > 105 && peak < 230, String(format: "%.0f", peak))

        run(1, .init())
        var sq = Player.Controls(); sq.squish = true
        run(1, sq)
        peak = -1e9
        run(1.6, .init()) { peak = max(peak, $0.bottom) }
        check("super jump height", peak > 250 && peak < 520, String(format: "%.0f", peak))

        run(1, .init())
        let x0 = p.c.x
        var mv = Player.Controls(); mv.move = V2(1, 0)
        run(2, mv)
        check("walks", p.c.x - x0 > 650, String(format: "%.0f in 2 s", p.c.x - x0))

        // running jump distance
        run(0.5, mv)
        var rj = mv; rj.jump = true
        let jx = p.c.x
        var landX: Float = 0
        var airborne = false, landed = false
        run(1.5, rj) { q in
            if !q.grounded { airborne = true }
            if airborne && q.grounded && !landed { landed = true; landX = q.c.x }
        }
        check("running jump distance", landed && landX - jx > 260, String(format: "%.0f", landX - jx))

        p.place(at: V3(0, 2600, 0))
        var minB: Float = 1e9
        run(3, .init()) { minB = min(minB, $0.bottom) }
        run(2, .init())
        check("big fall doesn't tunnel", minB > -16 && abs(p.bottom) < 8 && finite(), String(format: "min bottom %.1f final %.1f upright %.2f", minB, p.bottom, p.upright))

        // trampoline
        let t = Solid([V2(-60, -22), V2(60, -22), V2(60, 14), V2(-60, 14)], z0: -60, z1: 60, kind: .bouncy)
        w.solids.append(t)
        p.place(at: V3(0, 400, 0))
        peak = -1e9
        var bounced = false
        run(2.5, .init()) { q in if q.bottom > 30 && q.v[0].y > 0 { bounced = true }; if bounced { peak = max(peak, q.bottom) } }
        check("trampoline launches", peak > 350, String(format: "%.0f", peak))
        w.solids.removeLast()

        // ground pound
        p.place(at: V3(0, 700, 0))
        var pd = Player.Controls()
        run(0.2, pd)
        pd.squish = true
        var poundLanded = false
        for _ in 0..<Int(1.5 / h) {
            var ev: [Player.Event] = []
            p.step(h, pd, w, events: &ev)
            if ev.contains(where: { if case .poundLand = $0 { return true }; return false }) { poundLanded = true }
            if p.grounded { pd.squish = false }
        }
        check("butt slam lands", poundLanded, "")

        // knockback + recovers upright
        p.place(at: V3(0, 80, 0))
        run(0.5, .init())
        p.shove(V3(520, 520, 0), spin: -4)
        run(3, .init())
        check("recovers from a hit", p.upright > 0.97 && abs(p.bottom) < 8 && finite(), String(format: "upright %.3f", p.upright))
        // walking into the screen too
        run(0.5, .init())
        let z0 = p.c.z
        var mz = Player.Controls(); mz.move = V2(0, -1)
        run(1.5, mz)
        check("walks in depth", z0 - p.c.z > 450 && p.upright > 0.9, String(format: "%.0f", z0 - p.c.z))

        // googly pupils never leave their eyes
        var g = Googly(R: 14)
        var worst: Float = 0
        for i in 0..<2000 {
            let e = V3(sinf(Float(i) * 0.3) * 80, cosf(Float(i) * 0.47) * 60, sinf(Float(i) * 0.2) * 50)
            g.update(e, u: V3(1, 0, 0), v: V3(0, 1, 0), dt: 1.0 / 60)
            worst = max(worst, g.p.len)
        }
        check("pupils stay inside", worst <= g.R - g.r + 0.01, String(format: "%.2f / %.2f", worst, g.R - g.r))

        // level sanity
        for i in 0..<LevelData.names.count {
            let L = LevelData.make(i)
            let lw = World(); lw.solids = L.solids
            var problems: [String] = []
            if lw.groundBelow(L.goal.x, L.goal.z, L.goal.y + 50) == nil { problems.append("goal floats") }
            for cp in L.checkpoints where lw.groundBelow(cp.x, cp.z, cp.y + 50) == nil { problems.append("checkpoint \(cp.x) floats") }
            for (k, e) in L.enemies where k != .pigeon && lw.groundBelow(e.x, e.z, e.y) == nil { problems.append("enemy at \(e.x) floats") }
            for (_, d, _) in L.decor where lw.groundBelow(d.x, d.z, d.y + 5) == nil { problems.append("decor at \(d.x) floats") }
            for (_, pt) in L.pickups where lw.solidAt(pt) { problems.append("pickup buried at \(pt.x)") }
            check("level \(i + 1) layout", problems.isEmpty, problems.joined(separator: ", "))
        }
        ok = audio.selfCheck() && ok

        // bot playthroughs: can a dumb bot get far on each level?
        if CommandLine.arguments.contains("--bot") {
            let n = max(1, min(4, Int(CommandLine.arguments.first { $0.hasPrefix("--players=") }?.dropFirst(10) ?? "1") ?? 1))
            for sc in [Scheme.keysA, .keysB, .pad(0), .pad(1)].prefix(n) { join(sc) }
            for i in 0..<LevelData.names.count {
                demo = true
                startLevel(i, fresh: true)
                for s in slots { s.body.setEyes(10) }
                var best: Float = 0
                var tt = 0.0
                for _ in 0..<(60 * 300) {
                    tt += 1.0 / 60
                    tick(tt)
                    for s in slots { s.body.invuln = 1 }
                    best = max(best, slots.map { $0.body.c.x }.max() ?? 0)
                    if CommandLine.arguments.contains("--botlog") && Int(tt * 60) % 60 == 0 {
                        print(String(format: "  t=%.0f c=(%.0f,%.0f,%.0f) grounded=%d charging=%d hold=%.2f up=%.2f", tt, player.c.x, player.c.y, player.c.z, player.grounded ? 1 : 0, player.charging ? 1 : 0, slots.first?.demoHold ?? 0, player.upright))
                    }
                    if state != .playing { break }
                }
                print(String(format: "INFO bot level %d (%d players): reached x=%.0f of goal %.0f, state %@, falls %d, teleports %d", i + 1, slots.count, best, level.goal.x, "\(state)", slots.reduce(0) { $0 + $1.falls }, slots.reduce(0) { $0 + $1.teleports }))
            }
            demo = false
        }
        print(ok ? "ALL PASS" : "SOME FAILED")
        return ok
    }
}
