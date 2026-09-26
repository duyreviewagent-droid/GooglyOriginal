import SceneKit
import SpriteKit

extension NSColor {
    var hexValue: Int {
        let c = usingColorSpace(.sRGB) ?? self
        return (Int(c.redComponent * 255) << 16) | (Int(c.greenComponent * 255) << 8) | Int(c.blueComponent * 255)
    }
}

/// Online play. The host's Mac runs the whole world and streams it; guests run their own jelly body
/// (so their controls feel instant), send input and body state, and replay the host's snapshots and events.
extension Game {
    // MARK: host-side helpers used by the game code

    /// Records a cosmetic event for guests (only while hosting).
    func emit(_ e: [Any]) { if role == .host { evOut.append(e) } }

    func sfx(_ name: String, volume: Float = 1, rate: Float = 1, jitter: Float = 0.04) {
        audio.play(name, volume: volume, rate: rate, jitter: jitter)
        emit(["s", name, Int(volume * 100), Int(rate * 100)])
    }

    func addShake(_ a: Float) {
        shake = max(shake, a)
        emit(["k", Int(a)])
    }

    func banner(_ top: String, _ sub: String) {
        hud.banner(top, sub)
        emit(["b", top, sub])
    }

    func toast(_ s: String) {
        hud.toast(s)
        emit(["o", s])
    }

    /// Shoves a player; guests apply the same shove to their own copy.
    func knock(_ s: Slot, _ dv: V3, spin: Float = 0, axis: V3 = V3(0, 0, 1), jolt: Bool = true) {
        s.body.shove(dv, spin: spin, axis: axis)
        if jolt { s.body.jolt() }
        emit(["kn", s.index, Int(dv.x), Int(dv.y), Int(dv.z), Int(spin * 100), Int(axis.x * 100), Int(axis.y * 100), Int(axis.z * 100), jolt ? 1 : 0])
    }

    /// Moves a player (teleport, respawn). Guests move their own body when they get this.
    func placeSlot(_ s: Slot, _ p: V3) {
        s.body.place(at: p)
        s.placeCount += 1
        emit(["pl", s.index, Int(p.x), Int(p.y), Int(p.z), s.placeCount])
    }

    func hostFlush() {
        guard role == .host, !evOut.isEmpty else { return }
        net?.send(["t": "ev", "e": evOut])
        evOut.removeAll()
    }

    // MARK: connection & lobby

    func openOnline() {
        audio.play("click")
        for s in slots { s.tag.removeFromParent(); s.body.root.removeFromParentNode() }
        slots.removeAll()
        titleCountdown = nil
        worldNode.addChildNode(titleBody.root)
        titleMode = .online
        netError = ""
        if net == nil { net = Net() }
        listTimer = 0
    }

    func leaveOnline(_ reason: String) {
        net?.close()
        net = nil
        role = .offline
        lobbyCode = ""
        menuOpen = false
        state = .playing   // so toTitle rebuilds the title scene
        toTitle()
        hud.toast(reason)
    }

    func removeSlot(_ seat: Int) {
        guard let s = slot(seat) else { return }
        s.body.root.removeFromParentNode()
        s.tag.removeFromParent()
        s.bubble?.removeFromParent()
        slots.removeAll { $0.index == seat }
        if leader === s { leader = nil }
        if state == .playing { hud.toast("\(s.name) LEFT") }
        if slots.isEmpty { worldNode.addChildNode(titleBody.root) }
    }

    private func syncRoster(_ players: [Any]) {
        var seen = Set<Int>()
        for case let p as [String: Any] in players {
            let seat = p.i("seat")
            seen.insert(seat)
            if let s = slot(seat) { s.netName = p.s("name") }
            else { join(seat == mySeat ? .keysA : .remote(seat), seat: seat, name: p.s("name")) }
        }
        for s in slots where !seen.contains(s.index) { removeSlot(s.index) }
    }

