// Procedural tileable textures — a port of Textures.swift. Every texture is drawn in code on first use.
// Noise passes are computed per pixel (same formulas as the Mac app); the stroke/ellipse passes use a
// canvas 2D context flipped so that y points up, like a CGContext. Without a DOM (node smoke tests)
// only the per-pixel base layer is produced, as a DataTexture.
import * as THREE from 'three';
import { RNG, clamp, smoothstep } from './util.js';

const HAS_DOM = typeof document !== 'undefined';

// ---- Tileable value noise (TNoise)

function hash(x, y, s) {
  let h = (Math.imul(x, 374761393) + Math.imul(y, 668265263) + Math.imul(s, 1442695041)) >>> 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177) >>> 0;
  h = (h ^ (h >>> 16)) >>> 0;
  return (h & 0xFFFF) / 65535;
}

/** u, v in [0,1); `freq` cells across, wrapping. */
function value(u, v, freq, seed) {
  const x = u * freq, y = v * freq;
  const xi = Math.floor(x), yi = Math.floor(y);
  const fx = x - xi, fy = y - yi;
  const sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy);
  const x0 = ((xi % freq) + freq) % freq, y0 = ((yi % freq) + freq) % freq;
  const x1 = (((xi + 1) % freq) + freq) % freq, y1 = (((yi + 1) % freq) + freq) % freq;
  const a = hash(x0, y0, seed), b = hash(x1, y0, seed), c = hash(x0, y1, seed), d = hash(x1, y1, seed);
  const ab = a + (b - a) * sx, cd = c + (d - c) * sx;
  return ab + (cd - ab) * sy;
}

function fbm(u, v, freq, octaves, seed) {
  let s = 0, amp = 0.5, f = freq, n = 0;
  for (let o = 0; o < octaves; o++) { s += (value(u, v, f, seed + o * 17) - 0.5) * 2 * amp; n += amp; amp *= 0.5; f *= 2; }
  return s / n;
}

/** RGBA bytes from f(x, y) -> [r, g, b] (0..1, sRGB). Row 0 is the top of the image, like a CGImage. */
function pixels(w, h, f) {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const c = f(x, y), i = (y * w + x) * 4;
      data[i] = Math.floor(clamp(c[0], 0, 1) * 255);
      data[i + 1] = Math.floor(clamp(c[1], 0, 1) * 255);
      data[i + 2] = Math.floor(clamp(c[2], 0, 1) * 255);
      data[i + 3] = 255;
    }
  }
  return { w, h, data };
}

function noise(size, base, amt, { grain = 8, seed = 3, speck = 0.3, tint2 = null } = {}) {
  const g2 = Math.max(2, Math.floor(grain / 2));
  return pixels(size, size, (x, y) => {
    const u = x / size, v = y / size;
    const n = fbm(u, v, grain, 4, seed);
    const fine = hash(x, y, seed) - 0.5;
    const k = 1 + n * amt + fine * amt * speck;
    let r = base[0] * k, g = base[1] * k, b = base[2] * k;
    if (tint2) {
      const m = smoothstep(0.1, 0.6, fbm(u, v, g2, 2, seed + 99)) * 0.5;
      r += (tint2[0] - r) * m; g += (tint2[1] - g) * m; b += (tint2[2] - b) * m;
    }
    return [r, g, b];
  });
}

const rgba = (r, g, b, a = 1) => `rgba(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)},${a})`;

/** Base pixels plus an optional canvas drawing pass (CG-style coordinates: origin bottom-left). */
function compose(img, draw) {
  if (!HAS_DOM) return img;
  const cv = document.createElement('canvas');
  cv.width = img.w; cv.height = img.h;
  const ctx = cv.getContext('2d');
  ctx.putImageData(new ImageData(img.data, img.w, img.h), 0, 0);
  if (draw) {
    ctx.save();
    ctx.setTransform(1, 0, 0, -1, 0, img.h);
    ctx.lineCap = 'butt';
    draw(ctx);
    ctx.restore();
  }
  return cv;
}

