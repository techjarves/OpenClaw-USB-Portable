#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
NODE_VERSION="v24.15.0"

UNAME_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$UNAME_OS:$ARCH" in
  linux:x86_64)
    PLATFORM="linux-x64"
    NODE_ARCH="x64"
    NODE_TARBALL="node-$NODE_VERSION-linux-$NODE_ARCH.tar.xz"
    NODE_URL="https://nodejs.org/dist/$NODE_VERSION/$NODE_TARBALL"
    EXTRACT_FLAG="-xJf"
    EXTRACTED_DIR="$ROOT/runtime/node-$NODE_VERSION-linux-$NODE_ARCH"
    ;;
  linux:aarch64|linux:arm64)
    PLATFORM="linux-arm64"
    NODE_ARCH="arm64"
    NODE_TARBALL="node-$NODE_VERSION-linux-$NODE_ARCH.tar.xz"
    NODE_URL="https://nodejs.org/dist/$NODE_VERSION/$NODE_TARBALL"
    EXTRACT_FLAG="-xJf"
    EXTRACTED_DIR="$ROOT/runtime/node-$NODE_VERSION-linux-$NODE_ARCH"
    ;;
  darwin:x86_64)
    PLATFORM="macos-x64"
    NODE_ARCH="x64"
    NODE_TARBALL="node-$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
    NODE_URL="https://nodejs.org/dist/$NODE_VERSION/$NODE_TARBALL"
    EXTRACT_FLAG="-xzf"
    EXTRACTED_DIR="$ROOT/runtime/node-$NODE_VERSION-darwin-$NODE_ARCH"
    ;;
  darwin:arm64)
    PLATFORM="macos-arm64"
    NODE_ARCH="arm64"
    NODE_TARBALL="node-$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
    NODE_URL="https://nodejs.org/dist/$NODE_VERSION/$NODE_TARBALL"
    EXTRACT_FLAG="-xzf"
    EXTRACTED_DIR="$ROOT/runtime/node-$NODE_VERSION-darwin-$NODE_ARCH"
    ;;
  *)
    echo "Unsupported OS/CPU: $UNAME_OS/$ARCH"
    exit 1
    ;;
esac

PORTABLE_ENV_ROOT=$ROOT PORTABLE_ENV_PLATFORM=$PLATFORM . "$SCRIPT_DIR/portable-env.sh"

RUNTIME_DIR="$ROOT/runtime/$PLATFORM"
NODE_BIN="$RUNTIME_DIR/bin/node"
NPM_BIN="$RUNTIME_DIR/bin/npm"
OPENCLAW_PACKAGE_ROOT="$ROOT/packages/$PLATFORM/openclaw"
OPENCLAW_ENTRY="$OPENCLAW_PACKAGE_ROOT/node_modules/openclaw/openclaw.mjs"
DOWNLOAD_PATH="$ROOT/packages/downloads/$NODE_TARBALL"
GATEWAY_LOG="$ROOT/logs/gateway-$PLATFORM.log"

log() {
  printf '[portable-openclaw] %s\n' "$1"
}

download_file() {
  url=$1
  out=$2
  tmp="$out.partial"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar "$url" -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget "$url" -O "$tmp"
  else
    echo "curl or wget is required to download portable Node on first run."
    exit 1
  fi
  mv "$tmp" "$out"
}

write_node_bin_wrapper() {
  name=$1
  target=$2
  wrapper="$EXTRACTED_DIR/bin/$name"

  {
    printf '%s\n' '#!/usr/bin/env sh'
    printf '%s\n' 'SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)'
    printf 'exec "$SCRIPT_DIR/node" "$SCRIPT_DIR/%s" "$@"\n' "$target"
  } > "$wrapper"
  chmod +x "$wrapper" 2>/dev/null || true
}

repair_node_bin_wrappers() {
  write_node_bin_wrapper npm ../lib/node_modules/npm/bin/npm-cli.js
  write_node_bin_wrapper npx ../lib/node_modules/npm/bin/npx-cli.js
  write_node_bin_wrapper corepack ../lib/node_modules/corepack/dist/corepack.js
}

