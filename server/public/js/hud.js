// DOM HUD in GooglyGamble's style: Futura Condensed titles with hard shadows, Avenir Next UI, dark rounded
// panels with coloured borders, key "pills". World-anchored text (popups, bubbles, name tags) is projected
// from 3D each frame by the game.
import { LEVEL_NAMES, levelName } from './levels.js';
// level picker: the three story levels, plus the furthest endless level you've reached (key 4)
const levelPicks = unlocked => [...[0, 1, 2].slice(0, unlocked).map(i => [String(i + 1), LEVEL_NAMES[i], i]), ...(unlocked > 3 ? [['4', `∞ Level ${unlocked}`, unlocked - 1]] : [])];
import { PLAYER_COLORS, PLAYER_NAMES } from './player.js';
import { JUNK_INFO } from './things.js';

const $ = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html !== undefined) e.innerHTML = html; return e; };
const css = c => '#' + c.toString(16).padStart(6, '0');
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
/** Key name on a pill → the key it presses when tapped. */
const KEYCODE = { ESC: 'Escape', ENTER: 'Enter', SPACE: 'Space', R: 'KeyR', Q: 'KeyQ', M: 'KeyM', H: 'KeyH', J: 'KeyJ', O: 'KeyO', C: 'KeyC', T: 'KeyT',
  1: 'Digit1', 2: 'Digit2', 3: 'Digit3', 4: 'Digit4', 5: 'Digit5', 6: 'Digit6' };
export const pill = (key, what, cls = '', code = KEYCODE[key]) =>
  `<button class="pill ${cls}"${code ? ` data-key="${code}"` : ''}><b>${esc(key)}</b>${esc(what)}</button>`;

export class HUD {
  constructor(root, game) {
    this.g = game;
    this.root = root;
    root.innerHTML = '';
    this.world = $('div', 'world'); root.append(this.world);
    this.blind = $('div', 'blind'); root.append(this.blind);
    this.cards = $('div', 'cards'); root.append(this.cards);
    this.board = $('div', 'board panel'); root.append(this.board);
    this.score = $('div', 'score panel', '<small>SCORE</small><b>0</b><i></i>'); root.append(this.score);
    this.boss = $('div', 'bossbar panel', '<small>MEGA CUBE · CHIEF EXECUTIVE CUBE</small><div><span></span></div>'); root.append(this.boss);
    this.help = $('div', 'help'); root.append(this.help);
    this.saved = $('div', 'saved', 'SAVED ✓'); root.append(this.saved);
    this.toastEl = $('div', 'toast'); root.append(this.toastEl);
    this.bannerEl = $('div', 'banner'); root.append(this.bannerEl);
    this.panel = $('div', 'overlay'); root.append(this.panel);
    this.title = $('div', 'title'); root.append(this.title);
    this.logo = $('div', 'logo', '<span class="lt">G</span><span class="eye"><i></i></span><span class="eye"><i></i></span><span class="lt">GLY</span>');
    this.titleBody = $('div', 'title-body');
    this.title.append(this.logo, this.titleBody);
    this.eyeState = [0, 1].map(() => ({ p: { x: 0, y: -10 }, v: { x: 0, y: 0 } }));
    this.logoY = 0; this.logoVel = 0; this.lastLogoY = 0; this.lastLogoV = 0;
    this.keys = {};
    this.toastT = 0; this.savedT = 0; this.bannerT = 0; this.helpT = 0;
    this.boss.style.display = 'none';
    // every pill / card with data-key presses that key when tapped or clicked
    root.addEventListener('click', e => {
      const b = e.target.closest('[data-key]');
      if (b && root.contains(b)) { e.stopPropagation(); game.input.tap(b.dataset.key); }
    });
    this.touch = matchMedia('(pointer: coarse)').matches || 'ontouchstart' in window || new URLSearchParams(location.search).has('touch');
    root.classList.toggle('touchui', this.touch);
    this.fit();
    addEventListener('resize', () => this.fit());
  }

  /** Scales the whole interface down on small screens so it looks exactly like the Mac app, just smaller. */
  fit() {
    const s = Math.max(0.4, Math.min(1, innerWidth / 1180, innerHeight / 800));
    document.documentElement.style.setProperty('--s', s.toFixed(3));
    this.scale = s;
  }

