import { defineConfig } from 'vitest/config';

const clientConditions = ['browser', 'development'];

export default defineConfig({
  resolve: {
    conditions: clientConditions,
  },
  ssr: {
    resolve: {
      conditions: clientConditions,
    },
    noExternal: [/solid-js/, /@solidjs\//],
  },
  test: {
    environment: 'node',
    server: {
      deps: {
        inline: [/solid-js/, /@solidjs\//],
      },
    },
  },
});