install_node_if_needed() {
  if [ -x "$NODE_BIN" ]; then
    log "Portable Node already exists for $PLATFORM"
    return
  fi

  log "Downloading portable Node $NODE_VERSION for $PLATFORM"
  mkdir -p "$ROOT/packages/downloads" "$ROOT/runtime"
  download_file "$NODE_URL" "$DOWNLOAD_PATH"

  log "Extracting portable Node"
  rm -rf "$EXTRACTED_DIR" "$RUNTIME_DIR"
  tar "$EXTRACT_FLAG" "$DOWNLOAD_PATH" -C "$ROOT/runtime" \
    --exclude "node-$NODE_VERSION-*/bin/npm" \
    --exclude "node-$NODE_VERSION-*/bin/npx" \
    --exclude "node-$NODE_VERSION-*/bin/corepack"
  repair_node_bin_wrappers
  rm -rf "$RUNTIME_DIR"
  mv "$EXTRACTED_DIR" "$RUNTIME_DIR"
}

install_openclaw_if_needed() {
  if [ -f "$OPENCLAW_ENTRY" ]; then
    log "Portable OpenClaw already exists for $PLATFORM"
    return
  fi

  if [ ! -x "$NPM_BIN" ]; then
    echo "Portable npm not found at $NPM_BIN"
    exit 1
  fi

  log "Installing OpenClaw into USB package folder for $PLATFORM"
  out_log="$ROOT/logs/npm-install-$PLATFORM.out.log"
  err_log="$ROOT/logs/npm-install-$PLATFORM.err.log"
  : > "$out_log"
  : > "$err_log"

  "$NPM_BIN" install --prefix "$OPENCLAW_PACKAGE_ROOT" openclaw@latest --ignore-scripts --loglevel=info --progress=false </dev/null \
    > "$out_log" 2> "$err_log" &
  install_pid=$!
  started_at=$(date +%s)
  show_logs=0
  out_line=1
  err_line=1
  waiting_printed=0
  has_tty=0
  old_stty=""

  if [ -t 0 ] && [ -t 1 ]; then
    has_tty=1
    old_stty=$(stty -g 2>/dev/null || true)
    stty -icanon -echo min 0 time 0 2>/dev/null || has_tty=0
  fi

  while kill -0 "$install_pid" 2>/dev/null; do
    now=$(date +%s)
    elapsed=$((now - started_at))
    elapsed_text=$(printf '%02d:%02d' $((elapsed / 60)) $((elapsed % 60)))

    if [ "$has_tty" -eq 1 ]; then
      key=""
      read -r key || true
      case "$key" in
        l|L)
          if [ "$show_logs" -eq 0 ]; then
            show_logs=1
            waiting_printed=0
            printf '\n--- install logs, H to hide ---\n'
            out_count=$(wc -l < "$out_log" | tr -d ' ')
            err_count=$(wc -l < "$err_log" | tr -d ' ')
            if [ "$out_count" -gt 80 ]; then out_line=$((out_count - 79)); fi
            if [ "$err_count" -gt 80 ]; then err_line=$((err_count - 79)); fi
          fi
          ;;
        h|H)
          if [ "$show_logs" -eq 1 ]; then
            show_logs=0
            printf '\n--- logs hidden ---\n'
          fi
          ;;
      esac
    fi

    if [ "$show_logs" -eq 1 ]; then
      out_count=$(wc -l < "$out_log" | tr -d ' ')
      err_count=$(wc -l < "$err_log" | tr -d ' ')
      printed_any=0
      if [ "$out_count" -ge "$out_line" ]; then
        awk "NR >= $out_line" "$out_log"
        printed_any=1
        out_line=$((out_count + 1))
      fi
      if [ "$err_count" -ge "$err_line" ]; then
        awk "NR >= $err_line" "$err_log"
        printed_any=1
        err_line=$((err_count + 1))
      fi
      if [ "$printed_any" -eq 0 ] && [ "$waiting_printed" -eq 0 ]; then
        printf 'Waiting for npm output...\n'
        waiting_printed=1
      fi
      printf '\r[portable-openclaw] Installing OpenClaw | %s | H hide' "$elapsed_text"
    else
      printf '\r[portable-openclaw] Installing OpenClaw | %s | L logs | %s' "$elapsed_text" "logs/npm-install-$PLATFORM.out.log"
    fi

    sleep 1
  done

  set +e
  wait "$install_pid"
  install_status=$?
  set -e
  if [ "$has_tty" -eq 1 ] && [ -n "$old_stty" ]; then
    stty "$old_stty" 2>/dev/null || true
  fi
  printf '\n'

  if [ "$install_status" -ne 0 ]; then
    echo "OpenClaw install failed. Last log lines:"
    tail -n 25 "$err_log" 2>/dev/null || true
    tail -n 25 "$out_log" 2>/dev/null || true
    exit 1
  fi
}