  // ------------------------------------------------ per frame
  update(dt) {
    const g = this.g, playing = g.state === 'playing' || g.state === 'paused';
    for (const e of [this.cards, this.board, this.score]) e.style.display = playing ? '' : 'none';
    if (playing) { this.drawCards(); this.drawBoard(); }
    const sc = this.score.querySelector('b');
    if (sc.textContent !== String(g.score)) { sc.textContent = g.score; sc.classList.remove('pop'); void sc.offsetWidth; sc.classList.add('pop'); }
    this.score.querySelector('small').textContent = g.slots.length > 1 || g.role !== 'offline' ? 'TEAM SCORE' : 'SCORE';
    this.score.querySelector('i').textContent = g.level ? g.level.name.toUpperCase() : '';
    if (g.state === 'playing') this.helpT += dt;
    const hk = this.touch ? 'left thumb: move · JUMP · SPIT (aims itself) · hold SQUISH, let go = BOING · SQUISH in the air = butt slam'
      : g.slots.map(s => s.scheme.hint).filter(Boolean).join('   |   ') + (g.slots.length === 1 ? ' · scroll zoom · ESC pause' : '');
    if (this.keys.help !== hk) { this.keys.help = hk; this.help.textContent = hk; }
    this.help.style.opacity = g.state === 'paused' ? 1 : g.state === 'playing' ? Math.max(0, Math.min(1, 1.4 - (this.helpT - 22) / 3)) : 0;
    // blindness only on a solo screen
    const solo = g.slots.length === 1, eyes = g.player.eyes.length;
    const want = playing && solo && g.player.flushing < 0 ? (eyes === 0 ? 1 : eyes === 1 ? 0.35 : 0) : 0;
    this.blindA = (this.blindA || 0) + (want - (this.blindA || 0)) * Math.min(1, dt * 4);
    this.blind.style.opacity = this.blindA;
    if (this.blindA > 0.01) {
      const p = g.project(g.player.c);
      if (p) this.blind.style.background = `radial-gradient(circle at ${p.x}px ${p.y}px, transparent 0, transparent ${eyes === 0 ? 150 : 380}px, rgba(0,0,0,.97) ${eyes === 0 ? 260 : 700}px)`;
    }
    this.toastT -= dt; this.toastEl.style.opacity = Math.max(0, Math.min(1, this.toastT * 2));
    this.savedT -= dt; this.saved.style.opacity = Math.max(0, Math.min(1, this.savedT * 2));
    this.bannerT -= dt; this.bannerEl.style.opacity = Math.max(0, Math.min(1, this.bannerT * 1.5));
  }

  drawCards() {
    const g = this.g;
    const key = g.slots.map(s => `${s.index}:${s.name}:${s.body.eyes.length}:${s.inventory.length}:${s.inventory[s.inventory.length - 1] || ''}:${s.body.ko > 0}`).join(',');
    if (key === this.keys.cards) return;
    this.keys.cards = key;
    this.cards.innerHTML = g.slots.map(s => {
      const inv = s.inventory, next = inv[inv.length - 1];
      const eyes = s.body.eyes.length ? '<span class="eyes">' + '<i></i>'.repeat(s.body.eyes.length) + '</span>' : '<span class="noeyes">NO EYES!</span>';
      return `<div class="card panel" style="border-color:${css(s.color)}cc"><span class="stripe" style="background:${css(s.color)}"></span>
        <div class="nm" style="color:${css(s.color)}">${esc(s.name)} · ${PLAYER_NAMES[s.index]}${s.body.ko > 0 ? '<em>K.O.</em>' : ''}</div>${eyes}
        <div class="ammo">${next ? `<span class="emo">${JUNK_INFO[next].emoji}</span>×${inv.length} · next: ${JUNK_INFO[next].name}` : 'out of stuff · spitting peas'}</div></div>`;
    }).join('');
  }

