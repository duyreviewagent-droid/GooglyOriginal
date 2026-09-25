// GooglyOriginal online — lobby + relay server.
// The host's Mac runs the game world; this server only matches players into lobbies (4-letter codes)
// and relays messages: inputs from guests go to the host, world snapshots and events go to the guests.
import http from 'node:http';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.PORT || 8000);
const MAX_SEATS = 4;
const CODE_CHARS = 'ABCDEFGHJKMNPQRSTUVWXYZ';   // no I, L or O — easy to read out loud
const LEVELS = ['The Backyard of Destiny', 'The Desert of Mild Inconvenience', 'Cube Corp HQ'];

/** @type {Map<string, {code:string, host:any, seats:(any|null)[], started:boolean, level:number, created:number, priv:boolean}>} */
const lobbies = new Map();

function newCode() {
  for (;;) {
    let c = '';
    for (let i = 0; i < 4; i++) c += CODE_CHARS[Math.floor(Math.random() * CODE_CHARS.length)];
    if (!lobbies.has(c)) return c;
  }
}

const cleanName = n => String(n || 'Googly').replace(/[^\p{L}\p{N} _\-.!?']/gu, '').trim().slice(0, 14) || 'Googly';
const send = (ws, obj) => { if (ws && ws.readyState === 1) ws.send(typeof obj === 'string' ? obj : JSON.stringify(obj)); };
const roster = L => L.seats.map((s, i) => s ? { seat: i, name: s.name } : null).filter(Boolean);
const broadcast = (L, obj, except) => { const m = JSON.stringify(obj); for (const s of L.seats) if (s && s !== except) send(s, m); };

function publicList() {
  return [...lobbies.values()].filter(L => !L.priv).map(L => ({
    code: L.code, host: L.host?.name || '?', n: roster(L).length, max: MAX_SEATS,
    level: L.level, levelName: LEVELS[L.level] || '', started: L.started,
  })).filter(x => x.n < MAX_SEATS).sort((a, b) => b.n - a.n).slice(0, 12);
}

function leave(ws, reason = 'left') {
  const L = ws.lobby;
  if (!L) return;
  ws.lobby = null;
  const seat = L.seats.indexOf(ws);
  if (seat >= 0) L.seats[seat] = null;
  if (ws === L.host) {
    // the host carries the world, so the lobby ends with them
    broadcast(L, { t: 'closed', reason: `${ws.name} (the host) ${reason === 'left' ? 'left' : 'disconnected'}` });
    for (const s of L.seats) if (s) s.lobby = null;
    lobbies.delete(L.code);
    log(`lobby ${L.code} closed`);
  } else {
    broadcast(L, { t: 'left', seat, name: ws.name });
    broadcast(L, { t: 'players', players: roster(L) });
    log(`${ws.name} left ${L.code}`);
  }
}

function log(s) { console.log(new Date().toISOString().slice(11, 19), s); }

// ---------------------------------------------------------------- http
const page = () => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>GooglyOriginal</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; background: radial-gradient(circle at 50% 20%, #2b5fb8, #0b1d3a 70%); color: #fff;
         font-family: "Avenir Next", "Segoe UI", system-ui, sans-serif; display: flex; align-items: center; justify-content: center; }
  .card { max-width: 640px; margin: 24px 16px; padding: 32px; background: rgba(0,0,0,.55); border: 2px solid rgba(255,216,74,.5); border-radius: 22px; }
  h1 { font-family: Futura, "Futura-CondensedExtraBold", Impact, sans-serif; font-size: clamp(48px, 12vw, 88px); margin: 0; color: #e8262f;
       text-shadow: 5px 5px 0 #3a0508; letter-spacing: 1px; }
  .o { display: inline-block; width: .7em; height: .7em; background: #fff; border: .07em solid #3a0508; border-radius: 50%; position: relative; vertical-align: -.02em; }
  .o::after { content: ""; position: absolute; width: 50%; height: 50%; background: #111; border-radius: 50%; left: 28%; top: 38%; }
  p { font-size: 17px; line-height: 1.5; opacity: .9 }
  table { width: 100%; border-collapse: collapse; margin-top: 12px; font-weight: 700; }
  td { padding: 8px 6px; border-top: 1px solid rgba(255,255,255,.15); }
  .code { font-family: Menlo, monospace; color: #ffd84a; font-size: 20px; letter-spacing: 3px; }
  .muted { opacity: .6; font-weight: 500; }
</style></head><body><div class="card">
<h1>G<span class="o"></span><span class="o"></span>GLY</h1>
<p><b>GooglyOriginal</b> online server — wobbly jelly, googly eyes, up to four players per lobby.
Open the GooglyOriginal Mac app, press <b>O</b> on the title screen, then <b>Host</b> to get a lobby code or <b>Join</b> with a friend's code.</p>
<table id="t"><tr><td class="muted">loading open lobbies…</td></tr></table>
</div><script>
async function load() {
  const r = await fetch('/lobbies'); const j = await r.json(); const t = document.getElementById('t');
  t.innerHTML = j.lobbies.length ? j.lobbies.map(l => '<tr><td class="code">' + l.code + '</td><td>' + l.host.replace(/</g, '') +
    '</td><td>' + l.n + '/' + l.max + '</td><td class="muted">' + (l.started ? 'playing · ' : 'waiting · ') + l.levelName + '</td></tr>').join('')
    : '<tr><td class="muted">No open lobbies right now — host one from the Mac app.</td></tr>';
}
load(); setInterval(load, 5000);
</script></body></html>`;

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (url === '/health') { res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('ok'); }
  if (url === '/lobbies') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
    return res.end(JSON.stringify({ lobbies: publicList(), players: [...lobbies.values()].reduce((a, L) => a + roster(L).length, 0) }));
  }
  if (url === '/' || url === '/index.html') { res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); return res.end(page()); }
  res.writeHead(404); res.end('not found');
});

// ---------------------------------------------------------------- websockets
const wss = new WebSocketServer({ server, path: '/ws', maxPayload: 256 * 1024 });

wss.on('connection', ws => {
  ws.isAlive = true;
  ws.name = 'Googly';
  ws.lobby = null;
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('message', raw => {
    let m;
    try { m = JSON.parse(raw); } catch { return; }
    const L = ws.lobby;
    switch (m.t) {
      case 'hello': ws.name = cleanName(m.name); send(ws, { t: 'hi', v: 1 }); break;
      case 'ping': send(ws, { t: 'pong', at: m.at }); break;
      case 'list': send(ws, { t: 'lobbies', list: publicList() }); break;
      case 'create': {
        if (L) leave(ws);
        ws.name = cleanName(m.name || ws.name);
        const code = newCode();
        const lobby = { code, host: ws, seats: [ws, null, null, null], started: false, level: 0, created: Date.now(), priv: !!m.private };
        lobbies.set(code, lobby);
        ws.lobby = lobby;
        send(ws, { t: 'joined', code, seat: 0, host: true, players: roster(lobby), started: false, level: 0 });
        log(`${ws.name} created ${code}`);
        break;
      }
      case 'join': {
        const code = String(m.code || '').toUpperCase().replace(/[^A-Z]/g, '').slice(0, 4);
        const lobby = lobbies.get(code);
        if (!lobby) return send(ws, { t: 'error', msg: `No lobby with code ${code || '????'}` });
        const seat = lobby.seats.indexOf(null);
        if (seat < 0) return send(ws, { t: 'error', msg: `Lobby ${code} is full (4/4)` });
        if (L) leave(ws);
        ws.name = cleanName(m.name || ws.name);
        lobby.seats[seat] = ws;
        ws.lobby = lobby;
        send(ws, { t: 'joined', code, seat, host: false, players: roster(lobby), started: lobby.started, level: lobby.level });
        broadcast(lobby, { t: 'players', players: roster(lobby) }, ws);
        send(lobby.host, { t: 'arrive', seat, name: ws.name });
        log(`${ws.name} joined ${code} seat ${seat}`);
        break;
      }
      case 'leave': leave(ws); break;
      case 'start': {
        if (!L || L.host !== ws) return;
        L.started = true;
        L.level = Math.max(0, Math.min(2, m.level | 0));
        broadcast(L, { t: 'start', level: L.level }, ws);
        break;
      }
      case 'lobbyState': {
        if (!L || L.host !== ws) return;
        L.started = !!m.started;
        L.level = Math.max(0, Math.min(2, m.level | 0));
        break;
      }
      // host → guests: world snapshots and events, relayed untouched
      case 'snap': case 'ev': {
        if (!L || L.host !== ws) return;
        const s = raw.toString();
        for (const g of L.seats) if (g && g !== ws) send(g, s);
        break;
      }
      // guest → host: inputs and own-body state, stamped with the seat
      case 'in': {
        if (!L || L.host === ws) return;
        m.seat = L.seats.indexOf(ws);
        send(L.host, m);
        break;
      }
    }
  });
  ws.on('close', () => leave(ws, 'disconnected'));
  ws.on('error', () => {});
});

setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false;
    try { ws.ping(); } catch {}
  }
}, 20000);

server.listen(PORT, () => log(`GooglyOriginal server on :${PORT}`));
