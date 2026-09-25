import SpriteKit

struct Theme {
    var skyTop: NSColor, skyBottom: NSColor
    var ground: NSColor, groundEdge: NSColor, groundTop: NSColor
    var platform: NSColor, platformTop: NSColor
    var hillFar: NSColor, hillNear: NSColor
    var decor: [String]
    var music: Int
    var topTex: CGImage = Tex.grass, sideTex: CGImage = Tex.dirt, platTopTex: CGImage = Tex.grass, platSideTex: CGImage = Tex.wood
    var props = 0       // 0 fences, 1 desert rocks, 2 cubicle walls
}

/// Everything a level is made of, before it is turned into nodes. The course runs along +X;
/// the ground is a wide strip in Z you can wander across (and fall off).
final class LevelData {
    static let groundHalf: Float = 330, platHalf: Float = 170
    var name = "", subtitle = ""
    var theme: Theme
    var solids: [Solid] = []
    var fans: [Fan] = []
    var pickups: [(Pickup.What, V3)] = []
    var enemies: [(Enemy.Kind, V3)] = []
    var checkpoints: [V3] = []
    var signs: [(String, V3)] = []
    var decor: [(String, V3, Float)] = []
    var goal = V3(0, 0, 0)
    var goalHidden = false
    var start = V3(0, 80, 0)
    var minX: Float = -300, maxX: Float = 8000
    var bossTrigger: Float?
    private var rng = RNG(99)

    init(theme: Theme) { self.theme = theme }

    // MARK: builder

    func ground(_ x0: Float, _ x1: Float, y: Float = 0, ice: Bool = false) {
        let h = LevelData.groundHalf
        solids.append(Solid([V2(x0, y - 700), V2(x1, y - 700), V2(x1, y), V2(x0, y)], z0: -h, z1: h, kind: ice ? .ice : .ground))
    }
    func plat(_ x0: Float, _ top: Float, w: Float, h: Float = 34) {
        let d = min(LevelData.platHalf, max(70, w * 0.6))
        solids.append(Solid([V2(x0, top - h), V2(x0 + w, top - h), V2(x0 + w, top), V2(x0, top)], z0: -d, z1: d, kind: .platform))
    }
    func wall(_ x0: Float, _ x1: Float, top: Float) {
        let h = LevelData.groundHalf + 200
        solids.append(Solid([V2(x0, -700), V2(x1, -700), V2(x1, top), V2(x0, top)], z0: -h, z1: h, kind: .ground))
        // an invisible barrier above it, too tall to super-jump over
        let b = Solid([V2(x0, top), V2(x1, top), V2(x1, top + 1600), V2(x0, top + 1600)], z0: -h, z1: h, kind: .ground)
        b.hidden = true
        solids.append(b)
    }
    func ramp(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float) {
        let base = min(y0, y1) - 700, h = LevelData.groundHalf
        solids.append(Solid([V2(x0, base), V2(x1, base), V2(x1, y1), V2(x0, y0)], z0: -h, z1: h, kind: .ground))
    }
    func tramp(_ x: Float, _ top: Float, w: Float = 120) {
        solids.append(Solid([V2(x, top - 22), V2(x + w, top - 22), V2(x + w, top), V2(x, top)], z0: -w / 2, z1: w / 2, kind: .bouncy))
    }
    func mover(_ x0: Float, _ top: Float, w: Float, dx: Float = 0, dy: Float = 0, dz: Float = 0, speed: Float = 1, phase: Float = 0) {
        let d: Float = 110
        let s = Solid([V2(x0, top - 26), V2(x0 + w, top - 26), V2(x0 + w, top), V2(x0, top)], z0: -d, z1: d, kind: .mover)
        s.base = s.pts
        s.baseZ = (-d, d)
        s.amp = V3(dx, dy, dz)
        s.speed = speed
        s.phase = phase
        s.friction = 0.2
        solids.append(s)
    }
    func fan(_ x0: Float, _ x1: Float, bottom: Float, top: Float, power: Float = 3600) {
        let h = (x1 - x0) / 2 + 20
        fans.append(Fan(lo: V3(x0, bottom, -h), hi: V3(x1, top, h), power: power))
    }
    func item(_ j: Junk, _ x: Float, _ y: Float, z: Float = 0) { pickups.append((.junk(j), V3(x, y, z))) }
    func row(_ j: Junk, _ x0: Float, _ y: Float, _ n: Int, gap: Float = 55, z: Float = 0) {
        for i in 0..<n { item(j, x0 + Float(i) * gap, y, z: z) }
    }
    func arc(_ j: Junk, _ x0: Float, _ y: Float, _ n: Int, gap: Float = 50, h: Float = 90) {
        for i in 0..<n {
            let t = Float(i) / Float(max(1, n - 1))
            item(j, x0 + Float(i) * gap, y + sinf(t * .pi) * h)
        }
    }
    func eye(_ x: Float, _ y: Float, z: Float = 0) { pickups.append((.eye, V3(x, y, z))) }
    func enemy(_ k: Enemy.Kind, _ x: Float, _ groundY: Float) {
        let r: Float = k == .cube ? 30 : k == .toaster ? 32 : k == .boss ? 105 : 22
        let z: Float = k == .boss ? 0 : rng.range(-140, 140)
        enemies.append((k, V3(x, groundY + r + (k == .pigeon ? 0 : 2), z)))
    }
    func check(_ x: Float, _ y: Float) { checkpoints.append(V3(x, y, -120)) }
    func sign(_ s: String, _ x: Float, _ y: Float = 0) { signs.append((s, V3(x, y, -250))) }
    func deco(_ x0: Float, _ x1: Float, y: Float, every: Float = 120, seed: UInt64 = 1) {
        var r = RNG(seed &+ UInt64(abs(x0) * 7))
        var x = x0 + r.range(20, every)
        while x < x1 - 20 {
            let e = theme.decor[r.int(theme.decor.count)]
            let side: Float = r.chance(0.5) ? 1 : -1
            let z = side * r.range(250, LevelData.groundHalf - 25)
            decor.append((e, V3(x, y, z), r.range(0.7, 1.4)))
            x += r.range(every * 0.5, every * 1.3)
        }
    }

