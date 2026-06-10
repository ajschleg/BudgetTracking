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
| Linking a new bank, OAuth re-auth, Update mode | ✅ works | these load pages in a `WKWebView` whose host allowlist (`PlaidLinkWebView.isHostAllowedInWebView`, `SECURITY_POLICY` §7) includes the configured Server URL's host **when that URL is `https://`** — true for the tailnet name. A plaintext remote URL gets no WebView allowance. |

Everything above works over the tailnet name. The link / re-auth web flow
stays a host whitelist: unknown hosts (bank OAuth pages) still open in the
system browser, and a remote server configured over plain `http://` is still
refused by the WebView.

### Transaction store API (server-hub migration, 2026-06)

The server owns the books: it ingests the Plaid stream into its own
`transactions` table and devices sync against it (all under `/api`, so
`X-App-Token` + the 60 req/min limit apply):

| Endpoint | Purpose |
| --- | --- |
| `GET /api/transactions/changes?since=<seq>&limit=<≤500>` | Pull deltas after the device's cursor; returns `next_seq` + `has_more` |
| `POST /api/transactions` (≤250 rows) | Idempotent bulk create — manual entries, file imports, one-time history seed |
| `POST /api/transactions/batch` (≤250 ops) | Bulk edits (categorize, tombstone, restore) |
| `PATCH /api/transactions/:id` | Single edit |
| `POST /api/transactions/sync` | Trigger a Plaid ingest now (also still returns the legacy arrays for pre-migration app builds) |

Because the tailnet-only server can never receive Plaid webhooks, a
server-side timer drives ingestion: `AUTO_SYNC_INTERVAL_MINUTES` in
`server/.env` (default 360 = 6 h, `0` disables, first run ~60 s after
boot). Nightly DB snapshots land in `server/backups/` (newest 14 kept);
the restore procedure is documented in `SECURITY.md`.

## Keeping the server running (sleep, logout, launchd)

If the server Mac sleeps or auto-logs-out, the server stops: **sleep** suspends
the whole machine, and **auto-logout** tears down the login session (killing
anything started in a Terminal/SSH session). For an always-on mini, fix all
layers:

**1. Stop it sleeping.** System Settings → Energy → *Prevent automatic sleeping
when the display is off* (display sleep itself is fine). Or:
```bash
sudo pmset -a sleep 0 disksleep 0
sudo pmset -a womp 1 autorestart 1     # wake on network; reboot after power loss
```

**2. Stop auto-logout.** System Settings → Privacy & Security → Advanced →
*Log out automatically after N minutes* → off. Or:
```bash
sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0
```

**3. Keep Tailscale up when logged out.** Tailscale menu → enable *Run
unattended*, so the tunnel and `tailscale serve` survive logout/reboot.

**4. Run the server as a launchd service** so it starts at boot, restarts on
crash, and doesn't depend on a login session or an open Terminal. The helper
script generates and manages the LaunchDaemon — it auto-detects the node path,
server dir, and run-as user, so there's nothing to hand-edit:
```bash
cd server/deploy
./budgettracking-server.sh install     # set up + start (now and at every boot)
./budgettracking-server.sh status      # installed? loaded? responding?
./budgettracking-server.sh logs        # tail stdout/stderr
```
Run it from a terminal where `node -v` works (it calls `sudo` only for the
privileged steps — don't prefix the whole command with sudo). After installing,
stop any manual `npm start` so two instances don't fight over the port.

**Stopping / removing is one command:**
```bash
./budgettracking-server.sh stop        # stop now; stays stopped across reboots
./budgettracking-server.sh start       # start again
./budgettracking-server.sh uninstall   # remove the service entirely
```
`uninstall` removes only the service; revert the power/login changes with
`sudo pmset -a sleep 1` and re-enabling auto-logout in Settings.

The service runs as your user (so it can read the `0600` `.env` /
`.encryption-key`), writes logs to `~/Library/Logs/budgettracking-server*.log`,
and `launchctl load` may print a deprecation notice on newer macOS — harmless.

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
