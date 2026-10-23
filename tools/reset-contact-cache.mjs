import { config } from 'dotenv';
import Database from 'better-sqlite3';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { resetContactCache } from '../lib/contact-cache.mjs';

const app=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
config({ path: path.join(app,'.env'), quiet: true });
const data=path.resolve(app,process.env.DATA_DIR || '.data');
const file=path.join(data,'messages.sqlite');
if (!existsSync(file)) {
  console.error('SQLite messages database does not exist; no changes made.');
  process.exit(1);
}
let db;
try {
  db=new Database(file,{fileMustExist:true,timeout:10000});
  const results=resetContactCache(db);
  console.log('Контакты сброшены:');
  console.log('  удалено из импортированной адресной книги:',results.book);
  console.log('  очищено имён и отметок активности:',results.anonymized);
  console.log('  удалено записей контактов без истории:',results.removed);
  console.log('  сохранено: WhatsApp-сессия, сообщения, изображения и конфигурация.');
  console.log('  новые контакты будут добавляться из поступивших метаданных WhatsApp.');
} catch(error) {
  console.error('Не удалось очистить контакты:',error.message);
  process.exitCode=1;
} finally {
  db?.close();
}
