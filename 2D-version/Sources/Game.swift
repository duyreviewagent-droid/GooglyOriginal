import SpriteKit

final class GameScene: SKScene {
    var onUpdate: ((TimeInterval) -> Void)?
    var onResize: (() -> Void)?
    override func update(_ t: TimeInterval) { onUpdate?(t) }
    override func didChangeSize(_ oldSize: CGSize) { onResize?() }
}

struct SaveData: Codable {
    struct Run: Codable { var level: Int; var checkpoint: Int; var score: Int; var eyes: Int; var inventory: [Int] }
    var unlocked = 1
    var best: [Int] = [0, 0, 0]
    var wins = 0
    var run: Run?
    static var disabled = false
    static let key = "googly.save.v1"
    static func load() -> SaveData {
        guard !disabled, let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(SaveData.self, from: d) else { return SaveData() }
        return s
    }
    func store() {
        guard !SaveData.disabled, let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(d, forKey: SaveData.key)
    }
}

final class Game {
    enum State { case title, playing, paused, done, won }

    let view: GameView
    let scene = GameScene(size: CGSize(width: 1440, height: 900))
    let audio: AudioSystem
    let cam = SKCameraNode()
    let worldNode = SKNode()
    let skyNode = SKSpriteNode()
    let farLayer = SKNode(), nearLayer = SKNode()
    let hud: HUD
    var input: InputState { view.input }

    var state = State.title
    var levelIndex = 0
    var level: LevelData!
    var world = World()
    let player = Player()
    var pickups: [Pickup] = []
    var projectiles: [Projectile] = []
    var enemies: [Enemy] = []
    var particles: [Particle] = []
    var shocks: [Shockwave] = []
    var popups: [(SKNode, Float)] = []
    var inventory: [Junk] = []
    var score = 0
    var levelStartScore = 0
    var bonks = 0, collected = 0, eyesFound = 0, falls = 0
    var checkpointIdx = -1
    var checkpointFlags: [SKNode] = []
    var goalNode = SKNode()
    var goalVisible = true
    var camPos = V2(0, 300)
    var camScale: Float = 1
    var shake: Float = 0
    var time: Float = 0
    var lastT: TimeInterval = 0
    var fireCooldown: Float = 0, honkCooldown: Float = 0, jumpBuffer: Float = 0
    var quipCooldown: Float = 0, idleTime: Float = 0
    var bubble: SKNode?
    var bubbleLife: Float = 0
    var saveTimer: Float = 0
    var boss: Enemy?
    var bossAwake = false
    var junkRain: Float = 0
    var doneTimer: Float = 0
    var koRespawn = false
    var save: SaveData
    var ignoreInput = false
    var demo = false
    var titleHop: Float = 1.5
    var bounceSoundCooldown: Float = 0
    var levelTime: Float = 0
    var demoHold: Float = 0

    init(view: GameView, muted: Bool) {
        self.view = view
        audio = AudioSystem(muted: muted)
        save = SaveData.load()
        hud = HUD()
        scene.scaleMode = .resizeFill
        scene.backgroundColor = hex(0x5fb8ff)
        scene.addChild(skyNode)
        skyNode.zPosition = -1000
        farLayer.zPosition = -600
        nearLayer.zPosition = -500
        scene.addChild(farLayer)
        scene.addChild(nearLayer)
        scene.addChild(worldNode)
        cam.zPosition = 1000
        scene.addChild(cam)
        scene.camera = cam
        cam.addChild(hud.root)
        scene.onUpdate = { [weak self] t in self?.tick(t) }
        scene.onResize = { [weak self] in self?.layout() }
        view.ignoresSiblingOrder = false
        view.preferredFramesPerSecond = 120
        loadLevel(0)
        state = .title
        hud.showTitle(save: save)
        audio.music.style = 4
        view.presentScene(scene)
        layout()
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
        worldNode.removeAllChildren()
        for p in pickups { p.node.removeFromParent() }
        pickups.removeAll(); projectiles.removeAll(); enemies.removeAll(); particles.removeAll(); shocks.removeAll(); popups.removeAll()
        bubble = nil
        boss = nil; bossAwake = false
        checkpointFlags.removeAll()
        Scenery.build(level: level, world: world, into: worldNode, far: farLayer, near: nearLayer, sky: skyNode)
        for (w, p) in level.pickups { addPickup(Pickup(w, at: p)) }
        for (k, p) in level.enemies {
            let e = Enemy(k, at: p)
            enemies.append(e)
            worldNode.addChild(e.node)
            if k == .boss { boss = e }
        }
        for cp in level.checkpoints {
            let f = Scenery.flag(at: cp)
            worldNode.addChild(f)
            checkpointFlags.append(f)
        }
        goalNode = Scenery.toilet()
        goalNode.position = level.goal.cg
        goalVisible = !level.goalHidden
        goalNode.isHidden = !goalVisible
        worldNode.addChild(goalNode)
        worldNode.addChild(player.root)
        checkpointIdx = checkpoint
        for (k, f) in checkpointFlags.enumerated() where k <= checkpoint { Scenery.raise(f, instant: true) }
        let start = checkpoint >= 0 ? level.checkpoints[checkpoint] + V2(0, 90) : level.start
        player.place(at: start)
        camPos = start + V2(0, 150)
        levelTime = 0
        audio.music.style = level.theme.music
        layout()
    }

    func startLevel(_ i: Int, fresh: Bool) {
        if fresh {
            inventory = []
            score = 0
            player.setEyes(2)
        }
        levelStartScore = score
        bonks = 0; collected = 0; eyesFound = 0; falls = 0
        loadLevel(i)
        if player.eyes.count < 2 { player.setEyes(2) }
        state = .playing
        hud.hideTitle()
        hud.hidePanel()
        hud.banner(level.subtitle.uppercased(), level.name)
        audio.play("checkpoint", volume: 0.5)
        storeRun()
    }

    func continueRun() {
        guard let r = save.run else { startLevel(0, fresh: true); return }
        score = r.score
        levelStartScore = r.score
        inventory = r.inventory.compactMap { Junk(rawValue: $0) }
        player.setEyes(max(0, min(Player.maxEyes, r.eyes)))
        bonks = 0; collected = 0; eyesFound = 0; falls = 0
        loadLevel(r.level, checkpoint: min(r.checkpoint, LevelData.make(r.level).checkpoints.count - 1))
        state = .playing
        hud.hideTitle()
        hud.banner(level.subtitle.uppercased(), level.name)
    }

