#!/usr/bin/env bash
set -euo pipefail

# ===== Helpers (messages shown on STDERR unless values) =====
cecho(){ printf "\033[1;36m%s\033[0m\n" "$*" >&2; }
gecho(){ printf "\033[1;32m%s\033[0m\n" "$*" >&2; }
recho(){ printf "\033[1;31m%s\033[0m\n" "$*" >&2; }
yecho(){ printf "\033[1;33m%s\033[0m\n" "$*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    recho "This script must be run as root (sudo)."
    exit 1
  fi
}

# ===== Ensure backhaul exists in $HOME =====
ensure_backhaul() {
  local bh_path="${HOME}/backhaul"
  if [ -x "$bh_path" ]; then
    gecho "✅ 'backhaul' already exists at ${bh_path}. Proceeding."
    return 0
  fi

  yecho "⚠️ 'backhaul' not found at ${HOME}."
  printf "Download and install backhaul now? [Y/n]: " >&2
  local ans; read -r ans; ans="${ans:-Y}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    cecho "Downloading backhaul ..."
    cd "${HOME}"
    wget -O backhaul_linux_amd64.tar.gz "https://github.com/Musixal/Backhaul/releases/download/v0.7.1/backhaul_linux_amd64.tar.gz"
    tar -xzf backhaul_linux_amd64.tar.gz
    if [ ! -f "${HOME}/backhaul" ]; then
      recho "backhaul binary not found after extraction. Please inspect the archive contents."
      exit 1
    fi
    chmod +x "${HOME}/backhaul"
    gecho "✅ Installed: ${HOME}/backhaul"
  else
    recho "Cannot continue without backhaul."
    exit 1
  fi
}

# ===== Ensure IP forwarding (IPv4 + IPv6) =====
ensure_ip_forwarding() {
  local v4_now v6_now v4_msg v6_msg changed=0
  v4_now="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  v6_now="$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)"

  set_sysctl_conf() {
    local key="$1" value="$2" file="/etc/sysctl.conf"
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
      sed -ri "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "$file"
    else
      printf "%s=%s\n" "$key" "$value" >> "$file"
    fi
  }

  if [ "$v4_now" = "1" ]; then
    v4_msg="IPv4 forwarding: already enabled."
  else
    set_sysctl_conf "net.ipv4.ip_forward" "1"
    v4_msg="IPv4 forwarding: was disabled → enabling."
    changed=1
  fi

  if [ "$v6_now" = "1" ]; then
    v6_msg="IPv6 forwarding: already enabled."
  else
    set_sysctl_conf "net.ipv6.conf.all.forwarding" "1"
    v6_msg="IPv6 forwarding: was disabled → enabling."
    changed=1
  fi

  if [ "$changed" -eq 1 ]; then
    sysctl -p >/dev/null 2>&1 || true
  fi

  local v4_after v6_after
  v4_after="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  v6_after="$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)"

  cecho "IP Forwarding report:"
  printf "  %s (now: %s)\n" "$v4_msg" "$v4_after" >&2
  printf "  %s (now: %s)\n" "$v6_msg" "$v6_after" >&2
}

# ===== Input utilities (all prompts -> STDERR; only values -> STDOUT) =====
# Returns "VALUE|SOURCE" where SOURCE is "Default" or "Custom"
choose_port_with_default() {
  local label="$1" defv="$2" choice val src
  printf "\n" >&2
  cecho "Select ${label}:"
  printf "  [1] Default (%s)\n" "$defv" >&2
  printf "  [2] Custom (enter your own)\n" >&2
  printf "Your choice [1/2] (Enter=1): " >&2
  read -r choice; choice="${choice:-1}"
  case "$choice" in
    1) val="$defv"; src="Default" ;;
    2)
       while :; do
         printf "Enter %s: " "$label" >&2
         read -r val
         if [[ -n "$val" ]]; then src="Custom"; break; fi
         yecho "Value cannot be empty."
       done
       ;;
    *) yecho "Invalid choice. Using default (${defv})."; val="$defv"; src="Default" ;;
  esac
  printf "%s|%s" "$val" "$src"
}

ask_web_port() {
  local port=""
  printf "\n" >&2
  cecho "Enter Web Port."
  printf "Hint: choose a TCP port like 2525.\n" >&2
  while :; do
    printf "Web Port: " >&2
    read -r port
    if [[ -n "$port" ]]; then
      printf "%s" "$port"
      return
    fi
    yecho "Value cannot be empty."
  done
}

ask_number_with_hint() {
  local prompt="$1" hint="$2" val=""
  while :; do
    printf "%s (%s): " "$prompt" "$hint" >&2
    read -r val
    if [[ -n "$val" ]]; then
      printf "%s" "$val"
      return
    fi
    yecho "Value cannot be empty."
  done
}