function ellipse(ctx, x, y, w, h) {
  ctx.beginPath();
  ctx.ellipse(x + w / 2, y + h / 2, w / 2, h / 2, 0, 0, Math.PI * 2);
  ctx.fill();
}

const GEN = {
  /** Lawn seen from above: mottled greens with little blade strokes and clover. */
  grass: () => compose(noise(512, [0.30, 0.62, 0.22], 0.28, { grain: 6, seed: 5, tint2: [0.38, 0.70, 0.20] }), ctx => {
    const r = new RNG(7);
    ctx.lineWidth = 1.3;
    const light = rgba(0.55, 0.85, 0.35, 0.55), dark = rgba(0.12, 0.38, 0.1, 0.45);
    for (let i = 0; i < 5500; i++) {
      const x = r.range(0, 512), y = r.range(0, 512);
      const l = r.range(4, 11), a = r.range(-0.6, 0.6) + Math.PI / 2;
      ctx.strokeStyle = r.chance(0.5) ? light : dark;
      ctx.beginPath();
      const ex = Math.cos(a) * l, ey = Math.sin(a) * l;
      for (const dx of [0, 512, -512]) for (const dy of [0, 512, -512]) {
        ctx.moveTo(x + dx, y + dy); ctx.lineTo(x + dx + ex, y + dy + ey);
      }
      ctx.stroke();
    }
    for (let i = 0; i < 40; i++) {
      const x = r.range(20, 492), y = r.range(20, 492);
      ctx.fillStyle = r.chance(0.3) ? 'rgba(255,255,255,0.85)' : rgba(1, 0.85, 0.2, 0.85);
      for (let k = 0; k < 5; k++) {
        const a = k / 5 * 2 * Math.PI;
        ellipse(ctx, x + Math.cos(a) * 3 - 2, y + Math.sin(a) * 3 - 2, 4, 4);
      }
    }
  }),

  dirt: () => compose(noise(512, [0.45, 0.29, 0.17], 0.35, { grain: 5, seed: 11, tint2: [0.36, 0.22, 0.13] }), ctx => {
    const r = new RNG(13);
    for (let i = 0; i < 220; i++) {
      const x = r.range(10, 502), y = r.range(10, 502), s = r.range(3, 12);
      const g = r.range(0.35, 0.65);
      ctx.fillStyle = rgba(g, g * 0.9, g * 0.8, 0.9);
      ellipse(ctx, x, y, s * 1.3, s);
      ctx.fillStyle = 'rgba(255,255,255,0.25)';
      ellipse(ctx, x + s * 0.25, y + s * 0.5, s * 0.5, s * 0.3);
    }
    // strata lines
    ctx.strokeStyle = rgba(0.28, 0.17, 0.1, 0.35);
    ctx.lineWidth = 3;
    ctx.beginPath();
    for (let k = 0; k < 4; k++) {
      const y0 = 64 + k * 128;
      ctx.moveTo(0, y0);
      for (let x = 0; x <= 512; x += 32) ctx.lineTo(x, y0 + Math.sin(x * 0.05 + k) * 8);
    }
    ctx.stroke();
  }),

  sand: () => compose(noise(512, [0.93, 0.76, 0.48], 0.12, { grain: 8, seed: 21, speck: 1.2 }), ctx => {
    ctx.strokeStyle = rgba(0.8, 0.6, 0.35, 0.35);
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    for (let k = 0; k < 8; k++) {
      const y0 = k * 64 + 20;
      ctx.moveTo(0, y0);
      for (let x = 0; x <= 512; x += 16) ctx.lineTo(x, y0 + Math.sin(x / 512 * 4 * Math.PI + k) * 10);
    }
    ctx.stroke();
  }),

  sandstone: () => compose(noise(512, [0.78, 0.52, 0.30], 0.3, { grain: 4, seed: 25, tint2: [0.7, 0.42, 0.25] })),

  wood: () => compose(pixels(512, 512, (x, y) => {
    const u = x / 512, v = y / 512;
    const s = fbm(u, v, 4, 3, 31);
    const ring = Math.sin((v * 24 + s * 3) * Math.PI) * 0.5 + 0.5;
    const plank = (y % 128) < 3 ? 0.55 : 1;
    const grain = fbm(u, v, 16, 2, 33);
    const k = (0.8 + ring * 0.25 + grain * 0.1) * plank;
    return [0.62 * k, 0.40 * k, 0.22 * k];
  })),

  /** Office carpet: navy loop pile with a gold diamond lattice. */
  carpet: () => compose(noise(512, [0.16, 0.27, 0.5], 0.12, { grain: 32, seed: 41, speck: 1.5 }), ctx => {
    ctx.strokeStyle = rgba(0.85, 0.68, 0.3, 0.8);
    ctx.lineWidth = 4;
    ctx.beginPath();
    for (let k = -512; k <= 1024; k += 128) {
      ctx.moveTo(k, 0); ctx.lineTo(k + 512, 512);
      ctx.moveTo(k, 512); ctx.lineTo(k + 512, 0);
    }
    ctx.stroke();
    for (let gx = 0; gx <= 512; gx += 128) {
      for (let gy = 64; gy <= 512; gy += 128) {
        for (const [x, y] of [[gx, gy], [gx + 64, gy - 64]]) {
          ctx.fillStyle = rgba(0.9, 0.35, 0.3, 0.9);
          ellipse(ctx, x - 10, y - 10, 20, 20);
          ctx.fillStyle = rgba(1, 0.85, 0.4, 1);
          ellipse(ctx, x - 4, y - 4, 8, 8);
        }
      }
    }
  }),

  concrete: () => compose(noise(512, [0.56, 0.58, 0.64], 0.14, { grain: 6, seed: 51, speck: 1.4 })),

  ice: () => compose(noise(256, [0.72, 0.9, 1.0], 0.08, { grain: 4, seed: 61 }), ctx => {
    ctx.strokeStyle = 'rgba(255,255,255,0.7)';
    ctx.lineWidth = 2;
    const r = new RNG(3);
    ctx.beginPath();
    for (let i = 0; i < 14; i++) {
      const x = r.range(0, 256), y = r.range(0, 256);
      const ex = x + r.range(-40, 40), ey = y + r.range(-40, 40);
      ctx.moveTo(x, y); ctx.lineTo(ex, ey);
    }
    ctx.stroke();
  }),

  hillGrass: () => compose(noise(256, [0.42, 0.72, 0.36], 0.2, { grain: 4, seed: 71 })),

  /** Cubicle partition fabric (Scenery.cubicleMat). */
  cubicle: () => compose(noise(128, [0.55, 0.6, 0.72], 0.15, { grain: 16, seed: 81, speck: 2 })),
};

