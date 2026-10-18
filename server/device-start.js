import {execFileSync} from 'node:child_process';
import {readFileSync,existsSync} from 'node:fs';
import {createQuickstartServer} from './upstream.js';
const file=new URL('../.env.local',import.meta.url),env={...process.env};
if(existsSync(file))for(const line of readFileSync(file,'utf8').split(/\r?\n/)){const match=line.match(/^([A-Z_]+)=(.*)$/);if(match&&!env[match[1]])env[match[1]]=match[2].trim().replace(/^['"]|['"]$/g,'');}
const root=new URL('../artifacts/private/device-service/',import.meta.url);
if(!process.env.HTTPS_PROXY&&!process.env.https_proxy&&process.platform==='darwin'){
 try{const proxy=execFileSync('/usr/sbin/scutil',['--proxy'],{encoding:'utf8'});if(/HTTPSEnable\s*:\s*1/.test(proxy)){const host=proxy.match(/HTTPSProxy\s*:\s*(\S+)/)?.[1],port=proxy.match(/HTTPSPort\s*:\s*(\d+)/)?.[1];if(host&&port)process.env.HTTPS_PROXY=`http://${host}:${port}`;}}catch{}
}
const config=JSON.parse(readFileSync(new URL('../ios/Room/Resources/DeviceConfig.json',import.meta.url),'utf8'));
const address=new URL(config.baseURL);
if(address.protocol!=='https:'||address.port!=='8788')throw Error('请先运行 pnpm prepare:phone 配置本地手机服务');
const server=createQuickstartServer({host:'api.vidu.cn',apiKey:env.VIDU_API_KEY||'',clientToken:readFileSync(new URL('client-token',root),'utf8').trim(),tls:{cert:readFileSync(new URL('cert.pem',root)),key:readFileSync(new URL('key.pem',root)),minVersion:'TLSv1.2'}});
server.listen(8788,address.hostname,()=>console.log(`手机服务已启动：${address.origin}。保持电脑在线，手机与电脑连接同一 Wi-Fi。`));
for(const signal of ['SIGTERM','SIGINT'])process.on(signal,()=>server.close(()=>process.exit(0)));
