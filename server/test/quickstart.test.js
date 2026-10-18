import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { WebSocket, WebSocketServer } from 'ws';
import { createQuickstartServer } from '../server.js';

const avatar = { call_mode: 'video', character_id: '1', avatar: { persona: 'Hello', image_uri: 'https://example.com/avatar.png', persona_enhance: true } };
const editing = { image_url: 'https://example.com/style.png', editing_type: 'style_transfer' };

async function waitFor(check, timeout = 2500) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const result = check(); if (result) return result; await delay(10); }
  throw new Error('Timed out waiting for test observation.');
}

async function fixture(t, options = {}) {
  const requests = [], signals = [], connections = [], browserSockets = [];
  let id = 995200676634042368n;
  const lives = new Map();
  const upstream = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks)) : null;
    requests.push({ path: req.url, auth: req.headers.authorization, body });
    res.setHeader('Content-Type', 'application/json');
    if (req.method === 'GET') { res.end(JSON.stringify({ live: { id: req.url.split('/').at(-1), status: 'ended', billed_seconds: 4 } })); return; }
    const liveId = String(id++);
    const mode = req.url.includes('s_editing') ? 'editing' : 'avatar';
    lives.set(liveId, mode);
    res.end(JSON.stringify({
      live: { id: liveId, status: 'waiting', live_duration: 120 },
      rtc: { user_id: `live-user-1-${liveId}`, app_id: 'test-app', channel_id: 'test-channel', token: 'rtc-token', token_expire_at: String(Math.floor(Date.now() / 1000) + 120) },
      ...(mode === 'editing' ? { client_secret: 'editing-control-secret', render_uid: 'renderer-123' } : {})
    }));
  });
  const wss = new WebSocketServer({ server: upstream, maxPayload: 8 * 1024 * 1024 });
  wss.on('connection', (ws, req) => {
    const query = new URL(req.url, 'http://localhost').searchParams;
    const connection = { ws, query, auth: req.headers.authorization, initCount: 0 };
    connections.push(connection);
    ws.on('message', data => {
      const message = JSON.parse(data);
      signals.push(message);
      if (message.type === 1) {
        connection.initCount++;
        const ack = (success, error_code) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify({ type: 2, payload: { conn_init_ack: { success, error_code } } }));
        if (options.fatal) { ack(false, 'LIVE_CONN_INIT_FAILED'); return; }
        if (options.neverReady) { ack(false, 'NOT_READY'); return; }
        if (connection.initCount === 1) {
          ack(false, 'NOT_READY');
          if (lives.get(query.get('live_id')) === 'editing') setTimeout(() => ack(true), 50);
        } else ack(true);
      }
    });
  });
  upstream.listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  const origin = `http://127.0.0.1:${upstream.address().port}`;
  const server = createQuickstartServer({ apiKey: 'Token vda_test_server_secret', httpOrigin: origin, wsOrigin: origin.replace('http:', 'ws:'), retryMs: 20, initTimeoutMs: options.neverReady ? 100 : 1500 });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => {
    for (const ws of browserSockets) ws.terminate();
    for (const { ws } of connections) ws.terminate();
    wss.close();
    server.closeAllConnections(); upstream.closeAllConnections();
    await Promise.all([new Promise(resolve => server.close(resolve)), new Promise(resolve => upstream.close(resolve))]);
  });
  return {
    base, requests, signals, connections,
    async create(mode, body) {
      const response = await fetch(`${base}/api/${mode}/lives`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      return { status: response.status, body: await response.json() };
    },
    connect(liveId) {
      const events = [];
      const socket = new WebSocket(`${base.replace('http:', 'ws:')}/ws/live?live_id=${liveId}`);
      browserSockets.push(socket);
      socket.on('message', data => events.push(JSON.parse(data)));
      return { socket, events, event: name => waitFor(() => events.find(item => item.event === name)) };
    }
  };
}

test('S2 creation routes, secret isolation, and exact int64 IDs', async t => {
  const f = await fixture(t);
  const a = await f.create('avatar', avatar), e = await f.create('editing', editing);
  assert.equal(a.status, 200); assert.equal(e.status, 200);
  assert.equal(a.body.live.id, '995200676634042368');
  assert.equal(e.body.live.id, '995200676634042369');
  assert.deepEqual(f.requests.map(r => r.path), ['/live/s_avatar/realtime', '/live/s_editing/realtime']);
  assert.ok(f.requests.every(r => r.auth === 'Token vda_test_server_secret'));
  assert.equal(e.body.client_secret, undefined); assert.equal(e.body.render_uid, 'renderer-123');
  assert.equal(f.requests[0].body.avatar.persona_enhance, true);
  assert.equal(f.requests[0].body.model, 'vidu-s2');
  assert.equal(f.requests[0].body.character_id, undefined);
  assert.deepEqual(f.requests[0].body.rtc, {provider:'artc'});
  assert.equal(f.requests[0].body.idle_timeout_seconds,180);
  const config = await (await fetch(`${f.base}/api/config`)).text();
  assert.ok(!config.includes('vda_test')); assert.ok(!config.includes('editing-control-secret'));
});

