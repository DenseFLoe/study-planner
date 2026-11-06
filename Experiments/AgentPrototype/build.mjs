import { build } from 'esbuild';
await build({
  entryPoints: ['helper.mjs'], outfile: 'out/helper.cjs', bundle: true,
  platform: 'node', target: 'node26', format: 'cjs', sourcemap: false,
  legalComments: 'linked', logLevel: 'info',
});