    // MARK: levels

    static let names = ["The Backyard of Destiny", "The Desert of Mild Inconvenience", "Cube Corp HQ"]

    static func make(_ i: Int) -> LevelData {
        switch i {
        case 1: return desert()
        case 2: return office()
        default: return backyard()
        }
    }

    static func backyard() -> LevelData {
        let L = LevelData(theme: Theme(skyTop: hex(0x5fb8ff), skyBottom: hex(0xd8f1ff), ground: hex(0x8a5a36), groundEdge: hex(0x5a3820),
                                       groundTop: hex(0x5cc94a), platform: hex(0xb07a48), platformTop: hex(0x74d65e),
                                       hillFar: hex(0x9fd9a0), hillNear: hex(0x6cc070), decor: ["🌷", "🌻", "🌼", "🍄", "🌳", "🌿", "🪨"], music: 0))
        L.name = names[0]; L.subtitle = "Level 1"
        L.minX = -300; L.maxX = 7700
        L.ground(-600, 1500)
        L.deco(-500, 1500, y: 0)
        L.sign("WASD to wobble around\nSPACE to jump", 120)
        L.row(.duck, 330, 90, 5)
        L.plat(780, 100, w: 220)
        L.arc(.duck, 800, 150, 4, gap: 55, h: 40)
        L.sign("Hold SHIFT to squish.\nLet go to go BOING.", 1150)
        L.eye(1340, 330)
        // plateau that needs a super jump
        L.ground(1500, 2700, y: 210)
        L.deco(1520, 2700, y: 210, seed: 2)
        L.sign("CLICK to spit stuff you\npicked up at the mouse.", 1640, 210)
        L.row(.toast, 1800, 290, 4)
        L.enemy(.cube, 2250, 210)
        L.row(.duck, 2400, 290, 3)
        L.sign("SHIFT in the air\n= BUTT SLAM", 2560, 210)
        // drop down, a trampoline and a high ledge
        L.ground(2860, 4250)
        L.deco(2880, 4250, y: 0, seed: 3)
        L.check(3000, 0)
        L.tramp(3300, 14)
        L.sign("Trampoline.\nLegally a hat.", 3150)
        L.plat(3420, 560, w: 320)
        L.item(.melon, 3500, 620); L.eye(3640, 630)
        L.row(.fish, 3450, 110, 4)
        L.enemy(.pigeon, 3900, 380)
        L.enemy(.cube, 3950, 0)
        L.row(.sock, 4000, 90, 3)
        L.enemy(.pigeon, 4300, 420)
        L.ground(4250, 5200)
        L.deco(4270, 5200, y: 0, seed: 4)
        L.enemy(.cube, 4600, 0)
        L.enemy(.cube, 4950, 0)
        L.plat(4700, 110, w: 160)
        L.arc(.chicken, 4720, 170, 3, gap: 60, h: 30)
        // a gap with a stepping stone
        L.plat(5290, 40, w: 110, h: 30)
        L.sign("Mind the gap\n(it's rude)", 5080)
        L.ground(5470, 7700)
        L.deco(5490, 6400, y: 0, seed: 5)
        L.check(5600, 0)
        L.row(.banana, 5700, 90, 3)
        L.enemy(.toaster, 6150, 0)
        L.sign("Toasters: grumpy,\nbut generous", 5900)
        L.ramp(6400, 6700, 0, 150)
        L.ground(6700, 7700, y: 150)
        L.deco(6720, 7700, y: 150, seed: 6)
        L.enemy(.cube, 6950, 150)
        L.row(.cheese, 6800, 230, 2, gap: 80)
        L.goal = V3(7400, 150, 0)
        L.wall(7700, 8000, top: 420)
        return L
    }

