import { createSceneService } from './scenes.js';
import { recommendVoice } from './voice-match.js';
import { createServer } from 'node:http';
import { createServer as createSecureServer } from 'node:https';
import { randomUUID, createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';
import { createUpstreamTransport } from './transport.js';

const EXAMPLE_ROOT = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_ROOT = path.join(EXAMPLE_ROOT, 'public');
const EDITING_TYPES = ['style_transfer', 'virtual_tryon', 'subject_replacement', 'background_replacement'];
const ROUTES = { avatar: '/live/s_avatar/realtime', editing: '/live/s_editing/realtime' };
const MAX_SIGNAL_BYTES = 6 * 1024 * 1024; // A 4 MB editing image grows to ~5.4 MB in base64.

export function createQuickstartServer({
  host = 'api.vidu.cn', apiKey = '', defaults = {},
  httpOrigin = `https://${host}`, wsOrigin = `wss://${host}`,
  retryMs = 2000, initTimeoutMs = 120000, tls = null, clientToken = null
} = {}) {
  const sessions = new Map();
  const avatarCache = new Map();
  const transport = createUpstreamTransport(httpOrigin);
  const diagnostic = (event, details = {}) => console.log(JSON.stringify({ time: new Date().toISOString(), event, transport: transport.mode, ...details }));
  const token = apiKey.trim().replace(/^Token\s+/, '');
  const hasApiKey = token.startsWith('vda_') && !token.includes('your_api_key_here');
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_SIGNAL_BYTES });
  const config = {
    host, has_api_key: hasApiKey,
    defaults: {
      avatar: {
        call_mode: defaults.call_mode || 'video', model: 'vidu-s2',
        avatar: {
          image_uri: defaults.image_uri || '',
          persona: defaults.persona || 'You are Sweet Tina, a warm and friendly digital character.',
          name: defaults.name || 'Tina', voice: defaults.voice || 'Tina', persona_enhance: false
        }
      },
      editing: { image_url: defaults.editing_image_url || '', editing_type: defaults.editing_type || 'style_transfer' }
    }
  };

  async function terminateUnattached(session) {
    const connId = randomUUID();
    return new Promise(resolve => {
      const query = new URLSearchParams({ live_id: session.id, conn_id: connId });
      const ws = new WebSocket(`${wsOrigin}/live/ws/live/connect?${query}`, { ...transport.wsOptions, headers: { Authorization: authorization() }, handshakeTimeout: 10000 });
      const timer = setTimeout(() => { ws.terminate(); resolve(); }, 12000);
      ws.on('open', () => { ws.send(JSON.stringify({ type: 5, live_id: session.id, conn_id: connId, seq_id: 1, payload: { hangup: { hangup_reason: 'user_end' } } })); ws.close(); });
      ws.on('error', () => { clearTimeout(timer); resolve(); });
      ws.on('close', () => { clearTimeout(timer); resolve(); });
    });
  }

  function authorization() {
    if (!hasApiKey) throw httpError(503, 'Set VIDU_API_KEY to your region’s vda_... API key in .env.');
    return `Token ${token}`;
  }

  async function viduFetch(route, options = {}, requestId) {
    const started = Date.now();
    diagnostic('upstream_request', { route, method: options.method || 'GET', request_id: requestId });
    try {
      const response = await fetch(`${httpOrigin}${route}`, {
        ...transport.fetchOptions, ...options, signal: AbortSignal.timeout(60000),
        headers: { Authorization: authorization(), 'Content-Type': 'application/json', Accept: 'application/json' }
      });
      const body = await response.text();
      const data = safeJson(body);
      diagnostic('upstream_response', { route, request_id: requestId, status: response.status, ms: Date.now() - started, trace_id: data?.metadata?.trace_id });
      if (!response.ok) throw httpError(response.status, data?.error?.message || data?.message || `Vidu 返回错误（${response.status}）`);
      if (!data) throw httpError(502, 'Vidu 返回的数据无法解析。');
      return data;
    } catch (error) {
      diagnostic('upstream_failure', { route, request_id: requestId, ms: Date.now() - started, code: error.cause?.code || error.name });
      if (error.name === 'TimeoutError' || error.name === 'AbortError') {
        throw httpError(504, '会话创建未确认：60 秒内未收到 Vidu 的会话 ID。请勿连续重试。');
      }
      if (error instanceof TypeError && error.cause) throw httpError(502, '无法连接 Vidu，请检查本机网络与代理。');
      throw error;
    }
  }

  const sceneService = createSceneService(viduFetch);
  function authenticated(request) {
    if (!clientToken) return true;
    const bearer = request.headers.authorization;
    const cookie = request.headers.cookie?.split(';').map(x => x.trim()).find(x => x.startsWith('RoomDeviceToken='))?.slice('RoomDeviceToken='.length);
    return bearer === 'Bearer ' + clientToken || cookie === clientToken;
  }
  const handler = async (request, response) => {
    if (!authenticated(request)) { sendJson(response,401,{error:'Device authentication required'}); return; }
    try {
      const url = new URL(request.url, 'http://localhost');
      if (request.method === 'GET' && url.pathname === '/health') {
        sendJson(response, 200, { ok: true, host, has_api_key: hasApiKey, transport: transport.mode });
        return;
      }
      if (request.method === 'GET' && url.pathname === '/api/config') {
        sendJson(response, 200, config);
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/diagnostics') {
        const body = await readJsonBody(request);
        const allowed = ['ready','status','session','connected','video','ended','error','media','transcript','rtc','signal'];
        if (allowed.includes(body.event)) diagnostic('client_' + body.event, { detail: JSON.stringify(body.detail ?? {}).slice(0, 1500) });
        sendJson(response, 200, {ok:true}); return;
      }
      if (request.method === 'POST' && url.pathname === '/api/avatar/scenes') {
        authorization();
        sendJson(response,200,await sceneService.create(await readJsonBody(request))); return;
      }
      const sceneMatch=url.pathname.match(/^\/api\/avatar\/scenes\/([a-zA-Z0-9-]+)$/);
      if(request.method==='GET' && sceneMatch){sendJson(response,200,await sceneService.get(sceneMatch[1]));return;}
      if (request.method === 'POST' && url.pathname === '/api/avatar/recommend-voice') {
        const body=await readJsonBody(request); validateImage(body.image_uri);
        sendJson(response,200,await recommendVoice(body.image_uri)); return;
      }
      if (request.method === 'POST' && url.pathname === '/api/avatar/assets') {
        const body = await readJsonBody(request); validateImage(body.image_uri);
        const hash = createHash('sha256').update(body.image_uri).digest('hex');
        let asset = avatarCache.get(hash);
        if (!asset) {
          asset = await viduFetch('/live/v1/avatars', {method:'POST', body:JSON.stringify({image_uri:body.image_uri, name:body.name || '卧室人物'})});
          if (!asset.id) throw httpError(502, '人物图片未获得资源 ID');
          avatarCache.set(hash, asset);
        }
        sendJson(response, 200, {id:asset.id, status:asset.status}); return;
      }
      const assetMatch = url.pathname.match(/^\/api\/avatar\/assets\/([0-9]+)$/);
      if (request.method === 'GET' && assetMatch) {
        const asset = await viduFetch('/live/v1/avatars/'+assetMatch[1]);
        for (const [hash, cached] of avatarCache) if (cached.id === asset.id) avatarCache.set(hash, asset);
        sendJson(response, 200, {id:asset.id, status:asset.status}); return;
      }
      const createMatch = url.pathname.match(/^\/api\/(avatar|editing)\/lives$/);
      if (request.method === 'POST' && createMatch) {
        authorization();
        const mode = createMatch[1];
        const body = await readJsonBody(request);
        const payload = buildPayload(mode, body, config.defaults[mode]);
        const requestId = randomUUID();
        response.setHeader('X-Request-Id', requestId);
        diagnostic('create_begin', { request_id: requestId, model: payload.model, image_bytes: Buffer.byteLength(payload.avatar?.image_uri || '') });
        const data = await viduFetch(ROUTES[mode], { method: 'POST', body: JSON.stringify(payload) }, requestId);
        const id = data.live?.id;
        if (typeof id !== 'string' || !id || !data.rtc?.token || (mode === 'editing' && !data.render_uid)) {
          throw httpError(502, 'Vidu response is missing live.id (string), RTC credentials, or editing render_uid.');
        }
        const session = { id, mode, callMode: payload.call_mode || 'video', clientSecret: data.client_secret, proxy: null };
        diagnostic('session_created', { live_id: id, request_id: requestId });
        if (response.destroyed) {
          diagnostic('client_left_during_create', { live_id: id });
          await terminateUnattached(session);
          return;
        }
        // Reclaim only abandoned setup; an attached call has no duration cap.
        session.timer = setTimeout(() => {
          if (!session.proxy) { terminateUnattached(session).catch(() => {}); sessions.delete(id); }
        }, 90000);
        session.timer.unref();
        sessions.set(id, session);
        // The reusable API key and editing control credential stay on the server.
        sendJson(response, 200, { live: data.live, rtc: data.rtc, ...(mode === 'editing' ? { render_uid: data.render_uid } : {}) });
        return;
      }
      const endMatch = url.pathname.match(/^\/api\/avatar\/lives\/([^/]+)$/);
      if (request.method === 'DELETE' && endMatch) {
        const session = sessions.get(decodeURIComponent(endMatch[1]));
        if (session) {
          clearTimeout(session.timer);
          if (session.proxy) session.proxy.shutdown(true);
          else await terminateUnattached(session);
          sessions.delete(session.id);
        }
        sendJson(response, 200, { ended: true }); return;
      }
      const queryMatch = url.pathname.match(/^\/api\/avatar\/lives\/([^/]+)$/);
      if (request.method === 'GET' && queryMatch) {
        const id = decodeURIComponent(queryMatch[1]);
        const data = await viduFetch(`/live/v1/lives/${encodeURIComponent(id)}`);
        sendJson(response, 200, data);
        return;
      }
      if (request.method === 'GET' && !url.pathname.startsWith('/api/')) {
        await serveStatic(url.pathname, response);
        return;
      }
      sendJson(response, 404, { error: 'Not found.' });
    } catch (error) {
      sendJson(response, error.statusCode || 500, { error: error.message });
    }
  };
  const server = tls ? createSecureServer(tls, handler) : createServer(handler);

  server.on('upgrade', (request, socket, head) => {
    if (!authenticated(request)) { socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return; }
    const url = new URL(request.url, 'http://localhost');
    const session = sessions.get(url.searchParams.get('live_id'));
    if (url.pathname !== '/ws/live' || !session || session.proxy) {
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return;
    }
    wss.handleUpgrade(request, socket, head, client => {
      const proxy = new LiveControlProxy(client, session, {
        wsOrigin, authorization: authorization(), retryMs, wsOptions: transport.wsOptions, diagnostic,
        initTimeoutMs: session.mode === 'avatar' ? Math.min(initTimeoutMs, 60000) : initTimeoutMs,
        onClose: () => { clearTimeout(session.timer); sessions.delete(session.id); }
      });
      clearTimeout(session.timer);
      session.proxy = proxy;
      proxy.start();
    });
  });
  server.on('close', () => {
    for (const session of sessions.values()) {
      clearTimeout(session.timer);
      session.proxy?.shutdown(true);
    }
    sessions.clear();
    wss.close();
    transport.close();
  });
  return server;
}

