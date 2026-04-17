/**
 * Bearer-token middleware for the app-facing /api/* endpoints.
 *
 * The macOS app and the server share a secret (APP_AUTH_TOKEN) and the
 * app sends it on every request as `X-App-Token`. This blocks random
 * callers hitting the public ngrok URL — only our app can reach /api/*.
 *
 * /webhook stays public (Plaid does not know this token, and the
 * webhook router already verifies Plaid JWT signatures).
 *
 * If APP_AUTH_TOKEN is unset, the middleware logs a warning once and
 * allows all requests through. This keeps the default-dev path simple.
 */

let warned = false;

export function requireAppToken(req, res, next) {
  const expected = process.env.APP_AUTH_TOKEN;

  if (!expected) {
    if (!warned) {
      console.warn(
        '[auth] APP_AUTH_TOKEN not set — /api endpoints are UNAUTHENTICATED. ' +
          'Set APP_AUTH_TOKEN in .env to enable bearer-token auth.'
      );
      warned = true;
    }
    return next();
  }

  const provided = req.headers['x-app-token'];
  if (!provided || !constantTimeEqual(provided, expected)) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

// Constant-time string comparison to prevent timing attacks.
function constantTimeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}
