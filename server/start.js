import {existsSync,readFileSync} from 'node:fs';
import {createQuickstartServer} from './upstream.js';
const file=new URL('../.env.local',import.meta.url);
const env={};
if(existsSync(file))for(const line of readFileSync(file,'utf8').split(/\r?\n/)){const match=line.match(/^([A-Z_]+)=(.*)$/);if(match)env[match[1]]=match[2].replace(/^['"]|['"]$/g,'');}
const apiKey=process.env.VIDU_API_KEY||env.VIDU_API_KEY||'';
const server=createQuickstartServer({host:'api.vidu.cn',apiKey});
server.listen(8787,'127.0.0.1',()=>console.log(apiKey?'Local Vidu service: http://127.0.0.1:8787':'请配置自己的 VIDU_API_KEY；当前仅可使用本地角色管理与界面。'));
for(const signal of ['SIGTERM','SIGINT'])process.on(signal,()=>server.close(()=>process.exit(0)));