    func storeRun() {
        save.run = SaveData.Run(level: levelIndex, checkpoint: checkpointIdx, score: score, eyes: player.eyes.count, inventory: inventory.map { $0.rawValue })
        save.store()
        if !SaveData.disabled { hud.flashSaved() }
    }

    func addPickup(_ p: Pickup) {
        pickups.append(p)
        worldNode.addChild(p.node)
    }

    func layout() {
        let size = scene.size
        camScale = 900 / Float(max(1, size.height))
        if Float(size.width) * camScale < 1300 { camScale = 1300 / Float(max(1, size.width)) }
        cam.setScale(CGFloat(camScale))
        hud.root.setScale(CGFloat(camScale))
        hud.layout(size)
        skyNode.size = CGSize(width: size.width * CGFloat(camScale) + 40, height: size.height * CGFloat(camScale) + 40)
    }

    // MARK: Loop

    func tick(_ t: TimeInterval) {
        var dt = Float(lastT == 0 ? 1.0 / 60 : t - lastT)
        lastT = t
        dt = max(0.001, min(dt, 1.0 / 30))
        time += dt
        if ignoreInput { input.clear() }
        audio.music.duck = player.ko > 0 ? 0.35 : 1

        if input.wasPressed(Key.m) { audio.toggleMute(); hud.toast(audio.muted ? "muted" : "sound on") }

        switch state {
        case .title: updateTitle(dt)
        case .playing: updatePlaying(dt)
        case .paused:
            if input.wasPressed(Key.esc, Key.p) { state = .playing; hud.hidePanel() }
            else if input.wasPressed(Key.r) { hud.hidePanel(); restartLevel() }
            else if input.wasPressed(Key.q) { storeRun(); toTitle() }
        case .done:
            doneTimer += dt
            simulateScenery(dt)
            if doneTimer > 0.8 && (input.wasPressed(Key.ret, Key.enter, Key.space) || (demo && doneTimer > 2)) {
                hud.hidePanel()
                if levelIndex + 1 < LevelData.names.count { startLevel(levelIndex + 1, fresh: false) }
                else { win() }
            }
        case .won:
            doneTimer += dt
            simulateScenery(dt)
            if Int(time * 3) % 2 == 0 && Float.random(in: 0...1) < 0.3 { confetti(at: camPos + V2(frand(-600, 600), 500), n: 3) }
            if doneTimer > 1.5 && input.wasPressed(Key.ret, Key.enter, Key.space, Key.esc) { toTitle() }
        }
        updateCamera(dt)
        hud.update(self, dt: dt)
        input.endFrame()
    }

    func toTitle() {
        state = .title
        hud.hidePanel()
        loadLevel(0)
        audio.music.style = 4
        hud.showTitle(save: save)
    }

    func restartLevel() {
        score = levelStartScore
        bonks = 0; collected = 0; eyesFound = 0; falls = 0
        if player.eyes.count < 2 { player.setEyes(2) }
        loadLevel(levelIndex)
        state = .playing
        hud.banner(level.subtitle.uppercased(), level.name)
    }

    func win() {
        state = .won
        doneTimer = 0
        save.wins += 1
        save.run = nil
        save.store()
        audio.play("win")
        audio.music.style = 4
        hud.showWin(score: score)
    }

    private func updateTitle(_ dt: Float) {
        titleHop -= dt
        var ctl = Player.Controls()
        if titleHop < 0 { ctl.jump = true; titleHop = frand(1.2, 2.6) }
        stepPlayer(dt, ctl, sounds: false)
        player.frame(dt, world: world, t: time)
        player.draw(world: world, t: time)
        simulateScenery(dt)
        hud.titleTick(dt, time: time)
        if input.wasPressed(Key.space) { audio.play("click"); startLevel(0, fresh: true) }
        else if input.wasPressed(Key.ret, Key.enter), save.run != nil { audio.play("click"); continueRun() }
        else if input.wasPressed(Key.one) { startLevel(0, fresh: true) }
        else if input.wasPressed(Key.two), save.unlocked >= 2 { startLevel(1, fresh: true) }
        else if input.wasPressed(Key.three), save.unlocked >= 3 { startLevel(2, fresh: true) }
    }

    /// Enemies idling, pickups bobbing, particles: used behind menus.
    private func simulateScenery(_ dt: Float) {
        world.moveMovers(dt)
        for p in pickups { p.update(dt, world: world) }
        for e in enemies { e.updateEyes(dt) }
        updateParticles(dt)
        updatePopups(dt)
    }

    // MARK: Playing

    private func controls() -> Player.Controls {
        var c = Player.Controls()
        if demo { return demoControls() }
        if input.isHeld(Key.a, Key.left) { c.move -= 1 }
        if input.isHeld(Key.d, Key.right) { c.move += 1 }
        c.squish = input.isHeld(Key.s, Key.down)
        if input.wasPressed(Key.space, Key.w, Key.up) { jumpBuffer = 0.13 }
        c.jump = jumpBuffer > 0
        return c
    }

    private func stepPlayer(_ dt: Float, _ ctlIn: Player.Controls, sounds: Bool) -> Void {
        var ctl = ctlIn
        let sub = 4
        let h = dt / Float(sub)
        var events: [Player.Event] = []
        for s in 0..<sub {
            if s > 0 { ctl.jump = false }
            player.step(h, ctl, world, events: &events)
            for e in events { if case .jump = e { jumpBuffer = 0 }; if case .superJump = e { jumpBuffer = 0 } }
        }
        if sounds { handle(events) } else {
            for e in events { if case .jump = e { audio.play("boing", volume: 0.25) } }
        }
    }