  drawBoard() {
    const g = this.g;
    const span = Math.max(1, g.level.goal.x - g.level.start.x);
    const frac = s => Math.max(0, Math.min(1, (s.body.c.x - g.level.start.x) / span));
    const ranked = [...g.slots].sort((a, b) => b.body.c.x - a.body.c.x);
    const multi = g.slots.length > 1;
    const key = ranked.map(s => s.index + ':' + Math.round(frac(s) * 50)).join(',') + (g.leader ? g.leader.index : -1);
    if (key === this.keys.board) return;
    this.keys.board = key;
    this.board.innerHTML = `<h4>${multi ? 'RACE TO THE GOLDEN TOILET' : 'DISTANCE TO THE GOLDEN TOILET'}</h4>` + ranked.map((s, r) => {
      const lead = multi && s === g.leader, f = frac(s);
      return `<div class="row${lead ? ' lead' : ''}" style="${lead ? `background:${css(s.color)}4d` : ''}"><span class="rk">${r + 1}</span><span class="dot" style="background:${css(s.color)}"></span>
        <span class="nm">${esc(s.name)}${lead ? ' 👑' : ''}</span><span class="bar"><span style="width:${f * 100}%;background:${css(s.color)}"></span></span><span class="pc">${Math.round(f * 100)}%</span></div>`;
    }).join('');
  }

  toast(s) { this.toastEl.textContent = s; this.toastT = 1.8; }
  flashSaved() { this.savedT = 1.4; }
  banner(top, sub) {
    this.bannerEl.innerHTML = `<small>${esc(top)}</small><b data-t="${esc(sub.toUpperCase())}">${esc(sub.toUpperCase())}</b>`;
    this.bannerEl.classList.remove('in'); void this.bannerEl.offsetWidth; this.bannerEl.classList.add('in');
    this.bannerT = 2.6;
  }
  bossBar(f) {
    if (f === null || f === undefined) { this.boss.style.display = 'none'; return; }
    this.boss.style.display = '';
    this.boss.querySelector('span').style.width = Math.max(0, f) * 100 + '%';
  }

  // ------------------------------------------------ world labels
  popText(text, color, size) {
    const e = $('div', 'popup');
    e.innerHTML = text.split('\n').map(l => `<span data-t="${esc(l.toUpperCase())}">${esc(l.toUpperCase())}</span>`).join('<br>');
    e.style.color = css(color); e.style.fontSize = size * 1.15 * Math.max(0.6, this.scale || 1) + 'px';
    e.style.setProperty('--rot', (Math.random() * 0.4 - 0.2) + 'rad');
    this.world.append(e);
    return e;
  }
  bubble(text, color) {
    const e = $('div', 'bubble');
    e.textContent = text;
    if (color !== undefined) e.style.borderColor = css(color);
    this.world.append(e);
    return e;
  }
  tag(slot) {
    const e = $('div', 'tag');
    e.innerHTML = `<span class="tn"></span><span class="tp">⚡ ${esc(slot.scheme.teleport)} = TELEPORT</span>`;
    e.style.borderColor = css(slot.color);
    this.world.append(e);
    return e;
  }

  // ------------------------------------------------ panels
  hidePanel() { this.panel.innerHTML = ''; this.panel.className = 'overlay'; }
  box(accent, inner) { this.panel.className = 'overlay on'; this.panel.innerHTML = `<div class="box" style="border-color:${css(accent)}b3">${inner}</div>`; }