    /// Processes everything the server sent since last frame.
    func pumpNet() {
        guard let n = net else { return }
        if case .closed(let why) = n.status, role != .offline {
            leaveOnline("Lost connection: \(why)")
            return
        }
        for m in n.drain() {
            switch m.s("t") {
            case "lobbies":
                lobbyList = m.arr("list").compactMap { $0 as? [String: Any] }
            case "joined":
                lobbyCode = m.s("code")
                mySeat = m.i("seat")
                netError = ""
                for s in slots { s.tag.removeFromParent(); s.body.root.removeFromParentNode() }
                slots.removeAll()
                titleBody.root.removeFromParentNode()
                if m.b("host") {
                    role = .host
                    join(.keysA, seat: 0, name: Net.playerName)
                } else {
                    role = .guest
                    syncRoster(m.arr("players"))
                }
                titleMode = .lobby
                audio.play("checkpoint", volume: 0.6)
                if role == .guest && m.b("started") { startGuest(m.i("level")) }
                if autoCodeFile != nil, role == .host { try? lobbyCode.write(toFile: autoCodeFile!, atomically: true, encoding: .utf8) }
            case "players":
                if role == .guest { syncRoster(m.arr("players")) }
                else {
                    for case let p as [String: Any] in m.arr("players") { slot(p.i("seat"))?.netName = p.s("name") }
                }
            case "arrive":
                if role == .host {
                    join(.remote(m.i("seat")), seat: m.i("seat"), name: m.s("name"))
                    snapCount = 0   // next snapshot carries the full pickup list
                    if state == .playing { toast("\(m.s("name")) JOINED!") }
                }
            case "left":
                removeSlot(m.i("seat"))
            case "start":
                if role == .guest { startGuest(m.i("level")) }
            case "snap":
                if role == .guest { applySnap(m) }
            case "ev":
                if role == .guest { applyEvents(m.arr("e")) }
            case "in":
                if role == .host, let s = slot(m.i("seat")) { readInput(s, m) }
            case "closed":
                leaveOnline(m.s("reason").isEmpty ? "The lobby closed" : m.s("reason"))
                return
            case "error":
                netError = m.s("msg")
                audio.play("hurt", volume: 0.4)
            default: break
            }
        }
    }

    // MARK: title screens

    func animateTitleBodies(_ dt: Float) {
        let bodies = slots.isEmpty ? [titleBody] : slots.map { $0.body }
        for (i, b) in bodies.enumerated() {
            var ctl = Player.Controls()
            if titleHop < 0 && i == Int(time * 7) % bodies.count { ctl.jump = true; titleHop = frand(0.6, 1.6) }
            stepBody(b, dt, ctl)
            b.frame(dt, world: world, t: time)
            b.draw(world: world, t: time)
        }
        for a in bodies { for b in bodies where a !== b { a.pushOut(of: b) } }
        simulateScenery(dt)
        hud.titleTick(dt, time: time)
    }