    static func desert() -> LevelData {
        let L = LevelData(theme: Theme(skyTop: hex(0xff9d5c), skyBottom: hex(0xffe6a6), ground: hex(0xd9a35f), groundEdge: hex(0x9a6a33),
                                       groundTop: hex(0xf2c77e), platform: hex(0xb9854a), platformTop: hex(0xe8b96c),
                                       hillFar: hex(0xf0bf86), hillNear: hex(0xe0a568), decor: ["🌵", "🌵", "🪨", "🦴", "🌵", "🐚"], music: 1,
                                       topTex: Tex.sand, sideTex: Tex.sandstone, platTopTex: Tex.sand, platSideTex: Tex.wood, props: 1))
        L.name = names[1]; L.subtitle = "Level 2"
        L.minX = -300; L.maxX = 8400
        L.ground(-600, 1200)
        L.deco(-500, 1200, y: 0)
        L.sign("It's a dry heat.", 150)
        L.row(.banana, 350, 90, 3)
        L.row(.fish, 700, 90, 3)
        L.enemy(.cube, 950, 0)
        L.mover(1250, 20, w: 160, dx: 110, speed: 1.3)
        L.ground(1620, 2850)
        L.deco(1640, 2850, y: 0, seed: 11)
        L.check(1720, 0)
        L.enemy(.cube, 2050, 0)
        L.enemy(.cube, 2350, 0)
        L.enemy(.toaster, 2650, 0)
        L.row(.cheese, 1900, 90, 2, gap: 90)
        L.item(.bowling, 2200, 100)
        L.sign("This fan is\nload-bearing", 2760)
        L.fan(2870, 3090, bottom: -700, top: 620, power: 3500)
        L.plat(3120, 470, w: 480)
        L.eye(3350, 560)
        L.row(.sock, 3200, 540, 3)
        L.enemy(.pigeon, 3500, 700)
        L.ground(3600, 5000)
        L.deco(3620, 4550, y: 0, seed: 12)
        L.check(3700, 0)
        L.enemy(.pigeon, 3950, 380)
        L.enemy(.pigeon, 4300, 400)
        L.row(.duck, 3850, 90, 6, gap: 60)
        L.sign("Going up!\n(probably)", 4450)
        L.mover(4600, 190, w: 150, dy: 190, speed: 1.1)
        L.ground(4800, 6000, y: 390)
        L.deco(4820, 6000, y: 390, seed: 13)
        L.enemy(.cube, 5100, 390)
        L.enemy(.cube, 5350, 390)
        L.enemy(.toaster, 5700, 390)
        L.row(.melon, 5000, 470, 2, gap: 200)
        L.row(.chicken, 5450, 470, 3)
        L.ground(6280, 8400)
        L.deco(6300, 8400, y: 0, seed: 14)
        L.check(6400, 0)
        L.tramp(6700, 14)
        L.plat(6600, 520, w: 90)
        L.eye(6645, 600)
        L.enemy(.pigeon, 6900, 380)
        L.enemy(.cube, 7050, 0)
        L.enemy(.pigeon, 7300, 420)
        L.enemy(.cube, 7600, 0)
        L.enemy(.toaster, 7800, 0)
        L.row(.banana, 7000, 90, 3)
        L.goal = V3(8150, 0, 0)
        L.wall(8400, 8700, top: 300)
        return L
    }

