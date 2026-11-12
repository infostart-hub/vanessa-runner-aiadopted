import {spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync,existsSync} from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';

const [root,oscript,outRoot,version]=process.argv.slice(2);
assert(root && oscript && outRoot && version,'Usage: node mcp-enterprise.mjs ROOT OSCRIPT OUTPUT_DIRECTORY PLATFORM_VERSION');
const directory=mkdtempSync(path.join(outRoot,'verification-'));
const base=path.join(directory,'ib');
const settings=path.join(directory,'settings.json');
writeFileSync(settings,'{}');
const evidence=[];
function client(){
  const child=spawn(oscript,[path.join(root,'src','mcp.os')],{cwd:root,stdio:['pipe','pipe','pipe'],windowsHide:true});
  let buffer='',nextId=0,stderr='';
  const pending=new Map();
  child.stderr.on('data',data=>{stderr=(stderr+data).slice(-8000)});
  child.stdout.on('data',data=>{
    buffer+=data.toString('utf8');
    let end;
    while((end=buffer.indexOf('\n'))>=0){
      const line=buffer.slice(0,end);buffer=buffer.slice(end+1);
      let message;try{message=JSON.parse(line)}catch{continue}
      const p=pending.get(message.id);
      if(p){pending.delete(message.id);clearTimeout(p.timer);p.resolve(message)}
    }
  });
  child.on('exit',code=>{for(const p of pending.values()){clearTimeout(p.timer);p.reject(new Error(`MCP exited ${code}: ${stderr}`))}pending.clear()});
  function request(method,params){return new Promise((resolve,reject)=>{
    const id=++nextId;
    const timer=setTimeout(()=>{pending.delete(id);reject(new Error(`MCP timeout: ${method}; ${stderr}`))},60000);
    pending.set(id,{resolve,reject,timer});
    child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');
  })}
  return {
    async init(){await request('initialize',{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'vanessa-enterprise-check',version:'1'}})},
    async list(){return (await request('tools/list',{})).result.tools},
    async tool(name,args,expectError=false){
      const result=(await request('tools/call',{name,arguments:args})).result;
      evidence.push({name,args,result});
      writeFileSync(path.join(directory,'evidence.json'),JSON.stringify(evidence,null,2));
      assert.equal(Boolean(result.isError),expectError,JSON.stringify(result));
      if(result.structuredContent)return result.structuredContent; try{return JSON.parse(result.content[0].text)}catch{return result.content[0].text}
    },
    close(){child.stdin.end()}
  }
}
const first=client();let second;let runId;
try{
  await first.init();
  const names=(await first.list()).map(t=>t.name);
  for(const name of ['infobase_init','run_enterprise','enterprise_status','enterprise_stop'])assert(names.includes(name),name);
  await first.tool('enterprise_stop',{runId:'not-a-run'},true);
  await first.tool('run_enterprise',{ibpath:'relative',v8version:version},true);
  await first.tool('enterprise_status',{runId:'foreign',pid:12345},true);
  // The generic CLI adapter returns text for init, so use a tolerant result decoder below.
  await first.tool('infobase_init',{ibconnection:'/F"'+base+'"',v8version:version,settings,background:false,nocache:true});
  assert(existsSync(path.join(base,'1Cv8.1CD')),'base not created');
  const opened=await first.tool('run_enterprise',{ibpath:base,v8version:version});
  runId=opened.runId;assert(runId,'missing runId');
  let status=opened;
  for(let i=0;i<5&&!status.windowVisible;i++){await new Promise(r=>setTimeout(r,1000));status=await first.tool('enterprise_status',{runId})}
  assert.equal(status.state,'running');assert.equal(status.windowVisible,true,JSON.stringify(status));
  second=client();await second.init();const recovered=await second.tool('enterprise_status',{runId});assert.equal(recovered.runId,runId);second.close();second=null;
  await first.tool('enterprise_stop',{runId,timeoutSeconds:31},true);
  const closed=await first.tool('enterprise_stop',{runId,timeoutSeconds:10});
  assert.equal(closed.state,'exited',JSON.stringify(closed));assert.equal(closed.exitCode,0);
  const repeated=await first.tool('enterprise_stop',{runId});assert.equal(repeated.state,'exited');
  const finished=await first.tool('enterprise_status',{runId});assert.equal(finished.exitCode,0);
  console.log(JSON.stringify({success:true,directory,toolCount:names.length,runId,pid:status.pid,windowTitle:status.windowTitle,exitCode:finished.exitCode},null,2));
}catch(error){
  console.error(error.stack);
  if(runId){try{console.error('cleanup',await first.tool('enterprise_stop',{runId,timeoutSeconds:10}))}catch(cleanup){console.error(String(cleanup))}}
  console.error('Evidence:',directory);process.exitCode=1;
}finally{second?.close();first.close()}
