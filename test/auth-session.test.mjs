import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { retireLinkedAuth } from '../lib/auth-session.mjs';

test('WhatsApp relink preserves old credentials but releases auth directory for QR pairing',()=>{
  const dir=mkdtempSync(path.join(tmpdir(),'wa-auth-test-'));
  try{
    mkdirSync(path.join(dir,'auth'),{mode:0o700});
    writeFileSync(path.join(dir,'auth','creds.json'), '{"important":"session"}');
    const rotated=retireLinkedAuth(dir,new Date('2026-10-22T20:00:00.000Z'));
    assert.equal(existsSync(path.join(dir,'auth')),false);
    assert.equal(readFileSync(path.join(rotated,'creds.json'),'utf8'),'{"important":"session"}');
    assert.equal(retireLinkedAuth(dir),null);
  }finally{rmSync(dir,{recursive:true,force:true});}
});
