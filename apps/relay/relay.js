// Pairs a device host (the ESP Web Toolkit's /relay page, which has the
// device on Web Serial) with one remote client, and passes bytes between
// them. The bytes are RFC 2217; the relay never looks inside them.
//
//   host:   ws(s)://<relay>/host    → relay sends {"type":"session","id":...}
//   client: ws(s)://<relay>/c/<id>  → host gets {"type":"open"}, later {"type":"close"}
//
// Binary frames are data, in both directions. Text frames are control
// messages, relay to host only, except that either end may send
// {"type":"ping"} and gets {"type":"pong"} back. Knowing the random id is
// what lets a client in; there is one client per session at a time.

import { randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { WebSocketServer } from 'ws';

const port = Number(process.env.PORT ?? 8787);
const sessions = new Map(); // id → { host, client }

const server = createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end(`esp-relay: ${sessions.size} session(s)\n`);
});
const wss = new WebSocketServer({ noServer: true, maxPayload: 1 << 20 });

server.on('upgrade', (req, socket, head) => {
  const path = new URL(req.url, 'http://relay').pathname;
  const client = /^\/c\/([A-Za-z0-9_-]{16,64})$/.exec(path);
  if (path !== '/host' && !client) {
    socket.end('HTTP/1.1 404 Not Found\r\n\r\n');
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    alive(ws);
    if (client) onClient(ws, client[1], req); else onHost(ws);
  });
});

function onHost(host) {
  const id = randomBytes(16).toString('base64url');
  const session = { host, client: null };
  sessions.set(id, session);
  log(id, 'host connected');
  host.send(JSON.stringify({ type: 'session', id }));
  host.on('message', (data, isBinary) => {
    if (!isBinary) return pong(host, data);
    if (session.client?.readyState === 1) session.client.send(data, { binary: true });
  });
  host.on('close', () => {
    sessions.delete(id);
    session.client?.close(4410, 'Host left');
    log(id, 'host left');
  });
}

function onClient(ws, id, req) {
  const session = sessions.get(id);
  if (!session) return ws.close(4404, 'No such session');
  if (session.client) return ws.close(4409, 'Another client is connected');
  session.client = ws;
  const addr = req.headers['x-forwarded-for']?.split(',')[0].trim() ?? req.socket.remoteAddress;
  log(id, `client connected from ${addr}`);
  session.host.send(JSON.stringify({ type: 'open', addr }));
  ws.on('message', (data, isBinary) => {
    if (!isBinary) return pong(ws, data);
    if (session.host.readyState === 1) session.host.send(data, { binary: true });
  });
  ws.on('close', () => {
    if (session.client !== ws) return;
    session.client = null;
    if (session.host.readyState === 1) session.host.send(JSON.stringify({ type: 'close' }));
    log(id, 'client left');
  });
}

// Answer an application-level ping (browsers can't send protocol pings).
function pong(ws, data) {
  if (data.toString() === PING) ws.send(PONG);
}
const PING = JSON.stringify({ type: 'ping' });
const PONG = JSON.stringify({ type: 'pong' });

// Ping every 30 s; drop connections that missed the previous one.
function alive(ws) {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
}
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false;
    ws.ping();
  }
}, 30_000).unref();

function log(id, message) {
  console.log(`${new Date().toISOString()} ${id.slice(0, 6)} ${message}`);
}

server.listen(port, () => console.log(`esp-relay listening on :${port}`));