    func updateOnlineTitle(_ dt: Float) {
        guard let n = net else { titleMode = .main; hud.showTitle(save: save); return }
        let status: String
        switch n.status {
        case .connecting:
            let s = Int(n.secondsConnecting)
            status = s < 4 ? "Connecting to \(n.host)…" : "Waking up the free server… \(s)s (can take ~30–60s)"
        case .open: status = "Connected to \(n.host) · as \(Net.playerName)"
        case .closed(let why): status = "Offline: \(why)"
        }
        let open = n.status == .open
        listTimer -= dt
        if open && listTimer <= 0 && (titleMode == .online) { n.send(["t": "list"]); listTimer = 3 }
        autoOnline(n, open: open)
        switch titleMode {
        case .online:
            if input.wasPressed(Key.esc) { n.close(); net = nil; role = .offline; titleMode = .main; hud.showTitle(save: save); return }
            if open && input.wasPressed(Key.h) { audio.play("click"); n.send(["t": "create", "name": Net.playerName]) }
            if input.wasPressed(Key.j) { audio.play("click"); titleMode = .code; codeEntry = ""; netError = "" }
            for (k, key) in [Key.one, Key.two, Key.three, Key.four, Key.five, Key.six].enumerated() where input.wasPressed(key) && k < lobbyList.count {
                n.send(["t": "join", "code": lobbyList[k].s("code"), "name": Net.playerName])
            }
            hud.showOnline(status: status, lobbies: lobbyList, error: netError, open: open)
        case .code:
            for ch in input.typed where ch.isLetter && codeEntry.count < 4 { codeEntry.append(Character(ch.uppercased())) }
            if input.wasPressed(Key.backspace) && !codeEntry.isEmpty { codeEntry.removeLast() }
            if input.wasPressed(Key.esc) { titleMode = .online }
            if (input.wasPressed(Key.ret, Key.enter)) && codeEntry.count == 4 && open {
                audio.play("click")
                n.send(["t": "join", "code": codeEntry, "name": Net.playerName])
            }
            hud.showCodeEntry(codeEntry, status: status, error: netError)
        case .lobby:
            if input.wasPressed(Key.esc) {
                n.send(["t": "leave"])
                for s in slots { s.tag.removeFromParent(); s.body.root.removeFromParentNode() }
                slots.removeAll()
                worldNode.addChildNode(titleBody.root)
                role = .offline
                lobbyCode = ""
                titleMode = .online
                return
            }
            if role == .host {
                for (k, key) in [Key.one, Key.two, Key.three].enumerated() where input.wasPressed(key) && save.unlocked > k { lobbyLevel = k; audio.play("click") }
                if input.wasPressed(Key.four) && save.unlocked > 3 { lobbyLevel = save.unlocked - 1; audio.play("click") }
                if input.wasPressed(Key.ret, Key.enter) || autoStartReady() { audio.play("click"); startLevel(lobbyLevel, fresh: true) }
            }
            hud.showLobby(code: lobbyCode, slots: slots, host: role == .host, level: lobbyLevel, unlocked: save.unlocked, status: status, mySeat: mySeat)
        case .main: break
        }
    }

    // MARK: host: remote players

    private func readInput(_ s: Slot, _ m: [String: Any]) {
        var r = s.remote
        r.move = V2(m.f("mx"), m.f("mz")) / 100
        r.squish = m.b("sq")
        r.jump = max(r.jump, m.i("j")); r.fire = max(r.fire, m.i("f")); r.honk = max(r.honk, m.i("h")); r.teleport = max(r.teleport, m.i("tp"))
        let aim = m.arr("aim")
        r.aim = aim.count == 3 ? V3(num(aim[0]), num(aim[1]), num(aim[2])) : nil
        let p = m.arr("p")
        if p.count == 6 { r.pos = V3(num(p[0]), num(p[1]), num(p[2])); r.vel = V3(num(p[3]), num(p[4]), num(p[5])) }
        r.placeAck = m.i("pl")
        s.remote = r
    }

    func remoteActions(_ s: Slot) -> Actions {
        var a = Actions()
        a.ctl.move = s.remote.move
        a.ctl.squish = s.remote.squish
        a.jumpPressed = s.remote.jump > s.remote.seenJump
        a.fire = s.remote.fire > s.remote.seenFire
        a.mouseAim = s.remote.aim != nil
        a.honk = s.remote.honk > s.remote.seenHonk
        a.teleport = s.remote.teleport > s.remote.seenTeleport
        s.remote.seenJump = s.remote.jump; s.remote.seenFire = s.remote.fire
        s.remote.seenHonk = s.remote.honk; s.remote.seenTeleport = s.remote.teleport
        return a
    }

    /// Guests own their body's position; the host's copy follows what they report.
    func applyRemoteAuthority(_ s: Slot, _ dt: Float) {
        guard s.remote.placeAck >= s.placeCount, let pos = s.remote.pos, s.body.flushing < 0 else { return }
        let err = pos - s.body.c
        s.body.translate(err.len > 300 ? err : err * min(1, dt * 12))
    }

    // MARK: host: snapshots

    func hostNetTick(_ dt: Float) {
        snapTimer += dt
        guard snapTimer >= 0.05, let n = net else { return }
        snapTimer = 0
        hostFlush()
        n.send(buildSnap())
        snapCount += 1
    }

