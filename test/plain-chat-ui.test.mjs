import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
const html=readFileSync(new URL('../public/index.html',import.meta.url),'utf8');
const client=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const pause=ms=>new Promise(r=>setTimeout(r,ms));

test('without translation, typing and plain WhatsApp sending are available',async()=>{
  const dom=new JSDOM(html,{url:'https://wa.example.test/',runScripts:'dangerously',pretendToBeVisual:true});
  const w=dom.window;
  const calls=[];
  const chat={jid:'100@lid',title:'A',enabled:false,targetLanguage:'English',lastActivity:1};
  const ok=(value)=>({ok:true,status:200,json:async()=>value});
  w.EventSource=class{close(){}};
  Object.defineProperty(w.crypto,'randomUUID',{value:()=> 'a'.repeat(8)+'-1111-4111-8111-'+'b'.repeat(12),configurable:true});
  w.fetch=async (url,opt)=>{
    const path=String(url); calls.push({path,opt});
    if(path==='/api/status')return ok({connection:'connected',qr:null,groqConfigured:true});
    if(path==='/api/chats')return ok([chat]);
    if(path.includes('/messages'))return ok([]);
    if(path.endsWith('/send'))return ok({ok:true,translated:null});
    if(path==='/api/events')return ok({});
    throw Error('Unexpected '+path);
  };
  try{
    w.eval(client);await pause(80);
    w.document.querySelector('#chat-list .chat-item').click();await pause(40);
    const input=w.document.getElementById('draft');
    const button=w.document.getElementById('send');
    assert.equal(w.document.getElementById('enable-chat').checked,false);
    assert.equal(input.disabled,false);
    input.value='Отправить без перевода';
    input.dispatchEvent(new w.Event('input',{bubbles:true}));
    assert.equal(button.disabled,false);
    assert.match(button.textContent,/без перевода/);
    w.document.getElementById('compose').dispatchEvent(new w.Event('submit',{bubbles:true,cancelable:true}));
    await pause(80);
    const sent=calls.filter(x=>x.path.endsWith('/send'));
    assert.equal(sent.length,1);
    assert.equal(JSON.parse(sent[0].opt.body).text,'Отправить без перевода');
    assert.equal(input.value,'');
  }finally{dom.window.close();}
});
