import test from 'node:test';
import assert from 'node:assert/strict';
import { translate } from '../lib/translate.mjs';

test('requires an API key', async () => {
  const old = process.env.GROQ_API_KEY;
  delete process.env.GROQ_API_KEY;
  await assert.rejects(translate('Привет', 'Russian', 'Montenegrin'), /key is not configured/);
  if (old) process.env.GROQ_API_KEY = old;
});

test('rejects empty and excessive input without network access', async () => {
  const old = process.env.GROQ_API_KEY;
  process.env.GROQ_API_KEY = 'test_dummy_key';
  await assert.rejects(translate('   ', 'Russian', 'Montenegrin'), /Invalid text length/);
  await assert.rejects(translate('A'.repeat(4001), 'Russian', 'Montenegrin'), /Invalid text length/);
  if (old) process.env.GROQ_API_KEY = old; else delete process.env.GROQ_API_KEY;
});
