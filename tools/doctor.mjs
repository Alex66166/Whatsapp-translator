#!/usr/bin/env node
// Non-destructive diagnostics, safe for a production VPS.
// Must run from the installed app directory with access to its .env.
import 'dotenv/config';
import os from 'node:os';
import { statfsSync, existsSync } from 'node:fs';
import path from 'node:path';
import { translate } from '../lib/translate.mjs';

const dataDir=path.resolve(process.cwd(), process.env.DATA_DIR || '.data');
const port=Number(process.env.PORT || 3080);
const host=process.env.HOST || '127.0.0.1';
let failed=false;
function info(name,value){ console.log(name+': '+value); }
info('ОЗУ всего',Math.round(os.totalmem()/1048576)+' МБ');
info('ОЗУ свободно (оценка)',Math.round(os.freemem()/1048576)+' МБ');
const stats=statfsSync(process.cwd());
const free=Number(stats.bavail)*Number(stats.bsize);
info('Свободный диск',Math.round(free/1048576)+' МБ');
info('Папка данных',existsSync(dataDir)?'существует':'не найдена');
info('Baileys auth',existsSync(path.join(dataDir,'auth'))?'каталог есть, реальную привязку нужно проверить в веб-клиенте':'ещё не привязан');
if (free<1024*1048576){console.error('Недостаточно свободного диска: меньше 1 ГБ');failed=true;}
try{
  const response=await fetch('http://'+host+':'+port+'/health',{signal:AbortSignal.timeout(3000)});
  if(!response.ok)throw Error('HTTP '+response.status);
  info('Локальный HTTP API','работает');
}catch(error){console.error('Локальный HTTP API недоступен: '+error.message);failed=true;}
if(!process.env.GROQ_API_KEY){
  console.error('Groq API ключ отсутствует');
  failed=true;
}else{
  try{
    const output=await translate('Добрый день, документы готовы.','Russian',process.env.DEFAULT_TARGET_LANGUAGE || 'Montenegrin (Latin script, Ijekavian)');
    info('Тест перевода Groq',output.slice(0,200));
    if(output.length<2)throw Error('Пустой перевод');
  }catch(error){
    console.error('Тест Groq не прошёл: '+error.message);
    failed=true;
  }
}
if(failed)process.exitCode=1;
else console.log('Проверка ресурсов, локального API и тестового перевода завершена.');