    private func updatePlaying(_ dt: Float) {
        levelTime += dt
        if input.wasPressed(Key.esc, Key.p) { state = .paused; hud.showPause(); return }
        jumpBuffer -= dt
        fireCooldown -= dt
        honkCooldown -= dt
        quipCooldown -= dt
        bounceSoundCooldown -= dt
        world.moveMovers(dt)

        if player.flushing >= 0 {
            updateFlush(dt)
        } else {
            let ctl = player.ko > 0 ? Player.Controls() : controls()
            stepPlayer(dt, ctl, sounds: true)
            if ctl.move != 0 || ctl.jump || ctl.squish { idleTime = 0 } else { idleTime += dt }
            if idleTime > 9 { idleTime = 0; say(["hello?", "I'm just a guy.", "is anyone controlling me?", "*wobble*", "I could stand here all day.", "blink. blink."]) }
            if player.ko > 0 {
                player.ko -= dt
                if player.ko <= 0 { respawn(ko: true) }
            }
            // shooting and honking
            let wantFire = input.mouseClicked || input.wasPressed(Key.j, Key.f) || (input.mouseHeld && fireCooldown < -0.1) || (demo && demoWantsFire())
            if wantFire && fireCooldown <= 0 && player.ko <= 0 { shoot(mouse: input.mouseClicked || input.mouseHeld) }
            if (input.wasPressed(Key.h, Key.e) || input.rightClicked) && honkCooldown <= 0 && player.ko <= 0 { honk() }
        }
        player.frame(dt, world: world, t: time)
        player.draw(world: world, t: time)

        updatePickups(dt)
        updateProjectiles(dt)
        updateEnemies(dt)
        updateShocks(dt)
        updateParticles(dt)
        updatePopups(dt)
        updateBubble(dt)
        checkCheckpoints()
        updateBoss(dt)

        // goal
        if goalVisible && player.flushing < 0 && player.ko <= 0 && (player.c - (level.goal + V2(0, 60))).len < 80 {
            player.flushing = 0
            audio.play("flush")
            say(["finally, a bath!", "wheeeee—", "see you on the other side!"], priority: true)
        }
        // pits
        if player.c.y < world.killY && player.flushing < 0 {
            falls += 1
            audio.play("whoops")
            say(["WHOOOOPS", "brb", "that was on purpose"], priority: true)
            if player.eyes.count > 0 { player.removeEye() ; respawn(ko: false) }
            else { respawn(ko: true) }
        }
        saveTimer += dt
        if saveTimer > 30 { saveTimer = 0; storeRun() }
    }

    private func respawn(ko: Bool) {
        let p = checkpointIdx >= 0 ? level.checkpoints[checkpointIdx] + V2(0, 90) : level.start
        if ko {
            player.setEyes(2)
            score = max(0, score - 200)
            hud.toast("-200 (bonked out)")
        }
        player.place(at: p)
        player.invuln = 1.5
        camPos = p + V2(0, 150)
        if player.eyes.count == 0 { say(["still can't see...", "where am I?"], priority: true) }
    }

    private func updateFlush(_ dt: Float) {
        player.flushing += dt
        let k = min(1, player.flushing / 1.8)
        let center = level.goal + V2(0, 62 - k * 30)
        player.flushPose(center: center, scale: max(0.04, 1 - k * 0.96), angle: k * k * 16)
        if Int(player.flushing * 20) % 3 == 0 {
            let b = SKShapeNode(circleOfRadius: CGFloat(frand(3, 7)))
            b.fillColor = hex(0x8fd4ff, 0.8); b.strokeColor = .clear
            b.zPosition = 60
            worldNode.addChild(b)
            particles.append(Particle(b, pos: center + V2(frand(-40, 40), 0), vel: V2(frand(-150, 150), frand(100, 350)), life: 0.7))
        }
        if player.flushing > 2.2 && state == .playing { levelComplete() }
    }

    private func levelComplete() {
        state = .done
        doneTimer = 0
        let bonus = 1000 + player.eyes.count * 200
        score += bonus
        let got = score - levelStartScore
        if levelIndex < save.best.count { save.best[levelIndex] = max(save.best[levelIndex], got) }
        save.unlocked = max(save.unlocked, min(LevelData.names.count, levelIndex + 2))
        if levelIndex + 1 < LevelData.names.count {
            save.run = SaveData.Run(level: levelIndex + 1, checkpoint: -1, score: score, eyes: max(2, player.eyes.count), inventory: inventory.map { $0.rawValue })
        }
        save.store()
        audio.play("win")
        hud.showDone(level: level, stats: (got, bonus, bonks, collected, player.eyes.count, falls, levelTime), last: levelIndex + 1 >= LevelData.names.count)
        player.place(at: V2(0, -5000))
        player.root.alpha = 0
    }

    // MARK: Events

    private func handle(_ events: [Player.Event]) {
        for e in events {
            switch e {
            case .jump:
                audio.play("boing", volume: 0.55, rate: frand(0.95, 1.12))
                if Float.random(in: 0...1) < 0.07 { say(["wheee!", "hup!", "boing!", "yippee"]) }
            case .superJump(let k):
                audio.play("superboing", volume: 0.5 + 0.4 * k)
                puff(at: V2(player.c.x, player.bottom), n: 8)
                if k > 0.8 && Float.random(in: 0...1) < 0.4 { say(["TO THE MOON", "BOIIIING", "I believe I can fly"]) }
            case .land(let impact):
                audio.play("land", volume: min(1, 0.25 + impact / 1500))
                puff(at: V2(player.c.x, player.bottom), n: Int(min(10, impact / 150)))
                player.jolt()
                if impact > 1500 && Float.random(in: 0...1) < 0.5 { say(["my spine!", "(I have no spine)", "ow, my everything", "nailed it"]) }
            case .pound:
                audio.play("pound", volume: 0.6)
            case .poundLand:
                audio.play("stomp", volume: 0.55, rate: 1.4)
                shake = max(shake, 10)
                puff(at: V2(player.c.x, player.bottom), n: 14)
                player.jolt()
                for en in enemies where !en.dead && en.kind != .pigeon {
                    let d = en.pos - V2(player.c.x, player.bottom)
                    if abs(d.x) < 190 && abs(d.y) < 120 { damage(en, 2, dir: V2(d.x >= 0 ? 1 : -1, 0.8).norm, text: "SLAM!") }
                }
            case .trampoline:
                audio.play("tramp", volume: 0.7)
                player.jolt()
                if Float.random(in: 0...1) < 0.25 { say(["weeeeee!", "trampoline!!", "I am a bird now"]) }
            case .step:
                audio.play("step", volume: 0.18)
            case .fan:
                break
            }
        }
        if player.inFan && Int(time * 4) % 8 == 0 && Float.random(in: 0...1) < 0.05 { say(["wheeeeeeeee", "fan-tastic"]) }
    }

