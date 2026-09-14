import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  root: fileURLToPath(new URL('.', import.meta.url)),
  base: './',
  plugins: [
    react(),
    tailwindcss(),
    {
      name: 'standalone-dev-entry',
      configureServer(server) {
        // index.html is the committed build; development always uses source.
        server.middlewares.use((req, _res, next) => {
          req.url = req.url?.replace(/^\/(?:index\.html)?(?=\?|$)/, '/dev.html');
          next();
        });
      },
    },
  ],
  build: {
    outDir: '.build',
    cssCodeSplit: false,
    lib: {
      entry: fileURLToPath(new URL('src/standalone.tsx', import.meta.url)),
      name: 'SearchBench',
      formats: ['iife'],
      fileName: () => 'searchbench.js',
    },
    rollupOptions: { output: { inlineDynamicImports: true } },
  },
});
