import {buildSceneRequest,SCENE_PROMPT_VERSION} from './scene-prompt.js';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../artifacts/private/scene-jobs');
export function createSceneService(viduFetch, {storageRoot=root} = {}){
 const running=new Map();
 const file=id=>{if(!/^[a-zA-Z0-9-]{16,64}$/.test(id))throw Error('无效的场景任务');return path.join(storageRoot,id+'.json')};
 const save=async job=>{await mkdir(storageRoot,{recursive:true,mode:0o700});await writeFile(file(job.request_id),JSON.stringify(job),{mode:0o600})};
 const load=async id=>{try{return JSON.parse(await readFile(file(id),'utf8'))}catch(e){if(e.code==='ENOENT')return null;throw e}};
 async function create(body){
  const id=body.request_id;file(id);
  if(running.has(id))return running.get(id);
  const work=(async()=>{
   const old=await load(id);if(old)return old;
   const request=buildSceneRequest(body);
   const job={request_id:id,state:'submitting',created_at:new Date().toISOString(),model:request.model,pose_id:body.pose_id??'natural',prompt_version:SCENE_PROMPT_VERSION,prompt:request.prompt};await save(job);
   try{
    const data=await viduFetch('/ent/v2/reference2image',{method:'POST',body:JSON.stringify(request)});
    if(!data.task_id)throw Error('未收到场景任务编号');
    Object.assign(job,{task_id:data.task_id,state:data.state||'created'});
   }catch(e){job.state=e.statusCode>=400&&e.statusCode<500?'failed':'unknown';job.error=job.state==='unknown'?'提交结果暂未确认，请勿重复创建。':e.message;}
   await save(job);return job.state==='success'?get(id):job;
  })();running.set(id,work);try{return await work}finally{running.delete(id)}
 }
 async function get(id){
  const job=await load(id);if(!job)throw Object.assign(new Error('场景任务不存在'),{statusCode:404});
  if(job.task_id&&job.state!=='failed'){
   const data=await viduFetch('/ent/v2/tasks/'+encodeURIComponent(job.task_id)+'/creations');
   job.state=data.state;job.error=data.err_code||null;
   if(data.state==='success'){job.image_url=data.creations?.[0]?.url;if(!job.image_url){job.state='failed';job.error='场景服务未返回图片';}}
   await save(job);
  }
  return job;
 }
 return {create,get};
}
