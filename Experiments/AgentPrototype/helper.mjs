// Only the SDK's serializers and tool loop are exercised. No real model transport exists.
import { ToolLoopAgent, tool, stepCountIs } from 'ai';
import { createOpenAI } from '@ai-sdk/openai';
import { createAnthropic } from '@ai-sdk/anthropic';
import { z } from 'zod';
import { createInterface } from 'node:readline';
import { connect } from 'node:net';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const waiting = new Map();
let sequence = 0;
let started = false;
const controller = new AbortController();

function rpc(type, value) {
  if (waiting.size >= 4) throw new Error('Bridge request limit');
  const id = `bridge-${++sequence}`;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      waiting.delete(id); reject(new Error('Local approval or tool timed out'));
    }, 120_000);
    waiting.set(id, { resolve, reject, timeout });
    emit({ type, id, ...value });
  });
}

function permissionCheck(operation) {
  try { operation(); return false; }
  catch (error) { return error.code === 'ERR_ACCESS_DENIED'; }
}

async function run(provider) {
  if (!['openai', 'anthropic'].includes(provider)) throw new Error('Unknown synthetic protocol');
  const networkBlocked = await new Promise(resolve => {
    try {
      const socket = connect({ host: '127.0.0.1', port: 9 });
      socket.once('error', error => { socket.destroy(); resolve(error.code === 'ERR_ACCESS_DENIED'); });
      socket.once('connect', () => { socket.destroy(); resolve(false); });
    } catch (error) { resolve(error.code === 'ERR_ACCESS_DENIED'); }
  });
  const restrictions = {
    network: networkBlocked,
    fileRead: permissionCheck(() => readFileSync('/etc/passwd')),
    fileWrite: permissionCheck(() => writeFileSync('/tmp/study-agent-forbidden-write', 'blocked')),
    subprocess: permissionCheck(() => { const result = spawnSync('/usr/bin/true'); if (result.error) throw result.error; }),
  };
  if (!Object.values(restrictions).every(Boolean)) throw new Error('Required runtime restrictions are missing');
  emit({ type: 'ready', protocol: 1, restrictions, provider, node: process.version });

  const bridgeFetch = async (input, init) => {
    const url = String(input);
    if (!url.startsWith('https://synthetic-provider.invalid/')) throw new Error('Non-synthetic destination');
    if (typeof init?.body !== 'string') throw new Error('Only inspectable JSON requests are supported');
    const response = await rpc('request', {
      provider, url, method: init.method,
      headers: Object.fromEntries(new Headers(init.headers)), body: init.body,
    });
    if (!response.approved) throw new Error('User declined synthetic request');
    return new Response(response.body, { status: 200, headers: { 'content-type': 'application/json' } });
  };
  // Empty keys are deliberate: these adapters only serialize requests into the local bridge.
  const model = provider === 'openai'
    ? createOpenAI({ baseURL: 'https://synthetic-provider.invalid/v1', apiKey: '', fetch: bridgeFetch }).chat('synthetic-chat')
    : createAnthropic({ baseURL: 'https://synthetic-provider.invalid/v1', apiKey: '', fetch: bridgeFetch })('synthetic-chat');
  const localTool = (name, description) => tool({
    description, inputSchema: z.object({ date: z.literal('2026-09-14') }).strict(),
    execute: async input => (await rpc('tool', { name, input })).result,
  });
  const agent = new ToolLoopAgent({
    model, maxRetries: 0, stopWhen: stepCountIs(4),
    instructions: '合成数据验证。先查课表，再查冲突。所有数字必须来自工具证据；不得修改课表。',
    tools: {
      query_schedule: localTool('query_schedule', '查询合成课表；返回本机证据'),
      diagnose_conflict: localTool('diagnose_conflict', '核验合成课表的休息冲突'),
    },
  });
  const result = await agent.generate({ prompt: '为什么合成课程 A 的两节课排不进两小时？', abortSignal: controller.signal });
  emit({ type: 'done', text: result.text, steps: result.steps.length });
}

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on('line', line => {
  try {
    if (Buffer.byteLength(line) > 1_048_576) throw new Error('Oversized bridge frame');
    const message = JSON.parse(line);
    if (message.type === 'start' && !started) {
      started = true;
      run(message.provider).catch(() => emit({ type: 'failed', message: '验证已停止：审批被拒绝、通信中断或模拟协议错误。' }))
        .finally(() => { lines.close(); process.stdin.destroy(); });
    } else if (message.type === 'reply') {
      const request = waiting.get(message.id);
      if (!request) throw new Error('Unknown bridge reply');
      clearTimeout(request.timeout); waiting.delete(message.id); request.resolve(message);
    } else if (message.type === 'cancel') {
      controller.abort();
      for (const entry of waiting.values()) { clearTimeout(entry.timeout); entry.reject(new Error('Cancelled')); }
      waiting.clear();
    } else throw new Error('Unexpected bridge message');
  } catch { emit({ type: 'failed', message: '本机通信协议校验失败。' }); process.exitCode = 1; lines.close(); process.stdin.destroy(); }
});
lines.on('close', () => {
  controller.abort();
  for (const entry of waiting.values()) { clearTimeout(entry.timeout); entry.reject(new Error('Bridge closed')); }
  waiting.clear();
});
