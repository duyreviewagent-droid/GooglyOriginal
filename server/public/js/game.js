// The game: solo, couch co-op and online. A port of Game.swift + Online.swift + Players.swift, speaking the
// same network protocol as the Mac app so browsers and Macs can share a lobby.
import * as THREE from 'three';
import { V3, clamp, wrapAngle, frand, pick } from './util.js';
import { World } from './world.js';
import { makeLevel, LEVEL_NAMES } from './levels.js';
import { Player, PLAYER_COLORS, PLAYER_NAMES, MAX_EYES } from './player.js';
import { Pickup, Projectile, Enemy, Particle, Shockwave, JUNK, JUNK_INFO, ENEMY_KINDS } from './things.js';
import { makeFlag, raiseFlag, makeToilet, makeCrown, tickModels } from './models.js';
import { buildScenery } from './scenery.js';
import { Schemes, joinPressed, readActions } from './input.js';
import { Net } from './net.js';

const N = Player.N;
const QUIPS = {
  duck: ['a duck!', 'quack?', 'mine now'], toast: ['toast!', 'bread, but hot'], fish: ['a fish? on land?', 'smells fishy'],
  banana: ['banana! (it comes back)', 'potassium!'], sock: ['ew. a sock.', "it's still warm..."], cheese: ['the big cheese', 'cheeeese'],
  melon: ['one (1) melon', 'melon time'], bowling: ['this is heavy', 'a bowling ball??'], chicken: ['a chicken!!', 'BAWK'], pea: ['pea'],
};

class Slot {
  constructor(index, scheme, name = null) {
    this.index = index; this.scheme = scheme; this.netName = name;
    this.body = new Player(PLAYER_COLORS[index]);
    this.inventory = [];
    this.fireCooldown = 0; this.honkCooldown = 0; this.jumpBuffer = 0; this.quipCooldown = 0; this.idleTime = 0;
    this.bubble = null; this.bubbleLife = 0;
    this.voicePitch = [1.18, 0.92, 1.05, 1.35][index];
    this.bonks = 0; this.collected = 0; this.falls = 0; this.teleports = 0; this.flushOrder = -1;
    this.demoHold = 0; this.demoBack = 0; this.aimPoint = null;
    this.behind = false; this.blindDrift = { x: 0, y: 0 };
    this.lastSafe = new V3(0, 80, 0);
    this.placeCount = 0; this.jumpCount = 0;
    this.remote = { move: { x: 0, y: 0 }, squish: false, jump: 0, fire: 0, honk: 0, teleport: 0, aim: null, pos: null, vel: new V3(), placeAck: 0, seenJump: 0, seenFire: 0, seenHonk: 0, seenTeleport: 0 };
    this.netTarget = null; this.netVel = new V3();
    this.lastCtl = { move: { x: 0, y: 0 }, jump: false, squish: false };
    this.tag = null;
  }
  get name() { return this.netName || 'P' + (this.index + 1); }
  get color() { return PLAYER_COLORS[this.index]; }
}

function loadSave() {
  try { const s = JSON.parse(localStorage.getItem('googly.save.web.v1')); if (s) return { unlocked: 1, best: [0, 0, 0], wins: 0, run: null, ...s }; } catch {}
  return { unlocked: 1, best: [0, 0, 0], wins: 0, run: null };
}

export class Game {
  constructor({ renderer, scene, camera, audio, input, hudClass, hudRoot }) {
    this.renderer = renderer; this.scene = scene; this.camera = camera; this.audio = audio; this.input = input;
    this.save = loadSave();
    this.state = 'title';
    this.levelIndex = 0; this.level = null; this.world = new World();
    this.slots = []; this.titleBody = new Player(PLAYER_COLORS[0]); this.titleBody.setEyes(2);
    this.leader = null;
    this.pickups = []; this.projectiles = []; this.enemies = []; this.particles = []; this.shocks = []; this.popups = [];
    this.score = 0; this.levelStartScore = 0;
    this.checkpointIdx = -1; this.checkpointFlags = [];
    this.goalNode = null; this.goalVisible = true; this.goalDrop = -1;
    this.flushT = -1;
    this.camTarget = new V3(0, 100, 0); this.camDist = 1; this.shake = 0;
    this.time = 0; this.saveTimer = 0;
    this.boss = null; this.bossAwake = false; this.junkRain = 0; this.doneTimer = 0;
    this.demo = false; this.titleHop = 1.5; this.bounceSoundCooldown = 0; this.levelTime = 0;
    // online
    this.role = 'offline'; this.net = null; this.mySeat = 0; this.titleMode = 'main';
    this.codeEntry = ''; this.lobbyCode = ''; this.lobbyList = []; this.lobbyLevel = 0; this.netError = '';
    this.evOut = []; this.nextNetID = 0; this.snapTimer = 0; this.inputTimer = 0; this.listTimer = 0; this.snapCount = 0;
    this.menuOpen = false; this.netEnemyTargets = new Map(); this.lastSnapAt = 0;
    this.name = Net.playerName;

    this.worldNode = new THREE.Group(); scene.add(this.worldNode);
    this.sceneryTick = null;
    // lights
    this.sun = new THREE.DirectionalLight(0xfff0d8, 2.4);
    this.sun.castShadow = true;
    this.sun.shadow.mapSize.set(2048, 2048);
    const sc = this.sun.shadow.camera; sc.left = -900; sc.right = 900; sc.top = 900; sc.bottom = -900; sc.near = 10; sc.far = 6000;
    this.sun.shadow.bias = -0.0006; this.sun.shadow.normalBias = 2;
    scene.add(this.sun); scene.add(this.sun.target);
    this.sunDir = new THREE.Vector3(-0.45, 1, 0.55).normalize();
    scene.add(new THREE.HemisphereLight(0xcfe0ff, 0x6a5a40, 1.0));
    const fill = new THREE.DirectionalLight(0xffd8c0, 0.5); fill.position.set(-1, 0.4, -1); scene.add(fill);
    this.reticle = new THREE.Mesh(new THREE.TorusGeometry(18, 2.5, 8, 32).rotateX(-Math.PI / 2), new THREE.MeshBasicMaterial({ color: 0xffe14d }));
    this.reticle.visible = false; scene.add(this.reticle);
    this.crown = makeCrown(); this.crown.visible = false; scene.add(this.crown);
    this.raycaster = new THREE.Raycaster();

    this.hud = new hudClass(hudRoot, this);
    this.loadLevel(0);
    this.hud.showTitle();
    this.audio.setMusic(4);
    this.hookTestFlags();
  }

  get player() { return this.slots.length ? this.slots[0].body : this.titleBody; }
  get multi() { return this.slots.length > 1; }
  slot(seat) { return this.slots.find(s => s.index === seat) || null; }
  setName(n) { this.name = (n || '').trim().slice(0, 14) || this.name; Net.setPlayerName(this.name); }

  // ================================================================ players
  join(scheme, seat = null, name = null) {
    if (this.slots.length >= 4 || this.slots.some(s => s.scheme.id === scheme.id)) return null;
    let idx = seat;
    if (idx === null) idx = [0, 1, 2, 3].find(i => !this.slots.some(s => s.index === i)) ?? this.slots.length;
    if (this.slot(idx)) return null;
    const s = new Slot(idx, scheme, name);
    s.body.setEyes(2);
    this.slots.push(s); this.slots.sort((a, b) => a.index - b.index);
    s.tag = this.hud.tag(s);
    this.worldNode.remove(this.titleBody.root);
    this.worldNode.add(s.body.root);
    let at;
    const L = this.leader || this.slots.find(o => o !== s);
    if (this.state === 'playing' && L) at = L.body.c.add(new V3(-70, 110, s.index % 2 === 0 ? -60 : 60));
    else at = this.spawnPoint(s.index);
    s.body.place(at); s.lastSafe = at.clone(); s.body.invuln = 1.2;
    if (this.role === 'host' && this.state === 'playing') this.placeSlot(s, at);
    this.audio.play('checkpoint', 0.6, 1 + s.index * 0.12);
    if (this.state === 'playing') { this.puff(at, 10); this.popText(`${s.name} JOINED!`, at.add(new V3(0, 90, 0)), s.color, 26); }
    return s;
  }
  removeSlot(seat) {
    const s = this.slot(seat); if (!s) return;
    this.worldNode.remove(s.body.root);
    s.tag?.remove(); s.bubble?.remove();
    this.slots = this.slots.filter(x => x !== s);
    if (this.leader === s) this.leader = null;
    if (this.state === 'playing') this.hud.toast(`${s.name} LEFT`);
    if (!this.slots.length) this.worldNode.add(this.titleBody.root);
  }
  clearSlots() {
    for (const s of this.slots) { this.worldNode.remove(s.body.root); s.tag?.remove(); s.bubble?.remove(); }
    this.slots = []; this.leader = null;
  }
  spawnPoint(i) {
    const base = this.checkpointIdx >= 0 ? this.level.checkpoints[this.checkpointIdx].add(new V3(0, 90, 120)) : this.level.start;
    return base.add(new V3((i % 2) * 90 - 45, 0, Math.floor(i / 2) * 110 - 55 + (i % 2) * 30));
  }
  freeSchemes() {
    if (this.role !== 'offline') return [];
    const all = [Schemes.keysA, Schemes.keysB, ...this.input.pads.map((_, i) => Schemes.pad(i))];
    return all.filter(sc => !this.slots.some(s => s.scheme.id === sc.id));
  }

  // ================================================================ level setup
  loadLevel(i, checkpoint = -1) {
    this.levelIndex = i;
    this.level = makeLevel(i);
    const w = new World();
    w.solids = this.level.solids; w.fans = this.level.fans; w.minX = this.level.minX; w.maxX = this.level.maxX;
    this.world = w;
    this.scene.remove(this.worldNode);
    this.worldNode = new THREE.Group(); this.scene.add(this.worldNode);
    this.pickups = []; this.projectiles = []; this.enemies = []; this.particles = []; this.shocks = [];
    for (const p of this.popups) p.el.remove();
    this.popups = [];
    for (const s of this.slots) { s.bubble?.remove(); s.bubble = null; s.flushOrder = -1; }
    this.boss = null; this.bossAwake = false; this.flushT = -1;
    this.hud.bossBar(null);
    this.netEnemyTargets.clear();
    this.checkpointFlags = [];
    this.sceneryTick = buildScenery(this.level, this.worldNode, this.scene).tick;
    this.nextNetID = 0;
    for (const p of this.level.pickups) this.addPickup(new Pickup(p.what, p.pos));
    this.nextNetID = 2000;
    for (const e of this.level.enemies) this.addEnemy(new Enemy(e.kind, e.pos));
    this.nextNetID = 5000;
    for (const cp of this.level.checkpoints) { const f = makeFlag(); f.position.set(cp.x, cp.y, cp.z); this.worldNode.add(f); this.checkpointFlags.push(f); }
    this.goalNode = makeToilet();
    this.goalNode.position.set(this.level.goal.x, this.level.goal.y, this.level.goal.z);
    this.goalVisible = !this.level.goalHidden; this.goalNode.visible = this.goalVisible; this.goalDrop = -1;
    this.worldNode.add(this.goalNode);
    this.checkpointIdx = checkpoint;
    this.checkpointFlags.forEach((f, k) => { if (k <= checkpoint) raiseFlag(f, true); });
    if (!this.slots.length) { this.worldNode.add(this.titleBody.root); this.titleBody.place(this.level.start); }
    for (const s of this.slots) { this.worldNode.add(s.body.root); s.body.place(this.spawnPoint(s.index)); s.lastSafe = s.body.c.clone(); }
    this.camTarget = this.player.c.clone();
    this.levelTime = 0;
    this.audio.setMusic(this.level.theme.music);
  }
  addEnemy(e) { if (e.netID < 0) e.netID = this.nextNetID++; this.enemies.push(e); this.worldNode.add(e.node); if (e.kind === 'boss') this.boss = e; }
  addPickup(p) { if (p.netID < 0) p.netID = this.nextNetID++; this.pickups.push(p); this.worldNode.add(p.node); }
  addProjectile(p) { if (p.netID < 0) p.netID = this.nextNetID++; this.projectiles.push(p); this.worldNode.add(p.node); }