patch_config_with_node() {
  "$NODE_BIN" -e '
const fs = require("fs");
const path = process.env.OPENCLAW_CONFIG_PATH;
const workspace = process.env.OPENCLAW_PORTABLE_WORKSPACE;
let config = {};
try {
  config = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (error) {
  const backup = `${path}.invalid-${Date.now()}.bak`;
  if (fs.existsSync(path)) fs.copyFileSync(path, backup);
}
config.agents = config.agents && typeof config.agents === "object" ? config.agents : {};
config.agents.defaults = config.agents.defaults && typeof config.agents.defaults === "object" ? config.agents.defaults : {};
if (config.agents.defaults.workspace === workspace) process.exit(0);
config.agents.defaults.workspace = workspace;
fs.writeFileSync(path, JSON.stringify(config));
' || {
    echo "Could not patch OpenClaw config path."
    exit 1
  }
}

openclaw() {
  if [ ! -f "$OPENCLAW_ENTRY" ]; then
    echo "Portable OpenClaw is not installed at $OPENCLAW_ENTRY"
    exit 1
  fi
  "$NODE_BIN" "$OPENCLAW_ENTRY" "$@"
}

gateway_setting() {
  key=$1
  fallback=$2
  "$NODE_BIN" -e '
const fs = require("fs");
const key = process.argv[1];
const fallback = process.argv[2] ?? "";
let value;
try {
  const config = JSON.parse(fs.readFileSync(process.env.OPENCLAW_CONFIG_PATH, "utf8"));
  value = key.split(".").reduce((acc, part) => acc && acc[part], config);
} catch {}
if (value === undefined || value === null || value === "") value = fallback;
process.stdout.write(String(value));
' "$key" "$fallback"
}

gateway_port() {
  gateway_setting gateway.port 18789
}

gateway_bind() {
  gateway_setting gateway.bind loopback
}

gateway_auth_mode() {
  gateway_setting gateway.auth.mode none
}

gateway_token() {
  gateway_setting gateway.auth.token ""
}

gateway_password() {
  gateway_setting gateway.auth.password ""
}

gateway_port_running() {
  port=$(gateway_port)
  "$NODE_BIN" -e "const net=require('net');const port=Number(process.argv[1]);const s=net.connect(port,'127.0.0.1');s.setTimeout(500);s.on('connect',()=>{s.destroy();process.exit(0)});s.on('timeout',()=>{s.destroy();process.exit(1)});s.on('error',()=>process.exit(1));" "$port" >/dev/null 2>&1
}

gateway_healthy() {
  gateway_port_running || return 1
  mode=$(gateway_auth_mode)
  case "$mode" in
    token)
      token=$(gateway_token)
      [ -n "$token" ] && openclaw gateway health --timeout 2500 --token "$token" >/dev/null 2>&1
      ;;
    password)
      password=$(gateway_password)
      [ -n "$password" ] && openclaw gateway health --timeout 2500 --password "$password" >/dev/null 2>&1
      ;;
    *)
      openclaw gateway health --timeout 2500 >/dev/null 2>&1
      ;;
  esac
}

