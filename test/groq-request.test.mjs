import test from 'node:test';
import assert from 'node:assert/strict';
import { translate } from '../lib/translate.mjs';

test('Groq request includes the exact configured language and low reasoning mode for GPT-OSS', async () => {
  const priorKey=process.env.GROQ_API_KEY;
  const priorModel=process.env.GROQ_MODEL;
  const priorFetch=globalThis.fetch;
  try {
    process.env.GROQ_API_KEY='test_key_only';
    process.env.GROQ_MODEL='openai/gpt-oss-120b';
    let called=false;
    globalThis.fetch=async (url,opts)=>{
      called=true;
      assert.equal(url,'https://api.groq.com/openai/v1/chat/completions');
      assert.equal(opts.headers.Authorization,'Bearer test_key_only');
      const body=JSON.parse(opts.body);
      assert.equal(body.reasoning_effort,'low');
      assert.ok(body.max_completion_tokens>=1500);
      assert.match(body.messages[0].content,/Montenegrin.*Ijekavian/);
      assert.equal(body.messages[1].content,'Пожалуйста, перечислите зарплату');
      return {ok:true,json:async()=>({choices:[{message:{content:'Molim vas, uplatite platu'}}]})};
    };
    const output=await translate('Пожалуйста, перечислите зарплату','Russian','Montenegrin (Latin script, Ijekavian)');
    assert.equal(output,'Molim vas, uplatite platu');
    assert.equal(called,true);
  } finally {
    if (priorKey===undefined) delete process.env.GROQ_API_KEY; else process.env.GROQ_API_KEY=priorKey;
    if (priorModel===undefined) delete process.env.GROQ_MODEL; else process.env.GROQ_MODEL=priorModel;
    globalThis.fetch=priorFetch;
  }
});

test('Groq rate limit produces controlled error without sending untranslated text', async () => {
  const priorKey=process.env.GROQ_API_KEY;
  const priorFetch=globalThis.fetch;
  try {
    process.env.GROQ_API_KEY='test_key_only';
    globalThis.fetch=async()=>({ok:false,status:429});
    await assert.rejects(translate('Привет','Russian','Montenegrin'),/rate limit/);
  } finally {
    if (priorKey===undefined) delete process.env.GROQ_API_KEY; else process.env.GROQ_API_KEY=priorKey;
    globalThis.fetch=priorFetch;
  }
});
