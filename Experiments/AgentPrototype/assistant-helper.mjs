// This process never receives credentials and cannot open network connections.
// All SDK HTTP requests are serialized through Swift's one-shot approval gate.
import { ToolLoopAgent, tool, stepCountIs } from 'ai';
import { createOpenAI } from '@ai-sdk/openai';
import { createAnthropic } from '@ai-sdk/anthropic';
import { z } from 'zod';
import { createInterface } from 'node:readline';
import { connect } from 'node:net';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const pending = new Map();
let sequence = 0, started = false, requests = 0, queries = 0;
const controller = new AbortController();
function rpc(type, value) {
  if (pending.size >= 16) throw new Error('Bridge limit');
  const id = `sdk-${++sequence}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Expired')); }, 180_000);
    pending.set(id, { resolve, reject, timer }); emit({ type, id, ...value });
  });
}
function blocked(operation) {
  try { operation(); return false; } catch (error) { return error.code === 'ERR_ACCESS_DENIED'; }
}
async function run(start) {
  const network = await new Promise(resolve => {
    try {
      const socket = connect({ host: '127.0.0.1', port: 9 });
      socket.once('error', error => { socket.destroy(); resolve(error.code === 'ERR_ACCESS_DENIED'); });
      socket.once('connect', () => { socket.destroy(); resolve(false); });
    } catch (error) { resolve(error.code === 'ERR_ACCESS_DENIED'); }
  });
  const restrictions = {
    network,
    fileRead: blocked(() => readFileSync('/etc/passwd')),
    fileWrite: blocked(() => writeFileSync('/tmp/study-assistant-forbidden-write', 'blocked')),
    subprocess: blocked(() => { const result = spawnSync('/usr/bin/true'); if (result.error) throw result.error; }),
  };
  if (!Object.values(restrictions).every(Boolean)) throw new Error('Restrictions unavailable');
  if (!['openai', 'anthropic'].includes(start.provider)) throw new Error('Unknown protocol');
  emit({ type: 'ready', protocol: 2, node: process.version, restrictions });
  const baseURL = start.baseURL.replace(/\/+$/, '');
  const endpoint = baseURL + (start.provider === 'anthropic' ? '/messages' : '/chat/completions');
  const bridgeFetch = async (input, init) => {
    if (++requests > 8 || String(input) !== endpoint || init?.method !== 'POST' || typeof init.body !== 'string') throw new Error('Request boundary');
    const reply = await rpc('request', { url: String(input), body: init.body });
    if (!reply.approved || typeof reply.body !== 'string') throw new Error('Declined');
    return new Response(reply.body, { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const model = start.provider === 'anthropic'
    ? createAnthropic({ baseURL, apiKey: '', fetch: bridgeFetch })(start.model)
    : createOpenAI({ baseURL, apiKey: '', fetch: bridgeFetch }).chat(start.model);
  const tools = Object.fromEntries(start.tools.map(def => [def.name, tool({
    description: def.description,
    inputSchema: z.object(Object.fromEntries(Object.entries(def.fields).map(([key, description]) => [key, z.string().max(128).describe(description)]))).strict(),
    execute: async input => {
      if (++queries > 24) throw new Error('Query limit');
      const reply = await rpc('tool', { name: def.name, input });
      return JSON.parse(reply.resultJSON);
    },
  })]));
  const agent = new ToolLoopAgent({ model, tools, instructions: start.instructions,
    maxRetries: 0, maxOutputTokens: 4096, stopWhen: stepCountIs(8),
  });
  const result = await agent.generate({ messages: start.messages, abortSignal: controller.signal });
  if (result.finishReason !== 'stop' || !result.text.trim()) throw new Error('Incomplete answer');
  emit({ type: 'done', text: result.text });
}
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
function close() {
  controller.abort();
  for (const value of pending.values()) { clearTimeout(value.timer); value.reject(new Error('Closed')); }
  pending.clear();
}
lines.on('line', line => {
  try {
    if (Buffer.byteLength(line) > 1_048_576) throw new Error('Frame limit');
    const message = JSON.parse(line);
    if (message.type === 'start' && !started) {
      started = true;
      run(message).catch(() => emit({ type: 'failed' })).finally(() => { close(); lines.close(); process.stdin.destroy(); });
    } else if (message.type === 'reply') {
      const value = pending.get(message.id);
      if (!value) throw new Error('Unknown reply');
      pending.delete(message.id); clearTimeout(value.timer); value.resolve(message);
    } else if (message.type === 'cancel') { close(); lines.close(); process.stdin.destroy(); }
    else throw new Error('Unknown frame');
  } catch { emit({ type: 'failed' }); close(); lines.close(); process.stdin.destroy(); }
});
lines.on('close', close);