    private func r(_ f: Float) -> Int { Int(f.rounded()) }

    func buildSnap() -> [String: Any] {
        var p: [[Any]] = []
        for s in slots {
            let b = s.body
            p.append([s.index, r(b.c.x), r(b.c.y), r(b.c.z), r(b.cVel.x), r(b.cVel.y), r(b.cVel.z), b.eyes.count, b.ko > 0 ? 1 : 0,
                      r(s.lastCtl.move.x * 100), r(s.lastCtl.move.y * 100), s.lastCtl.squish ? 1 : 0, s.jumpCount, s.behind ? 1 : 0,
                      s.flushOrder, s.inventory.map { $0.rawValue }, s.placeCount, b.invuln > 0 ? 1 : 0])
        }
        var e: [[Any]] = []
        for x in enemies where !x.dead {
            e.append([x.netID, x.kind.rawValue, r(x.pos.x), r(x.pos.y), r(x.pos.z), r(x.yaw * 100), r(x.tumble * 100),
                      r(x.tumbleAxis.x * 100), r(x.tumbleAxis.z * 100), r(x.squash * 100), x.stun > 0 ? 1 : 0, x.hurtFlash > 0 ? 1 : 0])
        }
        var dp: [[Any]] = []
        for k in pickups where !k.dead && k.netID >= 2000 {
            let what: Int
            switch k.what { case .junk(let j): what = j.rawValue; case .eye: what = -1 }
            dp.append([k.netID, what, r(k.pos.x), r(k.pos.y), r(k.pos.z)])
        }
        var pr: [[Any]] = []
        for q in projectiles where !q.dead {
            pr.append([q.netID, q.junk.rawValue, q.isPoop ? 1 : 0, r(q.pos.x), r(q.pos.y), r(q.pos.z), q.r < 12 && q.junk == .melon ? 1 : 0])
        }
        let sw: [[Any]] = shocks.map { [r($0.center.x), r($0.center.y), r($0.center.z), r($0.radius), r($0.life * 100)] }
        let bossFrac: Float = boss.map { $0.hp / ($0.maxHP * (1 + 0.35 * Float(slots.count - 1))) } ?? 0
        var m: [String: Any] = ["t": "snap", "s": score, "lv": levelIndex, "cp": checkpointIdx, "gv": goalVisible ? 1 : 0,
                                "ft": r(flushT * 100), "ba": bossAwake ? 1 : 0, "bh": r(bossFrac * 1000), "ld": leader?.index ?? -1,
                                "mu": audio.music.style, "p": p, "e": e, "dp": dp, "pr": pr, "sw": sw]
        if snapCount % 40 == 0 { m["pa"] = pickups.filter { !$0.dead && $0.netID < 2000 }.map { $0.netID } }
        return m
    }

    // MARK: guest

    func startGuest(_ lv: Int) {
        titleMode = .main
        menuOpen = false
        for s in slots { s.bonks = 0; s.collected = 0; s.falls = 0; s.jumpCount = 0; s.remote = RemoteInput(); s.flushOrder = -1 }
        state = .playing
        loadLevel(lv)
        flushT = -1
        hud.hideTitle()
        hud.hidePanel()
        hud.banner("ONLINE · LOBBY \(lobbyCode)", level.name)
    }