  startLevel(i, fresh) {
    if (!this.slots.length) this.join(Schemes.keysA, null, this.role === 'offline' ? null : this.name);
    if (fresh) { this.score = 0; for (const s of this.slots) { s.inventory = []; s.body.setEyes(2); } }
    this.levelStartScore = this.score;
    for (const s of this.slots) { s.bonks = 0; s.collected = 0; s.falls = 0; s.teleports = 0; if (s.body.eyes.length < 2) s.body.setEyes(2); }
    this.state = 'playing';
    this.loadLevel(i);
    if (this.role === 'host') { this.net?.send({ t: 'start', level: i }); this.evOut = []; }
    this.titleMode = 'main'; this.titleCountdown = null;
    this.hud.hideTitle(); this.hud.hidePanel();
    this.hud.banner(this.level.subtitle.toUpperCase() + (this.multi ? ` · ${this.slots.length} PLAYERS` : ''), this.level.name);
    this.audio.play('checkpoint', 0.5);
    this.storeRun();
  }
  continueRun() {
    const r = this.save.run;
    if (!r) return this.startLevel(0, true);
    if (!this.slots.length) this.join(Schemes.keysA);
    this.score = r.score; this.levelStartScore = r.score;
    this.slots[0].inventory = (r.inventory || []).filter(j => JUNK_INFO[j]);
    this.slots[0].body.setEyes(clamp(r.eyes, 0, MAX_EYES));
    this.state = 'playing';
    this.loadLevel(r.level, Math.min(r.checkpoint, makeLevel(r.level).checkpoints.length - 1));
    this.hud.hideTitle();
    this.hud.banner(this.level.subtitle.toUpperCase(), this.level.name);
  }
  storeSave() { try { localStorage.setItem('googly.save.web.v1', JSON.stringify(this.save)); } catch {} }
  storeRun() {
    const p1 = this.slots[0]; if (!p1 || this.role === 'guest') return;
    this.save.run = { level: this.levelIndex, checkpoint: this.checkpointIdx, score: this.score, eyes: p1.body.eyes.length, inventory: [...p1.inventory] };
    this.storeSave();
    this.hud.flashSaved();
  }
  toTitle() {
    this.titleCountdown = null;
    if (this.net && this.state !== 'title') { this.net.close(); this.net = null; this.role = 'offline'; }
    this.titleMode = 'main'; this.menuOpen = false;
    this.state = 'title';
    this.hud.hidePanel();
    this.clearSlots();
    this.loadLevel(0);
    this.audio.setMusic(4);
    this.hud.showTitle();
  }
  restartLevel() {
    if (this.role === 'guest') return;
    if (this.role === 'host') { this.net?.send({ t: 'start', level: this.levelIndex }); this.evOut = []; }
    this.score = this.levelStartScore;
    for (const s of this.slots) { s.bonks = 0; s.collected = 0; s.falls = 0; if (s.body.eyes.length < 2) s.body.setEyes(2); }
    this.state = 'playing';
    this.loadLevel(this.levelIndex);
    this.hud.banner(this.level.subtitle.toUpperCase(), this.level.name);
  }
  win() {
    this.state = 'won'; this.doneTimer = 0;
    this.save.wins++; this.save.run = null; this.storeSave();
    this.audio.play('win'); this.audio.setMusic(4);
    this.hud.showWin(this.score, this.slots.length);
    this.emit(['win', this.score]); this.hostFlush();
  }

  // ================================================================ loop
  tick(dt) {
    dt = clamp(dt, 0.001, 1 / 30);
    this.time += dt;
    const input = this.input;
    input.beginFrame(dt);
    this.pumpNet();
    this.audio.setDuck(this.slots.length && this.slots.every(s => s.body.ko > 0) ? 0.35 : 1);
    if (input.wasPressed('KeyM')) { this.audio.toggleMute(); this.hud.toast(this.audio.muted ? 'MUTED' : 'SOUND ON'); }
    if (input.scroll) this.camDist = clamp(this.camDist * (1 - input.scroll * 0.08), 0.6, 1.8);
    const anyPause = input.wasPressed('Escape') || input.anyPadPressed('menu');
    const anyConfirm = input.wasPressed('Enter', 'NumpadEnter', 'Space') || input.anyPadPressed('a') || input.anyPadPressed('menu');
    switch (this.state) {
      case 'title': this.updateTitle(dt); break;
      case 'playing': this.updatePlaying(dt, anyPause); break;
      case 'paused':
        if (anyPause) { this.state = 'playing'; this.hud.hidePanel(); }
        else if (input.wasPressed('KeyR')) { this.hud.hidePanel(); this.restartLevel(); }
        else if (input.wasPressed('KeyQ')) { this.storeRun(); this.toTitle(); }
        break;
      case 'done':
        this.doneTimer += dt; this.simulateScenery(dt);
        if (this.role === 'guest') break;
        if (this.doneTimer > 0.8 && (anyConfirm || (this.demo && this.doneTimer > 2))) {
          this.hud.hidePanel();
          if (this.levelIndex + 1 < LEVEL_NAMES.length) this.startLevel(this.levelIndex + 1, false); else this.win();
        }
        break;
      case 'won':
        this.doneTimer += dt; this.simulateScenery(dt);
        if (Math.random() < 0.1) this.confetti(this.camTarget.add(new V3(frand(-500, 500), 400, frand(-200, 200))), 4, false);
        if (this.doneTimer > 1.5 && (anyConfirm || anyPause)) this.toTitle();
        break;
    }
    this.updateCamera(dt);
    this.updatePopups(dt);
    this.updateTags();
    this.sceneryTick?.(dt, this.time);
    tickModels(dt);
    this.hud.update(dt);
    this.renderer.render(this.scene, this.camera);
  }

  simulateScenery(dt) {
    this.world.moveMovers(dt);
    for (const p of this.pickups) p.update(dt, this.world, this.camera);
    for (const e of this.enemies) e.updateEyes(dt);
    this.updateParticles(dt);
  }

  stepBody(b, dt, ctl) {
    const c = { ...ctl }, h = dt / 4, ev = [];
    for (let s = 0; s < 4; s++) { if (s > 0) c.jump = false; b.step(h, c, this.world, ev); }
  }

  // ================================================================ title
  titleState() {
    return {
      mode: this.titleMode, unlocked: this.save.unlocked, wins: this.save.wins,
      countdown: this.titleCountdown != null ? Math.ceil(this.titleCountdown) : null, joined: this.slots.map(s => ({ index: s.index, label: s.scheme.label })),
      canContinue: !!this.save.run, continueName: this.save.run ? LEVEL_NAMES[this.save.run.level] : '',
      free: this.freeSchemes().map(s => ({ join: s.join, label: s.label })), players: this.slots.map(s => s.index + s.scheme.id),
      status: this.netStatus(), open: this.net?.status === 'open', lobbies: this.lobbyList.map(l => ({ code: l.code, host: l.host, n: l.n, started: l.started, levelName: l.levelName })),
      error: this.netError, code: this.codeEntry, name: this.name, host: this.role === 'host', level: this.lobbyLevel, lobbyCode: this.lobbyCode,
      roster: this.slots.map(s => s.index + s.name),
      ...(this.titleMode === 'lobby' ? { code: this.lobbyCode } : {}),
    };
  }
  netStatus() {
    const n = this.net; if (!n) return '';
    if (n.status === 'connecting') { const s = Math.floor(n.secondsConnecting); return s < 4 ? `Connecting to ${n.host}…` : `Waking up the free server… ${s}s (can take ~30–60 s)`; }
    if (n.status === 'open') return `Connected to ${n.host} · as ${this.name}`;
    return 'Offline: ' + n.why;
  }
  titleAction(act) {
    this.audio.unlock();
    this.audio.play('click');
    this.titleCountdown = null;
    if (act === 'solo') { this.startLevel(0, true); }
    else if (act === 'online') this.openOnline();
    else if (act === 'continue') this.continueRun();
    else if (act.startsWith('level')) { this.startLevel(+act.slice(5), true); }
    else if (act.startsWith('lobbylevel')) { const k = +act.slice(10); if (k < this.save.unlocked) this.lobbyLevel = k; }
    else if (act.startsWith('joinlist')) { const l = this.lobbyList[+act.slice(8)]; if (l) this.net?.send({ t: 'join', code: l.code, name: this.name }); }
  }
  animateTitleBodies(dt) {
    this.titleHop -= dt;
    const bodies = this.slots.length ? this.slots.map(s => s.body) : [this.titleBody];
    bodies.forEach((b, i) => {
      const ctl = { move: { x: 0, y: 0 }, jump: false, squish: false };
      if (this.titleHop < 0 && i === Math.floor(this.time * 7) % bodies.length) { ctl.jump = true; this.titleHop = frand(0.6, 1.6); }
      this.stepBody(b, dt, ctl); b.frame(dt, this.world, this.time); b.draw(this.world, this.time);
    });
    for (const a of bodies) for (const b of bodies) if (a !== b) a.pushOut(b);
    this.simulateScenery(dt);
    this.hud.titleTick(dt, this.time);
  }
  updateTitle(dt) {
    const input = this.input;
    this.animateTitleBodies(dt);
    if (this.titleMode === 'main') {
      // same as the Mac app: jump joins (P1 = SPACE) and starts a short countdown; ENTER plays right away
      for (const sc of this.freeSchemes()) if (joinPressed(sc, input)) {
        const s = this.join(sc);
        if (s) { this.audio.unlock(); s.body.shove(new V3(0, 700, 0)); this.titleCountdown = this.slots.length >= 4 ? 1.5 : this.slots.length === 1 ? 3 : 4; }
      }
      if (this.titleCountdown != null) {
        this.titleCountdown -= dt;
        if (this.titleCountdown <= 0) { this.titleCountdown = null; return this.startLevel(0, true); }
      }
      if (input.wasPressed('Enter', 'NumpadEnter') || input.anyPadPressed('menu')) return this.titleAction('solo');
      if (input.wasPressed('KeyO')) return this.titleAction('online');
      if (input.wasPressed('KeyC') && this.save.run) return this.titleAction('continue');
      ['Digit1', 'Digit2', 'Digit3'].forEach((k, i) => { if (input.wasPressed(k) && this.save.unlocked > i) this.titleAction('level' + i); });
    } else this.updateOnlineTitle(dt);
    this.hud.drawTitle(this.titleState());
  }

  // ================================================================ playing
  updatePlaying(dt, pause) {
    this.levelTime += dt;
    const input = this.input;
    if (this.role !== 'offline') {
      if (pause) { this.menuOpen = !this.menuOpen; if (this.menuOpen) this.hud.showOnlineMenu(this.role === 'host'); else this.hud.hidePanel(); }
      if (this.menuOpen && input.wasPressed('KeyQ')) return this.leaveOnline('You left the lobby');
      if (this.role === 'guest') return this.updateGuest(dt);
    } else if (pause) { this.state = 'paused'; this.hud.showPause(); return; }
    this.bounceSoundCooldown -= dt;
    this.world.moveMovers(dt);
    for (const sc of this.freeSchemes()) if (joinPressed(sc, input) && sc.id !== 'keysA') this.join(sc);

    const solo = !this.multi;
    const acts = [];
    for (const s of this.slots) {
      s.jumpBuffer -= dt; s.fireCooldown -= dt; s.honkCooldown -= dt; s.quipCooldown -= dt;
      let a = s.scheme.remote ? this.remoteActions(s) : this.demo ? this.demoActions(s) : readActions(s.scheme, input, solo);
      if (this.menuOpen && !s.scheme.remote) a = readActions({ id: 'none' }, input, solo);
      if (a.jumpPressed) s.jumpBuffer = 0.13;
      const ctl = { move: { ...a.move }, jump: s.jumpBuffer > 0, squish: a.squish };
      if (s.body.ko > 0 || s.body.flushing >= 0) { ctl.move = { x: 0, y: 0 }; ctl.jump = false; ctl.squish = false; }
      if (this.multi && s.body.eyes.length === 0 && s.body.ko <= 0) {
        s.blindDrift.x += frand(-1, 1) * dt * 6; s.blindDrift.y += frand(-1, 1) * dt * 6;
        s.blindDrift.x *= 0.98; s.blindDrift.y *= 0.98;
        const l = Math.hypot(s.blindDrift.x, s.blindDrift.y); if (l > 0.8) { s.blindDrift.x *= 0.8 / l; s.blindDrift.y *= 0.8 / l; }
        ctl.move.x += s.blindDrift.x; ctl.move.y += s.blindDrift.y;
      }
      s.lastCtl = ctl;
      acts.push({ a, ctl });
    }
    if (this.flushT < 0) {
      const h = dt / 4, events = this.slots.map(() => []);
      for (let sub = 0; sub < 4; sub++) {
        this.slots.forEach((s, i) => {
          if (s.body.flushing >= 0) return;
          const c = { ...acts[i].ctl }; if (sub > 0) c.jump = false;
          s.body.step(h, c, this.world, events[i]);
        });
        if (this.multi) for (const a of this.slots) for (const b of this.slots) if (a !== b) a.body.pushOut(b.body);
      }
      this.slots.forEach((s, i) => {
        for (const e of events[i]) if (e.type === 'jump' || e.type === 'superJump') s.jumpBuffer = 0;
        this.handle(events[i], s);
      });
      if (this.role === 'host') for (const s of this.slots) if (s.scheme.remote) this.applyRemoteAuthority(s, dt);
    } else this.updateFlush(dt);
    this.updateLeader();
    if (this.flushT < 0) this.slots.forEach((s, i) => {
      const a = acts[i].a;
      if (Math.hypot(a.move.x, a.move.y) > 0 || a.jumpPressed || a.squish) s.idleTime = 0; else s.idleTime += dt;
      if (s.idleTime > 9) { s.idleTime = 0; this.say(s, ['hello?', "I'm just a guy.", 'is anyone controlling me?', '*wobble*', 'I could stand here all day.', 'blink. blink.']); }
      if (s.body.ko > 0) { s.body.ko -= dt; if (s.body.ko <= 0) this.respawn(s, true); return; }
      if (s.scheme.id === 'keysA') this.updateAim(s); else if (s.scheme.remote) s.aimPoint = s.remote.aim;
      const fire = a.fire || (a.fireHeld && s.fireCooldown < -0.1);
      if (fire && s.fireCooldown <= 0) this.shoot(s, a.mouseAim);
      if (a.honk && s.honkCooldown <= 0) this.honk(s);
      if (a.teleport && s.behind) this.teleport(s);
    });
    for (const s of this.slots) { s.body.frame(dt, this.world, this.time); s.body.draw(this.world, this.time); }
    this.updatePickups(dt);
    this.updateProjectiles(dt);
    this.updateEnemies(dt);
    this.updateShocks(dt);
    this.updateParticles(dt);
    for (const s of this.slots) this.updateBubble(s, dt);
    this.checkCheckpoints();
    this.updateBoss(dt);
    this.updateGoalDrop(dt);
    if (this.goalVisible && this.flushT < 0 && this.goalDrop < 0) {
      const g = this.level.goal.add(new V3(0, 60, 0));
      const s = this.slots.find(s => s.body.ko <= 0 && s.body.c.sub(g).len < 85);
      if (s) this.startFlush(s);
    }
    for (const s of this.slots) if (s.body.c.y < this.world.killY && s.body.flushing < 0) {
      s.falls++;
      this.sfx('whoops');
      this.say(s, ['WHOOOOPS', 'brb', 'that was on purpose'], true);
      if (s.body.eyes.length > 0) { s.body.removeEye(); this.respawn(s, false); } else this.respawn(s, true);
    }
    this.saveTimer += dt;
    if (this.saveTimer > 30) { this.saveTimer = 0; this.storeRun(); }
    if (this.role === 'host') this.hostNetTick(dt);
  }