    // MARK: Shooting

    func mouseWorld() -> V2 {
        let p = scene.convertPoint(fromView: input.mouseView)
        return V2(p)
    }

    private func shoot(mouse: Bool) {
        let j = inventory.popLast() ?? .pea
        let mouth = player.c + player.G.mul(V2(0, -4))
        var dir: V2
        if mouse { dir = (mouseWorld() - mouth).norm } else { dir = V2(player.facing, 0.18).norm }
        if demo { dir = demoAim() }
        if dir.len < 0.5 { dir = V2(player.facing, 0) }
        let p = Projectile(j, at: mouth + dir * 34, vel: dir * j.speed + V2(player.cVel.x * 0.4, max(0, player.cVel.y) * 0.3))
        projectiles.append(p)
        worldNode.addChild(p.node)
        player.shove(-dir * j.recoil * (player.grounded ? 0.5 : 1))
        player.mouthOpen = 1
        player.aimTimer = 0.35
        player.aimDir = dir
        player.facing = dir.x >= 0 ? 1 : -1
        fireCooldown = j == .pea ? 0.14 : 0.22
        audio.play(j == .pea ? "pea" : "ptoo", volume: j == .bowling ? 0.9 : 0.6, rate: j == .bowling ? 0.75 : frand(0.95, 1.1))
        if j == .chicken { audio.play("squawk", volume: 0.5) }
        if j == .pea && Float.random(in: 0...1) < 0.18 { say(["pew.", "this is embarrassing", "I'm out of stuff!", "a pea. truly terrifying."]) }
        if j == .bowling { shake = max(shake, 6); say(["STRIIIKE", "heavy!"]) }
        idleTime = 0
    }

    private func honk() {
        honkCooldown = 1.4
        audio.play("honk", volume: 0.8, rate: frand(0.96, 1.04))
        player.mouthOpen = 1
        player.shove(V2(0, 160))
        player.jolt()
        let t = popText("HONK!", at: player.c + V2(0, 90), color: hex(0xffe14d), size: 34)
        t.zRotation = CGFloat(frand(-0.2, 0.2))
        for e in enemies where !e.dead {
            let d = e.pos - player.c
            if d.len < 300 {
                e.vel += V2(d.x >= 0 ? 380 : -380, 300)
                e.stun = max(e.stun, 1.2)
                if e.kind == .boss { e.stun = 0.3 }
                for i in e.eyes.indices { e.eyes[i].jolt(V2(frand(-900, 900), 900)) }
            }
        }
    }

    // MARK: Pickups

