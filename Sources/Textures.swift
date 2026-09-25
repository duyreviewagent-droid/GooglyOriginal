import AppKit
import SceneKit

func makePixelImage(_ w: Int, _ h: Int, _ f: (Int, Int) -> SIMD4<Float>) -> CGImage {
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBufferPointer { buf in
        let p = buf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: h) { y in
            for x in 0..<w {
                let c = f(x, y)
                let a = clampf(c.w, 0, 1)
                let i = (y * w + x) * 4
                p[i] = UInt8(clampf(c.x * a, 0, 1) * 255)
                p[i + 1] = UInt8(clampf(c.y * a, 0, 1) * 255)
                p[i + 2] = UInt8(clampf(c.z * a, 0, 1) * 255)
                p[i + 3] = UInt8(a * 255)
            }
        }
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

/// Tileable value noise.
enum TNoise {
    @inline(__always) static func hash(_ x: Int, _ y: Int, _ s: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ s &* 1_442_695_041)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }
    /// u, v in [0,1); `freq` cells across, wrapping.
    static func value(_ u: Float, _ v: Float, freq: Int, seed: Int) -> Float {
        let x = u * Float(freq), y = v * Float(freq)
        let xi = Int(floorf(x)), yi = Int(floorf(y))
        let fx = x - Float(xi), fy = y - Float(yi)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        func g(_ a: Int, _ b: Int) -> Float { hash(((a % freq) + freq) % freq, ((b % freq) + freq) % freq, seed) }
        let a = g(xi, yi), b = g(xi + 1, yi), c = g(xi, yi + 1), d = g(xi + 1, yi + 1)
        return mixf(mixf(a, b, sx), mixf(c, d, sx), sy)
    }
    static func fbm(_ u: Float, _ v: Float, freq: Int, octaves: Int, seed: Int) -> Float {
        var s: Float = 0, amp: Float = 0.5, f = freq, n: Float = 0
        for o in 0..<octaves { s += (value(u, v, freq: f, seed: seed + o * 17) - 0.5) * 2 * amp; n += amp; amp *= 0.5; f *= 2 }
        return s / n
    }
}

/// Every texture is drawn in code at launch.
enum Tex {
    static func noise(_ size: Int, base: SIMD3<Float>, amt: Float, grain: Int = 8, seed: Int = 3, speck: Float = 0.3,
                      tint2: SIMD3<Float>? = nil) -> CGImage {
        makePixelImage(size, size) { x, y in
            let u = Float(x) / Float(size), v = Float(y) / Float(size)
            let n = TNoise.fbm(u, v, freq: grain, octaves: 4, seed: seed)
            let fine = TNoise.hash(x, y, seed) - 0.5
            var c = base * (1 + n * amt + fine * amt * speck)
            if let t = tint2 {
                let m = smoothstep(0.1, 0.6, TNoise.fbm(u, v, freq: max(2, grain / 2), octaves: 2, seed: seed + 99))
                c = c + (t - c) * m * 0.5
            }
            return SIMD4(c.x, c.y, c.z, 1)
        }
    }

