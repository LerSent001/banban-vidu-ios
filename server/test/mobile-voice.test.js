import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import {webcrypto} from 'node:crypto';

const playback = readFileSync(new URL('../public/voice-playback.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../public/mobile.html', import.meta.url), 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];

function fixture(overrides = {}) {
  const events = [], published = [], intervals = new Map(), messages = [];
  let captures = 0, timerID = 0; const timeouts = new Map();
  const engine = {
    publishLocalVideoStream: async () => {}, startAudioCapture: async () => { captures++; },
    publishLocalAudioStream: async value => { published.push(value); },
    setChannelProfile: async () => {}, setAudioOnlyMode: async () => {},
    setDefaultSubscribeAllRemoteAudioStreams: async () => {}, setDefaultSubscribeAllRemoteVideoStreams: async () => {},
    joinChannel: async () => {}, on: () => {}, leaveChannel: async () => {}, destroy: async () => {}, ...overrides,
  };
  class Socket {
    readyState = 1;
    constructor() { queueMicrotask(() => this.onmessage({ data: JSON.stringify({ event: 'on_live' }) })); }
    send(message) { messages.push(JSON.parse(message)); }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const video = { play: async () => {}, srcObject: null };
  const context = vm.createContext({
    console, performance, AbortSignal, URL, URLSearchParams, crypto: webcrypto, WebSocket: Socket,
    navigator: { mediaDevices: { getUserMedia: () => { throw Error('Unexpected web microphone'); } } },
    location: { protocol: 'https:', host: 'test.local', origin: 'https://test.local' },
    document: { getElementById: () => video, querySelectorAll: () => [] },
    setTimeout: (fn, ms) => { timeouts.set(++timerID, {fn, ms}); return timerID; }, clearTimeout: id => timeouts.delete(id),
    setInterval: callback => { intervals.set(++timerID, callback); return timerID; },
    clearInterval: id => intervals.delete(id),
    fetch: async path => ({ ok: true, json: async () => path === '/api/avatar/assets' ? { id: 'asset', status: 'success' } : path === '/api/avatar/lives' ? { live: { id: 'test-live' }, rtc: { token: 'fake-token', user_id: 'fake-user' } } : {} }),
    window: { __peerConnections: [], addEventListener() {}, webkit: { messageHandlers: { room: { postMessage: value => events.push(value) } } }, AliRtcEngine: { isSupported: async () => ({ support: true }), getInstance: () => engine } },
  });
  vm.runInContext(readFileSync(new URL('../public/control-connection.js',import.meta.url),'utf8'),context);
  vm.runInContext(playback, context);
  vm.runInContext(script, context);
  return { context, events, published, intervals, timeouts, messages, captures: () => captures };
}

test('Native dictation receives RTC without starting or publishing a second microphone', async () => {
  const f = fixture();
  await f.context.window.startCall({ call_mode: 'video', avatar: { image_uri: 'test', name: 'test' } }, { nativeSpeech: true });
  assert.equal(f.captures(), 0);
  assert.deepEqual(f.published, [false, false]);
  assert.ok(f.events.some(event => event.event === 'connected'));
  assert.equal(f.context.window.sendText('你好'), true);
  assert.equal(f.messages.at(-1).content, '你好');
  await f.context.window.setMuted(false);
  assert.deepEqual(f.published, [false, false]);
  await f.context.window.endCall();
  assert.equal(f.intervals.size, 0);
  assert.equal(f.context.window.sendText('挂断后不能发送'), false);
});

test('Reply detection does not reopen dictation during short speech pauses', () => {
  const changes = [];
  const context = vm.createContext({ changes, performance });
  vm.runInContext(playback + '\nthis.meter = new VoicePlayback(active => changes.push(active));', context);
  context.meter.sample(0, 0);
  context.meter.sample(0.1, 100);
  context.meter.sample(0, 700);
  context.meter.sample(0.15, 1100);
  context.meter.sample(0, 2300);
  assert.deepEqual(changes, [true]);
  context.meter.sample(0, 2600);
  assert.deepEqual(changes, [true, false]);
});

test('A text request before RTC is ready fails visibly instead of silently dropping', () => {
  assert.equal(fixture().context.window.sendText('你好'), false);
});


test('Stalled RTC joins and stalled SDK cleanup stop waiting and request a clean page reload', async () => {
 const f=fixture({joinChannel:()=>new Promise(()=>{}),leaveChannel:()=>new Promise(()=>{})});
 const call=f.context.window.startCall({call_mode:'video',avatar:{image_uri:'test',name:'test'}},{nativeSpeech:true});
 await new Promise(resolve=>setImmediate(resolve));
 const joinTimer=[...f.timeouts.values()].find(t=>t.ms===30000);assert.ok(joinTimer);joinTimer.fn();
 await new Promise(resolve=>setImmediate(resolve));
 const cleanupTimer=[...f.timeouts.values()].find(t=>t.ms===8000);assert.ok(cleanupTimer);cleanupTimer.fn();await call;
 assert.ok(f.events.some(e=>e.event==='error'&&/超时/.test(e.message)));
 assert.ok(f.events.some(e=>e.event==='ended'&&e.reloadRequired===true));
});
