// Turns level data into three.js objects: sky, distant hills, clouds, ground, platforms, props, fans,
// decor and signs — a port of Scenery.swift `build` / `solidNode` / `props`.
import * as THREE from 'three';
import { RNG } from './util.js';
import { tiled } from './textures.js';
import { mat, sphereGeo, cylGeo, torusGeo, roundedBoxGeo, decorModel, makeSign, setShadows } from './models.js';

// ------------------------------------------------------------------ shared materials

const worldMatCache = new Map();
/** Tiled material for geometry whose UVs are in world units: repeats every `tile` units. */
function worldTiled(name, tile, rough, extra = null) {
  const key = `${name}|${tile}|${rough}|${extra ? JSON.stringify(extra) : ''}`;
  let m = worldMatCache.get(key);
  if (!m) {
    m = tiled(name, 1, 1, tile, { rough });
    if (extra) {
      const p = new THREE.MeshPhysicalMaterial({ map: m.map, roughness: rough, ...extra });
      m.dispose();
      m = p;
    }
    worldMatCache.set(key, m);
  }
  return m;
}

let _fenceMat = null, _cubicleMat = null, _rockMat = null, _tuftGeo = null;
const fenceMat = () => _fenceMat ??= tiled('wood', 60, 60, 120, { rough: 0.8, tint: 0xfff3e0 });
const cubicleMat = () => _cubicleMat ??= tiled('cubicle', 100, 100, 60, { rough: 1 });
const rockMat = () => _rockMat ??= tiled('sandstone', 100, 100, 120, { rough: 0.9 });
const tuftMats = [null, null];
function tuftMat(desert) {
  const i = desert ? 1 : 0;
  return tuftMats[i] ??= new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.9, transparent: desert, opacity: desert ? 0.9 : 1 });
}

/** The 5-blade grass tuft as one merged geometry with vertex colours. */
function tuftGeo() {
  if (_tuftGeo) return _tuftGeo;
  const parts = [];
  const c1 = new THREE.Color(0x3f9c34), c2 = new THREE.Color(0x62c44a);
  for (let k = 0; k < 5; k++) {
    const a = k / 5 * 2 * Math.PI;
    const g = new THREE.CylinderGeometry(0, 2.2, 12 + k * 2, 6).toNonIndexed();
    const o = new THREE.Object3D();
    o.position.set(Math.cos(a) * 3, 6 + k, Math.sin(a) * 3);
    o.rotation.order = 'YXZ';
    o.rotation.set(Math.sin(a) * 0.35, 0, -Math.cos(a) * 0.35);
    o.updateMatrix();
    g.applyMatrix4(o.matrix);
    const col = k % 2 === 0 ? c1 : c2;
    const n = g.attributes.position.count, C = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) { C[i * 3] = col.r; C[i * 3 + 1] = col.g; C[i * 3 + 2] = col.b; }
    g.setAttribute('color', new THREE.BufferAttribute(C, 3));
    parts.push(g);
  }
  _tuftGeo = mergeNonIndexed(parts, ['position', 'normal', 'color']);
  return _tuftGeo;
}

function mergeNonIndexed(geos, names) {
  const out = new THREE.BufferGeometry();
  for (const name of names) {
    const size = geos[0].attributes[name].itemSize;
    const total = geos.reduce((s, g) => s + g.attributes[name].array.length, 0);
    const arr = new Float32Array(total);
    let off = 0;
    for (const g of geos) { arr.set(g.attributes[name].array, off); off += g.attributes[name].array.length; }
    out.setAttribute(name, new THREE.BufferAttribute(arr, size));
  }
  out.computeBoundingSphere();
  return out;
}

// ------------------------------------------------------------------ sky