    /// Lawn seen from above: mottled greens with little blade strokes and clover.
    static let grass: CGImage = {
        let base = noise(512, base: SIMD3(0.30, 0.62, 0.22), amt: 0.28, grain: 6, seed: 5, tint2: SIMD3(0.38, 0.70, 0.20))
        return makeImage(512, 512) { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: 512, height: 512))
            var r = RNG(7)
            for _ in 0..<5500 {
                let x = CGFloat(r.range(0, 512)), y = CGFloat(r.range(0, 512))
                let l = CGFloat(r.range(4, 11)), a = CGFloat(r.range(-0.6, 0.6)) + .pi / 2
                let light = r.chance(0.5)
                ctx.setStrokeColor(light ? NSColor(srgbRed: 0.55, green: 0.85, blue: 0.35, alpha: 0.55).cgColor : NSColor(srgbRed: 0.12, green: 0.38, blue: 0.1, alpha: 0.45).cgColor)
                ctx.setLineWidth(1.3)
                for dx in [0, 512, -512] as [CGFloat] {
                    for dy in [0, 512, -512] as [CGFloat] {
                        ctx.move(to: CGPoint(x: x + dx, y: y + dy)); ctx.addLine(to: CGPoint(x: x + dx + cos(a) * l, y: y + dy + sin(a) * l))
                    }
                }
                ctx.strokePath()
            }
            for _ in 0..<40 {
                let x = CGFloat(r.range(20, 492)), y = CGFloat(r.range(20, 492))
                ctx.setFillColor(r.chance(0.3) ? NSColor(white: 1, alpha: 0.85).cgColor : NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 0.85).cgColor)
                for k in 0..<5 {
                    let a = CGFloat(k) / 5 * 2 * .pi
                    ctx.fillEllipse(in: CGRect(x: x + cos(a) * 3 - 2, y: y + sin(a) * 3 - 2, width: 4, height: 4))
                }
            }
        }
    }()

    static let dirt: CGImage = {
        let base = noise(512, base: SIMD3(0.45, 0.29, 0.17), amt: 0.35, grain: 5, seed: 11, tint2: SIMD3(0.36, 0.22, 0.13))
        return makeImage(512, 512) { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: 512, height: 512))
            var r = RNG(13)
            for _ in 0..<220 {
                let x = CGFloat(r.range(10, 502)), y = CGFloat(r.range(10, 502)), s = CGFloat(r.range(3, 12))
                let g = CGFloat(r.range(0.35, 0.65))
                ctx.setFillColor(NSColor(srgbRed: g, green: g * 0.9, blue: g * 0.8, alpha: 0.9).cgColor)
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: s * 1.3, height: s))
                ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
                ctx.fillEllipse(in: CGRect(x: x + s * 0.25, y: y + s * 0.5, width: s * 0.5, height: s * 0.3))
            }
            // strata lines
            ctx.setStrokeColor(NSColor(srgbRed: 0.28, green: 0.17, blue: 0.1, alpha: 0.35).cgColor)
            ctx.setLineWidth(3)
            for k in 0..<4 {
                let y0 = CGFloat(64 + k * 128)
                ctx.move(to: CGPoint(x: 0, y: y0))
                for x in stride(from: 0, through: 512, by: 32) { ctx.addLine(to: CGPoint(x: CGFloat(x), y: y0 + CGFloat(sin(Double(x) * 0.05 + Double(k)) * 8))) }
            }
            ctx.strokePath()
        }
    }()

    static let sand: CGImage = {
        let base = noise(512, base: SIMD3(0.93, 0.76, 0.48), amt: 0.12, grain: 8, seed: 21, speck: 1.2)
        return makeImage(512, 512) { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: 512, height: 512))
            ctx.setStrokeColor(NSColor(srgbRed: 0.8, green: 0.6, blue: 0.35, alpha: 0.35).cgColor)
            ctx.setLineWidth(2.5)
            for k in 0..<8 {
                let y0 = CGFloat(k * 64 + 20)
                ctx.move(to: CGPoint(x: 0, y: y0))
                for x in stride(from: 0, through: 512, by: 16) { ctx.addLine(to: CGPoint(x: CGFloat(x), y: y0 + CGFloat(sin(Double(x) / 512 * 4 * .pi + Double(k)) * 10))) }
            }
            ctx.strokePath()
        }
    }()

    static let sandstone = noise(512, base: SIMD3(0.78, 0.52, 0.30), amt: 0.3, grain: 4, seed: 25, tint2: SIMD3(0.7, 0.42, 0.25))

    static let wood: CGImage = makePixelImage(512, 512) { x, y in
        let u = Float(x) / 512, v = Float(y) / 512
        let s = TNoise.fbm(u, v, freq: 4, octaves: 3, seed: 31)
        let ring = sinf((v * 24 + s * 3) * .pi) * 0.5 + 0.5
        let plank: Float = (y % 128) < 3 ? 0.55 : 1
        let grain: Float = TNoise.fbm(u, v, freq: 16, octaves: 2, seed: 33)
        let k: Float = (0.8 + ring * 0.25 + grain * 0.1) * plank
        return SIMD4<Float>(0.62 * k, 0.40 * k, 0.22 * k, 1)
    }

    /// Office carpet: navy loop pile with a gold diamond lattice, a bit like the casino carpet in GooglyGamble.
    static let carpet: CGImage = {
        let base = noise(512, base: SIMD3(0.16, 0.27, 0.5), amt: 0.12, grain: 32, seed: 41, speck: 1.5)
        return makeImage(512, 512) { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: 512, height: 512))
            ctx.setStrokeColor(NSColor(srgbRed: 0.85, green: 0.68, blue: 0.3, alpha: 0.8).cgColor)
            ctx.setLineWidth(4)
            for k in stride(from: -512, through: 1024, by: 128) {
                ctx.move(to: CGPoint(x: CGFloat(k), y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(k) + 512, y: 512))
                ctx.move(to: CGPoint(x: CGFloat(k), y: 512)); ctx.addLine(to: CGPoint(x: CGFloat(k) + 512, y: 0))
            }
            ctx.strokePath()
            for gx in stride(from: 0, through: 512, by: 128) {
                for gy in stride(from: 64, through: 512, by: 128) {
                    for (x, y) in [(gx, gy), (gx + 64, gy - 64)] {
                        ctx.setFillColor(NSColor(srgbRed: 0.9, green: 0.35, blue: 0.3, alpha: 0.9).cgColor)
                        ctx.fillEllipse(in: CGRect(x: x - 10, y: y - 10, width: 20, height: 20))
                        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1).cgColor)
                        ctx.fillEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                    }
                }
            }
        }
    }()

    static let concrete = noise(512, base: SIMD3(0.56, 0.58, 0.64), amt: 0.14, grain: 6, seed: 51, speck: 1.4)

    static let ice: CGImage = {
        let base = noise(256, base: SIMD3(0.72, 0.9, 1.0), amt: 0.08, grain: 4, seed: 61)
        return makeImage(256, 256) { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: 256, height: 256))
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.7).cgColor)
            ctx.setLineWidth(2)
            var r = RNG(3)
            for _ in 0..<14 {
                let x = CGFloat(r.range(0, 256)), y = CGFloat(r.range(0, 256))
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + CGFloat(r.range(-40, 40)), y: y + CGFloat(r.range(-40, 40))))
            }
            ctx.strokePath()
        }
    }()

    static let hillGrass = noise(256, base: SIMD3(0.42, 0.72, 0.36), amt: 0.2, grain: 4, seed: 71)

    /// A tiled PBR material whose texture repeats every `tile` world units.
    static func tiled(_ img: CGImage, sx: Float, sy: Float, tile: Float, rough: CGFloat = 0.9, tint: NSColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = img
        if let t = tint { m.multiply.contents = t }
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(CGFloat(sx / tile), CGFloat(sy / tile), 1)
        m.roughness.contents = rough
        return m
    }
}