  // ---------------- leader & teleport
  updateLeader() {
    for (const s of this.slots) if (s.body.grounded && s.body.ko <= 0 && s.body.flushing < 0) {
      const g = this.world.groundBelow(s.body.c.x, s.body.c.z, s.body.c.y);
      if (g !== null && s.body.bottom - g < 20) s.lastSafe = s.body.c.clone();
    }
    const alive = this.slots.filter(s => s.body.ko <= 0 && s.body.c.y > this.world.killY + 100);
    let best = null; for (const s of alive) if (!best || s.body.c.x > best.body.c.x) best = s;
    const l = this.leader;
    if (best && !(l && l !== best && alive.includes(l) && best.body.c.x < l.body.c.x + 60)) {
      if (this.leader !== best && this.multi && this.leader) this.popText(`${best.name} TAKES THE LEAD!`, best.body.c.add(new V3(0, 120, 0)), best.color, 22);
      this.leader = best;
    }
    for (const s of this.slots) {
      const L = this.leader;
      if (!this.multi || !L || L === s || s.body.ko > 0 || this.flushT >= 0) { s.behind = false; continue; }
      const gap = L.body.c.x - s.body.c.x;
      s.behind = gap > 700 || L.body.c.sub(s.body.c).len > 1200 || (s.body.c.y < L.body.c.y - 500 && gap > 200);
    }
    this.positionCrown();
  }
  positionCrown() {
    const L = this.leader;
    if (this.multi && L && this.flushT < 0) {
      this.crown.visible = true;
      this.crown.position.set(L.body.c.x, L.body.top + 14 + Math.sin(this.time * 4) * 3, L.body.c.z);
      this.crown.rotation.y = this.time * 1.5;
    } else this.crown.visible = false;
  }
  safeSpot(L, s) {
    const base = L.lastSafe;
    for (const dz of [s.index % 2 === 0 ? -80 : 80, 0, s.index % 2 === 0 ? 80 : -80]) {
      const p = base.add(new V3(-70, 0, dz));
      const g = this.world.groundBelow(p.x, p.z, p.y + 60);
      if (g !== null && g > base.y - 120 && !this.world.solidAt(p.add(new V3(0, 90, 0)))) return new V3(p.x, g + 150, p.z);
    }
    return base.add(new V3(0, 160, 0));
  }
  teleport(s) {
    const L = this.leader; if (!L || L === s) return;
    const from = s.body.c.clone(), dest = this.safeSpot(L, s);
    this.puff(from, 12);
    this.placeSlot(s, dest);
    s.body.invuln = 1.2; s.teleports++; s.behind = false;
    this.puff(dest, 12); this.sparkle(dest);
    this.sfx('superboing', 0.6, 1.3); this.sfx('whoosh', 0.5);
    this.popText('ZOOP!', dest.add(new V3(0, 80, 0)), s.color, 34);
    this.say(s, ['wait for me!', 'ZOOP', 'teleportation is easy', 'catching up!'], true);
  }
  respawn(s, ko) {
    let p = this.spawnPoint(s.index);
    const L = this.leader;
    if (this.multi && L && L !== s && L.body.ko <= 0 && L.lastSafe.x > p.x) p = this.safeSpot(L, s);
    if (this.world.solidAt(p)) p = p.add(new V3(0, 150, 0));
    if (ko) { s.body.setEyes(2); this.score = Math.max(0, this.score - 200); this.toast(`${s.name} BONKED OUT · -200`); }
    this.placeSlot(s, p);
    s.body.invuln = 1.5;
    if (s.body.eyes.length === 0) this.say(s, ["still can't see...", 'where am I?'], true);
  }

  // ---------------- flush
  startFlush(first) {
    this.flushT = 0;
    this.sfx('flush');
    first.flushOrder = 0;
    this.say(first, ['finally, a bath!', 'wheeeee—', 'see you on the other side!'], true);
    const rest = this.slots.filter(s => s !== first).sort((a, b) => a.body.c.sub(this.level.goal).len - b.body.c.sub(this.level.goal).len);
    rest.forEach((s, k) => { s.flushOrder = k + 1; });
    for (const s of this.slots) s.body.flushing = 0;
    if (this.multi) this.popText(`${first.name} FLUSHED FIRST!`, this.level.goal.add(new V3(0, 220, 0)), first.color, 34);
    this.crown.visible = false;
  }
  updateFlush(dt) {
    this.flushT += dt;
    for (const s of this.slots) {
      const delay = s.flushOrder * 0.35;
      const k = clamp((this.flushT - delay) / 1.8, 0, 1);
      if (k <= 0) {
        const pull = this.level.goal.add(new V3(0, 80, 0)).sub(s.body.c).mul(Math.min(1, dt * 3));
        s.body.flushPose(s.body.c.add(pull), 1, this.flushT * 3);
        continue;
      }
      const center = this.level.goal.add(new V3(0, 62 - k * 30, 0));
      s.body.flushPose(center, Math.max(0.04, 1 - k * 0.96), k * k * 16 + s.index);
      if (Math.floor(this.flushT * 20) % 3 === 0) {
        const b = new THREE.Mesh(new THREE.SphereGeometry(frand(3, 7), 8, 6), new THREE.MeshStandardMaterial({ color: 0x8fd4ff, roughness: 0.1 }));
        this.worldNode.add(b);
        this.particles.push(new Particle(b, center.add(new V3(frand(-30, 30), 0, frand(-30, 30))), new V3(frand(-150, 150), frand(100, 350), frand(-150, 150)), 0.7));
      }
    }
    const total = 2.2 + Math.max(0, this.slots.length - 1) * 0.35;
    if (this.flushT > total && this.state === 'playing' && this.role !== 'guest') this.levelComplete();
  }
  levelComplete() {
    this.state = 'done'; this.doneTimer = 0;
    const eyes = this.slots.reduce((a, s) => a + s.body.eyes.length, 0);
    this.score += 1000 + eyes * 200;
    const got = this.score - this.levelStartScore;
    this.save.best[this.levelIndex] = Math.max(this.save.best[this.levelIndex] || 0, got);
    this.save.unlocked = Math.max(this.save.unlocked, Math.min(LEVEL_NAMES.length, this.levelIndex + 2));
    const p1 = this.slots[0];
    if (this.levelIndex + 1 < LEVEL_NAMES.length && p1) this.save.run = { level: this.levelIndex + 1, checkpoint: -1, score: this.score, eyes: Math.max(2, p1.body.eyes.length), inventory: [...p1.inventory] };
    this.storeSave();
    this.audio.play('win');
    const last = this.levelIndex + 1 >= LEVEL_NAMES.length;
    this.hud.showDone(this.level, got, this.slots, this.levelTime, last);
    this.emit(['done', got, Math.floor(this.levelTime), last ? 1 : 0, this.slots.map(s => [s.index, s.collected, s.bonks, s.body.eyes.length, s.falls, s.flushOrder])]);
    this.hostFlush();
    for (const s of this.slots) s.body.place(new V3(0, -5000, 0));
  }

  // ---------------- player events (movement sounds are local on every machine)
  handle(events, s) {
    const b = s.body, feet = new V3(b.c.x, b.bottom, b.c.z);
    for (const e of events) {
      switch (e.type) {
        case 'jump':
          s.jumpCount++;
          this.audio.play('boing', 0.55, frand(0.95, 1.12) * (0.9 + s.voicePitch * 0.1));
          if (Math.random() < 0.07) this.say(s, ['wheee!', 'hup!', 'boing!', 'yippee']);
          break;
        case 'superJump':
          this.audio.play('superboing', 0.5 + 0.4 * e.k);
          this.puff(feet, 8, false);
          if (e.k > 0.8 && Math.random() < 0.4) this.say(s, ['TO THE MOON', 'BOIIIING', 'I believe I can fly']);
          break;
        case 'land':
          this.audio.play('land', Math.min(1, 0.25 + e.k / 1500));
          this.puff(feet, Math.floor(Math.min(10, e.k / 150)), false);
          b.jolt();
          if (e.k > 1500 && Math.random() < 0.5) this.say(s, ['my spine!', '(I have no spine)', 'ow, my everything', 'nailed it']);
          break;
        case 'pound': this.audio.play('pound', 0.6); break;
        case 'poundLand':
          this.audio.play('stomp', 0.55, 1.4);
          this.shake = Math.max(this.shake, 10);
          this.puff(feet, 14, false);
          b.jolt();
          if (this.role === 'guest') break;
          for (const en of this.enemies) {
            if (en.dead || en.kind === 'pigeon') continue;
            const d = en.pos.sub(feet);
            if (d.xzLen < 200 && Math.abs(d.y) < 120) this.damage(en, 2, d.flat.norm.add(new V3(0, 0.8, 0)).norm, 'SLAM!', s);
          }
          for (const o of this.slots) if (o !== s) {
            const d = o.body.c.sub(feet);
            if (d.xzLen < 170 && Math.abs(d.y) < 100) { this.knock(o, d.flat.norm.mul(300).add(new V3(0, 650, 0))); this.say(o, ['HEY!', 'rude!', 'whoa!']); }
          }
          break;
        case 'trampoline':
          this.audio.play('tramp', 0.7);
          b.jolt();
          if (Math.random() < 0.25) this.say(s, ['weeeeee!', 'trampoline!!', 'I am a bird now']);
          break;
        case 'step': this.audio.play('step', 0.18); break;
      }
    }
    if (b.inFan && Math.random() < 0.004) this.say(s, ['wheeeeeeeee', 'fan-tastic']);
  }

  // ---------------- aiming & shooting
  mouthOf(b) { return b.c.add(M3mulv(b.G, new V3(0, -4, 30))); }
  updateAim(s) {
    const input = this.input;
    if (!(input.mouseMovedRecently > 0 || input.mouseHeld)) { this.reticle.visible = false; s.aimPoint = null; return; }
    const ndc = new THREE.Vector2((input.mouse.x / innerWidth) * 2 - 1, -(input.mouse.y / innerHeight) * 2 + 1);
    this.raycaster.setFromCamera(ndc, this.camera);
    let target = null;
    const hits = this.raycaster.intersectObjects(this.worldNode.children, true);
    for (const h of hits) {
      let o = h.object, skip = false;
      while (o) { if (o.userData.enemy) break; if (o.userData.player) { skip = true; break; } o = o.parent; }
      if (skip) continue;
      if (o && o.userData.enemy && !o.userData.enemy.dead) { target = o.userData.enemy.pos.clone(); break; }
      if (h.object.type === 'Points' || h.object.isSprite) continue;
      if (Math.abs(h.point.z) < 1200) { target = new V3(h.point.x, h.point.y, h.point.z); break; }
    }
    if (!target) {
      const r = this.raycaster.ray;
      if (Math.abs(r.direction.y) > 1e-4) { const t = (s.body.c.y - r.origin.y) / r.direction.y; if (t > 0) target = new V3(r.origin.x + r.direction.x * t, s.body.c.y, r.origin.z + r.direction.z * t); }
    }
    s.aimPoint = target;
    if (target) { this.reticle.visible = true; this.reticle.position.set(target.x, target.y + 3, target.z); this.reticle.scale.setScalar(1 + 0.1 * Math.sin(this.time * 10)); }
    else this.reticle.visible = false;
  }
  autoAim(s) {
    const b = s.body, fwd = b.moveDir;
    let best = null;
    for (const e of this.enemies) {
      if (e.dead) continue;
      const d = e.pos.sub(b.c), l = d.len;
      if (l > 800 || l < 1) continue;
      const facing = d.flat.norm.dot(fwd);
      if (facing <= 0.2) continue;
      const sc = l * (1.6 - facing);
      if (!best || sc < best[0]) best = [sc, e.pos];
    }
    return best ? best[1] : null;
  }
  shoot(s, mouse) {
    const b = s.body, j = s.inventory.pop() || 'pea', info = JUNK_INFO[j];
    const from = this.mouthOf(b);
    let target = null;
    if (this.demo) target = this.demoTarget(s);
    else if (mouse && s.aimPoint) target = s.aimPoint;
    else target = this.autoAim(s);
    let vel;
    if (target) {
      const d = target.sub(from), flightT = Math.max(0.12, d.len / info.speed);
      vel = d.mul(1 / flightT).add(new V3(0, 0.5 * 1900 * info.g * flightT, 0));
    } else vel = b.moveDir.add(new V3(0, 0.18, 0)).norm.mul(info.speed);
    const dir = vel.norm;
    const p = new Projectile(j, from.add(dir.mul(20)), vel.add(b.cVel.mul(0.3)));
    p.owner = s.index;
    this.addProjectile(p);
    this.knock(s, dir.mul(-info.recoil * (b.grounded ? 0.5 : 1)), 0, new V3(0, 0, 1), false);
    b.mouthOpen = 1; b.aimTimer = 0.35; b.aimDir = dir;
    s.fireCooldown = j === 'pea' ? 0.14 : 0.22;
    this.sfx(j === 'pea' ? 'pea' : 'ptoo', j === 'bowling' ? 0.9 : 0.6, j === 'bowling' ? 0.75 : frand(0.95, 1.1));
    if (j === 'chicken') this.sfx('squawk', 0.5);
    if (j === 'pea' && Math.random() < 0.18) this.say(s, ['pew.', 'this is embarrassing', "I'm out of stuff!", 'a pea. truly terrifying.']);
    if (j === 'bowling') { this.addShake(6); this.say(s, ['STRIIIKE', 'heavy!']); }
    s.idleTime = 0;
  }
  honk(s) {
    const b = s.body;
    s.honkCooldown = 1.4;
    this.sfx('honk', 0.8, frand(0.96, 1.04) * (0.85 + s.voicePitch * 0.15));
    b.mouthOpen = 1;
    this.knock(s, new V3(0, 160, 0));
    this.popText('HONK!', b.c.add(new V3(0, 90, 0)), 0xffe14d, 34);
    for (const e of this.enemies) {
      if (e.dead) continue;
      const d = e.pos.sub(b.c);
      if (d.len < 320) {
        e.vel.addi(d.flat.norm.mul(380).add(new V3(0, 300, 0)));
        e.stun = Math.max(e.stun, e.kind === 'boss' ? 0.3 : 1.2);
        for (const ey of e.eyes) ey.jolt(frand(-900, 900), 900);
      }
    }
    for (const o of this.slots) if (o !== s && o.body.c.sub(b.c).len < 260) this.knock(o, new V3(0, 220, 0));
  }

