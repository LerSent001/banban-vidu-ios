import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {createQuickstartServer} from '../server.js';
test('Without a Vidu key, health reports unconfigured and scene creation is rejected before submitting',async()=>{
 const server=createQuickstartServer({apiKey:''});server.listen(0,'127.0.0.1');await once(server,'listening');
 try{
 const origin='http://127.0.0.1:'+server.address().port;
 assert.equal((await (await fetch(origin+'/health')).json()).has_api_key,false);
 const response=await fetch(origin+'/api/avatar/scenes',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({request_id:'unconfigured-scene-12345',image_uri:'data:image/png;base64,aGVsbG8=',scene:'测试'})});
 assert.equal(response.status,503);
 }finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
});
