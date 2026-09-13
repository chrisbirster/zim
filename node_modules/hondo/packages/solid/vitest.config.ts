import { defineConfig } from 'vitest/config';

const clientConditions = ['browser', 'development'];

export default defineConfig({
  // Hondo is a client-side native terminal runtime. Node is only the test
  // process; resolving Solid's `node` export would select the SSR build, where
  // imperative signal setters are intentionally inert.
  resolve: {
    conditions: clientConditions,
  },
  ssr: {
    // Vitest's Node environment uses Vite's server module runner. Give that
    // resolver Hondo's client conditions too; otherwise it adds `node` and
    // selects solid-js/dist/server.js even though Hondo itself is not SSR.
    resolve: {
      conditions: clientConditions,
    },
    noExternal: [/solid-js/, /@solidjs\//],
  },
  test: {
    environment: 'node',
    server: {
      deps: {
        // node_modules are externalized by Vitest by default. Inline the Solid
        // runtime family so Vite, not Node's native resolver, picks its exports.
        inline: [/solid-js/, /@solidjs\//],
      },
    },
  },
});
