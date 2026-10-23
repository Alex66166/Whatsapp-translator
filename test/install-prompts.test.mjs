import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = name => readFileSync(new URL('../' + name, import.meta.url), 'utf8');

test('one-command bootstrap completes and saves audit without offering report display', () => {
  const script=read('bootstrap.sh');
  assert.match(script, /bash "\$WORK\/project\/audit\.sh" > "\$REPORT"/);
  assert.match(script, /Отчёт сохранён:/);
  assert.doesNotMatch(script, /Показать полный отчёт\?/);
  assert.doesNotMatch(script, /less "\$REPORT"/);
});

test('deploy accepts a completed audit without AUDIT-APPROVED and retains final INSTALL gate', () => {
  const script=read('deploy.sh');
  assert.match(script, /AUDIT="\$\{WA_AUDIT_REPORT:-\}"/);
  assert.match(script, /АУДИТ ЗАВЕРШЁН:/);
  assert.doesNotMatch(script, /AUDIT-APPROVED/);
  assert.match(script, /read -rp "Для применения наберите INSTALL:/);
});

test('web password has a six-character minimum and no additional complexity rules', () => {
  const script=read('deploy.sh');
  assert.match(script, /read -rsp "Пароль веб-интерфейса \(не менее 6 символов\)/);
  assert.match(script, /\$\{#PASSWORD\}" -ge 6/);
  assert.doesNotMatch(script, /не менее 12 символов/);
});

test('HTTPS external port is a separate installer choice from local Node port', () => {
  const deploy=read('deploy.sh');
  const bootstrap=read('bootstrap.sh');
  assert.match(deploy, /ask EXTERNAL_PORT "Внешний порт HTTPS/);
  assert.match(deploy, /listen \$EXTERNAL_PORT ssl;/);
  assert.match(deploy, /Внешний и внутренний порты должны различаться/);
  assert.match(bootstrap, /WA_REC_EXTERNAL_PORT/);
});

test('Groq key uses visible interactive terminal read, retaining key validation', () => {
  const script=read('deploy.sh');
  assert.match(script, /read -rp "Вставьте ключ Groq \(ввод виден на экране, gsk_\.\.\.\): " GROQ/);
  assert.doesNotMatch(script, /read -rsp "[^"]*Groq/);
  assert.match(script, /\[\[ "\$GROQ" =~ \^gsk_/);
  assert.match(script, /unset PASSWORD GROQ HASH SALT/);
});
