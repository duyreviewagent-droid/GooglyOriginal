// Small vector + helper toolkit shared by every module. Coordinates match the Mac app:
// Y up, the course runs along +X, the camera sits on the +Z side looking toward -Z.
export class V3 {
  constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }
  set(x, y, z) { this.x = x; this.y = y; this.z = z; return this; }
  copy(v) { this.x = v.x; this.y = v.y; this.z = v.z; return this; }
  clone() { return new V3(this.x, this.y, this.z); }
  add(v) { return new V3(this.x + v.x, this.y + v.y, this.z + v.z); }
  sub(v) { return new V3(this.x - v.x, this.y - v.y, this.z - v.z); }
  mul(s) { return new V3(this.x * s, this.y * s, this.z * s); }
  mulv(v) { return new V3(this.x * v.x, this.y * v.y, this.z * v.z); }
  addi(v) { this.x += v.x; this.y += v.y; this.z += v.z; return this; }
  subi(v) { this.x -= v.x; this.y -= v.y; this.z -= v.z; return this; }
  muli(s) { this.x *= s; this.y *= s; this.z *= s; return this; }
  addScaled(v, s) { this.x += v.x * s; this.y += v.y * s; this.z += v.z * s; return this; }
  dot(v) { return this.x * v.x + this.y * v.y + this.z * v.z; }
  cross(v) { return new V3(this.y * v.z - this.z * v.y, this.z * v.x - this.x * v.z, this.x * v.y - this.y * v.x); }
  get len() { return Math.hypot(this.x, this.y, this.z); }
  get norm() { const l = this.len; return l > 1e-6 ? new V3(this.x / l, this.y / l, this.z / l) : new V3(); }
  get flat() { return new V3(this.x, 0, this.z); }
  get xzLen() { return Math.hypot(this.x, this.z); }
}
export const v3 = (x = 0, y = 0, z = 0) => new V3(x, y, z);

export const clamp = (x, a, b) => Math.min(Math.max(x, a), b);
export const mix = (a, b, t) => a + (b - a) * t;
export const smoothstep = (e0, e1, x) => { const t = clamp((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t); };
export const wrapAngle = a => { let x = (a + Math.PI) % (2 * Math.PI); if (x < 0) x += 2 * Math.PI; return x - Math.PI; };
export const frand = (a, b) => a + (b - a) * Math.random();
export const pick = arr => arr[Math.floor(Math.random() * arr.length)];
export const hex = h => '#' + (h >>> 0).toString(16).padStart(6, '0');

/// splitmix64, identical to the Mac app's RNG so levels (decor, enemy lanes) match between Mac and browser.
export class RNG {
  constructor(seed) { this.s = BigInt.asUintN(64, BigInt(Math.floor(seed))); }
  next() {
    this.s = BigInt.asUintN(64, this.s + 0x9E3779B97F4A7C15n);
    let z = this.s;
    z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n);
    z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94D049BB133111EBn);
    return z ^ (z >> 31n);
  }
  float() { return Number(this.next() >> 40n) / 16777216; }
  range(a, b) { return a + (b - a) * this.float(); }
  chance(p) { return this.float() < p; }
  int(n) { return Number(this.next() % BigInt(n)); }
}

