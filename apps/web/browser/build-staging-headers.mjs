import { readFile, writeFile } from 'node:fs/promises';

const headers = new URL('dist/_headers', import.meta.url);
const config = await readFile(headers, 'utf8');
const productionRelay = 'connect-src wss://relay.yumi.to;';
if (config.split(productionRelay).length !== 2) throw new Error('Expected exactly one production relay policy');
await writeFile(headers, config.replace(productionRelay, 'connect-src wss://yorozu-browser-test-relay.yumi-f4f.workers.dev;'));