gateway_ready_from_log() {
  gateway_port_running || return 1
  [ -f "$GATEWAY_LOG" ] || return 1
  tail -n 80 "$GATEWAY_LOG" 2>/dev/null | grep -q '\[gateway\].*ready'
}

stop_gateway() {
  stopped=0
  if [ -f "$ROOT/logs/gateway-$PLATFORM.pid" ]; then
    pid=$(cat "$ROOT/logs/gateway-$PLATFORM.pid" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      log "Stopping Gateway process: $pid"
      kill "$pid" >/dev/null 2>&1 || true
      stopped=1
    fi
    rm -f "$ROOT/logs/gateway-$PLATFORM.pid"
  fi
  if [ "$stopped" -eq 0 ]; then
    echo "Gateway is not running."
  else
    sleep 1
    if gateway_port_running; then
      echo "Gateway port is still open after stop attempt."
    else
      echo "Gateway stopped."
    fi
  fi
}

show_gateway_log_tail() {
  shown=0
  if [ -f "$GATEWAY_LOG" ]; then
    echo
    echo "--- OpenClaw Gateway log: logs/gateway-$PLATFORM.log ---"
    tail -n 40 "$GATEWAY_LOG"
    echo "--- end gateway log ---"
    shown=1
  fi
  native_log=$(find "$ROOT/data/temp/openclaw" -maxdepth 1 -type f -name 'openclaw-*.log' 2>/dev/null | sort | tail -n 1 || true)
  if [ -n "$native_log" ]; then
    echo
    echo "--- OpenClaw native log: $native_log ---"
    tail -n 40 "$native_log"
    echo "--- end native log ---"
    shown=1
  fi
  if [ "$shown" -eq 0 ]; then
    echo
    echo "No Gateway log files were created."
  fi
}

gateway_startup_milestone() {
  [ -f "$GATEWAY_LOG" ] || return 0
  tail -n 25 "$GATEWAY_LOG" 2>/dev/null |
    sed -n '/ready\|http server listening\|starting channels and sidecars\|loaded .* plugin\|starting HTTP server\|starting\.\.\./p' |
    tail -n 1
}

start_gateway() {
  force=${1:-}
  if [ "$force" = "force" ]; then
    stop_gateway
    sleep 1
  elif gateway_healthy; then
    log "Gateway already running and healthy"
    return 0
  elif gateway_port_running; then
    log "Gateway is running but not healthy. Restarting portable Gateway."
    stop_gateway
    sleep 1
  fi

  log "Starting Gateway"
  port=$(gateway_port)
  bind=$(gateway_bind)
  auth_mode=$(gateway_auth_mode)
  case "$auth_mode" in
    token)
      token=$(gateway_token)
      nohup "$NODE_BIN" "$OPENCLAW_ENTRY" gateway run --port "$port" --bind "$bind" --auth "$auth_mode" --token "$token" --verbose > "$GATEWAY_LOG" 2>&1 &
      ;;
    password)
      password=$(gateway_password)
      nohup "$NODE_BIN" "$OPENCLAW_ENTRY" gateway run --port "$port" --bind "$bind" --auth "$auth_mode" --password "$password" --verbose > "$GATEWAY_LOG" 2>&1 &
      ;;
    *)
      nohup "$NODE_BIN" "$OPENCLAW_ENTRY" gateway run --port "$port" --bind "$bind" --auth "$auth_mode" --verbose > "$GATEWAY_LOG" 2>&1 &
      ;;
  esac
  echo "$!" > "$ROOT/logs/gateway-$PLATFORM.pid"

  elapsed=0
  while [ "$elapsed" -lt 120 ]; do
    if gateway_ready_from_log; then
      show_gateway_log_tail
      return
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    if [ $((elapsed % 10)) -eq 0 ]; then
      milestone=$(gateway_startup_milestone)
      if [ -n "$milestone" ]; then
        printf 'Waiting for Gateway startup... %ss/120s | %s\n' "$elapsed" "$milestone"
      else
        printf 'Waiting for Gateway startup... %ss/120s\n' "$elapsed"
      fi
    fi
  done

  echo "Gateway did not become healthy within 120s. Check logs/gateway-$PLATFORM.log"
  show_gateway_log_tail
  return 1
}

