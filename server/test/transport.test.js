import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { connect } from 'node:net';
import { once } from 'node:events';
import { WebSocket, WebSocketServer } from 'ws';
import { createUpstreamTransport } from '../transport.js';

test('Upstream HTTP and WebSocket both use the configured CONNECT proxy', async t => {
  const target = createServer((req, res) => { res.setHeader('Content-Type', 'application/json'); res.end('{"ok":true}'); });
  const wss = new WebSocketServer({ server: target });
  wss.on('connection', ws => ws.on('message', data => ws.send(data)));
  target.listen(0, '127.0.0.1'); await once(target, 'listening');
  let tunnels = 0; const sockets = new Set();
  const proxy = createServer();
  proxy.on('connect', (req, client, head) => {
    tunnels++;
    const upstream = connect(target.address().port, '127.0.0.1', () => {
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      client.pipe(upstream); upstream.pipe(client);
    });
    for (const socket of [client, upstream]) { sockets.add(socket); socket.on('error', () => {}); }
  });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  const transport = createUpstreamTransport('http://upstream.invalid', {HTTP_PROXY:`http://127.0.0.1:${proxy.address().port}`});
  t.after(() => { transport.close(); for (const socket of sockets) socket.destroy(); for (const ws of wss.clients) ws.terminate(); wss.close(); target.closeAllConnections(); target.close(); proxy.close(); });
  const response = await fetch('http://upstream.invalid/health', {...transport.fetchOptions, signal:AbortSignal.timeout(3000)});
  assert.deepEqual(await response.json(), {ok:true});
  const ws = new WebSocket('ws://upstream.invalid/control', transport.wsOptions);
  await once(ws,'open');
  const reply = once(ws,'message'); ws.send('probe');
  assert.equal(String((await reply)[0]),'probe'); ws.close();
  assert.equal(transport.mode,'proxy'); assert.equal(tunnels,2);
});

test('Local services and NO_PROXY hosts bypass the proxy', () => {
  const env = {HTTPS_PROXY:'http://127.0.0.1:1', HTTP_PROXY:'http://127.0.0.1:1', NO_PROXY:'.example.com'};
  assert.equal(createUpstreamTransport('http://127.0.0.1:8787',env).mode,'direct');
  assert.equal(createUpstreamTransport('https://api.example.com',env).mode,'direct');
});
