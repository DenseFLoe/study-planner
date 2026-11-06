import { build } from 'esbuild';
await build({
  entryPoints: ['helper.mjs', 'assistant-helper.mjs'], outdir: 'out', outExtension: { '.js': '.cjs' }, bundle: true,
  platform: 'node', target: 'node26', format: 'cjs', sourcemap: false,
  legalComments: 'linked', logLevel: 'info',
});
