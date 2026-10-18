import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,copyFile,readFile,rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import https from 'node:https';
import {once} from 'node:events';
import {createQuickstartServer} from '../server.js';

test('Fresh phone setup produces a trusted authenticated LAN service and reuses its identity',async()=>{
 const root=await mkdtemp(path.join(tmpdir(),'banban wifi '));
 let server;
 try{
  for(const dir of ['server','ios/Room/Resources','ios/BedroomRoom.xcodeproj'])await mkdir(path.join(root,dir),{recursive:true});
  await copyFile(new URL('../prepare-device.js',import.meta.url),path.join(root,'server/prepare-device.mjs'));
  await copyFile(new URL('../../ios/BedroomRoom.xcodeproj/project.pbxproj',import.meta.url),path.join(root,'ios/BedroomRoom.xcodeproj/project.pbxproj'));
  const prepare=()=>execFileSync(process.execPath,[path.join(root,'server/prepare-device.mjs'),'--host','127.0.0.1'],{stdio:'pipe'});
  prepare();
  const configPath=path.join(root,'ios/Room/Resources/DeviceConfig.json');
  const before=await readFile(configPath,'utf8');prepare();assert.equal(await readFile(configPath,'utf8'),before);
  const config=JSON.parse(before),certificate=await readFile(path.join(root,'artifacts/private/device-service/cert.pem'));
  server=createQuickstartServer({apiKey:'',clientToken:config.token,tls:{cert:certificate,key:await readFile(path.join(root,'artifacts/private/device-service/key.pem'))}});
  server.listen(0,'127.0.0.1');await once(server,'listening');
  const request=authenticated=>new Promise((resolve,reject)=>{
   https.get(`https://127.0.0.1:${server.address().port}/health`,{ca:certificate,headers:authenticated?{Authorization:'Bearer '+config.token}:{}},response=>{let body='';response.on('data',chunk=>body+=chunk);response.on('end',()=>resolve({status:response.statusCode,body:JSON.parse(body)}));}).on('error',reject);
  });
  assert.equal((await request(false)).status,401);
  const allowed=await request(true);assert.equal(allowed.status,200);assert.equal(allowed.body.has_api_key,false);
 }finally{if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}await rm(root,{recursive:true,force:true});}
});
