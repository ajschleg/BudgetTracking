#!/usr/bin/env bash
#
# budgettracking-server.sh — run the BudgetTracking Plaid server (/server)
# as a macOS launchd LaunchDaemon, so it starts at boot, restarts on crash,
# and keeps running whether or not anyone is logged in (survives the screen
# locking, auto-logout, and your SSH session closing).
#
# Run it from a terminal where `node -v` works (so node is auto-detected).
# Privileged steps call `sudo` and will prompt for your password — do NOT
# run the whole script with sudo (that hides your node install).
#
#   ./budgettracking-server.sh install      # generate + load the service, start now + at every boot
#   ./budgettracking-server.sh status       # installed? loaded? responding?
#   ./budgettracking-server.sh stop         # stop now; stays stopped across reboots until 'start'
#   ./budgettracking-server.sh start        # start (and re-enable at boot)
#   ./budgettracking-server.sh restart      # bounce it
#   ./budgettracking-server.sh logs         # tail stdout + stderr
#   ./budgettracking-server.sh uninstall    # stop + remove the service entirely
#
# Auto-detected at install time and baked into the plist:
#   - node path   (NODE=... to override; needed if node is via nvm and not on PATH)
#   - server dir  (this script's parent dir)
#   - run-as user (your login user; never root)

set -euo pipefail

LABEL="com.schlegel.budgettracking-server"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # deploy/ -> server/

# Port the health check hits; read from .env, default 8080.
PORT="$(grep -E '^PORT=' "${SERVER_DIR}/.env" 2>/dev/null | head -1 | cut -d= -f2 | tr -dc '0-9' || true)"
PORT="${PORT:-8080}"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

target_user() { printf '%s' "${SUDO_USER:-$(id -un)}"; }
user_home()   { dscl . -read "/Users/$(target_user)" NFSHomeDirectory 2>/dev/null | awk '{print $2}'; }

health() {
  if curl -fs "http://localhost:${PORT}/health" >/dev/null 2>&1; then
    echo "health:  UP — http://localhost:${PORT}/health is responding"
  else
    echo "health:  DOWN — nothing answering on :${PORT}"
  fi
}

cmd_install() {
  if [ "$(id -u)" -eq 0 ] && [ -z "${NODE:-}" ]; then
    die "run this WITHOUT sudo (as your user) so 'node' is found; sudo is invoked internally. Or pass NODE=/abs/path/to/node."
  fi

  local node user home log
  node="${NODE:-$(command -v node || true)}"
  [ -n "${node}" ]                   || die "node not found on PATH. Run from a terminal where 'node -v' works, or: NODE=/abs/path/to/node $0 install"
  [ -x "${node}" ]                   || die "node path '${node}' is not executable"
  [ -f "${SERVER_DIR}/server.js" ]   || die "server.js not found in ${SERVER_DIR}"
  user="$(target_user)"
  [ "${user}" != "root" ]            || die "refusing to install as root — run as your normal user"
  home="$(user_home)"; [ -n "${home}" ] || home="/Users/${user}"
  log="${home}/Library/Logs"

  info "installing ${LABEL}"
  echo "    node:       ${node}"
  echo "    server dir: ${SERVER_DIR}"
  echo "    run as:     ${user}"
  echo "    logs:       ${log}/budgettracking-server.{log,err.log}"

  local tmp; tmp="$(mktemp)"
  cat > "${tmp}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key>             <string>${LABEL}</string>
  <key>ProgramArguments</key>  <array>
    <string>${node}</string>
    <string>${SERVER_DIR}/server.js</string>
  </array>
  <key>WorkingDirectory</key>  <string>${SERVER_DIR}</string>
  <key>UserName</key>          <string>${user}</string>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>StandardOutPath</key>   <string>${log}/budgettracking-server.log</string>
  <key>StandardErrorPath</key> <string>${log}/budgettracking-server.err.log</string>
  <key>EnvironmentVariables</key> <dict>
    <key>PATH</key> <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict></plist>
EOF

  mkdir -p "${log}" 2>/dev/null || true
  sudo cp "${tmp}" "${PLIST}"
  sudo chown root:wheel "${PLIST}"
  sudo chmod 644 "${PLIST}"
  rm -f "${tmp}"

  # (re)load cleanly
  sudo launchctl unload -w "${PLIST}" 2>/dev/null || true
  sudo launchctl load   -w "${PLIST}"
  info "loaded — giving it a moment to come up…"
  sleep 1
  health
  echo "Manage with: $0 {status|stop|start|restart|logs|uninstall}"
}

cmd_start() {
  [ -f "${PLIST}" ] || die "not installed — run: $0 install"
  sudo launchctl load -w "${PLIST}"
  sleep 1; health
}

cmd_stop() {
  [ -f "${PLIST}" ] || die "not installed"
  sudo launchctl unload -w "${PLIST}"
  echo "stopped — stays stopped across reboots until '$0 start' (use 'uninstall' to remove for good)"
}

cmd_restart() {
  [ -f "${PLIST}" ] || die "not installed — run: $0 install"
  sudo launchctl kickstart -k "system/${LABEL}" 2>/dev/null || sudo launchctl load -w "${PLIST}"
  sleep 1; health
}

cmd_status() {
  if [ -f "${PLIST}" ]; then echo "plist:   ${PLIST} (installed)"; else echo "plist:   not installed"; fi
  local line; line="$(sudo launchctl list 2>/dev/null | grep -F "${LABEL}" || true)"
  if [ -n "${line}" ]; then
    echo "launchd: loaded (PID  ExitCode  Label):"; echo "         ${line}"
  else
    echo "launchd: not loaded"
  fi
  health
}

cmd_logs() {
  local log; log="$(user_home)/Library/Logs"
  echo "tailing ${log}/budgettracking-server*.log  (Ctrl-C to stop)"
  tail -n 50 -f "${log}/budgettracking-server.log" "${log}/budgettracking-server.err.log"
}

cmd_uninstall() {
  info "removing ${LABEL}"
  sudo launchctl unload -w "${PLIST}" 2>/dev/null || true
  sudo rm -f "${PLIST}"
  echo "removed. Logs in ~/Library/Logs and any pmset / auto-logout changes are left untouched."
}

case "${1:-}" in
  install)   cmd_install ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  uninstall) cmd_uninstall ;;
  *)
    cat >&2 <<USAGE
Usage: $0 {install|status|stop|start|restart|logs|uninstall}

  install    Generate + load the LaunchDaemon (starts now, and at every boot).
  status     Show whether it's installed, loaded, and responding.
  stop       Stop the server now; stays stopped across reboots until 'start'.
  start      Start it (and re-enable at boot).
  restart    Bounce the server.
  logs       Tail stdout/stderr (~/Library/Logs/budgettracking-server*.log).
  uninstall  Stop and remove the service entirely.

Run from a terminal where 'node -v' works (do not prefix with sudo).
USAGE
    exit 2 ;;
esac
