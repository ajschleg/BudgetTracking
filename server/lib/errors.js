/**
 * Error helpers that keep internal details server-side.
 *
 * Plaid responses sometimes contain data we do not want to send back
 * to the client (rate-limit caller info, full error stacks, specific
 * access-token-related messages). These helpers log the full context
 * to the server console and return a short generic message suitable
 * for the client.
 */

/**
 * Log the full error server-side and return a short message safe to
 * send to the client. Never leaks the stack or internal Plaid
 * specifics. Callers use the returned string as the response body.
 *
 * @param {string} scope     Logical area, e.g. "link/create", used in logs
 * @param {unknown} error    The caught error
 * @param {string} [fallback] Client-facing message
 */
export function logAndSanitize(scope, error, fallback = 'An error occurred') {
  const plaidError = error?.response?.data;
  if (plaidError) {
    console.error(`[${scope}] Plaid error:`, plaidError);
  } else {
    console.error(`[${scope}]`, error?.message || error);
  }
  // A few Plaid error codes are safe to surface — they are user-actionable
  // ("Your bank needs re-auth", "Invalid institution") rather than internal.
  const userActionableCodes = new Set([
    'ITEM_LOGIN_REQUIRED',
    'INSTITUTION_DOWN',
    'INSTITUTION_NOT_RESPONDING',
    'RATE_LIMIT_EXCEEDED',
    'PRODUCT_NOT_READY',
  ]);
  if (plaidError?.error_code && userActionableCodes.has(plaidError.error_code)) {
    return plaidError.display_message || plaidError.error_message || fallback;
  }
  return fallback;
}
