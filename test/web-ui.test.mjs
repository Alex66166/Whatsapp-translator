import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const html=readFileSync(new URL('../public/index.html', import.meta.url),'utf8');
const script=readFileSync(new URL('../public/app.js', import.meta.url),'utf8');
const pause=ms=>new Promise(r=>setTimeout(r,ms));

test('Web UI discovers chats dynamically, switches contacts, and keeps recipient language', async () => {
  const dom=new JSDOM(html,{url:'https://wa.example.test/',runScripts:'dangerously',pretendToBeVisual:true});
  const w=dom.window;
  const chats=[
    {jid:'1@s.whatsapp.net',title:'Даниэла',enabled:true,targetLanguage:'Montenegrin (Latin script, Ijekavian)',lastActivity:1},
    {jid:'2@s.whatsapp.net',title:'Jelena',enabled:true,targetLanguage:'English',lastActivity:2}
  ];
  const calls=[];
  const response=(data,status=200)=>({ok:status<400,status,json:async()=>data});
  w.EventSource=class { close(){} };
  Object.defineProperty(w.crypto,'randomUUID',{value:()=> '00000000-0000-4000-8000-000000000001',configurable:true});
  w.fetch=async (url,opts)=>{
    const endpoint=String(url);
    calls.push({endpoint,opts});
    if (endpoint==='/api/status') return response({connection:'connected',qr:null,groqConfigured:true});
    if (endpoint==='/api/chats') return response(chats);
    if (endpoint.includes('/messages')) return response([]);
    if (endpoint.endsWith('/send')) return response({ok:true,translated:'Hvala vam'});
    if (endpoint==='/api/events') return response({});
    throw new Error('Unexpected URL '+endpoint);
  };
  try {
    w.eval(script);
    await pause(60);
    assert.equal(w.document.getElementById('login').hidden,true);
    const list=w.document.querySelectorAll('#chat-list .chat-item');
    assert.equal(list.length,2);
    assert.match(list[0].textContent,/Даниэла/);
    list[1].click();
    await pause(50);
    assert.equal(w.document.getElementById('chat-name').textContent,'Jelena');
    assert.equal(w.document.getElementById('target-language').value,'English');
    list[0].click();
    await pause(50);
    assert.equal(w.document.getElementById('chat-name').textContent,'Даниэла');
    const input=w.document.getElementById('draft');
    input.value='Спасибо за документы!';
    input.dispatchEvent(new w.Event('input',{bubbles:true}));
    w.document.getElementById('compose').dispatchEvent(new w.Event('submit',{bubbles:true,cancelable:true}));
    await pause(50);
    const outgoing=calls.filter(c=>c.endpoint.endsWith('/send'));
    assert.equal(outgoing.length,1);
    assert.equal(outgoing[0].endpoint,'/api/chats/'+encodeURIComponent('1@s.whatsapp.net')+'/send');
    assert.equal(JSON.parse(outgoing[0].opts.body).text,'Спасибо за документы!');
    // Mobile layout has a single-column chat mode and optional back button.
    assert.match(readFileSync(new URL('../public/style.css',import.meta.url),'utf8'),/@media\(max-width:700px\)/);
    assert.ok(w.document.getElementById('mobile-back'));
  } finally {
    dom.window.close();
  }
});
