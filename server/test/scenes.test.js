import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createSceneService} from '../scenes.js';
import {buildSceneRequest,SCENE_POSES} from '../scene-prompt.js';
const input={request_id:'scene-test-123456789',image_uri:'data:image/png;base64,aGVsbG8=',scene:'夜景办公室'};
test('Every pose preserves the identity and front-facing frame within Vidu prompt limits',()=>{
 for(const pose of SCENE_POSES){const request=buildSceneRequest({...input,pose_id:pose.id,scene:'景'.repeat(800)});assert.equal(request.model,'viduq2');assert.equal(request.aspect_ratio,'9:16');assert.equal(request.images[0],input.image_uri);assert.ok(request.prompt.includes(pose.prompt));assert.match(request.prompt,/正面平视/);assert.match(request.prompt,/不换脸、不换装/);assert.ok(request.prompt.length<=2000);}
 assert.throws(()=>buildSceneRequest({...input,pose_id:'unknown'}));
});
test('Double taps and repeated submissions reuse one task; immediate success fetches the image',async()=>{
 const root=await mkdtemp(path.join(tmpdir(),'vidu-scenes-'));let creates=0;
 try{const service=createSceneService(async(route,options)=>{
  if(options?.method==='POST'){creates++;assert.match(JSON.parse(options.body).prompt,/大方舒展/);return {task_id:'task-001',state:'success'};}
  return {state:'success',creations:[{url:'https://example.com/result.png'}]};
 },{storageRoot:root});
 const body={...input,pose_id:'male-open'};
 const [a,b]=await Promise.all([service.create(body),service.create(body)]);assert.equal(creates,1);assert.equal(a.image_url,b.image_url);assert.ok(a.image_url);assert.equal(a.pose_id,'male-open');await service.create(body);assert.equal(creates,1);
 }finally{await rm(root,{recursive:true,force:true});}
});
test('An ambiguous upstream outcome is persisted and never resubmitted',async()=>{
 const root=await mkdtemp(path.join(tmpdir(),'vidu-scenes-'));let calls=0;
 try{const service=createSceneService(async()=>{calls++;throw Error('timeout');},{storageRoot:root});
 assert.equal((await service.create(input)).state,'unknown');assert.equal((await service.create(input)).state,'unknown');assert.equal(calls,1);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('Missing task returns 404 so the client can safely retry its original key',async()=>{
 const root=await mkdtemp(path.join(tmpdir(),'vidu-scenes-'));
 try { const service=createSceneService(async()=>{throw Error('must not call upstream');},{storageRoot:root});
 await assert.rejects(service.get(input.request_id),{statusCode:404});
 } finally { await rm(root,{recursive:true,force:true}); }
});
