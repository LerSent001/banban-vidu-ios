import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {webcrypto} from 'node:crypto';
const source=readFileSync(new URL('../public/control-connection.js',import.meta.url),'utf8');
test('Cloud control initializes once, retries NOT_READY on the same session, and hangs up explicitly',()=>{
 const sockets=[],timers=new Map();let next=0;
 class Socket{readyState=1;sent=[];constructor(url){this.url=url;sockets.push(this)}send(text){this.sent.push(JSON.parse(text))}close(){this.readyState=3;this.onclose?.({code:1000})}}
 const context=vm.createContext({window:{},WebSocket:Socket,crypto:webcrypto,URLSearchParams,setTimeout:fn=>{timers.set(++next,fn);return next},clearTimeout:id=>timers.delete(id)});
 vm.runInContext(source,context);
 const connection=context.window.createControlConnection({live:{id:'live-1'},control:{host:'api.vidu.cn',client_secret:'temporary-only'}}),events=[];
 connection.onmessage=event=>events.push(JSON.parse(event.data));const raw=sockets[0];raw.onopen();assert.equal(raw.sent[0].type,1);
 const deliver=payload=>raw.onmessage({data:JSON.stringify({type:2,payload:{conn_init_ack:payload}})});
 deliver({success:false,error_code:'NOT_READY'});[...timers.values()][0]();assert.equal(sockets.length,1);assert.equal(raw.sent[1].live_id,'live-1');
 deliver({success:true});assert.ok(events.some(e=>e.event==='on_live'));assert.equal(timers.size,0);
 connection.send(JSON.stringify({action:'text',content:'你好'}));assert.equal(raw.sent.at(-1).type,99);
 connection.send(JSON.stringify({action:'hangup'}));assert.equal(raw.sent.at(-1).type,5);connection.close();assert.equal(raw.readyState,3);
 assert.throws(()=>context.window.createControlConnection({live:{id:'live-1'},control:{host:'unexpected.example',client_secret:'temporary'}}));
});