const cache = new Map();

/** Base texture by name (cached). RepeatWrapping, sRGB, anisotropy 8, mipmaps. */
export function texture(name) {
  let t = cache.get(name);
  if (t) return t;
  const gen = GEN[name];
  if (!gen) throw new Error(`unknown texture '${name}'`);
  const src = gen();
  if (HAS_DOM) {
    t = new THREE.CanvasTexture(src);
  } else {
    t = new THREE.DataTexture(new Uint8Array(src.data.buffer), src.w, src.h, THREE.RGBAFormat);
    t.flipY = false;
    t.magFilter = THREE.LinearFilter;
  }
  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 8;
  t.generateMipmaps = true;
  t.minFilter = THREE.LinearMipmapLinearFilter;
  t.name = name;
  t.needsUpdate = true;
  cache.set(name, t);
  return t;
}

/** A tiled PBR material whose texture repeats every `tile` world units across a sx × sy face. */
export function tiled(name, sx, sy, tile, { rough = 0.9, tint = null, metal = 0 } = {}) {
  const map = texture(name).clone();
  map.repeat.set(sx / tile, sy / tile);
  map.needsUpdate = true;
  const m = new THREE.MeshStandardMaterial({ map, roughness: rough, metalness: metal });
  if (tint !== null && tint !== undefined) m.color.setHex(tint);
  return m;
}