// ---- 3×3 matrices (column-major, as arrays of 9) and quaternions for the jelly shape matching
export const M3 = {
  identity: () => [1, 0, 0, 0, 1, 0, 0, 0, 1],
  zero: () => [0, 0, 0, 0, 0, 0, 0, 0, 0],
  // m * v
  mulv: (m, v) => new V3(m[0] * v.x + m[3] * v.y + m[6] * v.z, m[1] * v.x + m[4] * v.y + m[7] * v.z, m[2] * v.x + m[5] * v.y + m[8] * v.z),
  mulvInto: (m, x, y, z, out) => { out.x = m[0] * x + m[3] * y + m[6] * z; out.y = m[1] * x + m[4] * y + m[7] * z; out.z = m[2] * x + m[5] * y + m[8] * z; return out; },
  mul: (a, b) => {
    const r = new Array(9);
    for (let c = 0; c < 3; c++) for (let rw = 0; rw < 3; rw++) r[c * 3 + rw] = a[rw] * b[c * 3] + a[3 + rw] * b[c * 3 + 1] + a[6 + rw] * b[c * 3 + 2];
    return r;
  },
  scale: (m, s) => m.map(x => x * s),
  add: (a, b) => a.map((x, i) => x + b[i]),
  det: m => m[0] * (m[4] * m[8] - m[7] * m[5]) - m[3] * (m[1] * m[8] - m[7] * m[2]) + m[6] * (m[1] * m[5] - m[4] * m[2]),
  inverse: m => {
    const d = M3.det(m); if (Math.abs(d) < 1e-12) return M3.identity();
    const k = 1 / d;
    return [
      (m[4] * m[8] - m[5] * m[7]) * k, (m[2] * m[7] - m[1] * m[8]) * k, (m[1] * m[5] - m[2] * m[4]) * k,
      (m[5] * m[6] - m[3] * m[8]) * k, (m[0] * m[8] - m[2] * m[6]) * k, (m[2] * m[3] - m[0] * m[5]) * k,
      (m[3] * m[7] - m[4] * m[6]) * k, (m[1] * m[6] - m[0] * m[7]) * k, (m[0] * m[4] - m[1] * m[3]) * k,
    ];
  },
  col: (m, c) => new V3(m[c * 3], m[c * 3 + 1], m[c * 3 + 2]),
  fromCols: (a, b, c) => [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z],
};

export class Quat {
  constructor(x = 0, y = 0, z = 0, w = 1) { this.x = x; this.y = y; this.z = z; this.w = w; }
  static axisAngle(ax, ang) { const s = Math.sin(ang / 2); const a = ax.norm; return new Quat(a.x * s, a.y * s, a.z * s, Math.cos(ang / 2)); }
  mul(q) { // this * q
    return new Quat(
      this.w * q.x + this.x * q.w + this.y * q.z - this.z * q.y,
      this.w * q.y - this.x * q.z + this.y * q.w + this.z * q.x,
      this.w * q.z + this.x * q.y - this.y * q.x + this.z * q.w,
      this.w * q.w - this.x * q.x - this.y * q.y - this.z * q.z);
  }
  normalize() { const l = Math.hypot(this.x, this.y, this.z, this.w) || 1; this.x /= l; this.y /= l; this.z /= l; this.w /= l; return this; }
  toM3() {
    const { x, y, z, w } = this;
    return [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w),
            2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w),
            2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)];
  }
  slerp(q, t) {
    let cos = this.x * q.x + this.y * q.y + this.z * q.z + this.w * q.w;
    let qx = q.x, qy = q.y, qz = q.z, qw = q.w;
    if (cos < 0) { cos = -cos; qx = -qx; qy = -qy; qz = -qz; qw = -qw; }
    let a = 1 - t, b = t;
    if (cos < 0.9995) { const th = Math.acos(cos), s = Math.sin(th); a = Math.sin((1 - t) * th) / s; b = Math.sin(t * th) / s; }
    return new Quat(this.x * a + qx * b, this.y * a + qy * b, this.z * a + qz * b, this.w * a + qw * b).normalize();
  }
}

/// Rotation that best matches a 3×3 matrix (Müller et al. 2016), warm-started from q.
export function extractRotation(A, q0, iterations = 6) {
  let q = q0;
  for (let i = 0; i < iterations; i++) {
    const R = q.toM3();
    const r0 = M3.col(R, 0), r1 = M3.col(R, 1), r2 = M3.col(R, 2);
    const a0 = M3.col(A, 0), a1 = M3.col(A, 1), a2 = M3.col(A, 2);
    const num = r0.cross(a0).add(r1.cross(a1)).add(r2.cross(a2));
    const den = Math.abs(r0.dot(a0) + r1.dot(a1) + r2.dot(a2)) + 1e-9;
    const w = num.mul(1 / den);
    const a = w.len;
    if (a < 1e-9) break;
    q = Quat.axisAngle(w, a).mul(q).normalize();
  }
  return q;
}
