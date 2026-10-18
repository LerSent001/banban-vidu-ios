import {readFileSync,writeFileSync,existsSync,mkdirSync,chmodSync} from 'node:fs';
import {X509Certificate,randomBytes} from 'node:crypto';
import {networkInterfaces} from 'node:os';
import {isIP} from 'node:net';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
const argument=process.argv.indexOf('--host');
const networks=networkInterfaces();
const candidates=Object.entries(networks).sort(([a],[b])=>Number(b==='en0')-Number(a==='en0')).flatMap(([,values])=>values).filter(value=>!value.internal&&value.family==='IPv4'&&/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(value.address));
const host=argument>=0?process.argv[argument+1]:candidates[0]?.address;
if(!host||isIP(host)!==4)throw Error('未找到局域网 IPv4 地址，请连接 Wi-Fi，或使用 --host 192.168.x.x 指定电脑地址');
const root=new URL('../artifacts/private/device-service/',import.meta.url);
mkdirSync(root,{recursive:true,mode:0o700});
const certFile=new URL('cert.pem',root),keyFile=new URL('key.pem',root),tokenFile=new URL('client-token',root);
let certificate;
try{certificate=new X509Certificate(readFileSync(certFile));if(!certificate.checkIP(host)||Date.parse(certificate.validTo)<Date.now()+86400000||!existsSync(keyFile))certificate=null;}catch{}
if(!certificate){
 const config=new URL('openssl.cnf',root);
 writeFileSync(config,`[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n[dn]\nCN=${host}\n[extensions]\nsubjectAltName=IP:${host}\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n`,{mode:0o600});
 execFileSync('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','365','-keyout',fileURLToPath(keyFile),'-out',fileURLToPath(certFile),'-config',fileURLToPath(config)],{stdio:'ignore'});
 certificate=new X509Certificate(readFileSync(certFile));
}
chmodSync(keyFile,0o600);chmodSync(certFile,0o600);
const token=existsSync(tokenFile)?readFileSync(tokenFile,'utf8').trim():randomBytes(32).toString('hex');
writeFileSync(tokenFile,token,{mode:0o600});
const configFile=new URL('../ios/Room/Resources/DeviceConfig.json',import.meta.url);
writeFileSync(configFile,JSON.stringify({baseURL:`https://${host}:8788`,token,certificateSHA256:certificate.fingerprint256.replaceAll(':','').toLowerCase()},null,2),{mode:0o600});
const projectFile=new URL('../ios/BedroomRoom.xcodeproj/project.pbxproj',import.meta.url);
let project=readFileSync(projectFile,'utf8');
if(!project.includes('DeviceConfig.json in Resources')){
 const build='A65E9130A2FE44F89D010001',file='A65E9130A2FE44F89D010002';
 const edits=[
 ['/* Begin PBXBuildFile section */',`/* Begin PBXBuildFile section */\n\t\t${build} /* DeviceConfig.json in Resources */ = {isa = PBXBuildFile; fileRef = ${file} /* DeviceConfig.json */; };`],
 ['/* Begin PBXFileReference section */',`/* Begin PBXFileReference section */\n\t\t${file} /* DeviceConfig.json */ = {isa = PBXFileReference; lastKnownFileType = text.json; path = DeviceConfig.json; sourceTree = "<group>"; };`],
 ['\t\t\t\tF374E24B69A1464C81BB9A12 /* ScenePoses.json */,',`\t\t\t\t${file} /* DeviceConfig.json */,\n\t\t\t\tF374E24B69A1464C81BB9A12 /* ScenePoses.json */,`],
 ['\t\t\t\tF374E24B69A1464C81BB9A11 /* ScenePoses.json in Resources */,',`\t\t\t\t${build} /* DeviceConfig.json in Resources */,\n\t\t\t\tF374E24B69A1464C81BB9A11 /* ScenePoses.json in Resources */,`]
 ];
 for(const [before,after]of edits){if(!project.includes(before))throw Error('Xcode 项目结构已更改，请手动将 DeviceConfig.json 加入 App 资源');project=project.replace(before,after);}
 writeFileSync(projectFile,project);
}
console.log(`手机连接已配置： https://${host}:8788 。请重新编译安装 App，手机与电脑保持同一 Wi-Fi。`);