function buildPayload(mode, body, defaults) {
  if (mode === 'editing') {
    const image = body.image_url ?? defaults.image_url;
    validateImage(image, true);
    const editingType = body.editing_type ?? defaults.editing_type;
    validateEditingType(editingType);
    return { image_url: image, editing_type: editingType };
  }
  const callMode = body.call_mode ?? defaults.call_mode;
  if (!['audio', 'video'].includes(callMode)) throw httpError(400, 'call_mode must be audio or video.');
  if (body.avatar !== undefined && (!body.avatar || typeof body.avatar !== 'object' || Array.isArray(body.avatar))) {
    throw httpError(400, 'avatar must be an object.');
  }
  const avatar = { ...defaults.avatar, ...body.avatar };
  if (!avatar.id) validateImage(avatar.image_uri);
  else if (typeof avatar.id !== 'string' || !/^[0-9]+$/.test(avatar.id)) throw httpError(400, 'Invalid avatar ID');
  if (typeof avatar.persona !== 'string' || !avatar.persona.trim() || avatar.persona.length > 50000) {
    throw httpError(400, 'avatar.persona must contain 1–50,000 characters.');
  }
  if (avatar.persona_enhance !== undefined && typeof avatar.persona_enhance !== 'boolean') {
    throw httpError(400, 'avatar.persona_enhance must be a boolean.');
  }
  const model = body.model ?? defaults.model;
  if (!['vidu-s1', 'vidu-s2'].includes(model)) throw httpError(400, 'model must be vidu-s1 or vidu-s2.');
  const result = { persona: avatar.persona, ...(avatar.id ? {id:avatar.id} : {image_uri:avatar.image_uri}) };
  for (const key of ['name', 'voice']) {
    if (avatar[key] !== undefined && typeof avatar[key] !== 'string') throw httpError(400, `avatar.${key} must be a string.`);
    if (avatar[key]) result[key] = avatar[key];
  }
  if (callMode === 'video') result.persona_enhance = Boolean(avatar.persona_enhance);
  return { model, call_mode: callMode, rtc: { provider: 'artc' }, idle_timeout_seconds: 180, voice_model: {provider:'qwen_omni'}, audio: {enable_transcription:true}, avatar: result };
}

