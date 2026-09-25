import SpriteKit

/// A dumb bot that holds right, hops over things and spits at enemies (for --demo and the autotest),
/// plus the physics self-test.
extension Game {
    func demoControls() -> Player.Controls {
        var c = Player.Controls()
        c.move = 1
        if demoHold > 0 {
            demoHold -= 1.0 / 60
            c.squish = demoHold > 0.05
            c.move = 0
            return c
        }
        let f = player.c.x + 75
        let wall = world.solidAt(V2(f, player.c.y - 20)) || world.solidAt(V2(f, player.c.y + 20))
        let tall = world.solidAt(V2(f, player.c.y + 120))
        let below = world.groundBelow(player.c.x + 120, player.c.y + 40)
        let pit = below == nil || below! < player.bottom - 120
        let fanAhead = world.fans.contains { player.c.x + 150 > $0.lo.x && player.c.x < $0.lo.x }
        if player.grounded {
            if wall && tall { demoHold = 0.95 }
            else if wall || (pit && !fanAhead) { c.jump = true }
            else if Float.random(in: 0...1) < 0.004 { c.jump = true }
        }
        // in a fan column: drift right once above the ledge
        if player.inFan { c.move = player.c.y > 560 ? 1 : 0.2 }
        return c
    }

    private func nearestEnemy() -> Enemy? {
        enemies.filter { !$0.dead && abs($0.pos.x - player.c.x) < 650 && abs($0.pos.y - player.c.y) < 400 }
            .min { ($0.pos - player.c).len < ($1.pos - player.c).len }
    }

    func demoWantsFire() -> Bool { nearestEnemy() != nil && Float.random(in: 0...1) < 0.12 }

    func demoAim() -> V2 {
        guard let e = nearestEnemy() else { return V2(player.facing, 0.2).norm }
        let d = e.pos - player.c
        return V2(d.x, d.y + abs(d.x) * 0.45).norm
    }

    // MARK: Self-test

    func autotest() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool, _ info: String) {
            print((cond ? "PASS " : "FAIL ") + name + "  " + info)
            ok = ok && cond
        }
        let w = World()
        w.solids = [Solid([V2(-3000, -700), V2(3000, -700), V2(3000, 0), V2(-3000, 0)], kind: .ground)]
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

        p.place(at: V2(0, 80))
        run(2, .init())
        check("rests upright", abs(p.bottom) < 6 && abs(p.angle) < 0.08 && finite(), String(format: "bottom %.1f angle %.3f", p.bottom, p.angle))

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
        var mv = Player.Controls(); mv.move = 1
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

        p.place(at: V2(0, 2600))
        var minB: Float = 1e9
        run(3, .init()) { minB = min(minB, $0.bottom) }
        check("big fall doesn't tunnel", minB > -16 && abs(p.bottom) < 8 && finite(), String(format: "min bottom %.1f", minB))

        // trampoline
        let t = Solid([V2(-60, -22), V2(60, -22), V2(60, 14), V2(-60, 14)], kind: .bouncy)
        w.solids.append(t)
        p.place(at: V2(0, 400))
        peak = -1e9
        var bounced = false
        run(2.5, .init()) { q in if q.bottom > 30 && q.v[0].y > 0 { bounced = true }; if bounced { peak = max(peak, q.bottom) } }
        check("trampoline launches", peak > 350, String(format: "%.0f", peak))
        w.solids.removeLast()

        // ground pound
        p.place(at: V2(0, 700))
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
        p.place(at: V2(0, 80))
        run(0.5, .init())
        p.shove(V2(520, 520), spin: -4)
        run(3, .init())
        check("recovers from a hit", abs(p.angle) < 0.15 && abs(p.bottom) < 8 && finite(), String(format: "angle %.2f", p.angle))

        // googly pupils never leave their eyes
        var g = Googly(R: 14)
        var worst: Float = 0
        for i in 0..<2000 {
            let e = V2(sinf(Float(i) * 0.3) * 80, cosf(Float(i) * 0.47) * 60)
            g.update(e, dt: 1.0 / 60)
            worst = max(worst, g.p.len)
        }
        check("pupils stay inside", worst <= g.R - g.r + 0.01, String(format: "%.2f / %.2f", worst, g.R - g.r))

        // level sanity
        for i in 0..<LevelData.names.count {
            let L = LevelData.make(i)
            let lw = World(); lw.solids = L.solids
            var problems: [String] = []
            if lw.groundBelow(L.goal.x, L.goal.y + 50) == nil { problems.append("goal floats") }
            for cp in L.checkpoints where lw.groundBelow(cp.x, cp.y + 50) == nil { problems.append("checkpoint \(cp.x) floats") }
            for (k, e) in L.enemies where k != .pigeon && lw.groundBelow(e.x, e.y) == nil { problems.append("enemy at \(e.x) floats") }
            for (_, pt) in L.pickups where lw.solidAt(pt) { problems.append("pickup buried at \(pt.x)") }
            check("level \(i + 1) layout", problems.isEmpty, problems.joined(separator: ", "))
        }
        ok = audio.selfCheck() && ok

        // bot playthroughs: can a dumb bot get far on each level?
        if CommandLine.arguments.contains("--bot") {
            for i in 0..<LevelData.names.count {
                demo = true
                startLevel(i, fresh: true)
                player.setEyes(10)
                var best: Float = 0
                var tt = 0.0
                for _ in 0..<(60 * 150) {
                    tt += 1.0 / 60
                    tick(tt)
                    player.invuln = 1
                    best = max(best, player.c.x)
                    if state != .playing { break }
                }
                print(String(format: "INFO bot level %d: reached x=%.0f of goal %.0f, state %@, falls %d", i + 1, best, level.goal.x, "\(state)", falls))
            }
            demo = false
        }
        print(ok ? "ALL PASS" : "SOME FAILED")
        return ok
    }
}