  // ---------------- pickups
  updatePickups(dt) {
    for (const p of this.pickups) {
      if (p.dead) continue;
      p.update(dt, this.world, this.camera);
      if (p.delay > 0) continue;
      let s = null, bd = Infinity;
      for (const o of this.slots) {
        if (o.body.ko > 0 || o.body.flushing >= 0) continue;
        const d = o.body.c.sub(p.pos).len;
        if (d < 60 + p.r && d < bd) { bd = d; s = o; }
      }
      if (!s) continue;
      if (p.what === 'eye') {
        if (s.body.eyes.length >= MAX_EYES) continue;
        s.body.addEye();
        this.score += 50;
        this.sfx('eye', 0.7);
        const n = s.body.eyes.length;
        this.say(s, n === 1 ? ['I CAN SEE!', 'light! glorious light!'] : n >= 5 ? ['SO MANY EYES', 'I see everything', 'eye eye eye!', `${n} eyes. no regrets.`] : ['MORE EYES!', 'I can see... more!', 'eye spy!'], true);
        this.sparkle(p.pos);
      } else {
        if (s.inventory.length >= 30) continue;
        const j = p.what;
        s.inventory.push(j); s.collected++; this.score += 10;
        this.sfx(j === 'duck' ? 'squeak' : j === 'chicken' ? 'squawk' : 'collect', 0.5, frand(0.95, 1.15));
        if (j === 'duck' || j === 'chicken') this.sfx('collect', 0.3);
        if (Math.random() < 0.1) this.say(s, QUIPS[j]);
        this.popText('+' + JUNK_INFO[j].emoji, p.pos.add(new V3(0, 30, 0)), 0xffffff, 22);
      }
      p.dead = true;
      this.fadeOut(p.node, 1.8);
    }
    this.pickups = this.pickups.filter(p => {
      if (p.dead) { this.emit(['pg', p.netID]); if (!p.node.userData.fading) this.worldNode.remove(p.node); }
      return !p.dead;
    });
  }
  fadeOut(node, scaleTo) {
    node.userData.fading = true;
    this.particles.push(new Particle(node, new V3(node.position.x, node.position.y, node.position.z), new V3(), 0.15, { gravity: 0, drag: 0, shrink: false, grow: scaleTo }));
  }

  // ---------------- projectiles
  updateProjectiles(dt) {
    for (const p of this.projectiles) {
      if (p.dead) continue;
      p.age += dt;
      const owner = this.slot(p.owner);
      const info = JUNK_INFO[p.junk];
      if (p.junk === 'banana' && !p.hostile && !p.isPoop && p.r > 10 && owner) {
        if (p.age > 0.5) p.returning = true;
        if (p.returning) {
          const d = owner.body.c.sub(p.pos);
          p.vel.addi(d.norm.mul(2600 * dt));
          const sp = p.vel.len; if (sp > 1000) p.vel.muli(1000 / sp);
          if (d.len < 60) { p.dead = true; owner.inventory.push('banana'); this.sfx('collect', 0.4); continue; }
          if (p.age > 4) p.returning = false;
        }
      }
      p.vel.y -= 1900 * (p.isPoop ? 0.6 : info.g) * dt * (p.returning ? 0 : 1);
      p.vel.y += this.world.fanForce(p.pos) * dt * 0.6;
      const np = p.pos.add(p.vel.mul(dt)), cts = [];
      this.world.resolve(np, p.r, cts);
      if (cts.length) {
        if (p.isPoop) { this.splat(np, 0xf4f1e6); this.sfx('splat', 0.3); p.dead = true; continue; }
        for (const ct of cts) {
          const vn = p.vel.dot(ct.n);
          if (vn < 0) {
            const bounce = ct.solid.kind === 'bouncy' ? 1.1 : info.bounce;
            p.vel.subi(ct.n.mul(vn * (1 + bounce)));
            p.vel.subi(p.vel.sub(ct.n.mul(p.vel.dot(ct.n))).mul(0.15));
            if (-vn > 200) {
              p.bounces++; p.spin = p.vel.len / p.r * 0.8;
              if (this.bounceSoundCooldown <= 0) {
                this.bounceSoundCooldown = 0.05;
                this.sfx(p.junk === 'duck' ? 'squeak' : p.junk === 'chicken' ? 'squawk' : 'thud', Math.min(0.5, -vn / 2000), frand(0.9, 1.2));
              }
            }
          }
        }
        if (p.hostile && p.junk === 'toast') p.hostile = false;
        if (p.junk === 'melon' && p.r > 12 && p.bounces > 0) { this.splitMelon(p); continue; }
        p.returning = false;
      }
      p.pos = np; p.angle += p.spin * dt;
      p.node.position.set(p.pos.x, p.pos.y, p.pos.z);
      p.node.quaternion.setFromAxisAngle(p.spinAxis, p.angle);
      if (p.hostile) {
        for (const s of this.slots) {
          if (s.body.ko > 0 || s.body.flushing >= 0 || s.body.invuln > 0 || p.pos.sub(s.body.c).len >= 46 + p.r) continue;
          p.dead = true;
          if (p.isPoop) { this.splat(p.pos, 0xf4f1e6); this.sfx('splat', 0.6); this.say(s, ['EW', 'on my head??', 'gross gross gross'], true); }
          this.hurt(s, p.pos.sub(p.vel.norm.mul(30)));
          break;
        }
        if (p.dead) continue;
      } else if (p.age > 0.03) {
        for (const e of this.enemies) {
          if (e.dead || p.hitIDs.has(e.serial)) continue;
          const reach = e.r * (e.kind === 'cube' || e.kind === 'boss' ? 1.15 : 1) + p.r;
          if (e.pos.sub(p.pos).len < reach) {
            p.hitIDs.add(e.serial);
            const dmg = p.r < 12 && p.junk === 'melon' ? 1 : info.dmg;
            this.damage(e, dmg, p.vel.norm, null, owner);
            if (p.junk === 'sock') { e.stun = Math.max(e.stun, 2.2); this.popText('STINKY', e.pos.add(new V3(0, e.r + 30, 0)), 0xa8e063, 22); }
            if (p.junk === 'melon' && p.r > 12) { this.splitMelon(p); break; }
            if (p.junk !== 'bowling') { p.vel = new V3(-p.vel.x * 0.35, 380, -p.vel.z * 0.35); p.spin *= -2; }
            break;
          }
        }
        if (p.dead) continue;
        if (p.age > 0.1 && p.vel.len > 300) {
          for (const s of this.slots) {
            if (s.index === p.owner || s.body.ko > 0 || s.body.flushing >= 0 || p.pos.sub(s.body.c).len >= 44 + p.r) continue;
            const fl = p.vel.flat.norm;
            this.knock(s, fl.mul(260).add(new V3(0, 300, 0)), 2, fl.cross(new V3(0, 1, 0)));
            s.body.hurtFace = 0.5;
            this.sfx('bonk', 0.6, 1.2);
            this.popText('BONK!', s.body.c.add(new V3(0, 70, 0)), owner ? owner.color : 0xffffff, 28);
            this.say(s, ['HEY!', 'watch it!', `${owner ? owner.name : 'someone'} hit me!`, 'friendly fire!!'], true);
            p.vel = new V3(-p.vel.x * 0.3, 300, -p.vel.z * 0.3);
            p.owner = s.index;
            break;
          }
        }
      }
      if (!p.hostile && !p.isPoop && p.junk !== 'pea' && !(p.junk === 'melon' && p.r < 12) && p.age > 0.6 && p.vel.len < 90 && cts.length) {
        p.dead = true;
        const k = new Pickup(p.junk, p.pos, true); k.life = 25; k.delay = 0.3;
        this.addPickup(k);
        continue;
      }
      if (p.age > 9 || p.pos.y < this.world.killY || (p.junk === 'pea' && p.bounces > 1) || (p.r < 12 && p.junk === 'melon' && p.age > 1.5)) p.dead = true;
    }
    this.projectiles = this.projectiles.filter(p => { if (p.dead) this.worldNode.remove(p.node); return !p.dead; });
  }
  splitMelon(p) {
    p.dead = true;
    this.sfx('splat', 0.7, 0.8);
    this.splat(p.pos, 0xff3a4a);
    for (let k = 0; k < 5; k++) {
      const a = k / 5 * 2 * Math.PI;
      const q = new Projectile('melon', p.pos, new V3(Math.cos(a) * 450, 450, Math.sin(a) * 450));
      q.r = 9; q.owner = p.owner; q.node.scale.setScalar(0.45); q.hitIDs = new Set(p.hitIDs);
      this.addProjectile(q);
    }
  }