function validateImage(value, editing = false) {
  if (typeof value !== 'string' || !( /^https?:\/\/\S+$/i.test(value) || /^data:image\/[\w.+-]+;base64,[A-Za-z0-9+/=\s]+$/.test(value) || (editing && /^ssupload:\?id=\S+/.test(value)))) {
    throw httpError(400, 'Provide an image URL or base64 image data URI. Editing also accepts a platform upload URI.');
  }
}

function validateEditingType(value) {
  if (!EDITING_TYPES.includes(value)) throw httpError(400, `editing_type must be one of: ${EDITING_TYPES.join(', ')}.`);
}

class LiveControlProxy {
  constructor(client, session, options) {
    Object.assign(this, { client, session, ...options });
    this.connId = randomUUID();
    this.seqId = 0;
    this.ready = false;
    this.closed = false;
    this.hangupSent = false;
  }

  start() {
    const query = new URLSearchParams({ live_id: this.session.id, conn_id: this.connId });
    if (this.session.clientSecret) query.set('client_secret', this.session.clientSecret);
    this.remote = new WebSocket(`${this.wsOrigin}/live/ws/live/connect?${query}`, {
      ...this.wsOptions, headers: { Authorization: this.authorization }, handshakeTimeout: 15000, maxPayload: MAX_SIGNAL_BYTES
    });
    this.client.on('message', data => this.handleClientMessage(data));
    this.client.on('close', () => this.shutdown());
    this.client.on('error', () => this.shutdown());
    this.initTimer = setTimeout(() => this.fail('人物初始化超时，连接已结束。请稍后重试。'), this.initTimeoutMs);
    this.remote.on('open', () => {
      this.diagnostic?.('control_open', { live_id: this.session.id });
      if (this.closed) return;
      this.sendClient({ event: 'remote_open' });
      this.heartbeat = setInterval(() => { if (this.remote?.readyState === WebSocket.OPEN) this.remote.ping(); }, 5000);
      this.sendSignal(1, { conn_init: { version: 1 } });
    });
    this.remote.on('message', data => {
      if (this.closed) return;
      const message = safeJson(data.toString());
      if (!message) return;
      this.sendClient({ event: 'vidu_message', message });
      this.diagnostic?.('signal_received', {live_id:this.session.id,type:message.type, payload_keys:Object.keys(message.payload || {}), ...([9,10].includes(message.type)?{payload:message.payload}:{})});
      const ack = message.payload?.conn_init_ack;
      if (message.type === 2 && ack) {
        if (ack.success === true) {
          clearTimeout(this.initTimer);
          clearTimeout(this.retryTimer);
          this.ready = true;
          this.diagnostic?.('control_ready', { live_id: this.session.id });
          this.sendClient({ event: 'on_live', live_id: this.session.id });
        } else if (ack.error_code === 'NOT_READY') {
          this.sendClient({ event: 'not_ready' });
          // Editing pushes a success ack when ready. Avatar needs conn_init retried on this socket.
          if (this.session.mode === 'avatar' && !this.ready) {
            clearTimeout(this.retryTimer);
            this.retryTimer = setTimeout(() => this.sendSignal(1, { conn_init: { version: 1 } }), this.retryMs);
          }
        } else {
          this.fail(ack.error_msg || ack.error_code || 'Initialization failed.');
        }
      }
      if (message.type === 6) {
        this.sendClient({ event: 'server_hangup', reason: message.payload?.hangup?.hangup_reason || 'unknown' });
        this.shutdown(true, false);
      }
    });
    // ws automatically responds to upstream ping frames with pong frames.
    this.remote.on('error', () => this.fail('人物实时连接失败，请检查网络与代理设置。'));
    this.remote.on('close', (code) => {
      if (!this.closed) {
        this.sendClient({ event: 'remote_closed', code });
        this.shutdown(true, false);
      }
    });
  }