    private func updatePickups(_ dt: Float) {
        for p in pickups where !p.dead {
            p.update(dt, world: world)
            guard p.delay <= 0, player.ko <= 0, player.flushing < 0 else { continue }
            if (p.pos - player.c).len < 58 + p.r {
                switch p.what {
                case .junk(let j):
                    if inventory.count >= 30 { continue }
                    inventory.append(j)
                    collected += 1
                    score += 10
                    audio.play(j == .duck ? "squeak" : j == .chicken ? "squawk" : "collect", volume: 0.5, rate: frand(0.95, 1.15))
                    if j != .duck && j != .chicken { } else { audio.play("collect", volume: 0.3) }
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
                        say(lines)
                    }
                    popText("+\(j.emoji)", at: p.pos + V2(0, 30), color: .white, size: 22)
                case .eye:
                    if player.eyes.count >= Player.maxEyes { continue }
                    player.addEye()
                    eyesFound += 1
                    score += 50
                    audio.play("eye", volume: 0.7)
                    say(player.eyes.count == 1 ? ["I CAN SEE!", "light! glorious light!"] :
                        player.eyes.count >= 5 ? ["SO MANY EYES", "I see everything", "eye eye eye!", "\(player.eyes.count) eyes. no regrets."] :
                        ["MORE EYES!", "I can see... more!", "eye spy!"], priority: true)
                    sparkle(at: p.pos)
                }
                p.dead = true
                p.node.run(.sequence([.group([.scale(to: 1.8, duration: 0.15), .fadeOut(withDuration: 0.15)]), .removeFromParent()]))
            }
        }
        pickups.removeAll { p in
            if p.dead && p.node.action(forKey: "x") == nil && p.node.hasActions() == false { p.node.removeFromParent() }
            return p.dead
        }
    }

    // MARK: Projectiles

    private func updateProjectiles(_ dt: Float) {
        for p in projectiles where !p.dead {
            p.age += dt
            if p.junk == .banana && !p.hostile && !p.isPoop && p.r > 10 {
                if p.age > 0.5 { p.returning = true }
                if p.returning {
                    let d = player.c - p.pos
                    p.vel += d.norm * 2600 * dt
                    let s = p.vel.len
                    if s > 1000 { p.vel *= 1000 / s }
                    if d.len < 60 {
                        p.dead = true
                        inventory.append(.banana)
                        audio.play("collect", volume: 0.4)
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
                    audio.play("splat", volume: 0.3)
                    p.dead = true
                    continue
                }
                for ct in cts {
                    let vn = dot(p.vel, ct.n)
                    if vn < 0 {
                        let bounce = ct.solid.kind == .bouncy ? 1.1 : p.junk.bounce
                        p.vel -= ct.n * vn * (1 + bounce)
                        p.vel -= (p.vel - ct.n * dot(p.vel, ct.n)) * 0.15
                        if -vn > 200 {
                            p.bounces += 1
                            p.spin = -p.vel.x / p.r * 0.8
                            if bounceSoundCooldown <= 0 {
                                bounceSoundCooldown = 0.05
                                let name = p.junk == .duck ? "squeak" : p.junk == .chicken ? "squawk" : "thud"
                                audio.play(name, volume: min(0.5, -vn / 2000), rate: frand(0.9, 1.2))
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
            p.node.position = p.pos.cg
            p.node.zRotation = CGFloat(p.angle)

            if p.hostile {
                if player.ko <= 0 && player.flushing < 0 && player.invuln <= 0 && (p.pos - player.c).len < 46 + p.r {
                    p.dead = true
                    if p.isPoop { splat(at: p.pos, color: hex(0xf4f1e6)); audio.play("splat", volume: 0.6); say(["EW", "on my head??", "gross gross gross"], priority: true) }
                    hurt(from: p.pos - p.vel.norm * 30)
                }
            } else if p.age > 0.03 {
                for e in enemies where !e.dead && !p.hitIDs.contains(ObjectIdentifier(e)) {
                    let reach = e.r * (e.kind == .cube || e.kind == .boss ? 1.12 : 1) + p.r
                    if (e.pos - p.pos).len < reach {
                        p.hitIDs.insert(ObjectIdentifier(e))
                        let dir = p.vel.norm
                        var dmg = p.junk.damage
                        if p.r < 12 && p.junk == .melon { dmg = 1 }
                        damage(e, dmg, dir: dir, text: nil)
                        if p.junk == .sock { e.stun = max(e.stun, 2.2); popText("STINKY", at: e.pos + V2(0, e.r + 30), color: hex(0xa8e063), size: 22) }
                        if p.junk == .melon && p.r > 12 { splitMelon(p); break }
                        if !p.junk.pierces {
                            p.vel = V2(-p.vel.x * 0.35, 380)
                            p.spin *= -2
                        }
                        break
                    }
                }
            }
            // turn into a pickup once it has settled
            if !p.hostile && !p.isPoop && p.junk != .pea && !(p.junk == .melon && p.r < 12) && p.age > 0.6 && p.vel.len < 90 && !cts.isEmpty {
                p.dead = true
                let k = Pickup(.junk(p.junk), at: p.pos, dynamic: true)
                k.life = 25
                k.delay = 0.3
                k.angle = p.angle
                addPickup(k)
                continue
            }
            if p.age > 9 || p.pos.y < world.killY || (p.junk == .pea && p.bounces > 1) || (p.r < 12 && p.junk == .melon && p.age > 1.5) {
                p.dead = true
            }
        }
        projectiles.removeAll { p in if p.dead { p.node.removeFromParent() }; return p.dead }
    }

    private func splitMelon(_ p: Projectile) {
        p.dead = true
        audio.play("splat", volume: 0.7, rate: 0.8)
        splat(at: p.pos, color: hex(0xff3a4a))
        for k in 0..<4 {
            let a = Float(k) / 4 * .pi + 0.3
            let q = Projectile(.melon, at: p.pos, vel: V2(cosf(a) * 520, sinf(a) * 520 + 200))
            q.r = 9
            q.node.size = CGSize(width: 24, height: 24)
            q.hitIDs = p.hitIDs
            projectiles.append(q)
            worldNode.addChild(q.node)
        }
    }

    // MARK: Enemies

    func damage(_ e: Enemy, _ amt: Float, dir: V2, text: String?) {
        guard !e.dead, e.hp > 0 else { return }
        e.hp -= amt
        e.hurtFlash = 0.18
        let kb: Float = e.kind == .boss ? 0.15 : 1
        e.vel += V2(dir.x * 320, 260) * kb
        e.spin = frand(-9, 9) * kb
        e.awake = true
        for i in e.eyes.indices { e.eyes[i].jolt(V2(dir.x * 900, 700)) }
        bonks += 1
        let words = ["BONK!", "POW!", "THWACK!", "BOINK!", "WHAP!", "BOP!", "KAPOW!", "SPLAT!"]
        let t = popText(text ?? words.randomElement()!, at: e.pos + V2(frand(-20, 20), e.r + 20), color: hex(0xffe14d), size: e.kind == .boss ? 44 : 32)
        t.zRotation = CGFloat(frand(-0.3, 0.3))
        audio.play("bonk", volume: 0.7, rate: frand(0.9, 1.15))
        shake = max(shake, e.kind == .boss ? 8 : 4)
        if e.hp <= 0 { kill(e) }
    }

    private func kill(_ e: Enemy) {
        e.dead = true
        audio.play("pop", volume: 0.8)
        confetti(at: e.pos, n: e.kind == .boss ? 120 : 26)
        switch e.kind {
        case .cube:
            score += 100
            if Float.random(in: 0...1) < 0.6 { dropJunk([.duck, .toast, .sock, .fish, .banana, .cheese].randomElement()!, at: e.pos) }
            if Float.random(in: 0...1) < 0.2 { say(["sorry!", "get cubed", "bonk'd", "nothing personal"]) }
        case .pigeon:
            score += 150
            for _ in 0..<8 {
                let f = SKSpriteNode(texture: emojiTexture("🪶", size: 48))
                f.size = CGSize(width: 24, height: 24)
                f.zPosition = 55
                worldNode.addChild(f)
                particles.append(Particle(f, pos: e.pos, vel: V2(frand(-200, 200), frand(0, 300)), life: 2, gravity: -200, spin: frand(-4, 4), drag: 2, shrink: false))
            }
            if Float.random(in: 0...1) < 0.5 { dropJunk(.duck, at: e.pos) }
            if Float.random(in: 0...1) < 0.3 { say(["no more poop!", "sorry, bird"]) }
        case .toaster:
            score += 200
            for _ in 0..<3 { dropJunk(.toast, at: e.pos) }
            audio.play("ding", volume: 0.5, rate: 1.3)
        case .boss:
            score += 5000
            shake = 30
            audio.play("stomp", volume: 1)
            popText("YOU FIRED\nTHE CEO!", at: e.pos + V2(0, 150), color: hex(0xffe14d), size: 60)
            say(["I DID IT", "promotion time!", "take that, capitalism"], priority: true)
            goalVisible = true
            goalNode.isHidden = false
            goalNode.position = CGPoint(x: CGFloat(level.goal.x), y: CGFloat(level.goal.y) + 900)
            goalNode.run(.sequence([.move(to: level.goal.cg, duration: 1.2), .run { [weak self] in
                self?.audio.play("stomp", volume: 0.6, rate: 1.3)
                self?.shake = 12
                self?.puff(at: self?.level.goal ?? .zero, n: 16)
            }]))
            for k in 0..<8 { dropJunk(Junk.allCases[k % 9], at: e.pos + V2(0, 40)) }
            audio.music.style = level.theme.music
            bossAwake = false
            hud.bossBar(nil)
        }
        e.node.run(.sequence([.group([.scale(to: 1.5, duration: 0.12), .fadeOut(withDuration: 0.12)]), .removeFromParent()]))
    }

    private func dropJunk(_ j: Junk, at p: V2) {
        let k = Pickup(.junk(j), at: p, dynamic: true)
        k.vel = V2(frand(-250, 250), frand(350, 650))
        k.spin = frand(-8, 8)
        k.delay = 0.35
        k.life = 30
        addPickup(k)
    }

    private func updateEnemies(_ dt: Float) {
        let pc = player.c
        for e in enemies where !e.dead {
            e.stun -= dt
            e.hurtFlash -= dt
            e.squash = max(0, e.squash - dt * 4)
            let dx = pc.x - e.pos.x
            let near = abs(dx) < 900 && abs(pc.y - e.pos.y) < 600
            switch e.kind {
            case .cube, .toaster, .boss:
                e.vel.y -= 1900 * dt
                if e.kind != .boss || !bossAwake || e.phase != 2 {
                    e.timer -= dt
                }
                if e.grounded {
                    e.angle += wrapAngle(-e.angle) * min(1, 10 * dt)
                    e.spin *= 0.8
                }
                if e.kind == .cube && e.grounded && e.timer <= 0 && e.stun <= 0 {
                    if near && player.ko <= 0 {
                        e.vel = V2((dx >= 0 ? 1 : -1) * frand(200, 300), frand(520, 660))
                        e.facing = dx >= 0 ? 1 : -1
                    } else {
                        e.vel = V2(frand(-60, 60), frand(250, 350))
                    }
                    e.timer = frand(0.9, 1.6)
                    e.squash = 1
                    if near { audio.play("hop", volume: 0.25, rate: frand(0.9, 1.2)) }
                }
                if e.kind == .toaster && e.timer <= 0 && e.stun <= 0 {
                    e.timer = frand(2.0, 2.8)
                    if near && abs(dx) < 850 && player.ko <= 0 {
                        let T = clampf(abs(dx) / 520, 0.6, 1.4)
                        let from = e.pos + V2(0, 40)
                        let dy = pc.y - from.y
                        let v = V2(dx / T, (dy + 0.5 * 1900 * T * T) / T)
                        let toast = Projectile(.toast, at: from, vel: v, hostile: true)
                        projectiles.append(toast)
                        worldNode.addChild(toast.node)
                        audio.play("ding", volume: 0.55)
                        e.squash = 1
                        e.vel.y += 200
                        e.facing = dx >= 0 ? 1 : -1
                    }
                }
                if e.kind == .boss { bossBrain(e, dt) }
                var p = e.pos + e.vel * dt
                var cts: [Contact] = []
                world.resolve(&p, e.r, contacts: &cts)
                let was = e.grounded
                e.grounded = false
                for ct in cts {
                    let vn = dot(e.vel, ct.n)
                    if vn < 0 { e.vel -= ct.n * vn * (ct.solid.kind == .bouncy ? 2.1 : 1) }
                    if ct.n.y > 0.5 {
                        e.grounded = true
                        let fr: Float = ct.solid.kind == .ice ? 0.3 : 10
                        e.vel.x += (ct.solid.vel.x - e.vel.x) * min(1, fr * dt)
                    }
                }
                if e.grounded && !was { e.squash = 0.8; if e.kind == .boss { bossLanded(e) } }
                e.pos = p
                e.angle += e.spin * dt
            case .pigeon:
                if e.hp > 0 {
                    let t = time + e.home.x * 0.01
                    let hoverX = near ? pc.x + sinf(t * 0.7) * 60 : e.home.x + sinf(t * 0.4) * 200
                    let targetY = max(e.home.y, pc.y + 260) + sinf(t * 2.1) * 30
                    let want = V2(clampf((hoverX - e.pos.x) * 1.5, -190, 190), clampf((targetY - e.pos.y) * 2, -160, 160))
                    e.vel += (want - e.vel) * min(1, (e.stun > 0 ? 0.5 : 3) * dt)
                    if e.stun > 0 { e.vel.y -= 400 * dt }
                    e.facing = e.vel.x >= 0 ? 1 : -1
                    e.timer -= dt
                    if near && abs(dx) < 50 && pc.y < e.pos.y && e.timer <= 0 && e.stun <= 0 && player.ko <= 0 {
                        e.timer = frand(1.3, 2.2)
                        let poop = Projectile(.pea, at: e.pos - V2(0, 16), vel: V2(e.vel.x * 0.5, -120), hostile: true, poop: true)
                        projectiles.append(poop)
                        worldNode.addChild(poop.node)
                        audio.play("coo", volume: 0.4, rate: frand(0.9, 1.1))
                    }
                    if Float.random(in: 0...1) < dt * 0.15 && near { audio.play("coo", volume: 0.25) }
                    e.pos += e.vel * dt
                    e.angle = e.vel.x * -0.0012
                    // flap
                    e.bodyNode.yScale = CGFloat(1 + sinf(time * 22 + e.home.x) * 0.08)
                }
            }
            // touching the player
            if !e.dead && player.ko <= 0 && player.flushing < 0 {
                var close = false
                let reach = e.r * (e.kind == .cube || e.kind == .boss ? 1.12 : 1) + Player.pointR
                for q in player.x where (q - e.pos).len < reach { close = true; break }
                if close {
                    let above = player.c.y > e.pos.y + e.r * 0.5 && player.cVel.y < 50
                    if above {
                        // stomped on
                        let wasPound = player.pounding
                        player.shove(V2(0, 0))
                        for i in 0..<Player.N { player.v[i].y = max(player.v[i].y, 820) }
                        player.jolt()
                        damage(e, wasPound ? 3 : 1, dir: V2(dx >= 0 ? -1 : 1, 0), text: wasPound ? "SLAM!" : "BOING!")
                        audio.play("tramp", volume: 0.4, rate: 1.3)
                    } else if player.invuln <= 0 && e.stun <= 0 {
                        hurt(from: e.pos)
                    }
                }
            }
            // visuals
            e.node.position = e.pos.cg
            let sq = e.squash
            e.bodyNode.xScale = CGFloat(1 + sq * 0.18) * (e.kind == .pigeon ? CGFloat(-e.facing) : 1)
            if e.kind != .pigeon { e.bodyNode.yScale = CGFloat(1 - sq * 0.18) }
            e.bodyNode.zRotation = CGFloat(e.angle)
            e.bodyNode.alpha = e.hurtFlash > 0 ? 0.55 : 1
            e.showStars(e.stun > 0 && e.kind != .boss)
            e.updateEyes(dt)
            if e.pos.y < world.killY { e.dead = true; e.node.removeFromParent() }
        }
        enemies.removeAll { $0.dead && $0.node.parent == nil }
    }

    // MARK: Boss

    private func bossBrain(_ e: Enemy, _ dt: Float) {
        guard bossAwake else { e.timer = 1.5; return }
        let dx = player.c.x - e.pos.x
        let rage = 1 - e.hp / e.maxHP
        if e.grounded && e.timer <= 0 && e.stun <= 0 {
            e.vel = V2(clampf(dx * 1.1, -650, 650), 1150 + rage * 200)
            e.timer = 1.7 - rage * 0.8
            e.squash = 1
            e.phase = 2
            audio.play("whoosh", volume: 0.6)
        }
        if e.hp < e.maxHP * 0.66 && e.spawnedMinis == 0 { e.spawnedMinis = 1; spawnMinis(e, 2) }
        if e.hp < e.maxHP * 0.33 && e.spawnedMinis == 1 { e.spawnedMinis = 2; spawnMinis(e, 3) }
    }

    private func spawnMinis(_ boss: Enemy, _ n: Int) {
        popText("INTERNS!", at: boss.pos + V2(0, 160), color: .white, size: 40)
        for k in 0..<n {
            let m = Enemy(.cube, at: boss.pos + V2(Float(k - n / 2) * 70, 140))
            m.vel = V2(Float(k - n / 2) * 250, 600)
            m.timer = 1
            enemies.append(m)
            worldNode.addChild(m.node)
        }
    }

    private func bossLanded(_ e: Enemy) {
        guard bossAwake, e.phase == 2 else { return }
        e.phase = 0
        audio.play("stomp", volume: 0.9)
        shake = max(shake, 18)
        puff(at: e.pos - V2(0, e.r), n: 20)
        for d in [-1, 1] as [Float] {
            let s = Shockwave(x: e.pos.x + d * e.r, y: e.pos.y - e.r + 30, dir: d)
            shocks.append(s)
            worldNode.addChild(s.node)
        }
        if player.grounded { player.jolt(); player.shove(V2(0, 120)) }
    }

    private func updateShocks(_ dt: Float) {
        for s in shocks {
            s.life -= dt
            s.x += s.dir * 640 * dt
            s.node.position = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
            s.node.alpha = CGFloat(min(1, s.life * 3))
            s.node.setScale(CGFloat(1 + (1 - s.life) * 0.4))
            if player.ko <= 0 && player.invuln <= 0 && abs(player.c.x - s.x) < 45 && player.bottom < s.y + 20 && s.life > 0.1 {
                hurt(from: V2(s.x - s.dir * 50, s.y))
            }
        }
        shocks.removeAll { s in if s.life <= 0 { s.node.removeFromParent(); return true }; return false }
    }

    private func updateBoss(_ dt: Float) {
        guard let b = boss, !b.dead, let trig = level.bossTrigger else { return }
        if !bossAwake && player.c.x > trig {
            bossAwake = true
            b.awake = true
            audio.music.style = 3
            hud.banner("MEGA CUBE", "Chief Executive Cube")
            audio.play("stomp", volume: 0.8, rate: 0.8)
            shake = 15
            say(["uh oh.", "that's a big cube", "I'd like to speak to your manager... oh."], priority: true)
        }
        if bossAwake {
            hud.bossBar(b.hp / b.maxHP)
            junkRain -= dt
            if junkRain <= 0 {
                junkRain = 2.2
                let j: Junk = [.duck, .toast, .fish, .cheese, .melon, .bowling, .chicken, .sock, .banana].randomElement()!
                let k = Pickup(.junk(j), at: V2(frand(6700, 8100), camPos.y + 520), dynamic: true)
                k.life = 20
                k.spin = frand(-5, 5)
                addPickup(k)
            }
        }
    }

    // MARK: Player damage

    func hurt(from: V2) {
        guard player.invuln <= 0, player.ko <= 0, player.flushing < 0 else { return }
        let side: Float = player.c.x >= from.x ? 1 : -1
        player.shove(V2(side * 520, 520), spin: frand(2.5, 4.5) * -side)
        player.invuln = 1.4
        player.hurtFace = 0.9
        shake = max(shake, 12)
        player.jolt()
        if player.eyes.count > 0 {
            let at = player.removeEye() ?? player.c
            let k = Pickup(.eye, at: at, dynamic: true)
            k.vel = V2(side * frand(200, 380), frand(600, 800))
            k.delay = 0.9
            k.life = 12
            addPickup(k)
            audio.play("hurt", volume: 0.8)
            if player.eyes.count == 0 { say(["I CAN'T SEE!", "who turned off the world?", "MY EYES! (both of them)"], priority: true) }
            else { say(["MY EYE!", "that was my favourite eye", "I needed that!", "ow ow ow", "not the eye!"], priority: true) }
        } else {
            player.ko = 2.2
            audio.play("ko", volume: 0.8)
            popText("K.O.", at: player.c + V2(0, 90), color: hex(0xff5a5a), size: 50)
            say(["ow.", "I'll just lie here.", "tell my eyes I love them"], priority: true)
        }
    }

    // MARK: Checkpoints

    private func checkCheckpoints() {
        for (k, cp) in level.checkpoints.enumerated() where k > checkpointIdx {
            if player.c.x > cp.x - 20 && abs(player.c.y - cp.y) < 260 {
                checkpointIdx = k
                Scenery.raise(checkpointFlags[k], instant: false)
                audio.play("checkpoint", volume: 0.7)
                popText("CHECKPOINT!", at: cp + V2(0, 200), color: hex(0x9dff8a), size: 30)
                if player.eyes.count < 2 {
                    while player.eyes.count < 2 { player.addEye() }
                    say(["free eyes!", "fresh eyes!"], priority: true)
                }
                storeRun()
            }
        }
    }

    // MARK: Camera

    private func updateCamera(_ dt: Float) {
        let size = scene.size
        let halfW = Float(size.width) * camScale / 2
        var target = player.c + V2(clampf(player.cVel.x * 0.25, -220, 220), 110)
        if state == .title { target = level.start + V2(200, 220) }
        if player.flushing >= 0 || state == .done { target = level.goal + V2(0, 150) }
        if bossAwake, let b = boss, !b.dead { target = (player.c + b.pos) * 0.5 + V2(0, 160) }
        camPos.x += (target.x - camPos.x) * min(1, 5 * dt)
        camPos.y += (target.y - camPos.y) * min(1, 3.2 * dt)
        camPos.x = clampf(camPos.x, world.minX + halfW, max(world.minX + halfW, world.maxX - halfW))
        camPos.y = max(camPos.y, 250)
        shake = max(0, shake - dt * 40)
        let off = V2(frand(-1, 1), frand(-1, 1)) * shake
        cam.position = (camPos + off).cg
        skyNode.position = cam.position
        farLayer.position = CGPoint(x: CGFloat(camPos.x * 0.8), y: CGFloat(camPos.y * 0.85))
        nearLayer.position = CGPoint(x: CGFloat(camPos.x * 0.55), y: CGFloat(camPos.y * 0.6))
    }

    // MARK: Effects

    @discardableResult
    func popText(_ s: String, at p: V2, color c: NSColor, size: CGFloat) -> SKLabelNode {
        let l = label(s, size: size, fill: c)
        l.position = p.cg
        l.zPosition = 90
        l.setScale(0.3)
        l.run(.sequence([.scale(to: 1.15, duration: 0.1), .scale(to: 1, duration: 0.08)]))
        worldNode.addChild(l)
        popups.append((l, 1.1))
        return l
    }

    private func updatePopups(_ dt: Float) {
        for i in popups.indices {
            popups[i].1 -= dt
            popups[i].0.position.y += CGFloat(60 * dt)
            if popups[i].1 < 0.3 { popups[i].0.alpha = CGFloat(max(0, popups[i].1 / 0.3)) }
        }
        popups.removeAll { if $0.1 <= 0 { $0.0.removeFromParent(); return true }; return false }
    }

    func confetti(at p: V2, n: Int) {
        let cols: [UInt32] = [0xff4d6d, 0xffd23f, 0x3bceac, 0x5e60ce, 0xff9f1c, 0xffffff, 0x4cc9f0]
        for _ in 0..<n {
            let s = SKSpriteNode(color: hex(cols.randomElement()!), size: CGSize(width: CGFloat(frand(6, 12)), height: CGFloat(frand(4, 8))))
            s.zPosition = 70
            worldNode.addChild(s)
            let a = frand(0, 2 * .pi), sp = frand(150, 700)
            particles.append(Particle(s, pos: p, vel: V2(cosf(a) * sp, sinf(a) * sp + 250), life: frand(0.9, 1.8), gravity: -900, spin: frand(-12, 12), drag: 1.2, shrink: false))
        }
    }

    func puff(at p: V2, n: Int) {
        guard n > 0 else { return }
        for _ in 0..<n {
            let s = SKShapeNode(circleOfRadius: CGFloat(frand(6, 14)))
            s.fillColor = hex(0xffffff, 0.75)
            s.strokeColor = .clear
            s.zPosition = 55
            worldNode.addChild(s)
            particles.append(Particle(s, pos: p + V2(frand(-30, 30), 4), vel: V2(frand(-220, 220), frand(20, 140)), life: frand(0.35, 0.6), gravity: 0, drag: 4))
        }
    }

    func splat(at p: V2, color c: NSColor) {
        for _ in 0..<10 {
            let s = SKShapeNode(circleOfRadius: CGFloat(frand(3, 7)))
            s.fillColor = c; s.strokeColor = .clear
            s.zPosition = 56
            worldNode.addChild(s)
            particles.append(Particle(s, pos: p, vel: V2(frand(-260, 260), frand(50, 360)), life: frand(0.4, 0.8)))
        }
    }

    func sparkle(at p: V2) {
        for _ in 0..<12 {
            let s = SKLabelNode(text: "✨")
            s.fontSize = CGFloat(frand(14, 26))
            s.zPosition = 70
            worldNode.addChild(s)
            let a = frand(0, 2 * .pi)
            particles.append(Particle(s, pos: p, vel: V2(cosf(a), sinf(a)) * frand(100, 300), life: 0.7, gravity: 0, drag: 3))
        }
    }

    private func updateParticles(_ dt: Float) {
        for p in particles {
            p.life -= dt
            p.vel.y += p.gravity * dt
            p.vel *= max(0, 1 - p.drag * dt)
            p.pos += p.vel * dt
            p.node.position = p.pos.cg
            p.node.zRotation += CGFloat(p.spin * dt)
            let k = max(0, p.life / p.maxLife)
            if p.shrink { p.node.setScale(CGFloat(0.3 + 0.7 * k)) }
            p.node.alpha = CGFloat(min(1, k * 3))
        }
        particles.removeAll { if $0.life <= 0 { $0.node.removeFromParent(); return true }; return false }
    }

    // MARK: Speech

    func say(_ lines: [String], priority: Bool = false) {
        if !priority && quipCooldown > 0 { return }
        guard let s = lines.randomElement() else { return }
        quipCooldown = 3
        bubble?.removeFromParent()
        let b = Scenery.speechBubble(s)
        b.zPosition = 95
        worldNode.addChild(b)
        bubble = b
        bubbleLife = 2.2
        let syll = max(2, min(9, s.count / 3))
        var acts: [SKAction] = []
        let base = frand(1.05, 1.3)
        for k in 0..<syll {
            acts.append(.run { [weak self] in self?.audio.play("voice", volume: 0.35, rate: base * frand(0.88, 1.18) * (k == syll - 1 ? 0.9 : 1), jitter: 0) })
            acts.append(.wait(forDuration: Double(frand(0.07, 0.11))))
        }
        scene.run(.sequence(acts))
        player.mouthOpen = 1
    }

    private func updateBubble(_ dt: Float) {
        guard let b = bubble else { return }
        bubbleLife -= dt
        b.position = CGPoint(x: CGFloat(player.c.x), y: CGFloat(player.top + 28))
        if bubbleLife < 0.3 { b.alpha = CGFloat(max(0, bubbleLife / 0.3)) }
        if bubbleLife <= 0 { b.removeFromParent(); bubble = nil }
        if bubbleLife > 0.2 { player.mouthOpen = max(player.mouthOpen, 0.4 + 0.4 * abs(sinf(time * 25))) }
    }

    func saveNow() { if state == .playing || state == .paused { storeRun() } }
}
