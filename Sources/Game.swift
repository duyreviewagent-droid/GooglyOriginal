import SceneKit
import SpriteKit
import GameController

struct SaveData: Codable {
    struct Run: Codable { var level: Int; var checkpoint: Int; var score: Int; var eyes: Int; var inventory: [Int] }
    var unlocked = 1
    var best: [Int] = [0, 0, 0]
    var wins = 0
    var run: Run?
    static var disabled = false
    static let key = "googly3d.save.v1"
    static func load() -> SaveData {
        guard !disabled, let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(SaveData.self, from: d) else { return SaveData() }
        return s
    }
    func store() {
        guard !SaveData.disabled, let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(d, forKey: SaveData.key)
    }
}

/// Runs on SceneKit's render thread (renderer(_:updateAtTime:)); input arrives through a lock.
final class Game: NSObject, SCNSceneRendererDelegate {
    enum State { case title, playing, paused, done, won }

    let view: GameView
    let scene = SCNScene()
    let overlay = SKScene(size: CGSize(width: 1440, height: 900))
    let audio: AudioSystem
    let camNode = SCNNode()
    let sun = SCNNode()
    let worldNode = SCNNode()
    let reticle: SCNNode
    let crown: SCNNode
    let hud: HUD
    var input: InputState { view.input }

    var state = State.title
    var levelIndex = 0
    var level: LevelData!
    var world = World()
    var slots: [Slot] = []
    /// The red guy shown on the title before anyone joins.
    let titleBody = Player()
    var player: Player { slots.first?.body ?? titleBody }
    var leader: Slot?
    var pickups: [Pickup] = []
    var projectiles: [Projectile] = []
    var enemies: [Enemy] = []
    var particles: [Particle] = []
    var shocks: [Shockwave] = []
    var popups: [(SKNode, V3, Float)] = []
    var score = 0
    var levelStartScore = 0
    var checkpointIdx = -1
    var checkpointFlags: [SCNNode] = []
    var goalNode = SCNNode()
    var goalVisible = true
    var flushT: Float = -1
    var camTarget = V3(0, 100, 0)
    var camDist: Float = 1
    var shake: Float = 0
    var time: Float = 0
    var lastT: TimeInterval = 0
    var saveTimer: Float = 0
    var boss: Enemy?
    var bossAwake = false
    var junkRain: Float = 0
    var doneTimer: Float = 0
    var save: SaveData
    var ignoreInput = false
    var demo = false
    var titleHop: Float = 1.5
    var titleCountdown: Float?
    var bounceSoundCooldown: Float = 0
    var levelTime: Float = 0
    var pads: [PadState] = []
    var pending: [() -> Void] = []
    let pendingLock = NSLock()
    private var enemyByNode: [ObjectIdentifier: Enemy] = [:]
    var viewSize = CGSize(width: 1440, height: 900)
    var multi: Bool { slots.count > 1 }

    // MARK: online state (see Online.swift)
    enum Role { case offline, host, guest }
    enum TitleMode { case main, online, code, lobby }
    var role = Role.offline
    var net: Net?
    var mySeat = 0
    var titleMode = TitleMode.main
    var codeEntry = ""
    var lobbyCode = ""
    var lobbyList: [[String: Any]] = []
    var lobbyLevel = 0
    var netError = ""
    var evOut: [[Any]] = []
    var nextNetID = 0
    var snapTimer: Float = 0, inputTimer: Float = 0, listTimer: Float = 0
    var snapCount = 0
    var menuOpen = false
    var netEnemyTargets: [Int: (V3, Float, Float, V3)] = [:]
    var guestState: [String: Any] = [:]
    var guestBossFrac: Float = -1
    var guestLeader = -1
    var guestFlushOrder: [Int: Int] = [:]
    var lastSnapAt: Float = 0
    var autoHost = false, autoSent = false, autoPlayers = 2
    var autoJoinFile: String?, autoCodeFile: String?

    init(view: GameView, muted: Bool) {
        self.view = view
        viewSize = view.bounds.size
        audio = AudioSystem(muted: muted)
        save = SaveData.load()
        hud = HUD()
        let rt = SCNTorus(ringRadius: 18, pipeRadius: 2.5)
        rt.firstMaterial = mat(hex(0xffe14d), rough: 0.4, emission: hex(0xffc000))
        reticle = SCNNode(geometry: rt)
        crown = Game.makeCrown()
        super.init()

        let cam = SCNCamera()
        cam.fieldOfView = 42
        cam.zNear = 5
        cam.zFar = 14000
        cam.wantsHDR = true
        cam.bloomIntensity = 0.35
        cam.bloomThreshold = 0.9
        cam.wantsExposureAdaptation = false
        cam.exposureOffset = -0.1
        cam.screenSpaceAmbientOcclusionIntensity = 0.7
        cam.screenSpaceAmbientOcclusionRadius = 30
        cam.vignettingIntensity = 0.5
        cam.vignettingPower = 0.6
        cam.saturation = 1.04
        cam.contrast = 0.08
        camNode.camera = cam
        scene.rootNode.addChildNode(camNode)

        let sl = SCNLight()
        sl.type = .directional
        sl.intensity = 1200
        sl.color = hex(0xfff0d8)
        sl.castsShadow = true
        sl.shadowMode = .forward
        sl.shadowMapSize = CGSize(width: 4096, height: 4096)
        sl.shadowSampleCount = 8
        sl.shadowRadius = 2.5
        sl.shadowColor = NSColor(white: 0, alpha: 0.5)
        sl.orthographicScale = 1700
        sl.zNear = 10
        sl.zFar = 6000
        sl.automaticallyAdjustsShadowProjection = false
        sun.light = sl
        sun.eulerAngles = SCNVector3(-1.0, -0.55, 0)
        scene.rootNode.addChildNode(sun)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light!.type = .ambient
        amb.light!.intensity = 260
        amb.light!.color = hex(0xcfe0ff)
        scene.rootNode.addChildNode(amb)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 280
        fill.light!.color = hex(0xffd8c0)
        fill.eulerAngles = SCNVector3(-0.3, 2.4, 0)
        scene.rootNode.addChildNode(fill)

        scene.rootNode.addChildNode(worldNode)
        reticle.opacity = 0
        scene.rootNode.addChildNode(reticle)
        crown.isHidden = true
        scene.rootNode.addChildNode(crown)

        overlay.scaleMode = .resizeFill
        overlay.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        overlay.backgroundColor = .clear
        overlay.addChild(hud.root)

        titleBody.setEyes(2)
        loadLevel(0)
        hud.showTitle(save: save)
        audio.music.style = 4
        view.scene = scene
        view.overlaySKScene = overlay
        view.delegate = self
        view.isPlaying = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 120
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        layout()
        view.onResize = { [weak self] s in self?.viewSize = s }
    }

    static func makeCrown() -> SCNNode {
        let gold = mat(hex(0xffc629), rough: 0.2, metal: 1)
        let c = SCNNode()
        c.add(SCNNode(geometry: { let t = SCNTube(innerRadius: 17, outerRadius: 20, height: 14); t.firstMaterial = gold; return t }()))
        for k in 0..<5 {
            let a = Float(k) / 5 * 2 * .pi
            c.add(cone(6, 0, 16, gold)).at(cosf(a) * 18.5, 14, sinf(a) * 18.5)
            c.add(sphere(3, mat(hex(0xe0115f), rough: 0.1), seg: 8)).at(cosf(a + 0.6) * 20, 0, sinf(a + 0.6) * 20)
        }
        c.castsShadow = false
        return c
    }

    func later(_ f: @escaping () -> Void) { pendingLock.lock(); pending.append(f); pendingLock.unlock() }

    // MARK: Players

    func slot(_ seat: Int) -> Slot? { slots.first { $0.index == seat } }

    @discardableResult func join(_ scheme: Scheme, seat: Int? = nil, name: String? = nil) -> Slot? {
        guard slots.count < 4, !slots.contains(where: { $0.scheme == scheme }) else { return nil }
        let idx = seat ?? (0..<4).first { i in !slots.contains { $0.index == i } } ?? slots.count
        guard slot(idx) == nil else { return nil }
        let s = Slot(index: idx, scheme: scheme)
        s.netName = name
        s.body.setEyes(2)
        slots.append(s)
        slots.sort { $0.index < $1.index }
        hud.world.addChild(s.tag)
        titleBody.root.removeFromParentNode()
        worldNode.addChildNode(s.body.root)
        setMask(s.body.root, 2)
        let at: V3
        if state == .playing, let L = leader ?? slots.first(where: { $0 !== s }) {
            at = L.body.c + V3(-70, 110, Float(s.index % 2 == 0 ? -60 : 60))
        } else {
            at = spawnPoint(s.index)
        }
        s.body.place(at: at)
        s.lastSafe = at
        s.body.invuln = 1.2
        if role == .host && state == .playing { placeSlot(s, at) }
        sfx("checkpoint", volume: 0.6, rate: 1 + Float(s.index) * 0.12)
        if state == .playing { puff(at: at, n: 10); popText("\(s.name) JOINED!", at: at + V3(0, 90, 0), color: s.color, size: 26) }
        return s
    }

    private func spawnPoint(_ i: Int) -> V3 {
        let base = checkpointIdx >= 0 ? level.checkpoints[checkpointIdx] + V3(0, 90, 120) : level.start
        return base + V3(Float(i % 2) * 90 - 45, 0, Float(i / 2) * 110 - 55 + Float(i % 2) * 30)
    }

    private func readPads() {
        let list = Devices.pads()
        var next: [PadState] = []
        for (i, c) in list.enumerated() { next.append(PadState.read(c, previous: i < pads.count ? pads[i] : nil)) }
        pads = next
    }