  handleClientMessage(data) {
    if (this.closed) return;
    try {
      const message = safeJson(data.toString());
      if (message?.action === 'hangup') {
        this.shutdown(true);
        return;
      }
      if (!this.ready) throw httpError(409, 'Wait for the session to become ready.');
      if (message?.action === 'text' && this.session.mode === 'avatar') {
        if (typeof message.content !== 'string' || !message.content.trim()) throw httpError(400, 'Text is required.');
        this.sendSignal(99, { text_msg: { msg_id: randomUUID(), content: message.content.trim(), timestamp: Date.now() } });
        this.sendClient({ event: 'text_sent' });
        return;
      }
      if (message?.action === 'switch_prompt' && this.session.mode === 'editing') {
        const prompt = {};
        if (message.image_url) {
          validateImage(message.image_url, true);
          prompt.prompts = [{ type: 'image', content: message.image_url }];
        }
        if (message.editing_type !== undefined) {
          validateEditingType(message.editing_type);
          prompt.editing_type = message.editing_type;
        }
        if (!Object.keys(prompt).length) throw httpError(400, 'Provide a new image or editing type.');
        this.sendSignal(13, { switch_prompt: prompt });
        this.sendClient({ event: 'switch_prompt_sent' });
        return;
      }
      throw httpError(400, 'Unsupported action for this session.');
    } catch (error) {
      this.sendClient({ event: 'action_error', message: error.message });
    }
  }

