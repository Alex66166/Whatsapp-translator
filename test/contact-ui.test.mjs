import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const html=readFileSync(new URL('../public/index.html',import.meta.url),'utf8');
const client=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));

test('remove one contact and clear all from browser UI',async()=>{
  const dom=new JSDOM(html,{url:'https://wa.example.test/',runScripts:'dangerously',pretendToBeVisual:true});
  const w=dom.window;
  let chats=[
    {jid:'1@s.whatsapp.net',title:'First',enabled:true,targetLanguage:'English',lastActivity:10},
    {jid:'2@s.whatsapp.net',title:'Second',enabled:true,targetLanguage:'Montenegrin (Latin script, Ijekavian)',lastActivity:9}
  ];
  const calls=[];
  w.EventSource=class{close(){}};
  w.confirm=()=>true;
  w.prompt=()=> 'СБРОС';
  const reply=value=>({ok:true,status:200,json:async()=>value});
  w.fetch=async (url,options={})=>{
    const path=String(url),method=options.method||'GET';
    calls.push({path,method,body:options.body});
    if(path==='/api/status')return reply({connection:'connected',qr:null,groqConfigured:true});
    if(path==='/api/chats')return reply(chats);
    if(path.endsWith('/messages'))return reply([]);
    if(path==='/api/contacts/'+encodeURIComponent('1@s.whatsapp.net') && method==='DELETE'){
      chats=chats.filter(c=>c.jid!=='1@s.whatsapp.net');
      return reply({ok:true});
    }
    if(path==='/api/contacts/reset' && method==='POST'){
      assert.equal(JSON.parse(options.body).confirm,'RESET');
      chats=[];
      return reply({ok:true});
    }
    throw Error('Unexpected request '+method+' '+path);
  };
  try{
    w.eval(client);await pause(80);
    assert.equal(w.document.querySelectorAll('#chat-list .chat-item').length,2);
    w.document.querySelector('#chat-list .chat-item').click();
    await pause(30);
    w.document.getElementById('remove-contact').click();
    await pause(80);
    assert.equal(chats.length,1);
    assert.equal(w.document.querySelectorAll('#chat-list .chat-item').length,1);
    w.document.getElementById('clear-contacts').click();
    await pause(80);
    assert.equal(chats.length,0);
    assert.equal(w.document.querySelectorAll('#chat-list .chat-item').length,0);
    assert.ok(calls.some(c=>c.method==='DELETE'));
    assert.ok(calls.some(c=>c.path==='/api/contacts/reset'));
  }finally{dom.window.close();}
});