    private func freeSchemes() -> [Scheme] {
        if role != .offline { return [] }
        let all: [Scheme] = [.keysA, .keysB] + (0..<pads.count).map { Scheme.pad($0) }
        return all.filter { sc in !slots.contains { $0.scheme == sc } }
    }

    // MARK: Level setup

    func loadLevel(_ i: Int, checkpoint: Int = -1) {
        levelIndex = i
        level = LevelData.make(i)
        world = World()
        world.solids = level.solids
        world.fans = level.fans
        world.minX = level.minX
        world.maxX = level.maxX
        worldNode.childNodes.forEach { $0.removeFromParentNode() }
        pickups.removeAll(); projectiles.removeAll(); enemies.removeAll(); particles.removeAll(); shocks.removeAll()
        for p in popups { p.0.removeFromParent() }
        popups.removeAll()
        for s in slots { s.bubble?.removeFromParent(); s.bubble = nil; s.flushOrder = -1 }
        boss = nil; bossAwake = false
        flushT = -1
        hud.bossBar(nil)
        enemyByNode.removeAll()
        checkpointFlags.removeAll()
        Scenery.build(level: level, into: worldNode, scene: scene)
        netEnemyTargets.removeAll()
        nextNetID = 0
        for (w, p) in level.pickups { addPickup(Pickup(w, at: p)) }
        nextNetID = 2000
        for (k, p) in level.enemies { addEnemy(Enemy(k, at: p)) }
        nextNetID = 5000
        for cp in level.checkpoints {
            let f = Scenery.flag(at: cp)
            worldNode.addChildNode(f)
            checkpointFlags.append(f)
        }
        goalNode = Scenery.toilet()
        goalNode.simdPosition = level.goal
        goalVisible = !level.goalHidden
        goalNode.isHidden = !goalVisible
        worldNode.addChildNode(goalNode)
        checkpointIdx = checkpoint
        for (k, f) in checkpointFlags.enumerated() where k <= checkpoint { Scenery.raise(f, instant: true) }
        if slots.isEmpty {
            worldNode.addChildNode(titleBody.root)
            setMask(titleBody.root, 2)
            titleBody.place(at: level.start)
        }
        for s in slots {
            worldNode.addChildNode(s.body.root)
            setMask(s.body.root, 2)
            s.body.place(at: spawnPoint(s.index))
            s.lastSafe = s.body.c
        }
        camTarget = player.c
        levelTime = 0
        audio.music.style = level.theme.music
    }

    func setMask(_ n: SCNNode, _ m: Int) {
        n.categoryBitMask = m
        for c in n.childNodes { setMask(c, m) }
    }

    func addEnemy(_ e: Enemy) {
        if e.netID < 0 { e.netID = nextNetID; nextNetID += 1 }
        enemies.append(e)
        worldNode.addChildNode(e.node)
        setMask(e.node, 4)
        enemyByNode[ObjectIdentifier(e.node)] = e
        if e.kind == .boss { boss = e }
    }

    func startLevel(_ i: Int, fresh: Bool) {
        if slots.isEmpty { join(.keysA) }
        if fresh {
            score = 0
            for s in slots { s.inventory = []; s.body.setEyes(2) }
        }
        levelStartScore = score
        for s in slots { s.bonks = 0; s.collected = 0; s.falls = 0; s.teleports = 0; if s.body.eyes.count < 2 { s.body.setEyes(2) } }
        state = .playing
        loadLevel(i)
        if role == .host { net?.send(["t": "start", "level": i]); evOut.removeAll() }
        titleCountdown = nil
        hud.hideTitle()
        hud.hidePanel()
        banner(level.subtitle.uppercased() + (multi ? " · \(slots.count) PLAYERS" : ""), level.name)
        sfx("checkpoint", volume: 0.5)
        storeRun()
    }

    func continueRun() {
        guard let r = save.run else { startLevel(0, fresh: true); return }
        if slots.isEmpty { join(.keysA) }
        score = r.score
        levelStartScore = r.score
        slots[0].inventory = r.inventory.compactMap { Junk(rawValue: $0) }
        slots[0].body.setEyes(max(0, min(Player.maxEyes, r.eyes)))
        for s in slots.dropFirst() { s.body.setEyes(2) }
        state = .playing
        loadLevel(r.level, checkpoint: min(r.checkpoint, LevelData.make(r.level).checkpoints.count - 1))
        titleCountdown = nil
        hud.hideTitle()
        banner(level.subtitle.uppercased(), level.name)
    }

    func storeRun() {
        guard let p1 = slots.first else { return }
        save.run = SaveData.Run(level: levelIndex, checkpoint: checkpointIdx, score: score, eyes: p1.body.eyes.count, inventory: p1.inventory.map { $0.rawValue })
        save.store()
        if !SaveData.disabled { hud.flashSaved() }
    }

    func addProjectile(_ p: Projectile) {
        if p.netID < 0 { p.netID = nextNetID; nextNetID += 1 }
        projectiles.append(p)
        worldNode.addChildNode(p.node)
    }

    func addPickup(_ p: Pickup) {
        if p.netID < 0 { p.netID = nextNetID; nextNetID += 1 }
        pickups.append(p)
        worldNode.addChildNode(p.node)
    }

    func layout() {
        overlay.size = viewSize
        hud.layout(viewSize)
    }