pause_menu() {
  printf '\nPress Enter to continue'
  read -r _ || true
}

show_header() {
  clear || true
  echo "Portable OpenClaw"
  echo "------------------------------------------------------------------------"
  echo "Root      $ROOT"
  echo "Platform  $PLATFORM"
  echo "Data      $OPENCLAW_STATE_DIR"
  echo "Workspace $OPENCLAW_PORTABLE_WORKSPACE"
  if gateway_port_running; then
    echo "Gateway   RUNNING"
  else
    echo "Gateway   STOPPED"
  fi
  echo "------------------------------------------------------------------------"
}

run_openclaw_command() {
  echo
  echo "Paste OpenClaw command, for example:"
  echo "openclaw pairing approve telegram R2F8ZL5S"
  printf 'Command: '
  read -r command_text || return
  [ -n "$command_text" ] || return

  case "$command_text" in
    openclaw\ *) command_text=${command_text#openclaw } ;;
    openclaw) return ;;
  esac

  echo
  log "Running OpenClaw command live. Press Ctrl+C to stop it."
  # shellcheck disable=SC2086
  set +e
  openclaw $command_text
  command_status=$?
  set -e
  if [ "${command_status:-0}" -ne 0 ]; then
    echo "OpenClaw command exited with code $command_status."
  fi
}

tools_menu() {
  while :; do
    show_header
    echo "Tools"
    echo
    echo "1. Full Setup"
    echo "2. Health Check / Repair"
    echo "3. Status"
    echo "4. Sessions"
    echo "5. Channels"
    echo "6. Logs"
    echo "7. Update"
    echo "8. Stop Gateway"
    echo "9. Run OpenClaw Command"
    echo "0. Back"
    echo
    printf 'Select: '
    read -r choice || exit 0
    case "$choice" in
      1) openclaw configure; start_gateway force; pause_menu ;;
      2) openclaw doctor; pause_menu ;;
      3) openclaw status; pause_menu ;;
      4) openclaw sessions; pause_menu ;;
      5) openclaw channels status; pause_menu ;;
      6) if [ -f "$GATEWAY_LOG" ]; then tail -n 80 -f "$GATEWAY_LOG"; else echo "No Gateway log yet."; pause_menu; fi ;;
      7) "$NPM_BIN" install --prefix "$OPENCLAW_PACKAGE_ROOT" openclaw@latest --ignore-scripts --loglevel=info --progress=false; pause_menu ;;
      8) stop_gateway; pause_menu ;;
      9) run_openclaw_command; pause_menu ;;
      0) return ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

install_node_if_needed
PORTABLE_ENV_ROOT=$ROOT PORTABLE_ENV_PLATFORM=$PLATFORM . "$SCRIPT_DIR/portable-env.sh"
patch_config_with_node
install_openclaw_if_needed

log "Portable runtime ready"
"$NODE_BIN" --version
"$NPM_BIN" --version
openclaw --version
sleep 1

while :; do
  show_header
  echo "1. Setup / Change AI"
  echo "2. Chat"
  echo "3. Dashboard"
  echo "4. Tools"
  echo "5. Stop Gateway"
  echo "0. Exit"
  echo
  printf 'Select: '
  read -r choice || exit 0
  case "$choice" in
    1) openclaw configure --section model; start_gateway force || true; pause_menu ;;
    2) if start_gateway; then
         case "$(gateway_auth_mode)" in
           token) token=$(gateway_token); openclaw tui --token "$token" ;;
           password) password=$(gateway_password); openclaw tui --password "$password" ;;
           *) openclaw tui ;;
         esac
       fi; pause_menu ;;
    3) if start_gateway; then openclaw dashboard; fi; pause_menu ;;
    4) tools_menu ;;
    5) stop_gateway; pause_menu ;;
    0) exit 0 ;;
    *) echo "Invalid option"; sleep 1 ;;
  esac
done