  // ---------------- enemies
  damage(e, amt, dir, text, by) {
    if (e.dead || e.hp <= 0) return;
    e.hp -= amt; e.hurtFlash = 0.18;
    const kb = e.kind === 'boss' ? 0.15 : 1;
    e.vel.addi(dir.flat.mul(320).add(new V3(0, 260, 0)).mul(kb));
    e.spin = frand(6, 12) * kb;
    const df = dir.flat.len > 0.1 ? dir.flat.norm : new V3(1, 0, 0);
    e.tumbleAxis = new V3(0, 1, 0).cross(df).norm;
    e.awake = true;
    for (const ey of e.eyes) ey.jolt(frand(-900, 900), 700);
    if (by) by.bonks++;
    const words = ['BONK!', 'POW!', 'THWACK!', 'BOINK!', 'WHAP!', 'BOP!', 'KAPOW!', 'SPLAT!'];
    this.popText(text || pick(words), e.pos.add(new V3(frand(-20, 20), e.r + 20, 0)), this.multi && by ? by.color : 0xffe14d, e.kind === 'boss' ? 44 : 32);
    this.sfx('bonk', 0.7, frand(0.9, 1.15));
    this.addShake(e.kind === 'boss' ? 8 : 4);
    if (e.hp <= 0) this.kill(e, by);
  }
  kill(e, by) {
    e.dead = true;
    this.sfx('pop', 0.8);
    this.confetti(e.pos, e.kind === 'boss' ? 140 : 30);
    const talker = by || this.slots[0];
    if (e.kind === 'cube') {
      this.score += 100;
      if (Math.random() < 0.6) this.dropJunk(pick(['duck', 'toast', 'sock', 'fish', 'banana', 'cheese']), e.pos);
      if (Math.random() < 0.2 && talker) this.say(talker, ['sorry!', 'get cubed', "bonk'd", 'nothing personal']);
    } else if (e.kind === 'pigeon') {
      this.score += 150;
      const fm = new THREE.MeshStandardMaterial({ color: 0xb8bcc8, roughness: 0.9 }), fg = new THREE.BoxGeometry(10, 1, 4);
      for (let i = 0; i < 10; i++) { const f = new THREE.Mesh(fg, fm); this.worldNode.add(f); this.particles.push(new Particle(f, e.pos, new V3(frand(-200, 200), frand(0, 300), frand(-200, 200)), 2, { gravity: -200, spin: frand(-4, 4), drag: 2, shrink: false })); }
      if (Math.random() < 0.5) this.dropJunk('duck', e.pos);
      if (Math.random() < 0.3 && talker) this.say(talker, ['no more poop!', 'sorry, bird']);
    } else if (e.kind === 'toaster') {
      this.score += 200;
      for (let i = 0; i < 3; i++) this.dropJunk('toast', e.pos);
      this.sfx('ding', 0.5, 1.3);
    } else {
      this.score += 5000;
      this.addShake(30);
      this.sfx('stomp', 1);
      this.popText(this.multi ? `${by ? by.name : 'YOU'} FIRED\nTHE CEO!` : 'YOU FIRED\nTHE CEO!', e.pos.add(new V3(0, 150, 0)), 0xffe14d, 60);
      for (const s of this.slots) this.say(s, ['I DID IT', 'promotion time!', 'take that, capitalism', 'we did it!'], true);
      this.dropGoal();
      for (let k = 0; k < 8; k++) this.dropJunk(JUNK[k % 9], e.pos.add(new V3(0, 40, 0)));
      this.audio.setMusic(this.level.theme.music); this.musicStyle = this.level.theme.music;
      this.bossAwake = false;
      this.hud.bossBar(null);
    }
    this.fadeOut(e.node, 1.5);
  }
  dropGoal() {
    this.emit(['gd']);
    this.goalVisible = true; this.goalNode.visible = true;
    this.goalDrop = 0;
  }
  updateGoalDrop(dt) {
    if (this.goalDrop < 0) return;
    this.goalDrop += dt;
    const k = Math.min(1, this.goalDrop / 1.2), g = this.level.goal;
    this.goalNode.position.set(g.x, g.y + 900 * (1 - k * k), g.z);
    if (k >= 1) { this.goalDrop = -1; this.audio.play('stomp', 0.6, 1.3); this.shake = 12; this.puff(g, 16, false); }
  }
  dropJunk(j, p) {
    const k = new Pickup(j, p, true);
    k.vel = new V3(frand(-250, 250), frand(350, 650), frand(-250, 250)); k.spin = frand(-8, 8); k.delay = 0.35; k.life = 30;
    this.addPickup(k);
  }
  nearest(p) {
    let best = null, bd = Infinity;
    for (const s of this.slots) { if (s.body.ko > 0 || s.body.flushing >= 0) continue; const d = s.body.c.sub(p).len; if (d < bd) { bd = d; best = s; } }
    return best;
  }
  updateEnemies(dt) {
    for (const e of this.enemies) {
      if (e.dead) continue;
      e.stun -= dt; e.hurtFlash -= dt; e.squash = Math.max(0, e.squash - dt * 4);
      const target = this.nearest(e.pos);
      const pc = target ? target.body.c : e.pos.add(new V3(2000, 0, 0));
      const d = pc.sub(e.pos);
      const near = !!target && d.xzLen < 900 && Math.abs(d.y) < 600;
      const toward = d.flat.len > 1 ? d.flat.norm : new V3(1, 0, 0);
      if (e.kind !== 'pigeon') {
        e.vel.y -= 1900 * dt;
        if (e.kind !== 'boss' || !this.bossAwake || e.phase !== 2) e.timer -= dt;
        if (e.grounded) { e.tumble *= Math.max(0, 1 - 10 * dt); e.spin *= 0.8; } else e.tumble += e.spin * dt;
        if (near && e.stun <= 0) { const face = toward.add(new V3(0, 0, 0.9)); e.yaw += wrapAngle(Math.atan2(face.x, face.z) - e.yaw) * Math.min(1, 5 * dt); }
        if (e.kind === 'cube' && e.grounded && e.timer <= 0 && e.stun <= 0) {
          e.vel = near ? toward.mul(frand(200, 300)).add(new V3(0, frand(520, 660), 0)) : new V3(frand(-60, 60), frand(250, 350), frand(-60, 60));
          e.timer = frand(0.9, 1.6); e.squash = 1;
          if (near) this.sfx('hop', 0.25, frand(0.9, 1.2));
        }
        if (e.kind === 'toaster' && e.timer <= 0 && e.stun <= 0) {
          e.timer = frand(2, 2.8);
          if (near && d.xzLen < 850) {
            const from = e.pos.add(new V3(0, 40, 0)), dd = pc.sub(from);
            const T = clamp(dd.xzLen / 520, 0.6, 1.4);
            const toast = new Projectile('toast', from, new V3(dd.x / T, (dd.y + 0.5 * 1900 * T * T) / T, dd.z / T), true);
            this.addProjectile(toast);
            this.sfx('ding', 0.55);
            e.squash = 1; e.vel.y += 200;
          }
        }
        if (e.kind === 'boss') this.bossBrain(e, target, dt);
        const p = e.pos.add(e.vel.mul(dt)), cts = [];
        this.world.resolve(p, e.r, cts);
        const was = e.grounded;
        e.grounded = false;
        for (const ct of cts) {
          const vn = e.vel.dot(ct.n);
          if (vn < 0) e.vel.subi(ct.n.mul(vn * (ct.solid.kind === 'bouncy' ? 2.1 : 1)));
          if (ct.n.y > 0.5) {
            e.grounded = true;
            const fr = ct.solid.kind === 'ice' ? 0.3 : 10, rel = ct.solid.vel.sub(e.vel);
            e.vel.x += rel.x * Math.min(1, fr * dt); e.vel.z += rel.z * Math.min(1, fr * dt);
          }
        }
        if (e.grounded && !was) { e.squash = 0.8; if (e.kind === 'boss') this.bossLanded(e); }
        e.pos = p;
      } else if (e.hp > 0) {
        const t = this.time + e.home.x * 0.01;
        const hover = near ? new V3(pc.x + Math.sin(t * 0.7) * 60, 0, pc.z + Math.cos(t * 0.6) * 40) : new V3(e.home.x + Math.sin(t * 0.4) * 200, 0, e.home.z + Math.cos(t * 0.3) * 120);
        const targetY = Math.max(e.home.y, (near ? pc.y : e.home.y) + 260) + Math.sin(t * 2.1) * 30;
        const want = new V3(clamp((hover.x - e.pos.x) * 1.5, -190, 190), clamp((targetY - e.pos.y) * 2, -160, 160), clamp((hover.z - e.pos.z) * 1.5, -190, 190));
        e.vel.addi(want.sub(e.vel).mul(Math.min(1, (e.stun > 0 ? 0.5 : 3) * dt)));
        if (e.stun > 0) e.vel.y -= 400 * dt;
        if (e.vel.xzLen > 20) e.yaw += wrapAngle(Math.atan2(e.vel.x, e.vel.z) - Math.PI / 2 - e.yaw) * Math.min(1, 4 * dt);
        e.timer -= dt;
        if (near && d.xzLen < 55 && pc.y < e.pos.y && e.timer <= 0 && e.stun <= 0) {
          e.timer = frand(1.3, 2.2);
          this.addProjectile(new Projectile('pea', e.pos.sub(new V3(0, 16, 0)), new V3(e.vel.x * 0.5, -120, e.vel.z * 0.5), true, true));
          this.sfx('coo', 0.4, frand(0.9, 1.1));
        }
        if (Math.random() < dt * 0.15 && near) this.sfx('coo', 0.25);
        e.pos.addi(e.vel.mul(dt));
      }
      // touching players
      if (!e.dead) {
        const reach = e.r * (e.kind === 'cube' || e.kind === 'boss' ? 1.15 : 1) + Player.pointR;
        for (const s of this.slots) {
          const b = s.body;
          if (b.ko > 0 || b.flushing >= 0 || e.pos.sub(b.c).len >= reach + 70) continue;
          let touch = false;
          for (let i = 0; i < N && !touch; i++) { const dx = b.x[i * 3] - e.pos.x, dy = b.x[i * 3 + 1] - e.pos.y, dz = b.x[i * 3 + 2] - e.pos.z; if (dx * dx + dy * dy + dz * dz < reach * reach) touch = true; }
          if (!touch) continue;
          if (b.c.y > e.pos.y + e.r * 0.5 && b.cVel.y < 50) {
            const wasPound = b.pounding;
            b.shove(new V3());
            b.bounceUp(820);
            this.emit(['bo', s.index, 820]);
            b.jolt();
            this.damage(e, wasPound ? 3 : 1, e.pos.sub(b.c).flat.norm, wasPound ? 'SLAM!' : 'BOING!', s);
            this.sfx('tramp', 0.4, 1.3);
          } else if (b.invuln <= 0 && e.stun <= 0) this.hurt(s, e.pos);
          if (e.dead) break;
        }
      }
      e.pose(this.time);
      e.updateEyes(dt);
      if (e.pos.y < this.world.killY) { e.dead = true; this.worldNode.remove(e.node); }
    }
    this.enemies = this.enemies.filter(e => !e.dead);
  }
  bossBrain(e, target, dt) {
    if (!this.bossAwake || !target) { e.timer = 1.5; return; }
    const d = target.body.c.sub(e.pos), rage = 1 - e.hp / e.maxHP;
    if (e.grounded && e.timer <= 0 && e.stun <= 0) {
      let h = d.flat.mul(1.1); const hl = h.len; if (hl > 650) h = h.mul(650 / hl);
      e.vel = h.add(new V3(0, 1150 + rage * 200, 0));
      e.timer = (1.7 - rage * 0.8) * (this.multi ? 0.85 : 1);
      e.squash = 1; e.phase = 2;
      this.sfx('whoosh', 0.6);
    }
    const extra = Math.max(0, this.slots.length - 1);
    if (e.hp < e.maxHP * 0.66 && e.spawnedMinis === 0) { e.spawnedMinis = 1; this.spawnMinis(e, 2 + extra); }
    if (e.hp < e.maxHP * 0.33 && e.spawnedMinis === 1) { e.spawnedMinis = 2; this.spawnMinis(e, 3 + extra); }
  }
  spawnMinis(boss, n) {
    this.popText('INTERNS!', boss.pos.add(new V3(0, 160, 0)), 0xffffff, 40);
    for (let k = 0; k < n; k++) {
      const a = k / n * 2 * Math.PI;
      const m = new Enemy('cube', boss.pos.add(new V3(Math.cos(a) * 80, 140, Math.sin(a) * 80)));
      m.vel = new V3(Math.cos(a) * 250, 600, Math.sin(a) * 250); m.timer = 1;
      this.addEnemy(m);
    }
  }
  bossLanded(e) {
    if (!this.bossAwake || e.phase !== 2) return;
    e.phase = 0;
    this.sfx('stomp', 0.9);
    this.addShake(18);
    this.puff(e.pos.sub(new V3(0, e.r, 0)), 20);
    const s = new Shockwave(e.pos.sub(new V3(0, e.r - 8, 0)));
    s.radius = e.r; s.setRadius(s.radius);
    this.shocks.push(s); this.worldNode.add(s.node);
    for (const sl of this.slots) if (sl.body.grounded) this.knock(sl, new V3(0, 120, 0));
  }
  updateShocks(dt) {
    for (const s of this.shocks) {
      s.life -= dt; s.radius += 560 * dt; s.setRadius(s.radius);
      s.node.material.opacity = Math.min(1, s.life * 3); s.node.material.transparent = true;
      for (const sl of this.slots) {
        if (sl.body.ko > 0 || sl.body.invuln > 0 || s.life <= 0.1) continue;
        const dist = sl.body.c.sub(s.center).xzLen;
        if (Math.abs(dist - s.radius) < 40 && sl.body.bottom < s.center.y + 22) this.hurt(sl, s.center);
      }
    }
    this.shocks = this.shocks.filter(s => { if (s.life <= 0) { this.worldNode.remove(s.node); return false; } return true; });
  }
  updateBoss(dt) {
    const b = this.boss, trig = this.level.bossTrigger;
    if (!b || b.dead || trig === null) return;
    const scale = 1 + 0.35 * (this.slots.length - 1);
    if (!this.bossAwake && this.slots.some(s => s.body.c.x > trig)) {
      this.bossAwake = true; b.awake = true; b.hp = b.maxHP * scale;
      this.audio.setMusic(3); this.musicStyle = 3;
      this.banner('MEGA CUBE', 'Chief Executive Cube');
      this.sfx('stomp', 0.8, 0.8);
      this.addShake(15);
      if (this.slots[0]) this.say(this.slots[0], ['uh oh.', "that's a big cube", "I'd like to speak to your manager... oh."], true);
    }
    if (this.bossAwake) {
      this.hud.bossBar(b.hp / (b.maxHP * scale));
      this.junkRain -= dt;
      if (this.junkRain <= 0) {
        this.junkRain = 2.2 / Math.sqrt(Math.max(1, this.slots.length));
        const k = new Pickup(pick(['duck', 'toast', 'fish', 'cheese', 'melon', 'bowling', 'chicken', 'sock', 'banana']), new V3(frand(6800, 8100), 900, frand(-260, 260)), true);
        k.life = 20; k.spin = frand(-5, 5);
        this.addPickup(k);
      }
    }
  }

  // ---------------- damage
  hurt(s, from) {
    const b = s.body;
    if (b.invuln > 0 || b.ko > 0 || b.flushing >= 0) return;
    let away = b.c.sub(from).flat;
    if (away.len < 1) away = new V3(-1, 0, 0);
    away = away.norm;
    this.knock(s, away.mul(520).add(new V3(0, 520, 0)), frand(2.5, 4.5), away.cross(new V3(0, 1, 0)).norm);
    b.invuln = 1.4; b.hurtFace = 0.9;
    this.addShake(12);
    if (b.eyes.length > 0) {
      const at = b.removeEye() || b.c;
      const k = new Pickup('eye', at, true);
      k.vel = away.mul(frand(200, 380)).add(new V3(0, frand(600, 800), 0)); k.delay = 0.9; k.life = 12;
      this.addPickup(k);
      this.sfx('hurt', 0.8);
      if (b.eyes.length === 0) this.say(s, ["I CAN'T SEE!", 'who turned off the world?', 'MY EYES! (both of them)'], true);
      else this.say(s, ['MY EYE!', 'that was my favourite eye', 'I needed that!', 'ow ow ow', 'not the eye!'], true);
    } else {
      b.ko = 2.2;
      this.sfx('ko', 0.8);
      this.popText('K.O.', b.c.add(new V3(0, 90, 0)), 0xff5a5a, 50);
      this.say(s, ['ow.', "I'll just lie here.", 'tell my eyes I love them'], true);
    }
  }
  checkCheckpoints() {
    this.level.checkpoints.forEach((cp, k) => {
      if (k <= this.checkpointIdx) return;
      if (!this.slots.some(s => s.body.c.x > cp.x - 20 && Math.abs(s.body.c.y - cp.y) < 260)) return;
      this.checkpointIdx = k;
      raiseFlag(this.checkpointFlags[k], false);
      this.emit(['cp', k]);
      this.sfx('checkpoint', 0.7);
      this.popText('CHECKPOINT!', cp.add(new V3(0, 200, 0)), 0x9dff8a, 30);
      for (const o of this.slots) if (o.body.eyes.length < 2) { while (o.body.eyes.length < 2) o.body.addEye(); this.say(o, ['free eyes!', 'fresh eyes!'], true); }
      this.storeRun();
    });
  }

