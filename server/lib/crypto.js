import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
  scryptSync,
} from 'crypto';
import { existsSync, readFileSync, writeFileSync, chmodSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

/**
 * AES-256-GCM helper for access-token at-rest encryption.
 *
 * Security model:
 *   - The access_token is the sensitive value Plaid gives us in exchange
 *     for a public_token. Anyone with it can read the user's bank data
 *     until /item/remove is called, so FileVault alone is not enough if
 *     the plaid.db file is ever copied off the box.
 *   - We derive a 32-byte key from ENCRYPTION_KEY (hex) in the env, or
 *     generate a random one on first run and persist it to
 *     .encryption-key with 0600 perms. Either way, the key lives OUTSIDE
 *     the database file.
 *   - Each encrypted value is stored as base64(iv || ciphertext || tag),
 *     where iv is 12 bytes (GCM standard). The auth tag makes any
 *     tampering detectable — decryption throws if the blob was modified.
 */

const ALGO = 'aes-256-gcm';
const IV_LEN = 12;
const KEY_LEN = 32;
const TAG_LEN = 16;

function loadOrCreateKey() {
  if (process.env.ENCRYPTION_KEY) {
    // Use the env-provided hex key as-is if it is 32 bytes (64 hex chars).
    const buf = Buffer.from(process.env.ENCRYPTION_KEY, 'hex');
    if (buf.length === KEY_LEN) return buf;
    // Otherwise stretch it via scrypt so any passphrase works.
    return scryptSync(process.env.ENCRYPTION_KEY, 'budget-tracking-v1', KEY_LEN);
  }

  // Fallback: persist a random key next to the server directory. Good
  // enough for single-user local dev; operators running in production
  // should set ENCRYPTION_KEY in the env so the key can be rotated or
  // stored in a secret manager.
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const keyPath = join(__dirname, '..', '.encryption-key');
  if (existsSync(keyPath)) {
    const hex = readFileSync(keyPath, 'utf8').trim();
    return Buffer.from(hex, 'hex');
  }

  const newKey = randomBytes(KEY_LEN);
  writeFileSync(keyPath, newKey.toString('hex'));
  chmodSync(keyPath, 0o600);
  console.warn(
    '[crypto] Generated new .encryption-key. Back this up; losing it makes\n' +
      '         encrypted access tokens permanently unrecoverable (you would\n' +
      '         need to re-link every bank).'
  );
  return newKey;
}

const KEY = loadOrCreateKey();

/**
 * Encrypt a string. Returns a base64 blob containing iv + ciphertext + tag,
 * prefixed with a version byte so we can rotate schemes later.
 */
export function encrypt(plaintext) {
  if (plaintext == null) return null;
  const iv = randomBytes(IV_LEN);
  const cipher = createCipheriv(ALGO, KEY, iv);
  const ct = Buffer.concat([
    cipher.update(String(plaintext), 'utf8'),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  // Layout: [version=0x01][iv (12)][tag (16)][ciphertext]
  return Buffer.concat([Buffer.from([0x01]), iv, tag, ct]).toString('base64');
}

/**
 * Decrypt a blob produced by encrypt(). Throws on tampering or bad key.
 * Returns the input unchanged if it does not look like a v1 blob, so we
 * can transparently handle legacy plaintext rows during migration.
 */
export function decrypt(blob) {
  if (blob == null) return null;
  try {
    const buf = Buffer.from(blob, 'base64');
    if (buf[0] !== 0x01 || buf.length < 1 + IV_LEN + TAG_LEN) {
      // Not an encrypted blob — treat as legacy plaintext.
      return blob;
    }
    const iv = buf.slice(1, 1 + IV_LEN);
    const tag = buf.slice(1 + IV_LEN, 1 + IV_LEN + TAG_LEN);
    const ct = buf.slice(1 + IV_LEN + TAG_LEN);
    const decipher = createDecipheriv(ALGO, KEY, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ct), decipher.final()]).toString('utf8');
  } catch (error) {
    // Tampered blob or wrong key. Surface a clear error rather than
    // returning garbage that silently breaks downstream Plaid calls.
    throw new Error(
      `Failed to decrypt stored access token: ${error.message}. Check ENCRYPTION_KEY / .encryption-key.`
    );
  }
}

/** True if the string looks like an already-encrypted v1 blob. */
export function isEncrypted(blob) {
  if (blob == null) return false;
  try {
    const buf = Buffer.from(blob, 'base64');
    return buf[0] === 0x01 && buf.length >= 1 + IV_LEN + TAG_LEN;
  } catch {
    return false;
  }
}