function skyTexture(bottom, top) {
  // PMREM sizes its cube from width / 4, so the equirect must be reasonably wide
  const W = 256, H = 256;
  const data = new Uint8Array(W * H * 4);
  const cb = [(bottom >> 16) & 255, (bottom >> 8) & 255, bottom & 255], ct = [(top >> 16) & 255, (top >> 8) & 255, top & 255];
  for (let y = 0; y < H; y++) {
    const v = y / (H - 1);                       // row 0 = bottom of the texture
    const t = v <= 0.45 ? 0 : (v - 0.45) / 0.55;
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      for (let c = 0; c < 3; c++) data[i + c] = Math.round(cb[c] + (ct[c] - cb[c]) * t);
      data[i + 3] = 255;
    }
  }
  const tex = new THREE.DataTexture(data, W, H, THREE.RGBAFormat);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.mapping = THREE.EquirectangularReflectionMapping;
  tex.magFilter = THREE.LinearFilter;
  tex.minFilter = THREE.LinearFilter;
  tex.wrapS = THREE.RepeatWrapping;
  tex.needsUpdate = true;
  return tex;
}

// ------------------------------------------------------------------ build

export function buildScenery(level, root, scene) {
  const th = level.theme;
  const animated = { clouds: [], blades: [], fans: [] };

  const sky = skyTexture(th.skyBottom, th.skyTop);
  if (scene) {
    scene.background = sky;
    scene.environment = sky;           // lightingEnvironment = background, intensity 0.8
    scene.environmentIntensity = 0.8;
    scene.fog = new THREE.Fog(th.skyBottom, 2600, 9000);
  }

  // backdrop: big soft hills, clouds
  const r = new RNG((level.name || '').length * 31 + 7);
  const hillM = tiled('hillGrass', 4, 2, 1, { rough: 0.95, tint: th.hillNear });
  const hillF = tiled('hillGrass', 3, 2, 1, { rough: 1, tint: th.hillFar });
  const hillGeo = sphereGeo(1, 32);
  let x = level.minX - 1500;
  while (x < level.maxX + 1500) {
    const far = r.chance(0.5);
    const rad = r.range(500, 1100);
    const h = new THREE.Mesh(hillGeo, far ? hillF : hillM);
    h.scale.set(1.4 * rad, r.range(0.35, 0.6) * rad, rad);
    h.position.set(x, -250, far ? r.range(-3600, -2800) : r.range(-2200, -1300));
    h.receiveShadow = false; h.castShadow = false;
    h.name = 'hill';
    root.add(h);
    x += r.range(500, 900);
  }
  const cloudM = mat(0xffffff, 1, 0, 0x595959);
  const cloudGeo = sphereGeo(1, 16);
  x = level.minX - 800;
  while (x < level.maxX + 800) {
    const cl = new THREE.Group();
    cl.name = 'cloud';
    for (let k = 0; k < 5; k++) {
      const rad = r.range(60, 110);
      const s = new THREE.Mesh(cloudGeo, cloudM);
      s.scale.setScalar(rad);
      s.position.set(k * 70 - 140, r.range(-20, 30), r.range(-30, 30));
      cl.add(s);
    }
    cl.scale.set(1, 0.6, 0.7);
    cl.position.set(x, r.range(700, 1100), r.range(-2600, -900));
    animated.clouds.push({ node: cl, x0: cl.position.x });
    root.add(cl);
    x += r.range(600, 1200);
  }

  const tufts = { lawn: [], desert: [] };
  for (const s of level.solids) if (!s.hidden) root.add(solidNode(s, th, tufts));
  for (const key of ['lawn', 'desert']) {
    const list = tufts[key];
    if (!list.length) continue;
    const im = new THREE.InstancedMesh(tuftGeo(), tuftMat(key === 'desert'), list.length);
    list.forEach((m, i) => im.setMatrixAt(i, m));
    im.instanceMatrix.needsUpdate = true;
    im.castShadow = false; im.receiveShadow = false;
    im.computeBoundingSphere();
    im.name = 'tufts';
    root.add(im);
  }

  for (const f of level.fans) root.add(fanNode(f, animated));

  for (const d of level.decor) {
    const m = decorModel(d.kind);
    m.position.set(d.pos.x, d.pos.y, d.pos.z);
    m.scale.setScalar(d.scale);
    m.rotation.y = r.range(0, 6.28);
    root.add(m);
  }
  for (const sg of level.signs) {
    const s = makeSign(sg.text);
    s.position.set(sg.pos.x, sg.pos.y, sg.pos.z);
    root.add(s);
  }

  let clock = 0;
  return {
    tick(dt) {
      clock += dt;
      // clouds: moveBy +300 over 30 s, then back, forever
      const ph = clock % 60, off = (ph < 30 ? ph : 60 - ph) / 30 * 300;
      for (const c of animated.clouds) c.node.position.x = c.x0 + off;
      for (const b of animated.blades) b.rotation.y += 12 * dt;
      for (const f of animated.fans) f.tick(dt);
    },
  };
}