  // ================================================================ camera & projection
  updateCamera(dt) {
    let target = this.player.c.add(new V3(clamp(this.player.cVel.x * 0.2, -160, 160), 0, 0));
    let spread = 0;
    const L = this.leader;
    if (this.multi && L) {
      const group = this.slots.filter(s => !s.behind && s.body.c.y > this.world.killY + 200);
      const pts = group.length ? group.map(s => s.body.c) : [L.body.c];
      const center = pts.reduce((a, p) => a.add(p), new V3()).mul(1 / pts.length);
      spread = Math.max(...pts.map(p => p.sub(center).xzLen));
      target = center.add(new V3(clamp(L.body.cVel.x * 0.15, -120, 120), 0, 0));
    }
    if (this.state === 'title') target = this.level.start.add(new V3(330, 60, 0));
    if (this.flushT >= 0 || this.state === 'done' || this.state === 'won') target = this.level.goal.add(new V3(0, 60, 0));
    if (this.bossAwake && this.boss && !this.boss.dead) target = target.add(this.boss.pos).mul(0.5);
    const ct = this.camTarget;
    ct.x += (target.x - ct.x) * Math.min(1, 5 * dt); ct.z += (target.z - ct.z) * Math.min(1, 4 * dt); ct.y += (target.y - ct.y) * Math.min(1, 3 * dt);
    let dist = this.camDist * clamp(0.95 + spread / 800, 1, 2);
    if (this.bossAwake) dist *= 1.35;
    if (this.state === 'title') dist = 0.85;
    const aspect = innerWidth / Math.max(1, innerHeight);
    if (aspect < 1.2) dist *= 1.2 / Math.max(0.5, aspect);    // narrow windows: pull back
    this.shake = Math.max(0, this.shake - dt * 40);
    const j = new V3(frand(-1, 1), frand(-1, 1), frand(-1, 1)).mul(this.shake);
    const look = ct.add(new V3(0, 45, 0));
    const pos = look.add(new V3(-170, 360, 880).mul(dist)).add(j);
    this.camera.position.set(pos.x, pos.y, pos.z);
    this.camera.lookAt(look.x + j.x * 0.5, look.y + j.y * 0.5, look.z + j.z * 0.5);
    this.sun.position.set(look.x + this.sunDir.x * 2500, look.y + this.sunDir.y * 2500, look.z + this.sunDir.z * 2500);
    this.sun.target.position.set(look.x, look.y, look.z);
  }
  project(p) {
    const v = new THREE.Vector3(p.x, p.y, p.z).project(this.camera);
    if (v.z < -1 || v.z > 1) return null;
    return { x: (v.x + 1) / 2 * innerWidth, y: (1 - v.y) / 2 * innerHeight };
  }
  updateTags() {
    for (const s of this.slots) {
      const show = this.multi && (this.state === 'playing' || this.state === 'paused') && s.body.flushing < 0;
      if (!s.tag) continue;
      s.tag.style.display = show ? '' : 'none';
      if (!show) continue;
      const tn = s.tag.querySelector('.tn');
      const txt = s.body.eyes.length === 0 ? `${s.name} · CAN'T SEE` : s.body.ko > 0 ? `${s.name} · K.O.` : s.name;
      if (tn.textContent !== txt) tn.textContent = txt;
      s.tag.classList.toggle('behind', s.behind);
      const p = this.project(new V3(s.body.c.x, s.body.top + 26, s.body.c.z));
      const W = innerWidth, H = innerHeight;
      if (p) { s.tag.style.left = clamp(p.x, 70, W - 70) + 'px'; s.tag.style.top = clamp(p.y, 130, H - 60) + 'px'; }
    }
  }

  // ================================================================ effects
  popText(text, p, color, size) {
    this.emit(['t', text, Math.round(p.x), Math.round(p.y), Math.round(p.z), color, Math.round(size)]);
    const el = this.hud.popText(text, color, size);
    this.popups.push({ el, pos: p.clone(), life: 1.1 });
  }
  updatePopups(dt) {
    for (const u of this.popups) {
      u.life -= dt; u.pos.y += 60 * dt;
      const sp = this.project(u.pos);
      if (sp) { u.el.style.display = ''; u.el.style.left = sp.x + 'px'; u.el.style.top = sp.y + 'px'; } else u.el.style.display = 'none';
      if (u.life < 0.3) u.el.style.opacity = Math.max(0, u.life / 0.3);
    }
    this.popups = this.popups.filter(u => { if (u.life <= 0) { u.el.remove(); return false; } return true; });
  }
  confetti(p, n, net = true) {
    if (net) this.emit(['fx', 1, Math.round(p.x), Math.round(p.y), Math.round(p.z), n, 0]);
    for (let i = 0; i < n; i++) {
      const s = new THREE.Mesh(CONFETTI_GEO, pick(CONFETTI_MATS));
      s.scale.set(frand(0.7, 1.3), frand(0.7, 1.3), 1);
      this.worldNode.add(s);
      const dir = new V3(frand(-1, 1), frand(0.1, 1), frand(-1, 1)).norm;
      this.particles.push(new Particle(s, p, dir.mul(frand(200, 700)).add(new V3(0, 200, 0)), frand(1, 2), { gravity: -900, spin: frand(-12, 12), drag: 1.2, shrink: false }));
    }
  }
  puff(p, n, net = true) {
    if (n <= 0) return;
    if (net) this.emit(['fx', 0, Math.round(p.x), Math.round(p.y), Math.round(p.z), n, 0]);
    for (let i = 0; i < n; i++) {
      const s = new THREE.Mesh(PUFF_GEO, PUFF_MAT.clone());
      s.scale.setScalar(frand(7, 14));
      this.worldNode.add(s);
      const a = frand(0, 2 * Math.PI);
      this.particles.push(new Particle(s, p.add(new V3(Math.cos(a) * 25, 4, Math.sin(a) * 25)), new V3(Math.cos(a) * frand(120, 240), frand(20, 140), Math.sin(a) * frand(120, 240)), frand(0.35, 0.6), { gravity: 0, drag: 4 }));
    }
  }
  splat(p, color, net = true) {
    if (net) this.emit(['fx', 2, Math.round(p.x), Math.round(p.y), Math.round(p.z), 10, color]);
    const m = new THREE.MeshStandardMaterial({ color, roughness: 0.3, transparent: true });
    for (let i = 0; i < 10; i++) {
      const s = new THREE.Mesh(PUFF_GEO, m); s.scale.setScalar(frand(3, 7));
      this.worldNode.add(s);
      this.particles.push(new Particle(s, p, new V3(frand(-260, 260), frand(50, 360), frand(-260, 260)), frand(0.4, 0.8)));
    }
  }
  sparkle(p, net = true) {
    if (net) this.emit(['fx', 3, Math.round(p.x), Math.round(p.y), Math.round(p.z), 14, 0]);
    for (let i = 0; i < 14; i++) {
      const s = new THREE.Mesh(PUFF_GEO, SPARK_MAT); s.scale.setScalar(3);
      this.worldNode.add(s);
      this.particles.push(new Particle(s, p, new V3(frand(-1, 1), frand(-1, 1), frand(-1, 1)).norm.mul(frand(100, 300)), 0.7, { gravity: 0, drag: 3 }));
    }
  }
  updateParticles(dt) {
    for (const p of this.particles) {
      p.life -= dt;
      p.vel.y += p.gravity * dt;
      p.vel.muli(Math.max(0, 1 - p.drag * dt));
      p.pos.addi(p.vel.mul(dt));
      p.node.position.set(p.pos.x, p.pos.y, p.pos.z);
      if (p.spin) { p.angle += p.spin * dt; p.node.quaternion.setFromAxisAngle(p.axis, p.angle); }
      const k = Math.max(0, p.life / p.maxLife);
      if (p.grow) { const s = 1 + (p.grow - 1) * (1 - k); p.node.scale.setScalar(s); }
      else if (p.shrink) { if (p.baseScale === undefined) p.baseScale = p.node.scale.x; p.node.scale.setScalar(p.baseScale * (0.3 + 0.7 * k)); }
      const op = Math.min(1, k * 3);
      p.node.traverse(o => { if (o.material && o.material.transparent !== undefined) { if (!o.material.userData.own) { o.material = o.material.clone(); o.material.userData.own = true; } o.material.transparent = true; o.material.opacity = op; } });
    }
    this.particles = this.particles.filter(p => { if (p.life <= 0) { p.node.parent?.remove(p.node); return false; } return true; });
  }

  // ================================================================ speech
  say(s, lines, priority = false, fromNet = false) {
    if (this.role === 'guest' && !fromNet) return;
    if (!priority && s.quipCooldown > 0) return;
    const text = pick(lines); if (!text) return;
    s.quipCooldown = 3;
    this.emit(['q', s.index, text]);
    s.bubble?.remove();
    s.bubble = this.hud.bubble(text, this.multi ? s.color : undefined);
    s.bubbleLife = 2.2;
    const syll = Math.max(2, Math.min(9, Math.floor(text.length / 3)));
    const base = frand(1, 1.15) * s.voicePitch;
    let t = 0;
    for (let k = 0; k < syll; k++) {
      setTimeout(() => this.audio.play('voice', 0.35, base * frand(0.88, 1.18) * (k === syll - 1 ? 0.9 : 1), 0), t * 1000);
      t += frand(0.07, 0.11);
    }
    s.body.mouthOpen = 1;
  }
  updateBubble(s, dt) {
    if (!s.bubble) return;
    s.bubbleLife -= dt;
    const sp = this.project(new V3(s.body.c.x, s.body.top + 20, s.body.c.z));
    if (sp) { s.bubble.style.left = sp.x + 'px'; s.bubble.style.top = (sp.y - (this.multi ? 22 : 0)) + 'px'; }
    if (s.bubbleLife < 0.3) s.bubble.style.opacity = Math.max(0, s.bubbleLife / 0.3);
    if (s.bubbleLife <= 0) { s.bubble.remove(); s.bubble = null; }
    if (s.bubbleLife > 0.2) s.body.mouthOpen = Math.max(s.body.mouthOpen, 0.4 + 0.4 * Math.abs(Math.sin(this.time * 25)));
  }

  // ================================================================ online (same protocol as the Mac app)
  emit(e) { if (this.role === 'host') this.evOut.push(e); }
  sfx(name, volume = 1, rate = 1, jitter = 0.04) { this.audio.play(name, volume, rate, jitter); this.emit(['s', name, Math.round(volume * 100), Math.round(rate * 100)]); }
  addShake(a) { this.shake = Math.max(this.shake, a); this.emit(['k', Math.round(a)]); }
  banner(top, sub) { this.hud.banner(top, sub); this.emit(['b', top, sub]); }
  toast(s) { this.hud.toast(s); this.emit(['o', s]); }
  knock(s, dv, spin = 0, axis = new V3(0, 0, 1), jolt = true) {
    s.body.shove(dv, spin, axis);
    if (jolt) s.body.jolt();
    this.emit(['kn', s.index, Math.round(dv.x), Math.round(dv.y), Math.round(dv.z), Math.round(spin * 100), Math.round(axis.x * 100), Math.round(axis.y * 100), Math.round(axis.z * 100), jolt ? 1 : 0]);
  }
  placeSlot(s, p) {
    s.body.place(p);
    s.placeCount++;
    this.emit(['pl', s.index, Math.round(p.x), Math.round(p.y), Math.round(p.z), s.placeCount]);
  }
  hostFlush() { if (this.role === 'host' && this.evOut.length) { this.net?.send({ t: 'ev', e: this.evOut }); this.evOut = []; } }

