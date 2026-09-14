import './standalone-results';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { ThemeProvider } from '@serenedb/ui';
import { ProductApp } from './app/ProductApp';
import './standalone.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider storageKey="sb-theme">
      <ProductApp />
    </ThemeProvider>
  </StrictMode>,
);
