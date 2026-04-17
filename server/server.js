import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { Configuration, PlaidApi, PlaidEnvironments } from 'plaid';
import plaidRoutes from './routes/plaid.js';
import { createWebhookRouter } from './routes/webhooks.js';
import { requireAppToken } from './middleware/auth.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const PORT = process.env.PORT || 8080;

app.use(cors());

// Capture raw body for webhook signature verification
// express.json with verify hook runs before body parsing, preserving the raw bytes
app.use(express.json({
  verify: (req, _res, buf) => {
    req.rawBody = buf.toString('utf8');
  },
}));

app.use(express.static(join(__dirname, 'public')));

// Shared Plaid API client
const plaidClient = new PlaidApi(
  new Configuration({
    basePath: PlaidEnvironments[process.env.PLAID_ENV || 'sandbox'],
    baseOptions: {
      headers: {
        'PLAID-CLIENT-ID': process.env.PLAID_CLIENT_ID,
        'PLAID-SECRET': process.env.PLAID_SECRET,
        'Plaid-Version': '2020-09-14',
      },
    },
  })
);

// Plaid API routes (app-facing) — protected by bearer token.
// The macOS app sends X-App-Token; other callers get 401.
app.use('/api', requireAppToken, plaidRoutes);

// Webhook receiver (Plaid-facing) — unauthenticated, but each request
// is verified via Plaid JWT signature inside the router.
app.use('/webhook', createWebhookRouter(plaidClient));

// Health check
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', env: process.env.PLAID_ENV || 'sandbox' });
});

app.listen(PORT, () => {
  console.log(`BudgetTracking server running on http://localhost:${PORT}`);
  console.log(`Plaid environment: ${process.env.PLAID_ENV || 'sandbox'}`);
  console.log(`Webhook receiver: POST /webhook`);
});
