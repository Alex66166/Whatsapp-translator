// VCF v3/v4 contacts exported by Android/Google Contacts.
// Import is local to this VPS; no contacts are sent to an external service.
function unfold(vcf) {
  return vcf.replace(/\r\n?/g, '\n').replace(/\n[ \t]/g, '');
}
function unescapeValue(v) {
  return v.replace(/\\n/gi, ' ').replace(/\\([,;\\])/g, '$1').trim();
}
export function parseVcard(vcf) {
  if (typeof vcf !== 'string' || Buffer.byteLength(vcf, 'utf8') > 2 * 1024 * 1024)
    throw new Error('VCF не должен превышать 2 МБ');
  const result = new Map();
  for (const rawCard of unfold(vcf).split(/BEGIN:VCARD\s*\n/i).slice(1)) {
    const card = rawCard.split(/\nEND:VCARD/i)[0];
    const lines = card.split('\n');
    const fn = lines.find(l => /^FN(?:;[^:]*)?:/i.test(l));
    const name = unescapeValue(fn?.split(/:(.*)/s)[1] || '') || 'Без имени';
    for (const line of lines) {
      if (!/^TEL(?:;[^:]*)?:/i.test(line)) continue;
      const val = line.split(/:(.*)/s)[1] || '';
      let number = val.replace(/^tel:/i, '').replace(/[^0-9]/g, '');
      if (!/^[1-9][0-9]{6,14}$/.test(number)) continue;
      if (!result.has(number)) result.set(number, name.slice(0, 160));
      if (result.size > 10000) throw new Error('Максимум 10 000 контактов в одном импорте');
    }
  }
  return [...result].map(([phone, name]) => ({ phone, name }));
}
