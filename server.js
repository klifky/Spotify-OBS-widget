// server.js — Spotify Widget WebSocket server
// Receives data from smtc_reader.py and eq_capture.py, serves widget.html

const http = require('http');
const path = require('path');
const fs   = require('fs');
const { WebSocketServer } = require('ws');

const PORT   = 8765;
const WIDGET = path.join(__dirname, 'widget.html');

// ── HTTP server ───────────────────────────────────────────────────────────────
const httpServer = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/widget') {
    fs.readFile(WIDGET, (err, data) => {
      if (err) { res.writeHead(404); res.end('widget.html not found'); return; }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(data);
    });
  } else {
    res.writeHead(404); res.end('Not found');
  }
});

// ── WebSocket server ──────────────────────────────────────────────────────────
const wss = new WebSocketServer({ server: httpServer });

const widgetClients = new Set();
let lastState = null;

wss.on('connection', (ws, req) => {
  const clientType = new URL(req.url, 'http://localhost').searchParams.get('client');

  // ── EQ capture ─────────────────────────────────────────────────────────────
  if (clientType === 'eq') {
    console.log('[server] EQ capture connected');
    ws.on('message', (raw) => {
      try {
        const data = JSON.parse(raw.toString());
        if (data.type !== 'eq') return;
        const msg = JSON.stringify(data);
        widgetClients.forEach(c => { if (c.readyState === 1) c.send(msg); });
      } catch (e) {}
    });
    ws.on('close', () => console.log('[server] EQ capture disconnected'));
    return;
  }

  // ── SMTC reader ────────────────────────────────────────────────────────────
  if (clientType === 'smtc') {
    console.log('[server] SMTC reader connected');
    ws.on('message', (raw) => {
      try {
        const data = JSON.parse(raw.toString());
        if (data.artUrl) lastState = data; // cache only full state packets
        console.log('[track]', data.name, '-', data.artist);
        const msg = JSON.stringify({ type: 'state', data });
        widgetClients.forEach(c => { if (c.readyState === 1) c.send(msg); });
      } catch (e) {
        console.warn('[server] Bad message from SMTC reader:', e.message);
      }
    });
    ws.on('close', () => {
      console.log('[server] SMTC reader disconnected');
      const msg = JSON.stringify({ type: 'disconnected' });
      widgetClients.forEach(c => { if (c.readyState === 1) c.send(msg); });
    });
    return;
  }

  // ── Widget client ──────────────────────────────────────────────────────────
  console.log('[server] Widget connected');
  widgetClients.add(ws);
  if (lastState) {
    ws.send(JSON.stringify({ type: 'state', data: lastState }));
  }
  ws.on('close', () => {
    widgetClients.delete(ws);
    console.log('[server] Widget disconnected');
  });
});

// ── Start ─────────────────────────────────────────────────────────────────────
httpServer.listen(PORT, '127.0.0.1', () => {
  console.log(`\n🎵 Spotify Widget Server`);
  console.log(`   WebSocket : ws://localhost:${PORT}`);
  console.log(`   Widget URL: http://localhost:${PORT}/widget\n`);
});

process.on('SIGINT', () => {
  console.log('\n[server] Stopping...');
  wss.close(); httpServer.close(); process.exit(0);
});