    func applySnap(_ m: [String: Any]) {
        guard state == .playing || state == .done else { return }
        lastSnapAt = time
        if m.i("lv") != levelIndex && state == .playing { startGuest(m.i("lv")); return }
        score = m.i("s")
        let cp = m.i("cp")
        if cp > checkpointIdx { for k in (checkpointIdx + 1)...cp where k < checkpointFlags.count { Scenery.raise(checkpointFlags[k], instant: true) }; checkpointIdx = cp }
        let gv = m.b("gv")
        if gv != goalVisible && !goalNode.hasActions { goalVisible = gv; goalNode.isHidden = !gv }
        let ft = m.f("ft") / 100
        if ft >= 0 && flushT < 0 { flushT = ft; for s in slots { s.body.flushing = 0 }; crown.isHidden = true }
        bossAwake = m.b("ba")
        hud.bossBar(bossAwake ? m.f("bh") / 1000 : nil)
        if audio.music.style != m.i("mu") { audio.music.style = m.i("mu") }
        guestLeader = m.i("ld")
        leader = slot(guestLeader)

        for case let a as [Any] in m.arr("p") where a.count >= 18 {
            let seat = inum(a[0])
            guard let s = slot(seat) else { continue }
            let pos = V3(num(a[1]), num(a[2]), num(a[3])), vel = V3(num(a[4]), num(a[5]), num(a[6]))
            let eyes = inum(a[7])
            if s.body.eyes.count != eyes { s.body.setEyes(eyes); setMask(s.body.root, 2) }
            s.body.ko = inum(a[8]) == 1 ? 1 : 0
            s.behind = inum(a[13]) == 1
            s.flushOrder = inum(a[14])
            s.inventory = (a[15] as? [Any] ?? []).compactMap { Junk(rawValue: inum($0)) }
            if inum(a[17]) == 1 { s.body.invuln = max(s.body.invuln, 0.12) }
            if seat != mySeat {
                s.netTarget = pos
                s.netVel = vel
                s.remote.move = V2(num(a[9]), num(a[10])) / 100
                s.remote.squish = inum(a[11]) == 1
                let jc = inum(a[12])
                if s.remote.seenJump == 0 && s.remote.jump == 0 { s.remote.seenJump = jc }
                s.remote.jump = jc
            }
        }
        // enemies
        var alive = Set<Int>()
        for case let a as [Any] in m.arr("e") where a.count >= 12 {
            let id = inum(a[0])
            alive.insert(id)
            let pos = V3(num(a[2]), num(a[3]), num(a[4]))
            var e = enemies.first { $0.netID == id }
            if e == nil, let kind = Enemy.Kind(rawValue: inum(a[1])) {
                let n = Enemy(kind, at: pos)
                n.netID = id
                addEnemy(n)
                e = n
            }
            guard let en = e else { continue }
            netEnemyTargets[id] = (pos, num(a[5]) / 100, num(a[6]) / 100, V3(num(a[7]) / 100, 0, num(a[8]) / 100))
            en.squash = max(en.squash, num(a[9]) / 100)
            en.stun = inum(a[10]) == 1 ? 0.2 : 0
            en.hurtFlash = inum(a[11]) == 1 ? 0.1 : en.hurtFlash
        }
        for en in enemies where !en.dead && !alive.contains(en.netID) {
            en.dead = true
            en.node.runAction(.sequence([.group([.scale(to: 1.5, duration: 0.12), .fadeOut(duration: 0.12)]), .removeFromParentNode()]))
        }
        // dynamic pickups
        for case let a as [Any] in m.arr("dp") where a.count >= 5 {
            let id = inum(a[0])
            let pos = V3(num(a[2]), num(a[3]), num(a[4]))
            if let k = pickups.first(where: { $0.netID == id && !$0.dead }) { k.netTarget = pos; continue }
            let w = inum(a[1])
            let what: Pickup.What = w < 0 ? .eye : .junk(Junk(rawValue: w) ?? .duck)
            let k = Pickup(what, at: pos)
            k.netID = id
            k.netTarget = pos
            addPickup(k)
        }
        if let pa = m["pa"] as? [Any] {
            let keep = Set(pa.map { inum($0) })
            for k in pickups where k.netID < 2000 && !keep.contains(k.netID) && !k.dead { k.dead = true; k.node.removeFromParentNode() }
            pickups.removeAll { $0.dead }
        }
        // projectiles
        var live = Set<Int>()
        for case let a as [Any] in m.arr("pr") where a.count >= 7 {
            let id = inum(a[0])
            live.insert(id)
            let pos = V3(num(a[3]), num(a[4]), num(a[5]))
            if let q = projectiles.first(where: { $0.netID == id }) { q.netTarget = pos; continue }
            let q = Projectile(Junk(rawValue: inum(a[1])) ?? .pea, at: pos, vel: .zero, poop: inum(a[2]) == 1)
            q.netID = id
            q.netTarget = pos
            if inum(a[6]) == 1 { q.node.simdScale = V3(repeating: 0.45) }
            addProjectile(q)
        }
        for q in projectiles where !live.contains(q.netID) { q.dead = true; q.node.removeFromParentNode() }
        projectiles.removeAll { $0.dead }
        // boss shockwaves
        let sw = m.arr("sw").compactMap { $0 as? [Any] }
        while shocks.count > sw.count { shocks.removeLast().node.removeFromParentNode() }
        for (k, a) in sw.enumerated() where a.count >= 5 {
            let c = V3(num(a[0]), num(a[1]), num(a[2]))
            if k >= shocks.count { let s = Shockwave(center: c); shocks.append(s); worldNode.addChildNode(s.node) }
            let s = shocks[k]
            s.center = c; s.node.simdPosition = c
            s.radius = num(a[3]); s.life = num(a[4]) / 100
            (s.node.geometry as? SCNTorus)?.ringRadius = CGFloat(s.radius)
            s.node.opacity = CGFloat(min(1, s.life * 3))
        }
    }