    static func office() -> LevelData {
        let L = LevelData(theme: Theme(skyTop: hex(0x3f6fb8), skyBottom: hex(0xf2c9a0), ground: hex(0x8a90a6), groundEdge: hex(0x4b5263),
                                       groundTop: hex(0x3d6fb0), platform: hex(0x8d6e52), platformTop: hex(0xc9a27a),
                                       hillFar: hex(0x9aa4d6), hillNear: hex(0x7f8cc4), decor: ["🪴", "🗄️", "🖨️", "🪴", "📦", "🧯"], music: 2,
                                       topTex: Tex.carpet, sideTex: Tex.concrete, platTopTex: Tex.wood, platSideTex: Tex.concrete, props: 2))
        L.name = names[2]; L.subtitle = "Level 3"
        L.minX = -300; L.maxX = 8200
        L.ground(-600, 1500)
        L.deco(-500, 1500, y: 0)
        L.sign("CUBE CORP\nThinking inside the box since 1987", 150)
        L.row(.toast, 350, 90, 4)
        L.enemy(.cube, 900, 0)
        L.enemy(.cube, 1200, 0)
        L.ground(1500, 2350, ice: true)
        L.sign("CAUTION: WET FLOOR\n(extremely)", 1420)
        L.enemy(.cube, 1900, 0)
        L.row(.duck, 1600, 90, 8, gap: 70)
        L.ground(2350, 3150)
        // filing-cabinet stairs up to the mezzanine
        L.plat(2450, 100, w: 180, h: 100)
        L.plat(2700, 195, w: 180, h: 195)
        L.plat(2950, 290, w: 200, h: 290)
        L.check(2400, 0)
        L.enemy(.toaster, 2800, 0)
        L.ground(3150, 4450, y: 290)
        L.deco(3170, 4450, y: 290, seed: 21)
        L.enemy(.cube, 3500, 290)
        L.enemy(.cube, 3800, 290)
        L.enemy(.pigeon, 3700, 650)
        L.row(.bowling, 3300, 370, 2, gap: 300)
        L.row(.cheese, 3950, 370, 3)
        L.ramp(4450, 4700, 290, 0)
        L.ground(4700, 4850)
        L.sign("Air vent.\nDo not ride.", 4760)
        L.fan(4860, 5100, bottom: -700, top: 560, power: 3500)
        L.plat(5110, 340, w: 420)
        L.eye(5320, 420)
        L.ground(5530, 8200)
        L.deco(5550, 6500, y: 0, seed: 22)
        L.check(5650, 0)
        L.enemy(.toaster, 5950, 0)
        L.enemy(.toaster, 6250, 0)
        L.row(.melon, 5800, 90, 2, gap: 250)
        L.row(.chicken, 6050, 90, 3)
        L.sign("CEO'S OFFICE\nknock first", 6550)
        L.bossTrigger = 6750
        L.enemy(.boss, 7500, 0)
        L.goal = V3(7400, 0, 0)
        L.goalHidden = true
        L.wall(8200, 8500, top: 420)
        return L
    }
}