  showPause() {
    this.box(0xffd84a, `<h1 class="big" data-t="PAUSED" style="color:#ffd84a">PAUSED</h1>
      <div class="pills col">${pill('ESC', 'keep wobbling', 'green')}${pill('R', 'restart level')}${pill('Q', 'save & quit to title')}${pill('M', 'mute')}</div>`);
  }
  showOnlineMenu(host) {
    this.box(0x7a3fd1, `<h1 class="big" data-t="ONLINE">ONLINE</h1><p class="dim">the game keeps going while this is open</p>
      <div class="pills col">${pill('ESC', 'back to the game', 'green')}${pill('Q', host ? 'end the lobby for everyone' : 'leave the lobby', 'red')}</div>`);
  }
  showDone(level, got, slots, time, last, waiting = false) {
    const secs = Math.floor(time);
    const order = [...slots].sort((a, b) => (a.flushOrder < 0 ? 99 : a.flushOrder) - (b.flushOrder < 0 ? 99 : b.flushOrder));
    const multi = slots.length > 1;
    const rows = order.map((s, i) => `<tr style="background:${css(s.color)}${i === 0 && multi ? '59' : '26'}"><td class="l">${i === 0 && multi ? '👑 ' : ''}${esc(s.name)} ${PLAYER_NAMES[s.index]}</td>
      <td>${s.collected}</td><td>${s.bonks}</td><td>${s.body.eyes.length}</td><td>${s.falls}</td></tr>`).join('');
    this.box(0x8dffa0, `<h1 class="big wobble" data-t="FLUSHED!" style="color:#ffd84a">FLUSHED!</h1>
      <p class="dim">${esc(level.name.toUpperCase())} COMPLETE · ${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')} · +${got} POINTS</p>
      <table class="stats"><tr><th></th><th>STUFF</th><th>BONKS</th><th>EYES</th><th>FALLS</th></tr>${rows}</table>
      <div class="pills">${waiting ? '<span class="wait">waiting for the host…</span>' : pill('ENTER', last ? 'face the ending' : 'next level', 'green pulse')}</div>`);
  }
  showWin(score, players) {
    this.box(0xffd84a, `<h1 class="huge" data-t="YOU WIN!" style="color:#ffd84a">YOU WIN!</h1>
      <p>${players > 1 ? 'Your googly gang' : 'You'} fired the CEO of Cube Corp and flushed<br>three golden toilets. Officially the googliest alive.</p>
      <p class="final">SCORE ${score}</p><p>…but the toilets never end. Endless levels from here on!</p><div class="pills">${pill('ENTER', 'keep going · level 4', 'green pulse')}${pill('ESC', 'back to the title')}</div>`);
  }

  // ------------------------------------------------ title
  showTitle() { this.title.style.display = ''; this.keys.title = ''; }
  hideTitle() { this.title.style.display = 'none'; this.helpT = 0; }