// ------------------------------------------------------------------ solids

function solidNode(s, th, tufts) {
  const holder = new THREE.Group();
  holder.name = `solid-${s.kind}`;
  const midZ = (s.z0 + s.z1) / 2, depth = s.z1 - s.z0;

  if (s.kind === 'bouncy') {
    const w = s.hi.x - s.lo.x, h = s.hi.y - s.lo.y;
    holder.position.set((s.lo.x + s.hi.x) / 2, s.lo.y, midZ);
    const pad = new THREE.Mesh(cylGeo(w / 2, h), mat(0xff4f8b, 0.35));
    pad.position.y = h / 2;
    const rim = new THREE.Mesh(torusGeo(w / 2, 5, 12, 48), mat(0xffffff, 0.4));
    rim.position.y = h;
    const dot = new THREE.Mesh(cylGeo(w / 4, 1), mat(0xffffff, 0.4));
    dot.position.y = h + 0.6;
    holder.add(pad, rim, dot);
    setShadows(holder, true, true);
    s.node = holder;
    return holder;
  }

  if (s.kind === 'mover') {
    // build at the rest pose: the physics sets holder.position to the moving offset
    const pts = s.base && s.base.length ? s.base : s.pts;
    const z0 = s.baseZ ? s.baseZ[0] : s.z0, z1 = s.baseZ ? s.baseZ[1] : s.z1;
    let lx = Infinity, ly = Infinity, hx = -Infinity, hy = -Infinity;
    for (const p of pts) { lx = Math.min(lx, p.x); ly = Math.min(ly, p.y); hx = Math.max(hx, p.x); hy = Math.max(hy, p.y); }
    const w = hx - lx, h = hy - ly, d = z1 - z0;
    const plank = new THREE.Mesh(roundedBoxGeo(w, h, d, 5), mat(0x9c6b3e, 0.8));
    plank.position.set((lx + hx) / 2, (ly + hy) / 2, (z0 + z1) / 2);
    for (let k = 0; k < 3; k++) {
      const strip = new THREE.Mesh(roundedBoxGeo(w + 1, 3, 6), mat(0x6e4726, 0.9));
      strip.position.set(0, h / 2 + 0.5, (k - 1) * d * 0.3);
      plank.add(strip);
    }
    holder.add(plank);
    setShadows(holder, true, true);
    s.node = holder;
    return holder;
  }

  // ground / platform / ice: extruded polygon, bevelled 6 inside its outline
  const isPlat = s.kind === 'platform', isIce = s.kind === 'ice';
  const bev = Math.min(6, depth / 4);
  const shape = new THREE.Shape(s.pts.map(p => new THREE.Vector2(p.x, p.y)));
  const geo = new THREE.ExtrudeGeometry(shape, {
    depth: depth - 2 * bev, bevelEnabled: true, bevelThickness: bev, bevelSize: bev, bevelOffset: -bev, bevelSegments: 2,
  });
  geo.translate(0, 0, s.z0 + bev);
  // WorldUVGenerator gives world-unit UVs on caps and walls
  const side = isIce ? worldTiled('ice', 200, 0.05) : worldTiled(isPlat ? th.platSideTex : th.sideTex, isPlat ? 180 : 260, 0.9);
  const body = new THREE.Mesh(geo, side);
  body.castShadow = true; body.receiveShadow = true;
  holder.add(body);

  // grass / carpet / ice slabs along upward faces
  const topM = isIce
    ? worldTiled('ice', 200, 0.02, { metalness: 0.1, clearcoat: 1 })
    : worldTiled(isPlat ? th.platTopTex : th.topTex, 300, 0.95);
  const cnt = s.pts.length;
  for (let i = 0; i < cnt; i++) {
    if (s.normals[i].y <= 0.6) continue;
    const a = s.pts[i], b = s.pts[(i + 1) % cnt];
    const len = Math.hypot(b.x - a.x, b.y - a.y);
    const slab = new THREE.Mesh(roundedBoxGeo(len + 4, 12, depth + 6, 5, true), topM);
    slab.position.set((a.x + b.x) / 2, (a.y + b.y) / 2 - 4, midZ);
    slab.rotation.z = Math.atan2(b.y - a.y, b.x - a.x) + (b.x < a.x ? Math.PI : 0);
    slab.castShadow = true; slab.receiveShadow = true;
    holder.add(slab);
    if (Math.abs(s.normals[i].y) > 0.98 && !isIce) {
      props(holder, Math.min(a.x, b.x), Math.max(a.x, b.x), a.y, s.z0, s.z1, th, isPlat, tufts);
    }
  }
  return holder;
}

