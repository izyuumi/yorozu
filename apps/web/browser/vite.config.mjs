import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

const dir = (name) => fileURLToPath(new URL(name, import.meta.url));
export default defineConfig({
  resolve: { dedupe: ['react', 'react-dom', 'jsqr', 'qrcode-generator'] },
  optimizeDeps: { include: ['react', 'react/jsx-dev-runtime', 'react-dom/client', 'react-dom', 'jsqr', 'qrcode-generator'] },
  esbuild: { jsx: 'automatic' },
  server: { fs: { allow: [dir('./'), dir('../../windows/app/src/components/shared/')] } },
});
