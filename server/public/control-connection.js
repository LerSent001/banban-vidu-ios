// Only session-scoped credentials are accepted here. The permanent Vidu key stays in the cloud.
class ViduControlConnection {
 constructor(data){
  if(data.control?.host!=='api.vidu.cn'||!data.control.client_secret)throw Error('缺少临时通话凭证');
  this.id=data.live.id;this.conn=crypto.randomUUID();this.sequence=0;this.ready=false;this.closed=false;
  const query=new URLSearchParams({live_id:this.id,conn_id:this.conn,client_secret:data.control.client_secret});
  this.socket=new WebSocket('wss://api.vidu.cn/live/ws/live/connect?'+query);
  this.socket.onopen=()=>this.signal(1,{conn_init:{version:1}});
  this.socket.onmessage=event=>{
   let message;try{message=JSON.parse(event.data)}catch{return;}
   this.emit({event:'vidu_message',message});
   const ack=message.payload?.conn_init_ack;
   if(message.type===2&&ack){
    if(ack.success){this.ready=true;clearTimeout(this.retry);this.emit({event:'on_live',live_id:this.id});}
    else if(ack.error_code==='NOT_READY'){this.emit({event:'not_ready'});clearTimeout(this.retry);this.retry=setTimeout(()=>{if(!this.closed)this.signal(1,{conn_init:{version:1}})},2000);}
    else this.emit({event:'fatal',message:ack.error_msg||ack.error_code||'人物连接失败'});
   }
   if(message.type===6)this.emit({event:'server_hangup',reason:message.payload?.hangup?.hangup_reason});
  };
  this.socket.onerror=event=>this.onerror?.(event);
  this.socket.onclose=event=>{this.closed=true;clearTimeout(this.retry);this.onclose?.(event);};
 }
 get readyState(){return this.socket.readyState;}
 emit(data){this.onmessage?.({data:JSON.stringify(data)});}
 signal(type,payload){if(this.socket.readyState===1)this.socket.send(JSON.stringify({type,live_id:this.id,conn_id:this.conn,seq_id:++this.sequence,payload}));}
 send(raw){
  const message=JSON.parse(raw);
  if(message.action==='hangup'){this.signal(5,{hangup:{hangup_reason:'user_end'}});return;}
  if(message.action==='text'&&this.ready&&typeof message.content==='string'&&message.content.trim()){
   this.signal(99,{text_msg:{msg_id:crypto.randomUUID(),content:message.content.trim(),timestamp:Date.now()}});this.emit({event:'text_sent'});return;
  }
  this.emit({event:'action_error',message:'连接尚未就绪，请稍后重试'});
 }
 close(){this.closed=true;clearTimeout(this.retry);this.socket.close();}
}
window.createControlConnection=data=>data.control?new ViduControlConnection(data):new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws/live?live_id='+encodeURIComponent(data.live.id));
