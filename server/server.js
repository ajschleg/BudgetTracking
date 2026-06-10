import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { Configuration, PlaidApi, PlaidEnvironments } from 'plaid';
import rateLimit from 'express-rate-limit';
import plaidRoutes, { runFullIngest } from './routes/plaid.js';
import transactionsRoutes from './routes/transactions.js';
import { createWebhookRouter } from './routes/webhooks.js';
import { requireAppToken } from './middleware/auth.js';
import { logAndSanitize } from './lib/errors.js';
import { runBackupIfDue } from './lib/backup.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const PORT = process.env.PORT || 8080;

app.use(cors());

// Capture raw body for webhook signature verification
// express.json with verify hook runs before body parsing, preserving the raw bytes.
// 1mb limit (up from the 100kb default) so 250-row transaction batches —
// the seed/import path — fit comfortably while still bounding abuse.
app.use(express.json({
  limit: '1mb',
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

// Rate limits. Small-ish windows aimed at catching flooders on public
// (ngrok) URLs while staying well above any legitimate app use.
//   /api/*:    60 req / min / IP — the app does maybe 10/min peak
//   /webhook:  300 req / min / IP — Plaid can burst on reconnects
// Auth failures still count toward the limit so a bad actor can't
// spam guesses cheaply.
const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 60,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests' },
});
const webhookLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 300,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many requests' },
});

// Plaid API routes (app-facing) — protected by bearer token + rate limit.
// The macOS app sends X-App-Token; other callers get 401.
app.use('/api', apiLimiter, requireAppToken, plaidRoutes);

// Transaction store routes (app-facing) — same auth + rate limit. Mounted
// AFTER plaidRoutes so its /transactions/sync and /transactions/status
// keep matching first; the store router's :id routes are UUID-guarded.
app.use('/api', apiLimiter, requireAppToken, transactionsRoutes);

// Webhook receiver (Plaid-facing) — unauthenticated at the HTTP layer,
// but each request is verified via Plaid JWT signature inside the
// router. Rate-limited so a malicious prober can't burn CPU on
// signature verification forever.
app.use('/webhook', webhookLimiter, createWebhookRouter(plaidClient));

// Health check
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', env: process.env.PLAID_ENV || 'sandbox' });
});

app.listen(PORT, () => {
  console.log(`BudgetTracking server running on http://localhost:${PORT}`);
  console.log(`Plaid environment: ${process.env.PLAID_ENV || 'sandbox'}`);
  console.log(`Webhook receiver: POST /webhook`);
});

// Auto-ingest. The production deployment is tailnet-only, so Plaid's
// webhooks can never reach it — this timer is what actually drives
// ingestion into the transactions store; transactions accumulate even
// while every client device is asleep. Plaid bills /transactions/sync
// per subscribed item, not per call, so a polling cadence costs nothing
// extra. Set AUTO_SYNC_INTERVAL_MINUTES=0 to disable.
const autoSyncRaw = process.env.AUTO_SYNC_INTERVAL_MINUTES;
const autoSyncMinutes = autoSyncRaw == null ? 360 : Number.parseInt(autoSyncRaw, 10);
if (Number.isInteger(autoSyncMinutes) && autoSyncMinutes > 0) {
  const run = (trigger) =>
    runFullIngest(trigger).catch((error) => {
      logAndSanitize(`auto-ingest:${trigger}`, error);
    });
  setTimeout(() => run('boot'), 60 * 1000);
  setInterval(() => run('timer'), autoSyncMinutes * 60 * 1000);
  console.log(`Auto-ingest: every ${autoSyncMinutes} min (first run ~60s after boot)`);
} else {
  console.log('Auto-ingest: disabled');
}

// Nightly DB backup — hourly check, fires once per UTC day. The store
// is now the one copy of the books that matters; see lib/backup.js.
const backup = () =>
  runBackupIfDue().catch((error) => {
    logAndSanitize('backup', error);
  });
backup();
setInterval(backup, 60 * 60 * 1000);