test('Avatar retries initialization on one socket, sends text, and hangs up with consistent IDs', async t => {
  const f = await fixture(t);
  const { body } = await f.create('avatar', avatar);
  const client = f.connect(body.live.id);
  await client.event('on_live');
  assert.equal(f.connections.length, 1); assert.equal(f.connections[0].initCount, 2);
  client.socket.send(JSON.stringify({ action: 'text', content: 'Wave to me' }));
  await waitFor(() => f.signals.some(s => s.type === 99));
  client.socket.send(JSON.stringify({ action: 'hangup' }));
  await waitFor(() => f.signals.some(s => s.type === 5));
  assert.equal(f.signals.find(s => s.type === 99).payload.text_msg.content, 'Wave to me');
  assert.ok(f.signals.every(s => s.live_id === body.live.id && s.conn_id === f.connections[0].query.get('conn_id')));
  assert.deepEqual(f.signals.map(s => s.seq_id), [1, 2, 3, 4]);
  const query = await (await fetch(`${f.base}/api/avatar/lives/${body.live.id}`)).json();
  assert.equal(query.live.billed_seconds, 4);
});

test('Editing waits for automatic readiness and sends image/scenario changes once', async t => {
  const f = await fixture(t);
  const { body } = await f.create('editing', editing);
  const client = f.connect(body.live.id);
  await client.event('on_live');
  assert.equal(f.connections[0].initCount, 1);
  assert.equal(f.connections[0].query.get('client_secret'), 'editing-control-secret');
  assert.equal(f.connections[0].query.get('authorization'), null);
  client.socket.send(JSON.stringify({ action: 'switch_prompt', editing_type: 'virtual_tryon' }));
  await client.event('switch_prompt_sent');
  const signal = f.signals.find(s => s.type === 13);
  assert.deepEqual(signal.payload.switch_prompt, { editing_type: 'virtual_tryon' });
  await delay(60);
  assert.equal(f.signals.filter(s => s.type === 13).length, 1);
  f.connections[0].ws.send(JSON.stringify({ type: 14, payload: { switch_prompt_ack: { success: false, error_code: 'RENDER_NOT_READY' } } }));
  await waitFor(() => client.events.some(e => e.message?.type === 14));
});

test('4 MB local editing images pass through both HTTP and WebSocket', async t => {
  const f = await fixture(t);
  const image = `data:image/png;base64,${Buffer.alloc(4 * 1024 * 1024).toString('base64')}`;
  const created = await f.create('editing', { ...editing, image_url: image });
  assert.equal(created.status, 200);
  const client = f.connect(created.body.live.id);
  await client.event('on_live');
  client.socket.send(JSON.stringify({ action: 'switch_prompt', image_url: image }));
  await client.event('switch_prompt_sent');
  await waitFor(() => f.signals.some(s => s.type === 13));
  assert.equal(f.signals.find(s => s.type === 13).payload.switch_prompt.prompts[0].content, image);
});

test('Invalid fields fail before upstream creation; audio omits persona enhancement', async t => {
  const f = await fixture(t);
  for (const [mode, body] of [
    ['editing', { ...editing, editing_type: 'unknown' }], ['editing', { image_url: '' }],
    ['avatar', { ...avatar, model: 'unknown' }],
    ['avatar', { ...avatar, avatar: { ...avatar.avatar, persona: '' } }]
  ]) assert.equal((await f.create(mode, body)).status, 400);
  assert.equal(f.requests.length, 0);
  await f.create('avatar', { ...avatar, call_mode: 'audio' });
  assert.equal(f.requests[0].body.avatar.persona_enhance, undefined);
});

test('Fatal initialization and timeouts close the session', async t => {
  for (const options of [{ fatal: true }, { neverReady: true }]) {
    await t.test(JSON.stringify(options), async t => {
      const f = await fixture(t, options);
      const { body } = await f.create('avatar', avatar);
      const client = f.connect(body.live.id);
      await client.event('fatal');
      await waitFor(() => client.socket.readyState === WebSocket.CLOSED);
      const count = f.signals.length;
      await delay(80);
      assert.equal(f.signals.length, count);
    });
  }
});

test('Browser disconnect sends hangup; forced upstream termination closes the browser', async t => {
  const f = await fixture(t);
  const first = await f.create('avatar', avatar), a = f.connect(first.body.live.id);
  await a.event('on_live'); a.socket.close();
  await waitFor(() => f.signals.some(s => s.live_id === first.body.live.id && s.type === 5));
  const second = await f.create('editing', editing), b = f.connect(second.body.live.id);
  await b.event('on_live');
  f.connections[1].ws.send(JSON.stringify({ type: 6, payload: { hangup: { hangup_reason: 'credit_insufficient' } } }));
  assert.equal((await b.event('server_hangup')).reason, 'credit_insufficient');
  await waitFor(() => b.socket.readyState === WebSocket.CLOSED);
});

test('Cancellation before WebSocket attach hangs up the created session and is idempotent', async t => {
  const f = await fixture(t);
  const { body } = await f.create('avatar', avatar);
  const path = `${f.base}/api/avatar/lives/${body.live.id}`;
  assert.equal((await fetch(path, { method: 'DELETE' })).status, 200);
  await waitFor(() => f.signals.some(s => s.type === 5 && s.live_id === body.live.id));
  assert.equal((await fetch(path, { method: 'DELETE' })).status, 200);
  assert.equal(f.signals.filter(s => s.type === 5).length, 1);
});


test('Prepared avatar IDs omit image uploads and keep transcription enabled', async t => {
  const f = await fixture(t);
  const result = await f.create('avatar', {call_mode:'video',avatar:{id:'1007605002660749312',persona:'Hello'}});
  assert.equal(result.status,200);
  assert.equal(f.requests[0].body.avatar.id,'1007605002660749312');
  assert.equal(f.requests[0].body.avatar.image_uri,undefined);
  assert.equal(f.requests[0].body.audio.enable_transcription,true);
  const invalid = await f.create('avatar',{call_mode:'video',avatar:{id:'../bad',persona:'Hello'}});
  assert.equal(invalid.status,400);
  assert.equal(f.requests.length,1);
});