    func applyEvents(_ list: [Any]) {
        for case let e as [Any] in list {
            guard let t = e.first as? String else { continue }
            func I(_ i: Int) -> Int { i < e.count ? inum(e[i]) : 0 }
            func F(_ i: Int) -> Float { i < e.count ? num(e[i]) : 0 }
            func S(_ i: Int) -> String { i < e.count ? (e[i] as? String ?? "") : "" }
            switch t {
            case "s": audio.play(S(1), volume: F(2) / 100, rate: F(3) / 100)
            case "t":
                let saved = role; role = .offline
                popText(S(1), at: V3(F(2), F(3), F(4)), color: hex(UInt32(I(5))), size: CGFloat(I(6)))
                role = saved
            case "q": if let s = slot(I(1)) { say(s, [S(2)], priority: true, fromNet: true) }
            case "fx":
                let p = V3(F(2), F(3), F(4))
                switch I(1) {
                case 0: puff(at: p, n: I(5), net: false)
                case 1: confetti(at: p, n: I(5), net: false)
                case 2: splat(at: p, color: hex(UInt32(I(6))), net: false)
                default: sparkle(at: p, net: false)
                }
            case "k": shake = max(shake, F(1))
            case "b": hud.banner(S(1), S(2))
            case "o": hud.toast(S(1))
            case "kn":
                if let s = slot(I(1)) {
                    s.body.shove(V3(F(2), F(3), F(4)), spin: F(5) / 100, axis: V3(F(6), F(7), F(8)) / 100)
                    if I(9) == 1 { s.body.jolt() }
                    s.body.hurtFace = max(s.body.hurtFace, 0.3)
                }
            case "bo":
                if let s = slot(I(1)) { for i in 0..<Player.N { s.body.v[i].y = max(s.body.v[i].y, F(2)) }; s.body.jolt() }
            case "pl":
                if let s = slot(I(1)) {
                    let p = V3(F(2), F(3), F(4))
                    s.body.place(at: p)
                    s.body.invuln = 1.2
                    s.placeCount = I(5)
                    s.netTarget = p
                }
            case "cp":
                let k = I(1)
                if k < checkpointFlags.count && k > checkpointIdx { Scenery.raise(checkpointFlags[k], instant: false); checkpointIdx = k }
            case "gd": dropGoal()
            case "pg":
                if let k = pickups.first(where: { $0.netID == I(1) && !$0.dead }) {
                    k.dead = true
                    k.node.runAction(.sequence([.group([.scale(to: 1.8, duration: 0.15), .fadeOut(duration: 0.15)]), .removeFromParentNode()]))
                }
                pickups.removeAll { $0.dead }
            case "done":
                for case let a as [Any] in (e.count > 4 ? e[4] as? [Any] ?? [] : []) where a.count >= 6 {
                    guard let s = slot(inum(a[0])) else { continue }
                    s.collected = inum(a[1]); s.bonks = inum(a[2]); s.falls = inum(a[4]); s.flushOrder = inum(a[5])
                }
                state = .done
                doneTimer = 0
                audio.play("win")
                hud.showDone(level: level, got: I(1), slots: slots, time: F(2), last: I(3) == 1, waiting: true)
                for s in slots { s.body.place(at: V3(0, -5000, 0)) }
            case "win":
                state = .won
                doneTimer = 0
                audio.play("win")
                hud.showWin(score: I(1), players: slots.count)
            default: break
            }
        }
    }