  sendSignal(type, payload) {
    if (this.remote?.readyState === WebSocket.OPEN) {
      this.remote.send(JSON.stringify({ type, live_id: this.session.id, conn_id: this.connId, seq_id: ++this.seqId, payload }));
    }
  }

  sendClient(message) {
    if (this.client.readyState === WebSocket.OPEN) this.client.send(JSON.stringify(message));
  }

  fail(message) {
    if (this.closed) return;
    this.sendClient({ event: 'fatal', message });
    this.shutdown(true);
  }

  shutdown(closeClient = false, hangup = true) {
    if (this.closed) return;
    if (hangup && !this.hangupSent) {
      this.sendSignal(5, { hangup: { hangup_reason: 'user_end' } });
      this.hangupSent = true;
    }
    this.closed = true;
    clearTimeout(this.initTimer);
    clearTimeout(this.retryTimer);
    clearInterval(this.heartbeat);
    if (this.remote?.readyState < WebSocket.CLOSING) this.remote.close(1000, 'session ended');
    if (closeClient && this.client.readyState < WebSocket.CLOSING) this.client.close(1000, 'session ended');
    this.onClose();
  }
}

async function serveStatic(pathname, response) {
  const aliases = { '/': '/mobile.html', '/mobile': '/mobile.html', '/avatar': '/avatar.html', '/editing': '/editing.html' };
  const filePath = path.resolve(PUBLIC_ROOT, `.${decodeURIComponent(aliases[pathname] || pathname)}`);
  if (!filePath.startsWith(`${PUBLIC_ROOT}${path.sep}`)) throw httpError(403, 'Forbidden.');
  try {
    const body = await readFile(filePath);
    const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript' };
    response.writeHead(200, { 'Content-Type': `${types[path.extname(filePath)] || 'application/octet-stream'}; charset=utf-8`, 'Cache-Control': 'no-store' });
    response.end(body);
  } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'EISDIR') throw httpError(404, 'Not found.');
    throw error;
  }
}

async function readJsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 28 * 1024 * 1024) throw httpError(413, 'Request body is too large.');
    chunks.push(chunk);
  }
  const data = safeJson(Buffer.concat(chunks).toString());
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw httpError(400, 'Request body must be a JSON object.');
  return data;
}

function sendJson(response, status, data) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(data));
}

function httpError(statusCode, message) { return Object.assign(new Error(message), { statusCode }); }
function safeJson(text) { try { return JSON.parse(text); } catch { return null; } }

function loadDotEnv(filePath) {
  if (!existsSync(filePath)) return;
  for (const line of readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const match = line.trim().match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match || process.env[match[1]] !== undefined) continue;
    const raw = match[2].trim();
    process.env[match[1]] = /^(".*"|'.*')$/.test(raw) ? raw.slice(1, -1) : raw;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  loadDotEnv(path.resolve(EXAMPLE_ROOT, '../../.env'));
  loadDotEnv(path.join(EXAMPLE_ROOT, '.env'));
  const host = (process.env.VIDU_HOST || 'api.vidu.cn').replace(/^https?:\/\//, '').replace(/\/+$/, '');
  const port = Number(process.env.NODE_QUICKSTART_PORT || process.env.PORT || 8787);
  createQuickstartServer({
    host, apiKey: process.env.VIDU_API_KEY || process.env.VIDU_TOKEN || '',
    defaults: {
      call_mode: process.env.VIDU_CALL_MODE, image_uri: process.env.VIDU_AVATAR_IMAGE_URI,
      persona: process.env.VIDU_AVATAR_PERSONA, name: process.env.VIDU_AVATAR_NAME, voice: process.env.VIDU_AVATAR_VOICE,
      editing_image_url: process.env.VIDU_EDITING_IMAGE_URL, editing_type: process.env.VIDU_EDITING_TYPE
    }
  }).listen(port, '127.0.0.1', () => {
    console.log(`Vidu S2 Node quickstart: http://localhost:${port} (Avatar / Editing)`);
    console.log(`Using Vidu host ${host}`);
  });
}
