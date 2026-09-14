import { BenchPage } from '../pages/bench/BenchPage';
import './searchbench.css';

/** Shared results page. The host supplies rows and a ThemeProvider; the
 * standalone entry does both when opened outside the playground. */
export function ProductApp() {
  return (
    <div data-product="searchbench">
      <BenchPage />
    </div>
  );
}