    func updateGuest(_ dt: Float) {
        bounceSoundCooldown -= dt
        world.moveMovers(dt)
        var acts: [Actions] = []
        for s in slots {
            var a = Actions()
            if s.index == mySeat {
                if !menuOpen { a = demo ? demoActions(s) : Devices.actions(.keysA, input: input, pads: pads, solo: true) }
                s.jumpBuffer -= dt
                if a.jumpPressed { s.jumpBuffer = 0.13 }
                a.ctl.jump = s.jumpBuffer > 0
                if a.fire || (a.fireHeld && s.fireCooldown < -0.1) { if s.fireCooldown <= 0 { s.remote.fire += 1; s.fireCooldown = 0.22; s.body.mouthOpen = 1 } }
                s.fireCooldown -= dt
                if a.honk { s.remote.honk += 1 }
                if a.teleport && s.behind { s.remote.teleport += 1 }
                s.lastCtl = a.ctl
            } else {
                a.ctl.move = s.remote.move
                a.ctl.squish = s.remote.squish
                a.ctl.jump = s.remote.jump > s.remote.seenJump
                s.remote.seenJump = s.remote.jump
            }
            if s.body.ko > 0 || s.body.flushing >= 0 { a.ctl = Player.Controls() }
            acts.append(a)
        }
        if flushT < 0 {
            let h = dt / 4
            var events = [[Player.Event]](repeating: [], count: slots.count)
            for sub in 0..<4 {
                for (i, s) in slots.enumerated() where s.body.flushing < 0 {
                    var c = acts[i].ctl
                    if sub > 0 { c.jump = false }
                    s.body.step(h, c, world, events: &events[i])
                }
                if multi { for a in slots { for b in slots where a !== b { a.body.pushOut(of: b.body) } } }
            }
            for (i, s) in slots.enumerated() {
                if s.index == mySeat { for e in events[i] { if case .jump = e { s.jumpBuffer = 0 }; if case .superJump = e { s.jumpBuffer = 0 } } }
                handle(events[i], s)
            }
            // other players follow the host's view of them
            for s in slots where s.index != mySeat {
                guard let t = s.netTarget else { continue }
                let err = t + s.netVel * 0.09 - s.body.c
                s.body.translate(err.len > 350 ? err : err * min(1, dt * 9))
            }
        } else {
            updateFlush(dt)
        }
        if let me = slot(mySeat) { updateAim(me) }
        for s in slots {
            s.body.frame(dt, world: world, t: time)
            s.body.draw(world: world, t: time)
            updateBubble(s, dt)
        }
        // replay the world
        for p in pickups where !p.dead {
            if let t = p.netTarget { p.pos += (t - p.pos) * min(1, dt * 12) }
            p.update(dt, world: world)
        }
        for q in projectiles {
            if let t = q.netTarget {
                let d = t - q.pos
                q.pos += d * min(1, dt * 14)
                if d.len > 2 { q.angle += dt * 10 }
            }
            q.node.simdPosition = q.pos
            q.node.simdOrientation = simd_quatf(angle: q.angle, axis: q.spinAxis)
        }
        for e in enemies where !e.dead {
            if let (t, yaw, tumble, axis) = netEnemyTargets[e.netID] {
                e.pos += (t - e.pos) * min(1, dt * 12)
                e.yaw += wrapAngle(yaw - e.yaw) * min(1, dt * 12)
                e.tumble += (tumble - e.tumble) * min(1, dt * 12)
                if axis.len > 0.1 { e.tumbleAxis = V3(axis.x, 0, axis.z).norm }
            }
            e.squash = max(0, e.squash - dt * 4)
            e.hurtFlash -= dt
            if e.kind == .pigeon && e.wings.count == 2 {
                let flap = sinf(time * 22 + e.home.x) * 0.7
                e.wings[0].eulerAngles.x = CGFloat(-flap); e.wings[1].eulerAngles.x = CGFloat(flap)
            }
            e.node.simdPosition = e.pos
            var q = simd_quatf(angle: e.yaw, axis: V3(0, 1, 0))
            if abs(e.tumble) > 0.001 { q = simd_quatf(angle: e.tumble, axis: e.tumbleAxis) * q }
            e.bodyNode.simdOrientation = q
            if e.kind != .pigeon { e.bodyNode.simdScale = V3(1 + e.squash * 0.18, 1 - e.squash * 0.18, 1 + e.squash * 0.18) }
            e.bodyNode.opacity = e.hurtFlash > 0 ? 0.5 : 1
            e.showStars(e.stun > 0 && e.kind != .boss)
            e.updateEyes(dt)
        }
        enemies.removeAll { $0.dead && $0.node.parent == nil }
        updateParticles(dt)
        // crown on the host's leader
        for s in slots where s.body.grounded { s.lastSafe = s.body.c }
        if multi, let L = leader, flushT < 0 {
            crown.isHidden = false
            crown.simdPosition = V3(L.body.c.x, L.body.top + 14 + sinf(time * 4) * 3, L.body.c.z)
            crown.eulerAngles.y = CGFloat(time * 1.5)
        } else { crown.isHidden = true }
        if time - lastSnapAt > 6 { hud.toast("waiting for the host…") }
        if CommandLine.arguments.contains("--netlog") && Int(time * 60) % 60 == 0 {
            for s in slots where s.index != mySeat {
                let t = s.netTarget ?? V3(0, 0, 0)
                print(String(format: "t=%.0f seat %d body=(%.0f,%.0f,%.0f) target=(%.0f,%.0f,%.0f) grounded=%d ko=%.1f fl=%.1f", time, s.index, s.body.c.x, s.body.c.y, s.body.c.z, t.x, t.y, t.z, s.body.grounded ? 1 : 0, s.body.ko, s.body.flushing))
            }
        }
        // send input
        inputTimer += dt
        if inputTimer >= 1.0 / 30, let me = slot(mySeat), let n = net {
            inputTimer = 0
            let b = me.body
            var m: [String: Any] = ["t": "in", "mx": Int(me.lastCtl.move.x * 100), "mz": Int(me.lastCtl.move.y * 100), "sq": me.lastCtl.squish ? 1 : 0,
                                    "j": me.jumpCount, "f": me.remote.fire, "h": me.remote.honk, "tp": me.remote.teleport, "pl": me.placeCount,
                                    "p": [Int(b.c.x), Int(b.c.y), Int(b.c.z), Int(b.cVel.x), Int(b.cVel.y), Int(b.cVel.z)]]
            if let a = me.aimPoint, input.mouseMovedRecently > 0 || input.mouseHeld { m["aim"] = [Int(a.x), Int(a.y), Int(a.z)] }
            n.send(m)
        }
    }

    // MARK: automated tests (--online-host / --online-join)

    private func autoOnline(_ n: Net, open: Bool) {
        guard open else { return }
        if autoHost && titleMode == .online && lobbyCode.isEmpty && !autoSent { autoSent = true; n.send(["t": "create", "name": Net.playerName]) }
        if let f = autoJoinFile, titleMode == .online, lobbyCode.isEmpty, !autoSent, let code = try? String(contentsOfFile: f, encoding: .utf8), code.count == 4 {
            autoSent = true
            n.send(["t": "join", "code": code, "name": Net.playerName])
        }
    }

    private func autoStartReady() -> Bool { autoHost && slots.count >= autoPlayers }
}
