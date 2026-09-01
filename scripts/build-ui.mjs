import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { mkdir } from 'node:fs/promises';
import { build } from 'esbuild';

const require = createRequire(import.meta.url);
const hondoRoot = dirname(require.resolve('hondo/package.json'));

await mkdir('src/generated', { recursive: true });
await build({
  entryPoints: ['ui/src/bundle.ts'],
  outfile: 'src/generated/zim_ui.js',
  bundle: true,
  platform: 'neutral',
  format: 'iife',
  target: 'es2020',
  conditions: ['browser'],
  alias: {
    '@hondo/core': join(hondoRoot, 'packages/core/src/index.ts'),
    '@hondo/solid': join(hondoRoot, 'packages/solid/src/index.ts'),
  },
  logLevel: 'info',
});
