// WebSocket client for the GooglyOriginal lobby server (same protocol as the Mac app).
export class Net {
  constructor(url) {
    this.url = url || (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws';
    this.inbox = []; this.status = 'connecting'; this.why = ''; this.opened = false; this.attempts = 0; this.closedByUs = false;
    this.started = performance.now();
    this.connect();
  }
  connect() {
    let ws;
    try { ws = new WebSocket(this.url); } catch (e) { return this.failed(String(e)); }
    this.ws = ws;
    ws.onopen = () => {
      if (ws !== this.ws) return;
      this.opened = true; this.status = 'open';
      this.send({ t: 'hello', name: Net.playerName });
      clearInterval(this.pinger);
      this.pinger = setInterval(() => this.send({ t: 'ping', at: Date.now() / 1000 }), 8000);
    };
    ws.onmessage = e => { try { const m = JSON.parse(e.data); if (m.t === 'pong') this.rtt = Date.now() / 1000 - m.at; else this.inbox.push(m); } catch {} };
    ws.onclose = () => { if (ws === this.ws) this.failed('connection closed'); };
    ws.onerror = () => {};
  }
  failed(why) {
    if (this.closedByUs) return;
    if (!this.opened && this.attempts < 40) {
      this.attempts++; this.status = 'connecting';
      setTimeout(() => { if (!this.closedByUs) this.connect(); }, Math.min(3000, 600 + this.attempts * 300));
    } else { this.status = 'closed'; this.why = why; clearInterval(this.pinger); }
  }
  get secondsConnecting() { return (performance.now() - this.started) / 1000; }
  get host() { try { return new URL(this.url).host; } catch { return 'server'; } }
  drain() { const m = this.inbox; this.inbox = []; return m; }
  send(obj) { if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(obj)); }
  close() { this.closedByUs = true; this.send({ t: 'leave' }); clearInterval(this.pinger); try { this.ws.close(); } catch {} this.status = 'closed'; this.why = 'left'; }
  static get playerName() {
    let n = '';
    try { n = localStorage.getItem('googly.name') || ''; } catch {}
    return n || 'Googly' + Math.floor(Math.random() * 900 + 100);
  }
  static setPlayerName(n) { try { localStorage.setItem('googly.name', n.slice(0, 14)); } catch {} }
}