  openOnline() {
    this.titleCountdown = null;
    this.clearSlots();
    this.worldNode.add(this.titleBody.root);
    this.titleMode = 'online'; this.netError = '';
    if (!this.net) this.net = new Net(this.serverURL);
    this.listTimer = 0;
  }
  leaveOnline(reason) {
    this.net?.close(); this.net = null; this.role = 'offline'; this.lobbyCode = ''; this.menuOpen = false;
    this.state = 'playing';
    this.toTitle();
    this.hud.toast(reason);
  }
  syncRoster(players) {
    const seen = new Set();
    for (const p of players) {
      seen.add(p.seat);
      const s = this.slot(p.seat);
      if (s) s.netName = p.name; else this.join(p.seat === this.mySeat ? Schemes.keysA : Schemes.remote(p.seat), p.seat, p.name);
    }
    for (const s of [...this.slots]) if (!seen.has(s.index)) this.removeSlot(s.index);
  }
  pumpNet() {
    const n = this.net; if (!n) return;
    if (n.status === 'closed' && this.role !== 'offline') return this.leaveOnline('Lost connection: ' + n.why);
    for (const m of n.drain()) {
      switch (m.t) {
        case 'lobbies': this.lobbyList = m.list || []; break;
        case 'joined':
          this.lobbyCode = m.code; this.mySeat = m.seat; this.netError = '';
          this.clearSlots(); this.worldNode.remove(this.titleBody.root);
          if (m.host) { this.role = 'host'; this.join(Schemes.keysA, 0, this.name); }
          else { this.role = 'guest'; this.syncRoster(m.players || []); }
          this.titleMode = 'lobby';
          this.audio.play('checkpoint', 0.6);
          if (this.role === 'guest' && m.started) this.startGuest(m.level);
          break;
        case 'players':
          if (this.role === 'guest') this.syncRoster(m.players || []);
          else for (const p of m.players || []) { const s = this.slot(p.seat); if (s) s.netName = p.name; }
          break;
        case 'arrive':
          if (this.role === 'host') { this.join(Schemes.remote(m.seat), m.seat, m.name); this.snapCount = 0; if (this.state === 'playing') this.toast(`${m.name} JOINED!`); }
          break;
        case 'left': this.removeSlot(m.seat); break;
        case 'start': if (this.role === 'guest') this.startGuest(m.level); break;
        case 'snap': if (this.role === 'guest') this.applySnap(m); break;
        case 'ev': if (this.role === 'guest') this.applyEvents(m.e || []); break;
        case 'in': if (this.role === 'host') { const s = this.slot(m.seat); if (s) this.readInput(s, m); } break;
        case 'closed': return this.leaveOnline(m.reason || 'The lobby closed');
        case 'error': this.netError = m.msg; this.audio.play('hurt', 0.4); break;
      }
    }
  }
  updateOnlineTitle(dt) {
    const n = this.net, input = this.input;
    if (!n) { this.titleMode = 'main'; return; }
    const open = n.status === 'open';
    this.listTimer -= dt;
    if (open && this.listTimer <= 0 && this.titleMode === 'online') { n.send({ t: 'list' }); this.listTimer = 3; }
    this.autoOnline(n, open);
    if (this.titleMode === 'online') {
      if (input.wasPressed('Escape')) { n.close(); this.net = null; this.role = 'offline'; this.titleMode = 'main'; return; }
      if (open && input.wasPressed('KeyH')) { this.audio.play('click'); n.send({ t: 'create', name: this.name }); }
      if (input.wasPressed('KeyJ')) { this.audio.play('click'); this.titleMode = 'code'; this.codeEntry = ''; this.netError = ''; }
      ['Digit1', 'Digit2', 'Digit3', 'Digit4', 'Digit5', 'Digit6'].forEach((k, i) => { if (input.wasPressed(k) && this.lobbyList[i]) n.send({ t: 'join', code: this.lobbyList[i].code, name: this.name }); });
    } else if (this.titleMode === 'code') {
      for (const ch of input.typed) if (/[a-z]/i.test(ch) && this.codeEntry.length < 4) this.codeEntry += ch.toUpperCase();
      if (input.wasPressed('Backspace')) this.codeEntry = this.codeEntry.slice(0, -1);
      if (input.wasPressed('Escape')) this.titleMode = 'online';
      if (input.wasPressed('Enter', 'NumpadEnter') && this.codeEntry.length === 4 && open) { this.audio.play('click'); n.send({ t: 'join', code: this.codeEntry, name: this.name }); }
    } else if (this.titleMode === 'lobby') {
      if (input.wasPressed('Escape')) {
        n.send({ t: 'leave' }); this.clearSlots(); this.worldNode.add(this.titleBody.root);
        this.role = 'offline'; this.lobbyCode = ''; this.titleMode = 'online'; return;
      }
      if (this.role === 'host') {
        ['Digit1', 'Digit2', 'Digit3'].forEach((k, i) => { if (input.wasPressed(k) && this.save.unlocked > i) this.lobbyLevel = i; });
        if (input.wasPressed('Enter', 'NumpadEnter') || (this.autoHost && this.slots.length >= this.autoPlayers)) { this.audio.play('click'); this.startLevel(this.lobbyLevel, true); }
      }
    }
  }
  readInput(s, m) {
    const r = s.remote;
    r.move = { x: (m.mx || 0) / 100, y: (m.mz || 0) / 100 };
    r.squish = !!m.sq;
    r.jump = Math.max(r.jump, m.j || 0); r.fire = Math.max(r.fire, m.f || 0); r.honk = Math.max(r.honk, m.h || 0); r.teleport = Math.max(r.teleport, m.tp || 0);
    r.aim = m.aim && m.aim.length === 3 ? new V3(m.aim[0], m.aim[1], m.aim[2]) : null;
    if (m.p && m.p.length === 6) { r.pos = new V3(m.p[0], m.p[1], m.p[2]); r.vel = new V3(m.p[3], m.p[4], m.p[5]); }
    r.placeAck = m.pl || 0;
  }
  remoteActions(s) {
    const r = s.remote;
    const a = { move: { ...r.move }, squish: r.squish, jumpPressed: r.jump > r.seenJump, fire: r.fire > r.seenFire, fireHeld: false, mouseAim: !!r.aim, honk: r.honk > r.seenHonk, teleport: r.teleport > r.seenTeleport };
    r.seenJump = r.jump; r.seenFire = r.fire; r.seenHonk = r.honk; r.seenTeleport = r.teleport;
    return a;
  }
  applyRemoteAuthority(s, dt) {
    const r = s.remote;
    if (r.placeAck < s.placeCount || !r.pos || s.body.flushing >= 0) return;
    const err = r.pos.sub(s.body.c);
    s.body.translate(err.len > 300 ? err : err.mul(Math.min(1, dt * 12)));
  }
  hostNetTick(dt) {
    this.snapTimer += dt;
    if (this.snapTimer < 0.05 || !this.net) return;
    this.snapTimer = 0;
    this.hostFlush();
    this.net.send(this.buildSnap());
    this.snapCount++;
  }
  buildSnap() {
    const r = Math.round;
    const p = this.slots.map(s => {
      const b = s.body;
      return [s.index, r(b.c.x), r(b.c.y), r(b.c.z), r(b.cVel.x), r(b.cVel.y), r(b.cVel.z), b.eyes.length, b.ko > 0 ? 1 : 0,
        r(s.lastCtl.move.x * 100), r(s.lastCtl.move.y * 100), s.lastCtl.squish ? 1 : 0, s.jumpCount, s.behind ? 1 : 0,
        s.flushOrder, s.inventory.map(j => JUNK.indexOf(j)), s.placeCount, b.invuln > 0 ? 1 : 0];
    });
    const e = this.enemies.filter(x => !x.dead).map(x => [x.netID, ENEMY_KINDS.indexOf(x.kind), r(x.pos.x), r(x.pos.y), r(x.pos.z), r(x.yaw * 100), r(x.tumble * 100),
      r(x.tumbleAxis.x * 100), r(x.tumbleAxis.z * 100), r(x.squash * 100), x.stun > 0 ? 1 : 0, x.hurtFlash > 0 ? 1 : 0]);
    const dp = this.pickups.filter(k => !k.dead && k.netID >= 2000).map(k => [k.netID, k.what === 'eye' ? -1 : JUNK.indexOf(k.what), r(k.pos.x), r(k.pos.y), r(k.pos.z)]);
    const pr = this.projectiles.filter(q => !q.dead).map(q => [q.netID, JUNK.indexOf(q.junk), q.isPoop ? 1 : 0, r(q.pos.x), r(q.pos.y), r(q.pos.z), q.r < 12 && q.junk === 'melon' ? 1 : 0]);
    const sw = this.shocks.map(s => [r(s.center.x), r(s.center.y), r(s.center.z), r(s.radius), r(s.life * 100)]);
    const bossFrac = this.boss ? this.boss.hp / (this.boss.maxHP * (1 + 0.35 * (this.slots.length - 1))) : 0;
    const m = { t: 'snap', s: this.score, lv: this.levelIndex, cp: this.checkpointIdx, gv: this.goalVisible ? 1 : 0, ft: r(this.flushT * 100), ba: this.bossAwake ? 1 : 0,
      bh: r(bossFrac * 1000), ld: this.leader ? this.leader.index : -1, mu: this.musicStyle ?? this.level.theme.music, p, e, dp, pr, sw };
    if (this.snapCount % 40 === 0) m.pa = this.pickups.filter(k => !k.dead && k.netID < 2000).map(k => k.netID);
    return m;
  }
  startGuest(lv) {
    this.titleMode = 'main'; this.menuOpen = false;
    for (const s of this.slots) { s.bonks = 0; s.collected = 0; s.falls = 0; s.jumpCount = 0; s.flushOrder = -1; s.remote = new Slot(s.index, s.scheme).remote; }
    this.state = 'playing';
    this.loadLevel(lv);
    this.flushT = -1;
    this.hud.hideTitle(); this.hud.hidePanel();
    this.hud.banner(`ONLINE · LOBBY ${this.lobbyCode}`, this.level.name);
  }
  applySnap(m) {
    if (this.state !== 'playing' && this.state !== 'done') return;
    this.lastSnapAt = this.time;
    if (m.lv !== this.levelIndex && this.state === 'playing') return this.startGuest(m.lv);
    this.score = m.s;
    if (m.cp > this.checkpointIdx) { for (let k = this.checkpointIdx + 1; k <= m.cp && k < this.checkpointFlags.length; k++) raiseFlag(this.checkpointFlags[k], true); this.checkpointIdx = m.cp; }
    if (!!m.gv !== this.goalVisible && this.goalDrop < 0) { this.goalVisible = !!m.gv; this.goalNode.visible = this.goalVisible; }
    const ft = m.ft / 100;
    if (ft >= 0 && this.flushT < 0) { this.flushT = ft; for (const s of this.slots) s.body.flushing = 0; this.crown.visible = false; }
    this.bossAwake = !!m.ba;
    this.hud.bossBar(this.bossAwake ? m.bh / 1000 : null);
    if (this.musicStyle !== m.mu) { this.musicStyle = m.mu; this.audio.setMusic(m.mu); }
    this.leader = this.slot(m.ld);
    for (const a of m.p || []) {
      const s = this.slot(a[0]); if (!s) continue;
      const pos = new V3(a[1], a[2], a[3]), vel = new V3(a[4], a[5], a[6]);
      if (s.body.eyes.length !== a[7]) s.body.setEyes(a[7]);
      s.body.ko = a[8] === 1 ? 1 : 0;
      s.behind = a[13] === 1; s.flushOrder = a[14];
      s.inventory = (a[15] || []).map(i => JUNK[i]).filter(Boolean);
      if (a[17] === 1) s.body.invuln = Math.max(s.body.invuln, 0.12);
      if (s.index !== this.mySeat) {
        s.netTarget = pos; s.netVel = vel;
        s.remote.move = { x: a[9] / 100, y: a[10] / 100 }; s.remote.squish = a[11] === 1;
        if (s.remote.seenJump === 0 && s.remote.jump === 0) s.remote.seenJump = a[12];
        s.remote.jump = a[12];
      }
    }
    const alive = new Set();
    for (const a of m.e || []) {
      const id = a[0]; alive.add(id);
      const pos = new V3(a[2], a[3], a[4]);
      let e = this.enemies.find(x => x.netID === id);
      if (!e && ENEMY_KINDS[a[1]]) { e = new Enemy(ENEMY_KINDS[a[1]], pos); e.netID = id; this.addEnemy(e); }
      if (!e) continue;
      this.netEnemyTargets.set(id, { pos, yaw: a[5] / 100, tumble: a[6] / 100, axis: new V3(a[7] / 100, 0, a[8] / 100) });
      e.squash = Math.max(e.squash, a[9] / 100); e.stun = a[10] === 1 ? 0.2 : 0; if (a[11] === 1) e.hurtFlash = 0.1;
    }
    for (const e of this.enemies) if (!e.dead && !alive.has(e.netID)) { e.dead = true; this.fadeOut(e.node, 1.5); }
    this.enemies = this.enemies.filter(e => !e.dead);
    for (const a of m.dp || []) {
      const pos = new V3(a[2], a[3], a[4]);
      const k = this.pickups.find(x => x.netID === a[0] && !x.dead);
      if (k) { k.netTarget = pos; continue; }
      const nk = new Pickup(a[1] < 0 ? 'eye' : (JUNK[a[1]] || 'duck'), pos);
      nk.netID = a[0]; nk.netTarget = pos;
      this.addPickup(nk);
    }
    if (m.pa) {
      const keep = new Set(m.pa);
      for (const k of this.pickups) if (k.netID < 2000 && !keep.has(k.netID)) { k.dead = true; this.worldNode.remove(k.node); }
      this.pickups = this.pickups.filter(k => !k.dead);
    }
    const live = new Set();
    for (const a of m.pr || []) {
      live.add(a[0]);
      const pos = new V3(a[3], a[4], a[5]);
      const q = this.projectiles.find(x => x.netID === a[0]);
      if (q) { q.netTarget = pos; continue; }
      const nq = new Projectile(JUNK[a[1]] || 'pea', pos, new V3(), false, a[2] === 1);
      nq.netID = a[0]; nq.netTarget = pos;
      if (a[6] === 1) nq.node.scale.setScalar(0.45);
      this.addProjectile(nq);
    }
    for (const q of this.projectiles) if (!live.has(q.netID)) { q.dead = true; this.worldNode.remove(q.node); }
    this.projectiles = this.projectiles.filter(q => !q.dead);
    const sw = m.sw || [];
    while (this.shocks.length > sw.length) this.worldNode.remove(this.shocks.pop().node);
    sw.forEach((a, k) => {
      const c = new V3(a[0], a[1], a[2]);
      if (k >= this.shocks.length) { const s = new Shockwave(c); this.shocks.push(s); this.worldNode.add(s.node); }
      const s = this.shocks[k];
      s.center = c; s.node.position.set(c.x, c.y, c.z); s.radius = a[3]; s.life = a[4] / 100; s.setRadius(s.radius);
      s.node.material.transparent = true; s.node.material.opacity = Math.min(1, s.life * 3);
    });
  }
  applyEvents(list) {
    for (const e of list) {
      const [t] = e;
      switch (t) {
        case 's': this.audio.play(e[1], e[2] / 100, e[3] / 100); break;
        case 't': { const saved = this.role; this.role = 'offline'; this.popText(e[1], new V3(e[2], e[3], e[4]), e[5], e[6]); this.role = saved; break; }
        case 'q': { const s = this.slot(e[1]); if (s) this.say(s, [e[2]], true, true); break; }
        case 'fx': {
          const p = new V3(e[2], e[3], e[4]);
          if (e[1] === 0) this.puff(p, e[5], false); else if (e[1] === 1) this.confetti(p, e[5], false); else if (e[1] === 2) this.splat(p, e[6], false); else this.sparkle(p, false);
          break;
        }
        case 'k': this.shake = Math.max(this.shake, e[1]); break;
        case 'b': this.hud.banner(e[1], e[2]); break;
        case 'o': this.hud.toast(e[1]); break;
        case 'kn': { const s = this.slot(e[1]); if (s) { s.body.shove(new V3(e[2], e[3], e[4]), e[5] / 100, new V3(e[6], e[7], e[8]).mul(0.01)); if (e[9] === 1) s.body.jolt(); s.body.hurtFace = Math.max(s.body.hurtFace, 0.3); } break; }
        case 'bo': { const s = this.slot(e[1]); if (s) { s.body.bounceUp(e[2]); s.body.jolt(); } break; }
        case 'pl': { const s = this.slot(e[1]); if (s) { const p = new V3(e[2], e[3], e[4]); s.body.place(p); s.body.invuln = 1.2; s.placeCount = e[5]; s.netTarget = p; } break; }
        case 'cp': if (e[1] < this.checkpointFlags.length && e[1] > this.checkpointIdx) { raiseFlag(this.checkpointFlags[e[1]], false); this.checkpointIdx = e[1]; } break;
        case 'gd': this.dropGoal(); break;
        case 'pg': { const k = this.pickups.find(x => x.netID === e[1] && !x.dead); if (k) { k.dead = true; this.fadeOut(k.node, 1.8); } this.pickups = this.pickups.filter(x => !x.dead); break; }
        case 'done': {
          for (const a of e[4] || []) { const s = this.slot(a[0]); if (s) { s.collected = a[1]; s.bonks = a[2]; s.falls = a[4]; s.flushOrder = a[5]; } }
          this.state = 'done'; this.doneTimer = 0;
          this.audio.play('win');
          this.hud.showDone(this.level, e[1], this.slots, e[2], e[3] === 1, true);
          for (const s of this.slots) s.body.place(new V3(0, -5000, 0));
          break;
        }
        case 'win': this.state = 'won'; this.doneTimer = 0; this.audio.play('win'); this.hud.showWin(e[1], this.slots.length); break;
      }
    }
  }
  updateGuest(dt) {
    this.bounceSoundCooldown -= dt;
    this.world.moveMovers(dt);
    const input = this.input;
    const acts = this.slots.map(s => {
      const ctl = { move: { x: 0, y: 0 }, jump: false, squish: false };
      if (s.index === this.mySeat) {
        const a = this.menuOpen ? readActions({ id: 'none' }, input, true) : this.demo ? this.demoActions(s) : readActions(Schemes.keysA, input, true);
        s.jumpBuffer -= dt;
        if (a.jumpPressed) s.jumpBuffer = 0.13;
        ctl.move = a.move; ctl.squish = a.squish; ctl.jump = s.jumpBuffer > 0;
        if ((a.fire || (a.fireHeld && s.fireCooldown < -0.1)) && s.fireCooldown <= 0) { s.remote.fire++; s.fireCooldown = 0.22; s.body.mouthOpen = 1; }
        s.fireCooldown -= dt;
        if (a.honk) s.remote.honk++;
        if (a.teleport && s.behind) s.remote.teleport++;
        s.lastCtl = ctl;
      } else {
        ctl.move = s.remote.move; ctl.squish = s.remote.squish;
        ctl.jump = s.remote.jump > s.remote.seenJump; s.remote.seenJump = s.remote.jump;
      }
      if (s.body.ko > 0 || s.body.flushing >= 0) { ctl.move = { x: 0, y: 0 }; ctl.jump = false; ctl.squish = false; }
      return ctl;
    });
    if (this.flushT < 0) {
      const h = dt / 4, events = this.slots.map(() => []);
      for (let sub = 0; sub < 4; sub++) {
        this.slots.forEach((s, i) => { if (s.body.flushing >= 0) return; const c = { ...acts[i] }; if (sub > 0) c.jump = false; s.body.step(h, c, this.world, events[i]); });
        if (this.multi) for (const a of this.slots) for (const b of this.slots) if (a !== b) a.body.pushOut(b.body);
      }
      this.slots.forEach((s, i) => {
        if (s.index === this.mySeat) for (const e of events[i]) if (e.type === 'jump' || e.type === 'superJump') s.jumpBuffer = 0;
        this.handle(events[i], s);
      });
      for (const s of this.slots) {
        if (s.index === this.mySeat || !s.netTarget) continue;
        const err = s.netTarget.add(s.netVel.mul(0.09)).sub(s.body.c);
        s.body.translate(err.len > 350 ? err : err.mul(Math.min(1, dt * 9)));
      }
    } else this.updateFlush(dt);
    const me = this.slot(this.mySeat);
    if (me) this.updateAim(me);
    for (const s of this.slots) { s.body.frame(dt, this.world, this.time); s.body.draw(this.world, this.time); this.updateBubble(s, dt); }
    for (const p of this.pickups) {
      if (p.dead) continue;
      if (p.netTarget) p.pos.addi(p.netTarget.sub(p.pos).mul(Math.min(1, dt * 12)));
      p.update(dt, this.world, this.camera);
    }
    for (const q of this.projectiles) {
      if (q.netTarget) { const d = q.netTarget.sub(q.pos); q.pos.addi(d.mul(Math.min(1, dt * 14))); if (d.len > 2) q.angle += dt * 10; }
      q.node.position.set(q.pos.x, q.pos.y, q.pos.z);
      q.node.quaternion.setFromAxisAngle(q.spinAxis, q.angle);
    }
    for (const e of this.enemies) {
      if (e.dead) continue;
      const t = this.netEnemyTargets.get(e.netID);
      if (t) {
        e.pos.addi(t.pos.sub(e.pos).mul(Math.min(1, dt * 12)));
        e.yaw += wrapAngle(t.yaw - e.yaw) * Math.min(1, dt * 12);
        e.tumble += (t.tumble - e.tumble) * Math.min(1, dt * 12);
        if (t.axis.len > 0.1) e.tumbleAxis = t.axis.norm;
      }
      e.squash = Math.max(0, e.squash - dt * 4); e.hurtFlash -= dt;
      e.pose(this.time); e.updateEyes(dt);
    }
    this.updateParticles(dt);
    this.updateGoalDrop(dt);
    this.positionCrown();
    if (this.time - this.lastSnapAt > 6) this.hud.toast('waiting for the host…');
    this.inputTimer += dt;
    if (this.inputTimer >= 1 / 30 && me && this.net) {
      this.inputTimer = 0;
      const b = me.body, r = Math.round;
      const m = { t: 'in', mx: r(me.lastCtl.move.x * 100), mz: r(me.lastCtl.move.y * 100), sq: me.lastCtl.squish ? 1 : 0, j: me.jumpCount, f: me.remote.fire, h: me.remote.honk, tp: me.remote.teleport, pl: me.placeCount,
        p: [r(b.c.x), r(b.c.y), r(b.c.z), r(b.cVel.x), r(b.cVel.y), r(b.cVel.z)] };
      if (me.aimPoint && (input.mouseMovedRecently > 0 || input.mouseHeld)) m.aim = [r(me.aimPoint.x), r(me.aimPoint.y), r(me.aimPoint.z)];
      this.net.send(m);
    }
  }