    // MARK: Loop

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime t: TimeInterval) { tick(t) }

    func tick(_ t: TimeInterval) {
        pendingLock.lock(); let todo = pending; pending.removeAll(); pendingLock.unlock()
        for f in todo { f() }
        var dt = Float(lastT == 0 ? 1.0 / 60 : t - lastT)
        lastT = t
        dt = max(0.001, min(dt, 1.0 / 30))
        time += dt
        if ignoreInput { input.clear() }
        input.beginFrame()
        if !ignoreInput { readPads() }
        pumpNet()
        audio.music.duck = slots.allSatisfy({ $0.body.ko > 0 }) && !slots.isEmpty ? 0.35 : 1
        if overlay.size != viewSize { layout() }

        if input.wasPressed(Key.m) { audio.toggleMute(); toast(audio.muted ? "MUTED" : "SOUND ON") }
        if input.scroll != 0 { camDist = clampf(camDist * (1 - input.scroll * 0.08), 0.6, 1.8) }
        let anyPause = input.wasPressed(Key.esc) || pads.contains { $0.pressed(.menu) }
        let anyConfirm = input.wasPressed(Key.ret, Key.enter, Key.space) || pads.contains { $0.pressed(.a) || $0.pressed(.menu) }

        switch state {
        case .title: updateTitle(dt)
        case .playing: updatePlaying(dt, pause: anyPause)
        case .paused:
            if anyPause { state = .playing; hud.hidePanel() }
            else if input.wasPressed(Key.r) { hud.hidePanel(); restartLevel() }
            else if input.wasPressed(Key.q) { storeRun(); toTitle() }
        case .done:
            doneTimer += dt
            simulateScenery(dt)
            if role == .guest { break }
            if doneTimer > 0.8 && (anyConfirm || (demo && doneTimer > 2)) {
                hud.hidePanel()
                if levelIndex + 1 < LevelData.names.count { startLevel(levelIndex + 1, fresh: false) } else { win() }
            }
        case .won:
            doneTimer += dt
            simulateScenery(dt)
            if Float.random(in: 0...1) < 0.1 { confetti(at: camTarget + V3(frand(-500, 500), 400, frand(-200, 200)), n: 4) }
            if doneTimer > 1.5 && (anyConfirm || anyPause) { toTitle() }
        }
        updateCamera(dt)
        updatePopups(dt)
        updateTags()
        hud.update(self, dt: dt)
        input.endFrame()
    }

    func toTitle() {
        if net != nil && state != .title { net?.close(); net = nil; role = .offline }
        titleMode = .main
        menuOpen = false
        state = .title
        hud.hidePanel()
        for s in slots { s.tag.removeFromParent(); s.body.root.removeFromParentNode() }
        slots.removeAll()
        leader = nil
        loadLevel(0)
        audio.music.style = 4
        hud.showTitle(save: save)
    }

    func restartLevel() {
        if role == .guest { return }
        if role == .host { net?.send(["t": "start", "level": levelIndex]); evOut.removeAll() }
        score = levelStartScore
        for s in slots { s.bonks = 0; s.collected = 0; s.falls = 0; if s.body.eyes.count < 2 { s.body.setEyes(2) } }
        state = .playing
        loadLevel(levelIndex)
        banner(level.subtitle.uppercased(), level.name)
    }

    func win() {
        state = .won
        doneTimer = 0
        save.wins += 1
        save.run = nil
        save.store()
        sfx("win")
        audio.music.style = 4
        hud.showWin(score: score, players: slots.count)
        emit(["win", score])
        hostFlush()
    }

    private func updateTitle(_ dt: Float) {
        titleHop -= dt
        hud.setOnlineMode(titleMode != .main)
        if titleMode != .main { animateTitleBodies(dt); updateOnlineTitle(dt); return }
        if input.wasPressed(Key.o) { openOnline(); return }
        // joining
        for sc in freeSchemes() where Devices.joinPressed(sc, input: input, pads: pads) {
            if let s = join(sc) { s.body.shove(V3(0, 700, 0)); titleCountdown = slots.count >= 4 ? 1.5 : slots.count == 1 ? 3 : 4 }
        }
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
        if let c = titleCountdown {
            titleCountdown = c - dt
            if c - dt <= 0 { startLevel(0, fresh: true); return }
        }
        hud.titleJoin(self, countdownLeft: titleCountdown)
        if input.wasPressed(Key.ret, Key.enter) || pads.contains(where: { $0.pressed(.menu) }) { audio.play("click"); startLevel(0, fresh: true) }
        else if input.wasPressed(Key.c), save.run != nil { audio.play("click"); continueRun() }
        else if input.wasPressed(Key.one) { startLevel(0, fresh: true) }
        else if input.wasPressed(Key.two), save.unlocked >= 2 { startLevel(1, fresh: true) }
        else if input.wasPressed(Key.three), save.unlocked >= 3 { startLevel(2, fresh: true) }
    }

    func simulateScenery(_ dt: Float) {
        world.moveMovers(dt)
        for p in pickups { p.update(dt, world: world) }
        for e in enemies { e.updateEyes(dt) }
        updateParticles(dt)
    }

    // MARK: Playing

    func stepBody(_ b: Player, _ dt: Float, _ ctl: Player.Controls) {
        var c = ctl
        let h = dt / 4
        var ev: [Player.Event] = []
        for s in 0..<4 { if s > 0 { c.jump = false }; b.step(h, c, world, events: &ev) }
    }

    private func updatePlaying(_ dt: Float, pause: Bool) {
        levelTime += dt
        if role != .offline {
            // online games never pause: Esc opens a menu while the world keeps going
            if pause { menuOpen.toggle(); if menuOpen { hud.showOnlineMenu(host: role == .host) } else { hud.hidePanel() } }
            if menuOpen && input.wasPressed(Key.q) { leaveOnline("You left the lobby"); return }
            if role == .guest { updateGuest(dt); return }
        } else if pause { state = .paused; hud.showPause(); return }
        bounceSoundCooldown -= dt
        world.moveMovers(dt)

        // drop-in
        for sc in freeSchemes() where Devices.joinPressed(sc, input: input, pads: pads) { join(sc) }

        let solo = !multi
        var acts: [Actions] = []
        for s in slots {
            s.jumpBuffer -= dt; s.fireCooldown -= dt; s.honkCooldown -= dt; s.quipCooldown -= dt
            var a = s.scheme.isRemote ? remoteActions(s) : demo ? demoActions(s) : Devices.actions(s.scheme, input: input, pads: pads, solo: solo)
            if menuOpen && !s.scheme.isRemote { a = Actions() }
            if a.jumpPressed { s.jumpBuffer = 0.13 }
            a.ctl.jump = s.jumpBuffer > 0
            if s.body.ko > 0 || s.body.flushing >= 0 { a.ctl = Player.Controls() }
            s.lastCtl = a.ctl
            if multi && s.body.eyes.count == 0 && s.body.ko <= 0 {
                // can't see: stagger about
                s.blindDrift += V2(frand(-1, 1), frand(-1, 1)) * dt * 6
                s.blindDrift *= 0.98
                if s.blindDrift.len > 0.8 { s.blindDrift = s.blindDrift.norm * 0.8 }
                a.ctl.move += s.blindDrift
            }
            acts.append(a)
        }
        // physics: every body steps together so they can bump into each other
        if flushT < 0 {
            let h = dt / 4
            var events = [[Player.Event]](repeating: [], count: slots.count)
            for sub in 0..<4 {
                for (i, s) in slots.enumerated() where s.body.flushing < 0 {
                    var c = acts[i].ctl
                    if sub > 0 { c.jump = false }
                    s.body.step(h, c, world, events: &events[i])
                }
                if multi {
                    for a in slots { for b in slots where a !== b { a.body.pushOut(of: b.body) } }
                }
            }
            for (i, s) in slots.enumerated() {
                for e in events[i] { if case .jump = e { s.jumpBuffer = 0 }; if case .superJump = e { s.jumpBuffer = 0 } }
                handle(events[i], s)
            }
            if role == .host { for s in slots where s.scheme.isRemote { applyRemoteAuthority(s, dt) } }
        } else {
            updateFlush(dt)
        }
        updateLeader()
        for (i, s) in slots.enumerated() where flushT < 0 {
            let a = acts[i]
            let moved = a.ctl.move.len > 0 || a.jumpPressed || a.ctl.squish
            if moved { s.idleTime = 0 } else { s.idleTime += dt }
            if s.idleTime > 9 { s.idleTime = 0; say(s, ["hello?", "I'm just a guy.", "is anyone controlling me?", "*wobble*", "I could stand here all day.", "blink. blink."]) }
            if s.body.ko > 0 {
                s.body.ko -= dt
                if s.body.ko <= 0 { respawn(s, ko: true) }
                continue
            }
            if s.scheme == .keysA { updateAim(s) } else if s.scheme.isRemote { s.aimPoint = s.remote.aim }
            let fire = a.fire || (a.fireHeld && s.fireCooldown < -0.1)
            if fire && s.fireCooldown <= 0 { shoot(s, mouse: a.mouseAim) }
            if a.honk && s.honkCooldown <= 0 { honk(s) }
            if a.teleport && s.behind { teleport(s) }
        }
        for s in slots {
            s.body.frame(dt, world: world, t: time)
            s.body.draw(world: world, t: time)
        }

        updatePickups(dt)
        updateProjectiles(dt)
        updateEnemies(dt)
        updateShocks(dt)
        updateParticles(dt)
        for s in slots { updateBubble(s, dt) }
        checkCheckpoints()
        updateBoss(dt)

        if goalVisible && flushT < 0 {
            for s in slots where s.body.ko <= 0 && (s.body.c - (level.goal + V3(0, 60, 0))).len < 85 {
                startFlush(first: s)
                break
            }
        }
        for s in slots where s.body.c.y < world.killY && s.body.flushing < 0 {
            s.falls += 1
            sfx("whoops")
            say(s, ["WHOOOOPS", "brb", "that was on purpose"], priority: true)
            if s.body.eyes.count > 0 { s.body.removeEye(); respawn(s, ko: false) } else { respawn(s, ko: true) }
        }
        saveTimer += dt
        if saveTimer > 30 { saveTimer = 0; storeRun() }
        if role == .host { hostNetTick(dt) }
    }

    // MARK: Leader & teleport

    func updateLeader() {
        for s in slots where s.body.grounded && s.body.ko <= 0 && s.body.flushing < 0 {
            if let g = world.groundBelow(s.body.c.x, s.body.c.z, s.body.c.y), s.body.bottom - g < 20 { s.lastSafe = s.body.c }
        }
        let alive = slots.filter { $0.body.ko <= 0 && $0.body.c.y > world.killY + 100 }
        let best = alive.max { $0.body.c.x < $1.body.c.x }
        if let b = best, let l = leader, l !== b, alive.contains(where: { $0 === l }), b.body.c.x < l.body.c.x + 60 {
            // hysteresis: keep the crown unless clearly overtaken
        } else if let b = best {
            if leader !== b && multi && leader != nil { popText("\(b.name) TAKES THE LEAD!", at: b.body.c + V3(0, 120, 0), color: b.color, size: 22) }
            leader = b
        }
        for s in slots {
            guard multi, let L = leader, L !== s, s.body.ko <= 0, flushT < 0 else { s.behind = false; continue }
            let gap = L.body.c.x - s.body.c.x
            s.behind = gap > 700 || simd_length(L.body.c - s.body.c) > 1200 || (s.body.c.y < L.body.c.y - 500 && gap > 200)
        }
        if multi, let L = leader, flushT < 0 {
            crown.isHidden = false
            crown.simdPosition = V3(L.body.c.x, L.body.top + 14 + sinf(time * 4) * 3, L.body.c.z)
            crown.eulerAngles.y = CGFloat(time * 1.5)
        } else { crown.isHidden = true }
    }

    func teleport(_ s: Slot) {
        guard let L = leader, L !== s else { return }
        let from = s.body.c
        let dest = safeSpot(near: L, for: s)
        puff(at: from, n: 12)
        placeSlot(s, dest)
        s.body.invuln = 1.2
        s.teleports += 1
        s.behind = false
        puff(at: dest, n: 12)
        sparkle(at: dest)
        sfx("superboing", volume: 0.6, rate: 1.3)
        sfx("whoosh", volume: 0.5)
        popText("ZOOP!", at: dest + V3(0, 80, 0), color: s.color, size: 34)
        say(s, ["wait for me!", "ZOOP", "teleportation is easy", "catching up!"], priority: true)
    }

    /// Next to where the leader last stood on solid ground, dropping in from a little above.
    private func safeSpot(near L: Slot, for s: Slot) -> V3 {
        let base = L.lastSafe
        for dz: Float in [s.index % 2 == 0 ? -80 : 80, 0, s.index % 2 == 0 ? 80 : -80] {
            let p = base + V3(-70, 0, dz)
            if let g = world.groundBelow(p.x, p.z, p.y + 60), g > base.y - 120, !world.solidAt(p + V3(0, 90, 0)) { return V3(p.x, g + 150, p.z) }
        }
        return base + V3(0, 160, 0)
    }

    private func respawn(_ s: Slot, ko: Bool) {
        var p = spawnPoint(s.index)
        if multi, let L = leader, L !== s, L.body.ko <= 0, L.lastSafe.x > p.x { p = safeSpot(near: L, for: s) }
        if world.solidAt(p) { p += V3(0, 150, 0) }
        if ko {
            s.body.setEyes(2)
            score = max(0, score - 200)
            toast("\(s.name) BONKED OUT · -200")
        }
        setMask(s.body.root, 2)
        placeSlot(s, p)
        s.body.invuln = 1.5
        if s.body.eyes.count == 0 { say(s, ["still can't see...", "where am I?"], priority: true) }
    }

    // MARK: Flush

    private func startFlush(first: Slot) {
        flushT = 0
        sfx("flush")
        first.flushOrder = 0
        say(first, ["finally, a bath!", "wheeeee—", "see you on the other side!"], priority: true)
        let rest = slots.filter { $0 !== first }.sorted { (($0.body.c - level.goal).len) < (($1.body.c - level.goal).len) }
        for (k, s) in rest.enumerated() { s.flushOrder = k + 1 }
        for s in slots { s.body.flushing = 0 }
        if multi { popText("\(first.name) FLUSHED FIRST!", at: level.goal + V3(0, 220, 0), color: first.color, size: 34) }
        crown.isHidden = true
    }

    func updateFlush(_ dt: Float) {
        flushT += dt
        for s in slots {
            let delay = Float(s.flushOrder) * 0.35
            let k = clampf((flushT - delay) / 1.8, 0, 1)
            if k <= 0 {
                // being sucked towards the bowl
                let pull = (level.goal + V3(0, 80, 0) - s.body.c) * min(1, dt * 3)
                s.body.flushPose(center: s.body.c + pull, scale: 1, angle: flushT * 3)
                continue
            }
            let center = level.goal + V3(0, 62 - k * 30, 0)
            s.body.flushPose(center: center, scale: max(0.04, 1 - k * 0.96), angle: k * k * 16 + Float(s.index))
            if Int(flushT * 20) % 3 == 0 {
                let b = sphere(CGFloat(frand(3, 7)), mat(hex(0x8fd4ff), rough: 0.1), seg: 8)
                worldNode.addChildNode(b)
                particles.append(Particle(b, pos: center + V3(frand(-30, 30), 0, frand(-30, 30)), vel: V3(frand(-150, 150), frand(100, 350), frand(-150, 150)), life: 0.7))
            }
        }
        let total = 2.2 + Float(max(0, slots.count - 1)) * 0.35
        if flushT > total && state == .playing && role != .guest { levelComplete() }
    }

    func levelComplete() {
        state = .done
        doneTimer = 0
        let eyes = slots.reduce(0) { $0 + $1.body.eyes.count }
        let bonus = 1000 + eyes * 200
        score += bonus
        let got = score - levelStartScore
        if levelIndex < save.best.count { save.best[levelIndex] = max(save.best[levelIndex], got) }
        save.unlocked = max(save.unlocked, min(LevelData.names.count, levelIndex + 2))
        if levelIndex + 1 < LevelData.names.count, let p1 = slots.first {
            save.run = SaveData.Run(level: levelIndex + 1, checkpoint: -1, score: score, eyes: max(2, p1.body.eyes.count), inventory: p1.inventory.map { $0.rawValue })
        }
        save.store()
        sfx("win")
        hud.showDone(level: level, got: got, slots: slots, time: levelTime, last: levelIndex + 1 >= LevelData.names.count)
        emit(["done", got, Int(levelTime), levelIndex + 1 >= LevelData.names.count ? 1 : 0,
              slots.map { [$0.index, $0.collected, $0.bonks, $0.body.eyes.count, $0.falls, $0.flushOrder] }])
        hostFlush()
        for s in slots { s.body.place(at: V3(0, -5000, 0)) }
    }

    // MARK: Events

    func handle(_ events: [Player.Event], _ s: Slot) {
        let b = s.body
        let feet = V3(b.c.x, b.bottom, b.c.z)
        for e in events {
            switch e {
            case .jump:
                s.jumpCount += 1
                audio.play("boing", volume: 0.55, rate: frand(0.95, 1.12) * (0.9 + s.voicePitch * 0.1))
                if Float.random(in: 0...1) < 0.07 { say(s, ["wheee!", "hup!", "boing!", "yippee"]) }
            case .superJump(let k):
                audio.play("superboing", volume: 0.5 + 0.4 * k)
                puff(at: feet, n: 8, net: false)
                if k > 0.8 && Float.random(in: 0...1) < 0.4 { say(s, ["TO THE MOON", "BOIIIING", "I believe I can fly"]) }
            case .land(let impact):
                audio.play("land", volume: min(1, 0.25 + impact / 1500))
                puff(at: feet, n: Int(min(10, impact / 150)), net: false)
                b.jolt()
                if impact > 1500 && Float.random(in: 0...1) < 0.5 { say(s, ["my spine!", "(I have no spine)", "ow, my everything", "nailed it"]) }
            case .pound:
                audio.play("pound", volume: 0.6)
            case .poundLand:
                audio.play("stomp", volume: 0.55, rate: 1.4)
                shake = max(shake, 10)
                puff(at: feet, n: 14, net: false)
                b.jolt()
                guard role != .guest else { continue }
                for en in enemies where !en.dead && en.kind != .pigeon {
                    let d = en.pos - feet
                    if d.xz.len < 200 && abs(d.y) < 120 { damage(en, 2, dir: (d.flat.norm + V3(0, 0.8, 0)).norm, text: "SLAM!", by: s) }
                }
                for o in slots where o !== s {
                    let d = o.body.c - feet
                    if d.xz.len < 170 && abs(d.y) < 100 { knock(o, d.flat.norm * 300 + V3(0, 650, 0)); say(o, ["HEY!", "rude!", "whoa!"]) }
                }
            case .trampoline:
                audio.play("tramp", volume: 0.7)
                b.jolt()
                if Float.random(in: 0...1) < 0.25 { say(s, ["weeeeee!", "trampoline!!", "I am a bird now"]) }
            case .step:
                audio.play("step", volume: 0.18)
            }
        }
        if b.inFan && Float.random(in: 0...1) < 0.004 { say(s, ["wheeeeeeeee", "fan-tastic"]) }
    }

    // MARK: Aiming and shooting

    private func mouth(_ b: Player) -> V3 { b.c + b.G * V3(0, -4, 30) }

    /// Where the mouse points in the world: an enemy, a surface, or the plane at the player's height.
    func updateAim(_ s: Slot) {
        guard input.mouseMovedRecently > 0 || input.mouseHeld else { reticle.opacity = 0; s.aimPoint = nil; return }
        let m = input.mouseView
        var target: V3? = nil
        let hits = view.hitTest(m, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .categoryBitMask: 1 | 4, .ignoreHiddenNodes: true])
        for h in hits {
            var n: SCNNode? = h.node
            while let x = n, enemyByNode[ObjectIdentifier(x)] == nil { n = x.parent }
            if let x = n, let e = enemyByNode[ObjectIdentifier(x)], !e.dead { target = e.pos; break }
            let w = V3(Float(h.worldCoordinates.x), Float(h.worldCoordinates.y), Float(h.worldCoordinates.z))
            if abs(w.z) < 1200 { target = w; break }
        }
        if target == nil {
            let a = view.unprojectPoint(SCNVector3(m.x, m.y, 0)), b = view.unprojectPoint(SCNVector3(m.x, m.y, 1))
            let A = V3(Float(a.x), Float(a.y), Float(a.z)), B = V3(Float(b.x), Float(b.y), Float(b.z))
            let dir = B - A
            if abs(dir.y) > 1e-4 {
                let tt = (s.body.c.y - A.y) / dir.y
                if tt > 0 { target = A + dir * tt }
            }
        }
        s.aimPoint = target
        if let t = target {
            reticle.simdPosition = t + V3(0, 3, 0)
            reticle.opacity = 0.9
            reticle.simdScale = V3(repeating: 1 + 0.1 * sinf(time * 10))
        } else { reticle.opacity = 0 }
    }

    /// Controllers and the second keyboard aim themselves: the nearest enemy roughly in front, else straight ahead.
    private func autoAim(_ s: Slot) -> V3? {
        let b = s.body
        let fwd = b.moveDir
        var best: (Float, V3)? = nil
        for e in enemies where !e.dead {
            let d = e.pos - b.c
            let l = d.len
            guard l < 800, l > 1 else { continue }
            let facing = dot3(d.flat.norm, fwd)
            guard facing > 0.2 else { continue }
            let score = l * (1.6 - facing)
            if best == nil || score < best!.0 { best = (score, e.pos) }
        }
        return best?.1
    }

    private func shoot(_ s: Slot, mouse: Bool) {
        let b = s.body
        let j = s.inventory.popLast() ?? .pea
        let from = mouth(b)
        var target: V3? = nil
        if demo { target = demoTarget(s) }
        else if mouse, let t = s.aimPoint { target = t }
        else if s.scheme != .keysA || !mouse { target = autoAim(s) }
        var vel: V3
        if let t = target {
            let d = t - from
            let flightT = max(0.12, d.len / j.speed)
            vel = d / flightT + V3(0, 0.5 * 1900 * j.gravityScale * flightT, 0)
        } else {
            vel = (b.moveDir + V3(0, 0.18, 0)).norm * j.speed
        }
        let dir = vel.norm
        let p = Projectile(j, at: from + dir * 20, vel: vel + b.cVel * 0.3)
        p.owner = s.index
        addProjectile(p)
        worldNode.addChildNode(p.node)
        knock(s, -dir * j.recoil * (b.grounded ? 0.5 : 1), jolt: false)
        b.mouthOpen = 1
        b.aimTimer = 0.35
        b.aimDir = dir
        s.fireCooldown = j == .pea ? 0.14 : 0.22
        sfx(j == .pea ? "pea" : "ptoo", volume: j == .bowling ? 0.9 : 0.6, rate: j == .bowling ? 0.75 : frand(0.95, 1.1))
        if j == .chicken { sfx("squawk", volume: 0.5) }
        if j == .pea && Float.random(in: 0...1) < 0.18 { say(s, ["pew.", "this is embarrassing", "I'm out of stuff!", "a pea. truly terrifying."]) }
        if j == .bowling { addShake(6); say(s, ["STRIIIKE", "heavy!"]) }
        s.idleTime = 0
    }

    private func honk(_ s: Slot) {
        let b = s.body
        s.honkCooldown = 1.4
        sfx("honk", volume: 0.8, rate: frand(0.96, 1.04) * (0.85 + s.voicePitch * 0.15))
        b.mouthOpen = 1
        knock(s, V3(0, 160, 0))
        popText("HONK!", at: b.c + V3(0, 90, 0), color: hex(0xffe14d), size: 34)
        for e in enemies where !e.dead {
            let d = e.pos - b.c
            if d.len < 320 {
                e.vel += d.flat.norm * 380 + V3(0, 300, 0)
                e.stun = max(e.stun, e.kind == .boss ? 0.3 : 1.2)
                for i in e.eyes.indices { e.eyes[i].jolt(V2(frand(-900, 900), 900)) }
            }
        }
        for o in slots where o !== s && (o.body.c - b.c).len < 260 { knock(o, V3(0, 220, 0)) }
    }

    // MARK: Pickups

    func updatePickups(_ dt: Float) {
        for p in pickups where !p.dead {
            p.update(dt, world: world)
            guard p.delay <= 0 else { continue }
            guard let s = slots.filter({ $0.body.ko <= 0 && $0.body.flushing < 0 && ($0.body.c - p.pos).len < 60 + p.r })
                    .min(by: { ($0.body.c - p.pos).len < ($1.body.c - p.pos).len }) else { continue }
            switch p.what {
            case .junk(let j):
                if s.inventory.count >= 30 { continue }
                s.inventory.append(j)
                s.collected += 1
                score += 10
                sfx(j == .duck ? "squeak" : j == .chicken ? "squawk" : "collect", volume: 0.5, rate: frand(0.95, 1.15))
                if j == .duck || j == .chicken { sfx("collect", volume: 0.3) }
                if Float.random(in: 0...1) < 0.1 {
                    let lines: [String]
                    switch j {
                    case .duck: lines = ["a duck!", "quack?", "mine now"]
                    case .toast: lines = ["toast!", "bread, but hot"]
                    case .fish: lines = ["a fish? on land?", "smells fishy"]
                    case .banana: lines = ["banana! (it comes back)", "potassium!"]
                    case .sock: lines = ["ew. a sock.", "it's still warm..."]
                    case .cheese: lines = ["the big cheese", "cheeeese"]
                    case .melon: lines = ["one (1) melon", "melon time"]
                    case .bowling: lines = ["this is heavy", "a bowling ball??"]
                    case .chicken: lines = ["a chicken!!", "BAWK"]
                    case .pea: lines = ["pea"]
                    }
                    say(s, lines)
                }
                popText("+\(j.emoji)", at: p.pos + V3(0, 30, 0), color: .white, size: 22)
            case .eye:
                if s.body.eyes.count >= Player.maxEyes { continue }
                s.body.addEye()
                setMask(s.body.root, 2)
                score += 50
                sfx("eye", volume: 0.7)
                say(s, s.body.eyes.count == 1 ? ["I CAN SEE!", "light! glorious light!"] :
                    s.body.eyes.count >= 5 ? ["SO MANY EYES", "I see everything", "eye eye eye!", "\(s.body.eyes.count) eyes. no regrets."] :
                    ["MORE EYES!", "I can see... more!", "eye spy!"], priority: true)
                sparkle(at: p.pos)
            }
            p.dead = true
            p.node.runAction(.sequence([.group([.scale(to: 1.8, duration: 0.15), .fadeOut(duration: 0.15)]), .removeFromParentNode()]))
        }
        pickups.removeAll { p in
            if p.dead {
                emit(["pg", p.netID])
                if !p.node.hasActions { p.node.removeFromParentNode() }
            }
            return p.dead
        }
    }

    // MARK: Projectiles

    private func updateProjectiles(_ dt: Float) {
        for p in projectiles where !p.dead {
            p.age += dt
            let owner = slot(p.owner)
            if p.junk == .banana && !p.hostile && !p.isPoop && p.r > 10, let o = owner {
                if p.age > 0.5 { p.returning = true }
                if p.returning {
                    let d = o.body.c - p.pos
                    p.vel += d.norm * 2600 * dt
                    let s = p.vel.len
                    if s > 1000 { p.vel *= 1000 / s }
                    if d.len < 60 {
                        p.dead = true
                        o.inventory.append(.banana)
                        sfx("collect", volume: 0.4)
                        continue
                    }
                    if p.age > 4 { p.returning = false }
                }
            }
            p.vel.y -= 1900 * (p.isPoop ? 0.6 : p.junk.gravityScale) * dt * (p.returning ? 0 : 1)
            p.vel.y += world.fanForce(p.pos) * dt * 0.6
            var np = p.pos + p.vel * dt
            var cts: [Contact] = []
            world.resolve(&np, p.r, contacts: &cts)
            if !cts.isEmpty {
                if p.isPoop {
                    splat(at: np, color: hex(0xf4f1e6))
                    sfx("splat", volume: 0.3)
                    p.dead = true
                    continue
                }
                for ct in cts {
                    let vn = dot3(p.vel, ct.n)
                    if vn < 0 {
                        let bounce = ct.solid.kind == .bouncy ? 1.1 : p.junk.bounce
                        p.vel -= ct.n * vn * (1 + bounce)
                        p.vel -= (p.vel - ct.n * dot3(p.vel, ct.n)) * 0.15
                        if -vn > 200 {
                            p.bounces += 1
                            p.spin = p.vel.len / p.r * 0.8
                            if bounceSoundCooldown <= 0 {
                                bounceSoundCooldown = 0.05
                                let name = p.junk == .duck ? "squeak" : p.junk == .chicken ? "squawk" : "thud"
                                sfx(name, volume: min(0.5, -vn / 2000), rate: frand(0.9, 1.2))
                            }
                        }
                    }
                }
                if p.hostile && p.junk == .toast { p.hostile = false }
                if p.junk == .melon && p.r > 12 && p.bounces > 0 { splitMelon(p); continue }
                p.returning = false
            }
            p.pos = np
            p.angle += p.spin * dt
            p.node.simdPosition = p.pos
            p.node.simdOrientation = simd_quatf(angle: p.angle, axis: p.spinAxis)

            if p.hostile {
                for s in slots where s.body.ko <= 0 && s.body.flushing < 0 && s.body.invuln <= 0 && (p.pos - s.body.c).len < 46 + p.r {
                    p.dead = true
                    if p.isPoop { splat(at: p.pos, color: hex(0xf4f1e6)); sfx("splat", volume: 0.6); say(s, ["EW", "on my head??", "gross gross gross"], priority: true) }
                    hurt(s, from: p.pos - p.vel.norm * 30)
                    break
                }
                if p.dead { continue }
            } else if p.age > 0.03 {
                for e in enemies where !e.dead && !p.hitIDs.contains(ObjectIdentifier(e)) {
                    let reach = e.r * (e.kind == .cube || e.kind == .boss ? 1.15 : 1) + p.r
                    if (e.pos - p.pos).len < reach {
                        p.hitIDs.insert(ObjectIdentifier(e))
                        let dmg = (p.r < 12 && p.junk == .melon) ? 1 : p.junk.damage
                        damage(e, dmg, dir: p.vel.norm, text: nil, by: owner)
                        if p.junk == .sock { e.stun = max(e.stun, 2.2); popText("STINKY", at: e.pos + V3(0, e.r + 30, 0), color: hex(0xa8e063), size: 22) }
                        if p.junk == .melon && p.r > 12 { splitMelon(p); break }
                        if !p.junk.pierces {
                            p.vel = V3(-p.vel.x * 0.35, 380, -p.vel.z * 0.35)
                            p.spin *= -2
                        }
                        break
                    }
                }
                // friendly fire: no damage, just a very undignified shove
                if p.age > 0.1 && p.vel.len > 300 {
                    for s in slots where s.index != p.owner && s.body.ko <= 0 && s.body.flushing < 0 && (p.pos - s.body.c).len < 44 + p.r {
                        knock(s, p.vel.flat.norm * 260 + V3(0, 300, 0), spin: 2, axis: simd_cross(p.vel.flat.norm, V3(0, 1, 0)))
                        s.body.jolt()
                        s.body.hurtFace = 0.5
                        sfx("bonk", volume: 0.6, rate: 1.2)
                        popText("BONK!", at: s.body.c + V3(0, 70, 0), color: owner?.color ?? .white, size: 28)
                        say(s, ["HEY!", "watch it!", "\(owner?.name ?? "someone") hit me!", "friendly fire!!"], priority: true)
                        p.vel = V3(-p.vel.x * 0.3, 300, -p.vel.z * 0.3)
                        p.owner = s.index
                        break
                    }
                }
            }
            if !p.hostile && !p.isPoop && p.junk != .pea && !(p.junk == .melon && p.r < 12) && p.age > 0.6 && p.vel.len < 90 && !cts.isEmpty {
                p.dead = true
                let k = Pickup(.junk(p.junk), at: p.pos, dynamic: true)
                k.life = 25
                k.delay = 0.3
                addPickup(k)
                continue
            }
            if p.age > 9 || p.pos.y < world.killY || (p.junk == .pea && p.bounces > 1) || (p.r < 12 && p.junk == .melon && p.age > 1.5) {
                p.dead = true
            }
        }
        projectiles.removeAll { p in if p.dead { p.node.removeFromParentNode() }; return p.dead }
    }

    private func splitMelon(_ p: Projectile) {
        p.dead = true
        sfx("splat", volume: 0.7, rate: 0.8)
        splat(at: p.pos, color: hex(0xff3a4a))
        for k in 0..<5 {
            let a = Float(k) / 5 * 2 * .pi
            let q = Projectile(.melon, at: p.pos, vel: V3(cosf(a) * 450, 450, sinf(a) * 450))
            q.r = 9
            q.owner = p.owner
            q.node.simdScale = V3(repeating: 0.45)
            q.hitIDs = p.hitIDs
            addProjectile(q)
            worldNode.addChildNode(q.node)
        }
    }

    // MARK: Enemies

    func damage(_ e: Enemy, _ amt: Float, dir: V3, text: String?, by: Slot?) {
        guard !e.dead, e.hp > 0 else { return }
        e.hp -= amt
        e.hurtFlash = 0.18
        let kb: Float = e.kind == .boss ? 0.15 : 1
        e.vel += (dir.flat * 320 + V3(0, 260, 0)) * kb
        e.spin = frand(6, 12) * kb
        e.tumbleAxis = simd_cross(V3(0, 1, 0), dir.flat.len > 0.1 ? dir.flat.norm : V3(1, 0, 0)).norm
        e.awake = true
        for i in e.eyes.indices { e.eyes[i].jolt(V2(frand(-900, 900), 700)) }
        by?.bonks += 1
        let words = ["BONK!", "POW!", "THWACK!", "BOINK!", "WHAP!", "BOP!", "KAPOW!", "SPLAT!"]
        popText(text ?? words.randomElement()!, at: e.pos + V3(frand(-20, 20), e.r + 20, 0), color: multi ? (by?.color ?? hex(0xffe14d)) : hex(0xffe14d), size: e.kind == .boss ? 44 : 32)
        sfx("bonk", volume: 0.7, rate: frand(0.9, 1.15))
        addShake(e.kind == .boss ? 8 : 4)
        if e.hp <= 0 { kill(e, by: by) }
    }

    private func kill(_ e: Enemy, by: Slot?) {
        e.dead = true
        sfx("pop", volume: 0.8)
        confetti(at: e.pos, n: e.kind == .boss ? 140 : 30)
        let talker = by ?? slots.first
        switch e.kind {
        case .cube:
            score += 100
            if Float.random(in: 0...1) < 0.6 { dropJunk([.duck, .toast, .sock, .fish, .banana, .cheese].randomElement()!, at: e.pos) }
            if Float.random(in: 0...1) < 0.2, let t = talker { say(t, ["sorry!", "get cubed", "bonk'd", "nothing personal"]) }
        case .pigeon:
            score += 150
            let fm = mat(hex(0xb8bcc8), rough: 0.9)
            for _ in 0..<10 {
                let f = box(10, 1, 4, fm)
                worldNode.addChildNode(f)
                particles.append(Particle(f, pos: e.pos, vel: V3(frand(-200, 200), frand(0, 300), frand(-200, 200)), life: 2, gravity: -200, spin: frand(-4, 4), drag: 2, shrink: false))
            }
            if Float.random(in: 0...1) < 0.5 { dropJunk(.duck, at: e.pos) }
            if Float.random(in: 0...1) < 0.3, let t = talker { say(t, ["no more poop!", "sorry, bird"]) }
        case .toaster:
            score += 200
            for _ in 0..<3 { dropJunk(.toast, at: e.pos) }
            sfx("ding", volume: 0.5, rate: 1.3)
        case .boss:
            score += 5000
            addShake(30)
            sfx("stomp", volume: 1)
            popText(multi ? "\(by?.name ?? "YOU") FIRED\nTHE CEO!" : "YOU FIRED\nTHE CEO!", at: e.pos + V3(0, 150, 0), color: hex(0xffe14d), size: 60)
            for s in slots { say(s, ["I DID IT", "promotion time!", "take that, capitalism", "we did it!"], priority: true) }
            dropGoal()
            for k in 0..<8 { dropJunk(Junk.allCases[k % 9], at: e.pos + V3(0, 40, 0)) }
            audio.music.style = level.theme.music
            bossAwake = false
            hud.bossBar(nil)
        }
        e.node.runAction(.sequence([.group([.scale(to: 1.5, duration: 0.12), .fadeOut(duration: 0.12)]), .removeFromParentNode()]))
    }

    /// The golden toilet falls from the sky after the boss.
    func dropGoal() {
        emit(["gd"])
        goalVisible = true
        goalNode.isHidden = false
        goalNode.simdPosition = level.goal + V3(0, 900, 0)
        let g = level.goal
        goalNode.runAction(.sequence([.move(to: g.scn, duration: 1.2), .run { [weak self] _ in
            self?.later {
                self?.audio.play("stomp", volume: 0.6, rate: 1.3)
                self?.shake = 12
                self?.puff(at: g, n: 16, net: false)
            }
        }]))
    }

    private func dropJunk(_ j: Junk, at p: V3) {
        let k = Pickup(.junk(j), at: p, dynamic: true)
        k.vel = V3(frand(-250, 250), frand(350, 650), frand(-250, 250))
        k.spin = frand(-8, 8)
        k.delay = 0.35
        k.life = 30
        addPickup(k)
    }

    /// The closest player an enemy cares about.
    private func nearest(to p: V3) -> Slot? {
        slots.filter { $0.body.ko <= 0 && $0.body.flushing < 0 }.min { ($0.body.c - p).len < ($1.body.c - p).len }
    }

    private func updateEnemies(_ dt: Float) {
        for e in enemies where !e.dead {
            e.stun -= dt
            e.hurtFlash -= dt
            e.squash = max(0, e.squash - dt * 4)
            let target = nearest(to: e.pos)
            let pc = target?.body.c ?? e.pos + V3(2000, 0, 0)
            let d = pc - e.pos
            let near = target != nil && d.xz.len < 900 && abs(d.y) < 600
            let toward = d.flat.len > 1 ? d.flat.norm : V3(1, 0, 0)
            switch e.kind {
            case .cube, .toaster, .boss:
                e.vel.y -= 1900 * dt
                if e.kind != .boss || !bossAwake || e.phase != 2 { e.timer -= dt }
                if e.grounded { e.tumble *= max(0, 1 - 10 * dt); e.spin *= 0.8 }
                else { e.tumble += e.spin * dt }
                if near && e.stun <= 0 {
                    let face = toward + V3(0, 0, 0.9)
                    e.yaw += wrapAngle(atan2f(face.x, face.z) - e.yaw) * min(1, 5 * dt)
                }
                if e.kind == .cube && e.grounded && e.timer <= 0 && e.stun <= 0 {
                    if near {
                        e.vel = toward * frand(200, 300) + V3(0, frand(520, 660), 0)
                    } else {
                        e.vel = V3(frand(-60, 60), frand(250, 350), frand(-60, 60))
                    }
                    e.timer = frand(0.9, 1.6)
                    e.squash = 1
                    if near { sfx("hop", volume: 0.25, rate: frand(0.9, 1.2)) }
                }
                if e.kind == .toaster && e.timer <= 0 && e.stun <= 0 {
                    e.timer = frand(2.0, 2.8)
                    if near && d.xz.len < 850 {
                        let from = e.pos + V3(0, 40, 0)
                        let dd = pc - from
                        let T = clampf(dd.xz.len / 520, 0.6, 1.4)
                        let v = V3(dd.x / T, (dd.y + 0.5 * 1900 * T * T) / T, dd.z / T)
                        let toast = Projectile(.toast, at: from, vel: v, hostile: true)
                        addProjectile(toast)
                        worldNode.addChildNode(toast.node)
                        sfx("ding", volume: 0.55)
                        e.squash = 1
                        e.vel.y += 200
                    }
                }
                if e.kind == .boss { bossBrain(e, target, dt) }
                var p = e.pos + e.vel * dt
                var cts: [Contact] = []
                world.resolve(&p, e.r, contacts: &cts)
                let was = e.grounded
                e.grounded = false
                for ct in cts {
                    let vn = dot3(e.vel, ct.n)
                    if vn < 0 { e.vel -= ct.n * vn * (ct.solid.kind == .bouncy ? 2.1 : 1) }
                    if ct.n.y > 0.5 {
                        e.grounded = true
                        let fr: Float = ct.solid.kind == .ice ? 0.3 : 10
                        let rel = ct.solid.vel - e.vel
                        e.vel.x += rel.x * min(1, fr * dt)
                        e.vel.z += rel.z * min(1, fr * dt)
                    }
                }
                if e.grounded && !was { e.squash = 0.8; if e.kind == .boss { bossLanded(e) } }
                e.pos = p
            case .pigeon:
                if e.hp > 0 {
                    let t = time + e.home.x * 0.01
                    let hover = near ? V3(pc.x + sinf(t * 0.7) * 60, 0, pc.z + cosf(t * 0.6) * 40) : V3(e.home.x + sinf(t * 0.4) * 200, 0, e.home.z + cosf(t * 0.3) * 120)
                    let targetY = max(e.home.y, (near ? pc.y : e.home.y) + 260) + sinf(t * 2.1) * 30
                    let want = V3(clampf((hover.x - e.pos.x) * 1.5, -190, 190), clampf((targetY - e.pos.y) * 2, -160, 160), clampf((hover.z - e.pos.z) * 1.5, -190, 190))
                    e.vel += (want - e.vel) * min(1, (e.stun > 0 ? 0.5 : 3) * dt)
                    if e.stun > 0 { e.vel.y -= 400 * dt }
                    if e.vel.xz.len > 20 { e.yaw += wrapAngle(atan2f(e.vel.x, e.vel.z) - .pi / 2 - e.yaw) * min(1, 4 * dt) }
                    e.timer -= dt
                    if near && d.xz.len < 55 && pc.y < e.pos.y && e.timer <= 0 && e.stun <= 0 {
                        e.timer = frand(1.3, 2.2)
                        let poop = Projectile(.pea, at: e.pos - V3(0, 16, 0), vel: V3(e.vel.x * 0.5, -120, e.vel.z * 0.5), hostile: true, poop: true)
                        addProjectile(poop)
                        worldNode.addChildNode(poop.node)
                        sfx("coo", volume: 0.4, rate: frand(0.9, 1.1))
                    }
                    if Float.random(in: 0...1) < dt * 0.15 && near { sfx("coo", volume: 0.25) }
                    e.pos += e.vel * dt
                    let flap = sinf(time * 22 + e.home.x) * 0.7
                    if e.wings.count == 2 { e.wings[0].eulerAngles.x = CGFloat(-flap); e.wings[1].eulerAngles.x = CGFloat(flap) }
                }
            }
            // touching players
            if !e.dead {
                let reach = e.r * (e.kind == .cube || e.kind == .boss ? 1.15 : 1) + Player.pointR
                for s in slots where s.body.ko <= 0 && s.body.flushing < 0 && (e.pos - s.body.c).len < reach + 70 {
                    let b = s.body
                    guard b.x.contains(where: { ($0 - e.pos).len < reach }) else { continue }
                    if b.c.y > e.pos.y + e.r * 0.5 && b.cVel.y < 50 {
                        let wasPound = b.pounding
                        b.shove(V3(0, 0, 0))
                        for i in 0..<Player.N { b.v[i].y = max(b.v[i].y, 820) }
                        emit(["bo", s.index, 820])
                        b.jolt()
                        damage(e, wasPound ? 3 : 1, dir: (e.pos - b.c).flat.norm, text: wasPound ? "SLAM!" : "BOING!", by: s)
                        sfx("tramp", volume: 0.4, rate: 1.3)
                    } else if b.invuln <= 0 && e.stun <= 0 {
                        hurt(s, from: e.pos)
                    }
                    if e.dead { break }
                }
            }
            e.node.simdPosition = e.pos
            let sq = e.squash
            var q = simd_quatf(angle: e.yaw, axis: V3(0, 1, 0))
            if abs(e.tumble) > 0.001 { q = simd_quatf(angle: e.tumble, axis: e.tumbleAxis) * q }
            e.bodyNode.simdOrientation = q
            if e.kind != .pigeon { e.bodyNode.simdScale = V3(1 + sq * 0.18, 1 - sq * 0.18, 1 + sq * 0.18) }
            e.bodyNode.opacity = e.hurtFlash > 0 ? 0.5 : 1
            e.showStars(e.stun > 0 && e.kind != .boss)
            e.updateEyes(dt)
            if e.pos.y < world.killY { e.dead = true; e.node.removeFromParentNode() }
        }
        enemies.removeAll { $0.dead && $0.node.parent == nil }
    }

    // MARK: Boss

    private func bossBrain(_ e: Enemy, _ target: Slot?, _ dt: Float) {
        guard bossAwake, let t = target else { e.timer = 1.5; return }
        let d = t.body.c - e.pos
        let rage = 1 - e.hp / e.maxHP
        if e.grounded && e.timer <= 0 && e.stun <= 0 {
            let h = d.flat * 1.1
            let hl = h.len
            e.vel = (hl > 650 ? h * (650 / hl) : h) + V3(0, 1150 + rage * 200, 0)
            e.timer = (1.7 - rage * 0.8) * (multi ? 0.85 : 1)
            e.squash = 1
            e.phase = 2
            sfx("whoosh", volume: 0.6)
        }
        // more players, more interns
        let extra = max(0, slots.count - 1)
        if e.hp < e.maxHP * 0.66 && e.spawnedMinis == 0 { e.spawnedMinis = 1; spawnMinis(e, 2 + extra) }
        if e.hp < e.maxHP * 0.33 && e.spawnedMinis == 1 { e.spawnedMinis = 2; spawnMinis(e, 3 + extra) }
    }

    private func spawnMinis(_ boss: Enemy, _ n: Int) {
        popText("INTERNS!", at: boss.pos + V3(0, 160, 0), color: .white, size: 40)
        for k in 0..<n {
            let a = Float(k) / Float(n) * 2 * .pi
            let m = Enemy(.cube, at: boss.pos + V3(cosf(a) * 80, 140, sinf(a) * 80))
            m.vel = V3(cosf(a) * 250, 600, sinf(a) * 250)
            m.timer = 1
            addEnemy(m)
        }
    }

    private func bossLanded(_ e: Enemy) {
        guard bossAwake, e.phase == 2 else { return }
        e.phase = 0
        sfx("stomp", volume: 0.9)
        addShake(18)
        puff(at: e.pos - V3(0, e.r, 0), n: 20)
        let s = Shockwave(center: e.pos - V3(0, e.r - 8, 0))
        s.radius = e.r
        shocks.append(s)
        worldNode.addChildNode(s.node)
        for sl in slots where sl.body.grounded { knock(sl, V3(0, 120, 0)) }
    }

    private func updateShocks(_ dt: Float) {
        for s in shocks {
            s.life -= dt
            s.radius += 560 * dt
            (s.node.geometry as? SCNTorus)?.ringRadius = CGFloat(s.radius)
            s.node.opacity = CGFloat(min(1, s.life * 3))
            for sl in slots where sl.body.ko <= 0 && sl.body.invuln <= 0 && s.life > 0.1 {
                let dist = (sl.body.c - s.center).xz.len
                if abs(dist - s.radius) < 40 && sl.body.bottom < s.center.y + 22 { hurt(sl, from: s.center) }
            }
        }
        shocks.removeAll { s in if s.life <= 0 { s.node.removeFromParentNode(); return true }; return false }
    }

    private func updateBoss(_ dt: Float) {
        guard let b = boss, !b.dead, let trig = level.bossTrigger else { return }
        if !bossAwake && slots.contains(where: { $0.body.c.x > trig }) {
            bossAwake = true
            b.awake = true
            b.hp = b.maxHP * (1 + 0.35 * Float(slots.count - 1))
            audio.music.style = 3
            banner("MEGA CUBE", "Chief Executive Cube")
            sfx("stomp", volume: 0.8, rate: 0.8)
            addShake(15)
            if let s = slots.first { say(s, ["uh oh.", "that's a big cube", "I'd like to speak to your manager... oh."], priority: true) }
        }
        if bossAwake {
            hud.bossBar(b.hp / (b.maxHP * (1 + 0.35 * Float(slots.count - 1))))
            junkRain -= dt
            if junkRain <= 0 {
                junkRain = 2.2 / Float(max(1, slots.count)).squareRoot()
                let j: Junk = [.duck, .toast, .fish, .cheese, .melon, .bowling, .chicken, .sock, .banana].randomElement()!
                let k = Pickup(.junk(j), at: V3(frand(6800, 8100), 900, frand(-260, 260)), dynamic: true)
                k.life = 20
                k.spin = frand(-5, 5)
                addPickup(k)
            }
        }
    }

    // MARK: Player damage

    func hurt(_ s: Slot, from: V3) {
        let b = s.body
        guard b.invuln <= 0, b.ko <= 0, b.flushing < 0 else { return }
        var away = (b.c - from).flat
        if away.len < 1 { away = V3(-1, 0, 0) }
        away = away.norm
        knock(s, away * 520 + V3(0, 520, 0), spin: frand(2.5, 4.5), axis: simd_cross(away, V3(0, 1, 0)).norm)
        b.invuln = 1.4
        b.hurtFace = 0.9
        addShake(12)
        b.jolt()
        if b.eyes.count > 0 {
            let at = b.removeEye() ?? b.c
            let k = Pickup(.eye, at: at, dynamic: true)
            k.vel = away * frand(200, 380) + V3(0, frand(600, 800), 0)
            k.delay = 0.9
            k.life = 12
            addPickup(k)
            sfx("hurt", volume: 0.8)
            if b.eyes.count == 0 { say(s, ["I CAN'T SEE!", "who turned off the world?", "MY EYES! (both of them)"], priority: true) }
            else { say(s, ["MY EYE!", "that was my favourite eye", "I needed that!", "ow ow ow", "not the eye!"], priority: true) }
        } else {
            b.ko = 2.2
            sfx("ko", volume: 0.8)
            popText("K.O.", at: b.c + V3(0, 90, 0), color: hex(0xff5a5a), size: 50)
            say(s, ["ow.", "I'll just lie here.", "tell my eyes I love them"], priority: true)
        }
    }

    private func checkCheckpoints() {
        for (k, cp) in level.checkpoints.enumerated() where k > checkpointIdx {
            guard let s = slots.first(where: { $0.body.c.x > cp.x - 20 && abs($0.body.c.y - cp.y) < 260 }) else { continue }
            checkpointIdx = k
            Scenery.raise(checkpointFlags[k], instant: false)
            emit(["cp", k])
            sfx("checkpoint", volume: 0.7)
            popText("CHECKPOINT!", at: cp + V3(0, 200, 0), color: hex(0x9dff8a), size: 30)
            for o in slots where o.body.eyes.count < 2 {
                while o.body.eyes.count < 2 { o.body.addEye() }
                setMask(o.body.root, 2)
                say(o, ["free eyes!", "fresh eyes!"], priority: true)
            }
            _ = s
            storeRun()
        }
    }

    // MARK: Camera

    private func updateCamera(_ dt: Float) {
        var target = player.c + V3(clampf(player.cVel.x * 0.2, -160, 160), 0, 0)
        var spread: Float = 0
        if multi, let L = leader {
            // frame the players who are keeping up; stragglers get the teleport prompt instead
            let group = slots.filter { !$0.behind && $0.body.c.y > world.killY + 200 }
            let pts = group.isEmpty ? [L.body.c] : group.map { $0.body.c }
            let center = pts.reduce(V3(0, 0, 0), +) / Float(pts.count)
            spread = pts.map { ($0 - center).xz.len }.max() ?? 0
            target = center + V3(clampf(L.body.cVel.x * 0.15, -120, 120), 0, 0)
        }
        if state == .title { target = level.start + V3(330, 60, 0) }
        if flushT >= 0 || state == .done || state == .won { target = level.goal + V3(0, 60, 0) }
        if bossAwake, let b = boss, !b.dead { target = (target + b.pos) * 0.5 }
        camTarget.x += (target.x - camTarget.x) * min(1, 5 * dt)
        camTarget.z += (target.z - camTarget.z) * min(1, 4 * dt)
        camTarget.y += (target.y - camTarget.y) * min(1, 3 * dt)
        var dist = camDist * clampf(0.95 + spread / 800, 1, 2.0)
        if bossAwake { dist *= 1.35 }
        if state == .title { dist = 0.85 }
        let offset = V3(-170, 360, 880) * dist
        shake = max(0, shake - dt * 40)
        let jiggle = V3(frand(-1, 1), frand(-1, 1), frand(-1, 1)) * shake
        let look = camTarget + V3(0, 45, 0)
        camNode.simdPosition = look + offset + jiggle
        camNode.simdLook(at: look + jiggle * 0.5, up: V3(0, 1, 0), localFront: V3(0, 0, -1))
        sun.simdPosition = look - sun.simdWorldFront * 2500
    }

    /// Name tags over each player, clamped to the screen edge (with a teleport prompt) when off-screen.
    private func updateTags() {
        let W = overlay.size.width / 2 - 70, H = overlay.size.height / 2 - 60
        for s in slots {
            let show = multi && (state == .playing || state == .paused) && s.body.flushing < 0
            s.tag.isHidden = !show
            guard show else { continue }
            s.setTag(s.body.eyes.count == 0 ? "\(s.name) · CAN'T SEE" : s.body.ko > 0 ? "\(s.name) · K.O." : s.name)
            s.prompt.isHidden = !s.behind
            if var p = project(V3(s.body.c.x, s.body.top + 26, s.body.c.z)) {
                let off = abs(p.x) > W || abs(p.y) > H
                p.x = max(-W, min(W, p.x)); p.y = max(-H + 40, min(H - 120, p.y))
                s.tag.position = p
                s.tag.alpha = off ? 0.85 : 1
            } else {
                s.tag.position = CGPoint(x: -W, y: 0)
            }
        }
    }

    // MARK: Effects

    func project(_ p: V3) -> CGPoint? {
        let s = view.projectPoint(p.scn)
        guard s.z > 0 && s.z < 1 else { return nil }
        return CGPoint(x: CGFloat(s.x) - overlay.size.width / 2, y: CGFloat(s.y) - overlay.size.height / 2)
    }

    func popText(_ s: String, at p: V3, color c: NSColor, size: CGFloat) {
        emit(["t", s, Int(p.x), Int(p.y), Int(p.z), c.hexValue, Int(size)])
        let n = SKNode()
        for (k, line) in s.split(separator: "\n").enumerated() {
            let t = shadowTitle(String(line).uppercased(), size: size * 1.15, color: c, shadow: hex(0x1a0a10), offset: max(2, size * 0.07))
            t.position = CGPoint(x: 0, y: -CGFloat(k) * size * 1.1)
            n.addChild(t)
        }
        n.zPosition = 5
        n.zRotation = CGFloat(frand(-0.2, 0.2))
        n.setScale(0.3)
        n.run(.sequence([.scale(to: 1.15, duration: 0.1), .scale(to: 1, duration: 0.08)]))
        hud.world.addChild(n)
        popups.append((n, p, 1.1))
    }

    private func updatePopups(_ dt: Float) {
        for i in popups.indices {
            popups[i].2 -= dt
            popups[i].1.y += 60 * dt
            if let sp = project(popups[i].1) { popups[i].0.position = sp; popups[i].0.isHidden = false } else { popups[i].0.isHidden = true }
            if popups[i].2 < 0.3 { popups[i].0.alpha = CGFloat(max(0, popups[i].2 / 0.3)) }
        }
        popups.removeAll { if $0.2 <= 0 { $0.0.removeFromParent(); return true }; return false }
    }

    private static let confettiMats: [SCNMaterial] = [0xff4d6d, 0xffd23f, 0x3bceac, 0x5e60ce, 0xff9f1c, 0xffffff, 0x4cc9f0].map {
        let m = mat(hex(UInt32($0)), rough: 0.5)
        m.isDoubleSided = true
        return m
    }

    func confetti(at p: V3, n: Int, net: Bool = true) {
        if net { emit(["fx", 1, Int(p.x), Int(p.y), Int(p.z), n, 0]) }
        for _ in 0..<n {
            let s = box(CGFloat(frand(6, 11)), CGFloat(frand(4, 7)), 0.8, Game.confettiMats.randomElement()!)
            worldNode.addChildNode(s)
            let dir = V3(frand(-1, 1), frand(0.1, 1), frand(-1, 1)).norm
            particles.append(Particle(s, pos: p, vel: dir * frand(200, 700) + V3(0, 200, 0), life: frand(1.0, 2.0), gravity: -900, spin: frand(-12, 12), drag: 1.2, shrink: false))
        }
    }

    private static let puffMat: SCNMaterial = { let m = mat(.white, rough: 1); m.transparency = 0.8; return m }()

    func puff(at p: V3, n: Int, net: Bool = true) {
        guard n > 0 else { return }
        if net { emit(["fx", 0, Int(p.x), Int(p.y), Int(p.z), n, 0]) }
        for _ in 0..<n {
            let s = sphere(CGFloat(frand(7, 14)), Game.puffMat, seg: 10)
            worldNode.addChildNode(s)
            let a = frand(0, 2 * .pi)
            particles.append(Particle(s, pos: p + V3(cosf(a) * 25, 4, sinf(a) * 25), vel: V3(cosf(a) * frand(120, 240), frand(20, 140), sinf(a) * frand(120, 240)), life: frand(0.35, 0.6), gravity: 0, drag: 4))
        }
    }

    func splat(at p: V3, color c: NSColor, net: Bool = true) {
        if net { emit(["fx", 2, Int(p.x), Int(p.y), Int(p.z), 10, c.hexValue]) }
        let m = mat(c, rough: 0.3)
        for _ in 0..<10 {
            let s = sphere(CGFloat(frand(3, 7)), m, seg: 8)
            worldNode.addChildNode(s)
            particles.append(Particle(s, pos: p, vel: V3(frand(-260, 260), frand(50, 360), frand(-260, 260)), life: frand(0.4, 0.8)))
        }
    }

    func sparkle(at p: V3, net: Bool = true) {
        if net { emit(["fx", 3, Int(p.x), Int(p.y), Int(p.z), 14, 0]) }
        let m = mat(hex(0xfff6a0), emission: hex(0xffe060))
        for _ in 0..<14 {
            let s = sphere(3, m, seg: 6)
            worldNode.addChildNode(s)
            let d = V3(frand(-1, 1), frand(-1, 1), frand(-1, 1)).norm
            particles.append(Particle(s, pos: p, vel: d * frand(100, 300), life: 0.7, gravity: 0, drag: 3))
        }
    }

    func updateParticles(_ dt: Float) {
        for p in particles {
            p.life -= dt
            p.vel.y += p.gravity * dt
            p.vel *= max(0, 1 - p.drag * dt)
            p.pos += p.vel * dt
            p.angle += p.spin * dt
            p.node.simdPosition = p.pos
            if p.spin != 0 { p.node.simdOrientation = simd_quatf(angle: p.angle, axis: p.axis) }
            let k = max(0, p.life / p.maxLife)
            if p.shrink { p.node.simdScale = V3(repeating: 0.3 + 0.7 * k) }
            p.node.opacity = CGFloat(min(1, k * 3))
        }
        particles.removeAll { if $0.life <= 0 { $0.node.removeFromParentNode(); return true }; return false }
    }

    // MARK: Speech

    func say(_ s: Slot, _ lines: [String], priority: Bool = false, fromNet: Bool = false) {
        if role == .guest && !fromNet { return }
        if !priority && s.quipCooldown > 0 { return }
        guard let text = lines.randomElement() else { return }
        emit(["q", s.index, text])
        s.quipCooldown = 3
        s.bubble?.removeFromParent()
        let b = HUD.speechBubble(text, color: multi ? s.color : hex(0x1d1016))
        b.zPosition = 6
        hud.world.addChild(b)
        s.bubble = b
        s.bubbleLife = 2.2
        let syll = max(2, min(9, text.count / 3))
        var acts: [SKAction] = []
        let base = frand(1.0, 1.15) * s.voicePitch
        for k in 0..<syll {
            acts.append(.run { [weak self] in self?.sfx("voice", volume: 0.35, rate: base * frand(0.88, 1.18) * (k == syll - 1 ? 0.9 : 1), jitter: 0) })
            acts.append(.wait(forDuration: Double(frand(0.07, 0.11))))
        }
        hud.root.run(.sequence(acts))
        s.body.mouthOpen = 1
    }

    func updateBubble(_ s: Slot, _ dt: Float) {
        guard let b = s.bubble else { return }
        s.bubbleLife -= dt
        if let sp = project(V3(s.body.c.x, s.body.top + 20, s.body.c.z)) { b.position = CGPoint(x: sp.x, y: sp.y + (multi ? 22 : 0)) }
        if s.bubbleLife < 0.3 { b.alpha = CGFloat(max(0, s.bubbleLife / 0.3)) }
        if s.bubbleLife <= 0 { b.removeFromParent(); s.bubble = nil }
        if s.bubbleLife > 0.2 { s.body.mouthOpen = max(s.body.mouthOpen, 0.4 + 0.4 * abs(sinf(time * 25))) }
    }

    func saveNow() { if state == .playing || state == .paused { storeRun() } }
}
