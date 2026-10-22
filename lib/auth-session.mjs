import { existsSync, renameSync } from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';

/**
 * Retire credentials only after WhatsApp has explicitly reported a logout
 * and the administrator has confirmed re-linking. Never delete credentials
 * automatically on ordinary transport/network errors.
 */
export function retireLinkedAuth(dataDir, now=new Date()) {
  const current=path.join(dataDir,'auth');
  if(!existsSync(current))return null;
  const timestamp=now.toISOString().replace(/[:.]/g,'-');
  const destination=path.join(dataDir,'auth-retired-'+timestamp+'-'+randomBytes(4).toString('hex'));
  renameSync(current,destination);
  return destination;
}
