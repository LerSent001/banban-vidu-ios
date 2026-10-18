import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {WebSocket} from 'ws';
import {createQuickstartServer} from '../upstream.js';

test('device service rejects unauthenticated HTTP and WebSocket access, accepts app header and cookie',async()=>{
 const app=createQuickstartServer({apiKey:'vda_test_only',clientToken:'test-device-token',httpOrigin:'http://127.0.0.1:1'});
 app.listen(0,'127.0.0.1');await once(app,'listening');
 const base='http://127.0.0.1:'+app.address().port;
 try {
  for(const headers of [{},{Authorization:'Bearer wrong'},{Cookie:'RoomDeviceToken=wrong'}])assert.equal((await fetch(base+'/health',{headers})).status,401);
  for(const headers of [{Authorization:'Bearer test-device-token'},{Cookie:'other=1; RoomDeviceToken=test-device-token'}])assert.equal((await fetch(base+'/health',{headers})).status,200);
  const socket=new WebSocket(base.replace('http:','ws:')+'/ws/live?live_id=unrelated');
  const [error]=await once(socket,'error');assert.match(error.message,/401/);socket.terminate();
 }finally{await new Promise(resolve=>app.close(resolve));}
});
