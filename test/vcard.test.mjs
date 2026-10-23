import test from 'node:test';
import assert from 'node:assert/strict';
import { parseVcard } from '../lib/vcard.mjs';

test('Android VCF imports contact names with several international phones', () => {
  const list=parseVcard([
    'BEGIN:VCARD','VERSION:3.0','FN:Danijela Rakonjac','TEL;TYPE=CELL:+382 67 123456',
    'TEL;TYPE=WORK:+382 (20) 123-456','END:VCARD',
    'BEGIN:VCARD','FN:Jelena Petrović','TEL;TYPE=CELL:+381641112233','END:VCARD',
    'BEGIN:VCARD','FN:Ignore local','TEL:123','END:VCARD'
  ].join('\r\n'));
  assert.deepEqual(list,[
    {phone:'38267123456',name:'Danijela Rakonjac'},
    {phone:'38220123456',name:'Danijela Rakonjac'},
    {phone:'381641112233',name:'Jelena Petrović'}
  ]);
});
test('VCF rejects files exceeding maximum size and tolerates folded lines', () => {
  assert.throws(()=>parseVcard('X'.repeat(2*1024*1024+1)),/2 МБ/);
  assert.equal(parseVcard('BEGIN:VCARD\nFN:Montenegrin\n contact\nTEL:+38267123456\nEND:VCARD')[0].name,'Montenegrincontact');
});
