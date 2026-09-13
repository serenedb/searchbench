// Initialise the shared data module before ProductApp evaluates dataset.ts.
// Only the standalone entry imports JSON; the playground injects its own rows.
import rows from '../results.json';
import { provideResults } from './entities/results/model/source';

provideResults(rows);