  /** mode: 'main' | 'online' | 'code' | 'lobby' — same screens and wording as the Mac app */
  drawTitle(state) {
    const g = this.g;
    // the code screen keeps its text box (and the phone keyboard) alive between frames
    const key = JSON.stringify(state.mode === 'code' ? { ...state, code: '' } : state);
    if (key === this.keys.title) { if (state.mode === 'code') this.updateCode(state); return; }
    this.keys.title = key;
    let html = '';
    if (state.mode === 'main' && this.touch) {
      // phones & tablets: one giant PLAY button that starts a solo game straight away; online is optional
      html = `<p class="sub">Wobbly jelly. Googly eyes. One golden toilet.</p>
        <button class="tplay" data-key="Enter"><span>▶ PLAY</span><small>tap to play solo · no lobby needed</small></button>
        <div class="toptional"><span class="opt">optional</span>
          <button class="alt purple" data-key="KeyO"><b>👥</b> PLAY ONLINE <small>host or join a lobby with a code</small></button>
          ${state.canContinue ? `<button class="alt blue" data-key="KeyC"><b>↻</b> CONTINUE <small>${esc(state.continueName)}</small></button>` : ''}
        </div>
        ${state.unlocked > 1 ? `<div class="tlevels">${levelPicks(state.unlocked).map(([k, name]) => pill(k, name, 'small')).join('')}</div>` : ''}
        ${state.wins ? `<p class="wins">🏆 × ${state.wins}</p>` : ''}`;
    } else if (state.mode === 'main') {
      const cards = [0, 1, 2, 3].map(i => {
        const j = state.joined.find(x => x.index === i), col = css(PLAYER_COLORS[i]);
        if (j) return `<div class="jcard on" style="border-color:${col};background:${col}66"><h3 data-t="P${i + 1} ${PLAYER_NAMES[i]}">P${i + 1} ${PLAYER_NAMES[i]}</h3><p>${esc(j.label)}</p><em>READY!</em></div>`;
        return `<div class="jcard"${i === 0 ? ' data-key="Space"' : ''}><h3 style="color:${col}">P${i + 1}</h3><p class="y">PRESS JUMP TO JOIN</p>${state.free.slice(0, 2).map(f => `<p class="d">${esc(f.join)}  ·  ${esc(f.label)}</p>`).join('')}</div>`;
      }).join('');
      const n = state.joined.length;
      const count = state.countdown != null
        ? `<div class="count">${n <= 1 ? `PLAYING SOLO IN ${state.countdown}…  (ENTER = go now · friends press jump to join)` : `${n} PLAYERS · STARTING IN ${state.countdown}…  (ENTER = go now)`}</div>` : '';
      html = `<p class="sub">Wobbly jelly. Googly eyes. Up to four players. One golden toilet.</p>
        <p class="coop">COUCH CO-OP (optional): friends on this computer press their jump key to join · SPACE · / · Ⓐ</p>
        <div class="jrow">${cards}</div>${count}
        <div class="tpills">${pill('ENTER', 'PLAY SOLO', 'green big')}${pill('O', 'play online', 'purple')}${state.canContinue ? pill('C', 'continue · ' + state.continueName, 'blue') : ''}${state.unlocked > 1 ? pill(state.unlocked > 3 ? '1–4' : '1–' + state.unlocked, 'pick level', '', null) : ''}${pill('M', 'mute')}</div>
        ${state.unlocked > 1 ? `<div class="tlevels">${levelPicks(state.unlocked).map(([k, name]) => pill(k, name, 'small')).join('')}</div>` : ''}
        ${state.wins ? `<p class="wins">🏆 × ${state.wins}</p>` : ''}`;
    } else if (state.mode === 'online') {
      const list = state.lobbies.slice(0, 6).map((l, k) => `<button class="lob" data-key="Digit${k + 1}"><b>${k + 1}</b><code>${esc(l.code)}</code><span>${esc(l.host)}'s lobby</span><i>${l.n}/4 · ${l.started ? 'playing ' : 'waiting · '}${esc(l.levelName || '')}</i></button>`).join('');
      html = `<div class="obox"><h2 data-t="PLAY ONLINE">PLAY ONLINE</h2><p class="dim">${esc(state.status)}</p>
        <div class="pills">${pill('H', 'host a lobby', state.open ? 'green' : 'grey')}${pill('J', 'join with a code', 'blue')}</div>
        <h4>OPEN LOBBIES</h4><div class="lobs">${list || `<p class="dim">${state.open ? 'none right now — host one and send your friends the code' : '…'}</p>`}</div>
        ${state.error ? `<p class="err">${esc(state.error)}</p>` : ''}
        <label class="namefield">YOUR NAME <input id="nameInput" maxlength="14" value="${esc(state.name)}"></label>
        <div class="pills">${pill('ESC', 'back')}</div><p class="dim small">solo & couch play are on the main title</p></div>`;
    } else if (state.mode === 'code') {
      html = `<div class="obox"><h2 data-t="JOIN A LOBBY">JOIN A LOBBY</h2><p class="dim">type your friend's 4-letter code</p>
        <div class="code">${[0, 1, 2, 3].map(() => '<span></span>').join('')}<input id="codeInput" maxlength="4" autocomplete="off" autocapitalize="characters" spellcheck="false" inputmode="text"></div>
        <div class="pills"><span class="gopill"></span>${pill('ESC', 'back')}</div>
        <p class="cstatus"></p></div>`;
    } else if (state.mode === 'lobby') {
      const seats = [0, 1, 2, 3].map(i => {
        const s = g.slots.find(x => x.index === i), col = css(PLAYER_COLORS[i]);
        return `<div class="seat${s ? ' on' : ''}" style="${s ? `border-color:${col};background:${col}66` : ''}"><b>${s ? esc(s.name) + (i === g.mySeat ? ' (you)' : '') : 'waiting…'}</b><small style="color:${col}">${i === 0 ? 'HOST' : 'P' + (i + 1)}</small></div>`;
      }).join('');
      const n = g.slots.length;
      const hostBits = state.host
        ? `<div class="pills lv">${[...[0, 1, 2].map(i => [String(i + 1), LEVEL_NAMES[i], i]), ...(state.unlocked > 3 ? [['4', `∞ Level ${state.unlocked}`, state.unlocked - 1]] : [])].map(([k, name, i]) => pill(k, name, i === state.level ? 'purple' : i < state.unlocked ? '' : 'off')).join('')}${state.level > 2 && state.level !== state.unlocked - 1 ? pill('·', `Level ${state.level + 1}`, 'purple') : ''}</div>
           <div class="pills">${pill('ENTER', n <= 1 ? 'start — solo is fine' : `start with ${n} players`, 'green')}${pill('ESC', 'leave')}</div>`
        : `<p class="wait">waiting for the host to start…</p><div class="pills">${pill('ESC', 'leave')}</div>`;
      html = `<div class="obox"><h2 data-t="LOBBY">LOBBY</h2><p class="dim">tell your friends this code · up to 4 players · they can also join mid-game</p>
        <div class="bigcode" data-t="${esc(state.code.split('').join(' '))}">${esc(state.code.split('').join(' '))}</div><div class="seats">${seats}</div>${hostBits}
        <p class="dim small">${esc(state.status)}</p></div>`;
    }
    this.titleBody.innerHTML = html;
    const ni = this.titleBody.querySelector('#nameInput');
    if (ni) {
      ni.addEventListener('input', () => g.setName(ni.value));
      ni.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === 'Escape') ni.blur(); e.stopPropagation(); });
    }
    const ci = this.titleBody.querySelector('#codeInput');
    if (ci) {
      ci.value = state.code;
      ci.addEventListener('input', () => { g.codeEntry = ci.value.toUpperCase().replace(/[^A-Z]/g, '').slice(0, 4); ci.value = g.codeEntry; });
      ci.addEventListener('keydown', e => {
        if (e.key === 'Enter') { e.preventDefault(); g.input.tap('Enter'); }
        else if (e.key === 'Escape') { e.preventDefault(); g.input.tap('Escape'); }
        e.stopPropagation();
      });
      setTimeout(() => ci.focus(), 0);
      this.updateCode(state);
    }
  }

  updateCode(state) {
    const b = this.titleBody, ch = [...state.code];
    b.querySelectorAll('.code span').forEach((e, i) => { e.textContent = ch[i] || ''; e.className = i === ch.length ? 'cur' : ''; });
    const ci = b.querySelector('#codeInput');
    if (ci && ci.value !== state.code) ci.value = state.code;
    const gp = b.querySelector('.gopill');
    const want = ch.length === 4 ? pill('ENTER', 'join lobby', 'green') : pill('ENTER', 'type 4 letters', 'grey');
    if (gp && gp.innerHTML !== want) gp.innerHTML = want;
    const st = b.querySelector('.cstatus');
    if (st) { st.textContent = state.error || state.status; st.className = 'cstatus ' + (state.error ? 'err' : 'dim'); }
  }

  /** Bouncy logo; the O's are googly eyes riding the spring. */
  titleTick(dt, t) {
    if (this.title.style.display === 'none') return;
    if (Math.floor(t * 10) % 25 === 0 && this.logoVel === 0) this.logoVel = 900;
    this.logoVel += (0 - this.logoY) * 180 * dt - this.logoVel * 4 * dt;
    this.logoY += this.logoVel * dt;
    if (Math.abs(this.logoVel) < 4 && Math.abs(this.logoY) < 0.5) { this.logoVel = 0; this.logoY = 0; }
    this.logo.style.transform = `translateY(${-this.logoY}px) rotate(${Math.sin(t * 1.3) * 0.03}rad)`;
    const vel = (this.logoY - this.lastLogoY) / Math.max(dt, 1e-3), acc = (vel - this.lastLogoV) / Math.max(dt, 1e-3);
    this.lastLogoY = this.logoY; this.lastLogoV = vel;
    const eyes = this.logo.querySelectorAll('.eye i');
    this.eyeState.forEach((e, k) => {
      e.v.y += (-2600 - Math.max(-60000, Math.min(60000, acc))) * dt; e.v.x *= 1 - 1.2 * dt; e.v.y *= 1 - 1.2 * dt;
      e.p.x += e.v.x * dt; e.p.y += e.v.y * dt;
      const maxD = 30, d = Math.hypot(e.p.x, e.p.y);
      if (d > maxD) { const nx = e.p.x / d, ny = e.p.y / d; e.p.x = nx * maxD; e.p.y = ny * maxD; const vn = e.v.x * nx + e.v.y * ny; if (vn > 0) { e.v.x -= nx * vn * 1.5; e.v.y -= ny * vn * 1.5; } }
      if (eyes[k]) eyes[k].style.transform = `translate(${e.p.x}px, ${-e.p.y}px)`;
    });
  }
}