// ------------------------------------------------------------------ props

const f32 = Math.fround;
const tmpO = new THREE.Object3D();

/** Small props on a flat top: grass tufts, back fences, cubicle partitions, desert rocks. */
function props(n, x0, x1, y, z0, z1, th, plat, tufts) {
  const r = new RNG(Math.floor(f32(f32(f32(Math.abs(x0) * 13) + f32(Math.abs(y) * 7)) + 5)));
  if (th.props === 0 || th.props === 1) {
    const count = Math.floor((x1 - x0) * (z1 - z0) / (th.props === 0 ? 9000 : 30000));
    const list = th.props === 1 ? tufts.desert : tufts.lawn;
    for (let i = 0; i < Math.min(count, 260); i++) {
      const px = r.range(x0 + 8, x1 - 8), pz = r.range(z0 + 8, z1 - 8);
      let sc = r.range(0.7, 1.5);
      const ry = r.range(0, 6.28);
      if (th.props === 1) sc *= 0.7;
      tmpO.position.set(px, y + 1, pz);
      tmpO.rotation.set(0, ry, 0);
      tmpO.scale.setScalar(sc);
      tmpO.updateMatrix();
      list.push(tmpO.matrix.clone());
    }
  }
  if (plat || !(z0 < -300)) return;
  const zb = z0 + 12;
  if (th.props === 0) {
    // white picket fence along the back
    const xs = [];
    for (let x = x0 + 30; x < x1 - 30; x += 24) xs.push(x);
    if (xs.length) {
      const posts = new THREE.InstancedMesh(roundedBoxGeo(8, 70, 6, 2), fenceMat(), xs.length);
      xs.forEach((x, i) => { tmpO.position.set(x, y + 35, zb); tmpO.rotation.set(0, 0, 0); tmpO.scale.setScalar(1); tmpO.updateMatrix(); posts.setMatrixAt(i, tmpO.matrix); });
      posts.instanceMatrix.needsUpdate = true;
      posts.computeBoundingSphere();
      posts.castShadow = true; posts.receiveShadow = true;
      posts.name = 'fence';
      n.add(posts);
    }
    if (x1 - x0 - 60 > 0) {
      for (const ry of [22, 52]) {
        const rail = new THREE.Mesh(roundedBoxGeo(x1 - x0 - 60, 6, 4, 1), fenceMat());
        rail.position.set((x0 + x1) / 2, y + ry, zb - 5);
        rail.castShadow = true; rail.receiveShadow = true;
        n.add(rail);
      }
    }
  } else if (th.props === 2) {
    const trim = mat(0x9aa0aa, 0.4, 0.7);
    for (let x = x0 + 40; x < x1 - 160; x += 190) {
      const panel = new THREE.Mesh(roundedBoxGeo(150, 110, 8, 3), cubicleMat());
      panel.position.set(x + 75, y + 55, zb);
      const top = new THREE.Mesh(roundedBoxGeo(152, 6, 10), trim);
      top.position.set(0, 56, 0);
      panel.add(top);
      setShadows(panel, true, true);
      n.add(panel);
    }
  } else if (th.props === 1) {
    const g = sphereGeo(1, 12);
    let x = x0 + r.range(50, 200);
    while (x < x1 - 50) {
      const rad = r.range(25, 55);
      const rock = new THREE.Mesh(g, rockMat());
      const sx = r.range(1, 1.6), sy = r.range(0.5, 0.9);
      rock.scale.set(sx * rad, sy * rad, rad);
      rock.position.set(x, y + 5, zb + r.range(0, 20));
      rock.castShadow = true; rock.receiveShadow = true;
      n.add(rock);
      x += r.range(200, 450);
    }
  }
}