next_conf_name() {
  local n=1 candidate
  while :; do
    candidate="${HOME}/conf${n}.toml"
    if [ ! -e "$candidate" ]; then printf "%s" "$candidate"; return; fi
    n=$((n+1))
  done
}

create_service_safely() {
  local svc_name="$1" conf_path="$2" svc_file="/etc/systemd/system/${svc_name}.service"
  if [ -e "$svc_file" ]; then
    return 2
  fi
  cat > "$svc_file" <<EOF
[Unit]
Description=Backhaul Reverse Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=${HOME}/backhaul -c ${conf_path}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  gecho "Service created: ${svc_file}"
  return 0
}

enable_start_status() {
  local svc="$1"
  cecho "systemd: daemon-reload / enable / start / status ..."
  systemctl daemon-reload
  systemctl enable "$svc" || yecho "enable returned a warning."
  if ! systemctl start "$svc"; then
    recho "Failed to start ${svc}. Showing last logs:"
    journalctl -u "$svc" -n 100 --no-pager -l || true
    exit 1
  fi
  systemctl status "$svc" --no-pager -l || true
}

# ===== IRAN (server mode) =====
configure_iran() {
  local between_port between_src web_port iran_port foreign_port conf_path svc_name

  IFS="|" read -r between_port between_src <<< "$(choose_port_with_default 'inter-server port' '10000')"
  web_port="$(ask_web_port)"
  iran_port="$(ask_number_with_hint 'Enter IRAN port' 'e.g., 30000')"
  printf "Enter foreign port (default 20820, empty=20820): " >&2
  read -r foreign_port; foreign_port="${foreign_port:-20820}"

  conf_path="$(next_conf_name)"
  cat > "$conf_path" <<EOF
[server]
bind_addr = "0.0.0.0:${between_port}"
transport = "tcp"
accept_udp = true
token = "mehdi"
keepalive_period = 10
nodelay = true
heartbeat = 40
channel_size = 2048
sniffer = false
web_port = ${web_port}
sniffer_log = "${HOME}/backhaul.json"
log_level = "info"
ports = ["${iran_port}=${foreign_port}"]
EOF

  gecho "Config created: ${conf_path}"
  cecho "Summary:"
  printf "inter port : %s ---> %s\n" "$between_src" "$between_port" >&2
  printf "web_port : %s\n" "$web_port" >&2
  printf "  iran-port:kharej-port : %s:%s\n" "$iran_port" "$foreign_port" >&2

  while :; do
    printf "\nChoose a unique systemd service name (without .service): " >&2
    read -r svc_name
    if [[ -z "$svc_name" ]]; then yecho "Service name cannot be empty."; continue; fi
    if create_service_safely "$svc_name" "$conf_path"; then
      break
    else
      yecho "Service '${svc_name}.service' already exists; please choose another name."
    fi
  done
  enable_start_status "${svc_name}.service"
}

# ===== KHAREJ (client mode) =====
configure_kharej() {
  local between_port between_src web_port iran_ip conf_path svc_name

  IFS="|" read -r between_port between_src <<< "$(choose_port_with_default 'inter-server port' '10000')"
  web_port="$(ask_web_port)"
  printf "Enter IRAN server IP to connect to: " >&2
  read -r iran_ip
  if [[ -z "$iran_ip" ]]; then recho "IRAN server IP is required."; exit 1; fi

  conf_path="$(next_conf_name)"
  cat > "$conf_path" <<EOF
[client]
remote_addr = "${iran_ip}:${between_port}"
transport = "tcp"
token = "mehdi"
connection_pool = 128
aggressive_pool = false
keepalive_period = 10
dial_timeout = 10
nodelay = true
retry_interval = 3
sniffer = false
web_port = ${web_port}
sniffer_log = "${HOME}/backhaul.json"
log_level = "info"
EOF

  gecho "Config created: ${conf_path}"
  cecho "Summary:"
  printf "inter port : %s ---> %s\n" "$between_src" "$between_port" >&2
  printf "web_port : %s\n" "$web_port" >&2
  printf "  remote_addr : %s:%s\n" "$iran_ip" "$between_port" >&2

  while :; do
    printf "\nChoose a unique systemd service name (without .service): " >&2
    read -r svc_name
    if [[ -z "$svc_name" ]]; then yecho "Service name cannot be empty."; continue; fi
    if create_service_safely "$svc_name" "$conf_path"; then
      break
    else
      yecho "Service '${svc_name}.service' already exists; please choose another name."
    fi
  done
  enable_start_status "${svc_name}.service"
}

# ===== main =====
main() {
  require_root
  ensure_backhaul
  ensure_ip_forwarding

  printf "\nWhich side do you want to configure?\n  [1] IRAN\n  [2] KHAREJ\n" >&2
  printf "Your choice [1/2]: " >&2
  local choice; read -r choice
  case "${choice}" in
    1) configure_iran ;;
    2) configure_kharej ;;
    *) recho "Invalid choice."; exit 1 ;;
  esac
}

main "$@"
