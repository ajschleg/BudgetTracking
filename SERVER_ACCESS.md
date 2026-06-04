# Connecting the app to the Plaid server

The macOS app talks to the Node Plaid server (`/server/`) over HTTP using
two values in **Settings → Plaid Server**:

- **Server URL** — where the server is (default `http://localhost:8080`)
- **App Auth Token** — shared secret; must match `APP_AUTH_TOKEN` in the
  server's `.env` (sent as the `X-App-Token` header on every `/api/*` call)

Use the **Test Connection** button there to confirm both at once — it
probes `/health` (reachable?) then `/api/transactions/status` (token
accepted?) and reports which, if either, failed.

## Same machine

Server and app on one Mac: leave Server URL at `http://localhost:8080`.

## Another machine on the LAN (plaintext)

Point Server URL at the server Mac's LAN address, e.g.
`http://192.168.1.147:8080` or `http://<name>.local:8080`. This is plain
HTTP — fine on a trusted home network, but the traffic (including the
`X-App-Token` and transaction data) is **unencrypted on the wire**. Never
port-forward this to the internet.

## Encrypted access with Tailscale (recommended)

[Tailscale](https://tailscale.com) puts both Macs on a private WireGuard
network. Traffic between them is end-to-end encrypted, the server gets a
stable name (no more DHCP-IP churn), and it works even when the two
machines aren't on the same Wi-Fi.

### Setup

1. **Install on the server Mac (the mini):** `brew install --cask tailscale`
   (or download from tailscale.com), open it, sign in, and approve the
   network system extension when macOS prompts.
2. **Install on the laptop:** same steps, same Tailscale account.
3. **(Recommended) Enable MagicDNS** in the Tailscale admin console so the
   mini is reachable by name rather than IP.
4. **Find the mini's tailnet address** — on the mini run `tailscale ip -4`
   (→ `100.x.y.z`) or `tailscale status` (shows its MagicDNS name). The CLI
   for the GUI app lives at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.
5. **Repoint the app:** Settings → Plaid Server → Server URL =
   `http://<mini-magicdns-name>:8080` (e.g. `http://mac-mini:8080`) or
   `http://100.x.y.z:8080`. Keep the App Auth Token unchanged.
6. **Verify:** click **Test Connection** → expect the green "Connected"
   result.

The URL stays `http://` — encryption happens at the WireGuard network
layer, so no TLS certificates are involved.

### What works over Tailscale

| Action | Over Tailscale | Why |
| --- | --- | --- |
| Test Connection, Sync Transactions, Refresh Balances, accounts/items, disconnect | ✅ works as-is | plain `URLSession` calls to the Server URL — no host restriction |
| Linking a new bank, OAuth re-auth, Update mode | ⚠️ needs an allowlist change | these load pages in a `WKWebView` whose host allowlist is currently localhost-only (`PlaidLinkView.isHostAllowedInWebView`, per `SECURITY_POLICY` §7). Add the configured server host to it to link banks over a tailnet address. |

So day-to-day syncing works immediately after repointing; only the
link / re-auth web flow needs the allowlist widened for a non-localhost
server.

## Optional hardening — close the plaintext LAN port

The server listens on all interfaces (`0.0.0.0:8080`), so the unencrypted
LAN path stays reachable by other devices on your home network even after
the app switches to Tailscale. To force *all* access through the encrypted
tailnet, bind the server to its tailnet IP only. This needs a small `HOST`
env knob in `server.js` (not yet added — ask for it).

Caveat: if you bind to the tailnet IP only, make sure Plaid webhook
delivery still reaches the server. Webhooks arrive via the public
`PLAID_WEBHOOK_URL` ingress, which must forward to whatever interface the
server is bound to.

Until then: don't expose port 8080 to the internet, and optionally use the
macOS firewall to limit who on the LAN can reach it.
