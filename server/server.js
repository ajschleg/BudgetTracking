import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import plaidRoutes from './routes/plaid.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const PORT = process.env.PORT || 8080;

app.use(cors());
app.use(express.json());
app.use(express.static(join(__dirname, 'public')));

// Plaid API routes
app.use('/api', plaidRoutes);

// Health check
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', env: process.env.PLAID_ENV || 'sandbox' });
});

app.listen(PORT, () => {
  console.log(`BudgetTracking server running on http://localhost:${PORT}`);
  console.log(`Plaid environment: ${process.env.PLAID_ENV || 'sandbox'}`);
});