  // ================================================================ bot (for ?bot=1 and testing)
  demoActions(s) {
    const a = { move: { x: 1, y: clamp((s.index * 60 - 90 - s.body.c.z) / 150, -0.6, 0.6) }, squish: false, jumpPressed: false, fire: false, fireHeld: false, mouseAim: false, honk: false, teleport: false };
    const b = s.body, w = this.world;
    if (this.goalVisible && Math.abs(this.level.goal.x - b.c.x) < 700) {
      const d = this.level.goal.sub(b.c), l = Math.hypot(d.x, d.z) || 1;
      a.move = { x: d.x / l, y: d.z / l };
      if (this.boss && !this.boss.dead) a.move = { x: 0, y: 0 };
    }
    if (s.demoBack > 0) { s.demoBack -= 1 / 60; a.move.x = -1; if (s.demoBack <= 0) s.demoHold = 0.95; return a; }
    if (s.demoHold > 0) { s.demoHold -= 1 / 60; a.squish = s.demoHold > 0.05 && b.grounded; a.move = { x: 0, y: 0 }; return a; }
    const f = b.c.x + 75, z = b.c.z;
    const wall = w.solidAt(new V3(f, b.c.y - 20, z)) || w.solidAt(new V3(f, b.c.y + 20, z));
    const tall = w.solidAt(new V3(f, b.c.y + 120, z));
    const below = w.groundBelow(b.c.x + 120, z, b.c.y + 40);
    const pit = below === null || below < b.bottom - 120;
    const fanAhead = w.fans.some(fn => b.c.x + 150 > fn.lo.x && b.c.x < fn.lo.x);
    if (b.grounded) {
      const roof = w.solidAt(new V3(b.c.x, b.c.y + 150, z)) || w.solidAt(new V3(b.c.x + 40, b.c.y + 150, z));
      if (wall && tall && roof) s.demoBack = 0.6;
      else if (wall && tall) s.demoHold = 0.95;
      else if (wall || (pit && !fanAhead)) a.jumpPressed = true;
      else if (Math.random() < 0.004) a.jumpPressed = true;
    }
    if (b.inFan) a.move.x = b.c.y > 560 ? 1 : 0.2;
    a.fire = !!this.demoTarget(s) && Math.random() < 0.12;
    a.teleport = s.behind && Math.random() < 0.05;
    return a;
  }
  demoTarget(s) {
    let best = null, bd = Infinity;
    for (const e of this.enemies) { if (e.dead || Math.abs(e.pos.x - s.body.c.x) > 650 || Math.abs(e.pos.y - s.body.c.y) > 400) continue; const d = e.pos.sub(s.body.c).len; if (d < bd) { bd = d; best = e; } }
    return best ? best.pos.clone() : null;
  }
  autoOnline(n, open) {
    if (!open) return;
    if (this.autoHost && this.titleMode === 'online' && !this.lobbyCode && !this.autoSent) { this.autoSent = true; n.send({ t: 'create', name: this.name }); }
    if (this.autoJoin && this.titleMode === 'online' && !this.lobbyCode && !this.autoSent) { this.autoSent = true; n.send({ t: 'join', code: this.autoJoin, name: this.name }); }
  }
  hookTestFlags() {
    const q = new URLSearchParams(location.search);
    this.serverURL = q.get('server') || undefined;
    if (q.get('bot')) this.demo = true;
    if (q.get('host')) { this.autoHost = true; this.autoPlayers = +q.get('host') || 2; this.openOnline(); }
    if (q.get('join')) { this.autoJoin = q.get('join').toUpperCase(); this.openOnline(); }
    if (q.get('level')) { const n = +q.get('players') || 1; for (const sc of [Schemes.keysA, Schemes.keysB, Schemes.pad(0), Schemes.pad(1)].slice(0, n)) this.join(sc); this.startLevel(clamp(+q.get('level') - 1, 0, 2), true); }
    if (q.get('x') && this.slots.length) { const x = +q.get('x'); const y = this.world.groundBelow(x, 0, 3000) ?? 0; this.slots.forEach((s, i) => s.body.place(new V3(x + (i % 2) * 90, y + 70, Math.floor(i / 2) * 100 - 50))); this.camTarget = this.player.c.clone(); }
    if (q.get('junk')) for (const s of this.slots) s.inventory = [...JUNK.filter(j => j !== 'pea'), 'duck', 'duck', 'toast'];
  }
}

const CONFETTI_GEO = new THREE.BoxGeometry(9, 5.5, 0.8);
const CONFETTI_MATS = [0xff4d6d, 0xffd23f, 0x3bceac, 0x5e60ce, 0xff9f1c, 0xffffff, 0x4cc9f0].map(c => new THREE.MeshStandardMaterial({ color: c, roughness: 0.5, side: THREE.DoubleSide }));
const PUFF_GEO = new THREE.SphereGeometry(1, 10, 8);
const PUFF_MAT = new THREE.MeshStandardMaterial({ color: 0xffffff, roughness: 1, transparent: true, opacity: 0.8 });
const SPARK_MAT = new THREE.MeshStandardMaterial({ color: 0xfff6a0, emissive: 0xffe060 });

function M3mulv(m, v) { return new V3(m[0] * v.x + m[3] * v.y + m[6] * v.z, m[1] * v.x + m[4] * v.y + m[7] * v.z, m[2] * v.x + m[5] * v.y + m[8] * v.z); }