// ------------------------------------------------------------------ fans

function fanNode(f, animated) {
  const w = f.hi.x - f.lo.x, d = f.hi.z - f.lo.z, cx = (f.lo.x + f.hi.x) / 2;
  const g = new THREE.Group();
  g.name = 'fan';
  const unit = new THREE.Group();
  unit.position.set(cx, -160, 0);
  unit.add(new THREE.Mesh(roundedBoxGeo(w, 40, d, 8), mat(0x6b7280, 0.4, 0.6)));
  const blades = new THREE.Group();
  const bm = mat(0x30343c, 0.5, 0.5);
  for (let k = 0; k < 4; k++) {
    const b = new THREE.Mesh(roundedBoxGeo(w * 0.9, 4, 26), bm);
    b.rotation.y = k * Math.PI / 4;
    blades.add(b);
  }
  blades.position.set(0, 24, 0);
  unit.add(blades);
  setShadows(unit, true, true);
  animated.blades.push(blades);
  g.add(unit);

  // updraft streaks: 90/s, 1.3 s life, 800±200 up, stretched by 0.06·v, white 0.55 additive
  const N = 130, emY = -130;
  const P = new Float32Array(N * 6);
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.BufferAttribute(P, 3));
  const lines = new THREE.LineSegments(geo, new THREE.LineBasicMaterial({
    color: 0xffffff, transparent: true, opacity: 0.55, blending: THREE.AdditiveBlending, depthWrite: false,
  }));
  lines.frustumCulled = false;
  lines.name = 'fanStreaks';
  g.add(lines);
  const parts = Array.from({ length: N }, () => ({ age: 1e9, x: 0, y: 0, z: 0, v: 0 }));
  let acc = 0, cursor = 0;
  const spawn = q => {
    q.x = cx + (Math.random() - 0.5) * w;
    q.z = (Math.random() - 0.5) * d;
    q.y = emY;
    q.v = 800 + (Math.random() * 2 - 1) * 200;
    q.age = 0;
  };
  // pre-warm so the column is full on the first frame
  for (let i = 0; i < N; i++) { spawn(parts[i]); parts[i].age = (i / N) * 1.3; parts[i].y = emY + parts[i].v * parts[i].age; }
  animated.fans.push({
    tick(dt) {
      acc += dt * 90;
      while (acc >= 1) {
        acc -= 1;
        for (let k = 0; k < N; k++) {
          const q = parts[(cursor + k) % N];
          if (q.age >= 1.3) { spawn(q); cursor = (cursor + k + 1) % N; break; }
        }
      }
      for (let i = 0; i < N; i++) {
        const q = parts[i], o = i * 6;
        q.age += dt;
        if (q.age < 1.3) {
          q.y += q.v * dt;
          const len = q.v * 0.06;
          P[o] = q.x; P[o + 1] = q.y; P[o + 2] = q.z;
          P[o + 3] = q.x; P[o + 4] = q.y - len; P[o + 5] = q.z;
        } else {
          P[o] = P[o + 3] = q.x; P[o + 1] = P[o + 4] = -1e5; P[o + 2] = P[o + 5] = q.z;
        }
      }
      geo.attributes.position.needsUpdate = true;
    },
  });
  return g;
}

