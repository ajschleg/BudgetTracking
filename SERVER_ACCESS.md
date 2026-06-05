# Connecting the app to the Plaid server

The macOS app talks to the Node Plaid server (`/server/`) using two values in
**Settings → Plaid Server**:

- **Server URL** — where the server is (default `http://localhost:8080`)
- **App Auth Token** — shared secret; must match `APP_AUTH_TOKEN` in the
  server's `.env` (sent as the `X-App-Token` header on every `/api/*` call)

Use the **Test Connection** button there to confirm both at once — it probes
`/health` (reachable?) then `/api/transactions/status` (token accepted?).

## Same machine

Server and app on one Mac: leave Server URL at `http://localhost:8080`.
Loopback is the one host the app can reach over plaintext HTTP (see ATS below).

## App Transport Security — why a remote server needs HTTPS

macOS App Transport Security (ATS) blocks cleartext `http://` to remote hosts;
it only lets loopback through. So pointing the app at a **remote** server over
plain `http://` fails inside the app with *"Couldn't reach the server"* — most
definitively for a public-looking hostname like a Tailscale `*.ts.net` name or
a `100.64/10` tailnet IP, which ATS treats as public. The tell-tale symptom:
**`curl` to the exact same URL works but the app doesn't**, because `curl`
ignores ATS and the app's `URLSession` does not.

This project ships no ATS exceptions, so the reliable way to reach a remote
server is **HTTPS with a valid certificate**. Tailscale provides exactly that.

## Encrypted access with Tailscale (recommended)

[Tailscale](https://tailscale.com) puts both Macs on a private WireGuard
network and can terminate **real HTTPS** — a valid Let's Encrypt cert for the
machine's MagicDNS name — in front of the local server. The app then uses a
normal `https://` URL that satisfies ATS, and traffic is encrypted twice
(TLS + WireGuard). It also gives the server a stable name and works off home
Wi-Fi.

### Setup

1. **Install Tailscale on both Macs** (`brew install --cask tailscale` or
   download from tailscale.com), open each, sign in to the same account, and
   approve the network system extension when macOS prompts.
2. In the Tailscale **admin console**, enable **MagicDNS** and **HTTPS
   Certificates** (both on the DNS page).
3. **On the server Mac (the mini)**, put HTTPS in front of the Node server's
   port. The CLI lives inside the app bundle, so use its full path:
   ```bash
   /Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 8080
   /Applications/Tailscale.app/Contents/MacOS/Tailscale serve status
   #  https://<machine>.<tailnet>.ts.net/  →  http://127.0.0.1:8080
   ```
   The Node server needs **no changes** — it keeps listening on
   `localhost:8080`; Tailscale proxies to it. `serve --bg` persists across
   reboots. Run this on the **server** machine, not the laptop — `serve`
   proxies that machine's own `localhost`. (Undo with `tailscale serve reset`.)
4. **Point the app** at the HTTPS name — Settings → Plaid Server → Server URL =
   `https://<machine>.<tailnet>.ts.net` (note: `https`, and **no `:8080`** —
   TLS is on 443). Keep the App Auth Token unchanged.
5. **Verify:** click **Test Connection** → green. (The first request can be
   slow while the cert provisions; retry once if it times out.)

You can sanity-check the cert from the client Mac before switching the app:
```bash
curl https://<machine>.<tailnet>.ts.net/health    # valid cert ⇒ no -k needed
```

### What works over Tailscale

| Action | Status | Notes |
| --- | --- | --- |
| Test Connection, Sync Transactions, Refresh Balances, accounts/items, disconnect | ✅ works | plain `URLSession` calls to the `https://` Server URL |
| Linking a new bank, OAuth re-auth, Update mode | ⚠️ needs an allowlist change | these load pages in a `WKWebView` whose host allowlist is localhost-only (`PlaidLinkView.isHostAllowedInWebView`, `SECURITY_POLICY` §7). Add the configured server host to it to link banks over the tailnet name. |

So day-to-day syncing works immediately; only the link / re-auth web flow needs
the allowlist widened for a non-localhost host.

## Optional hardening — close the plaintext LAN port

The Node server still listens on `0.0.0.0:8080`, so the unencrypted LAN path
stays reachable by other devices on your home network even after the app
switches to the HTTPS tailnet name. To force *all* access through Tailscale,
bind the server to `127.0.0.1` — `tailscale serve` still reaches it (it proxies
to localhost), but the LAN and direct tailnet-IP plaintext paths close. This
needs a small `HOST` env knob in `server.js` (not yet added — ask for it). A
localhost-based webhook tunnel (e.g. ngrok on the mini → `localhost:8080`) keeps
working; only direct off-box plaintext is closed.

Until then: don't expose port 8080 to the internet.
