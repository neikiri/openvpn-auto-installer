#!/usr/bin/env bash
set -euo pipefail

# === COLORS ===
RED="\e[31m"
GREEN="\e[92m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"
BOLD="\e[1m"

# Disable colors if not running in terminal
if [[ ! -t 1 ]]; then
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""; BOLD=""
fi

# === LOG FUNCTIONS ===
info()  { echo -e "${BLUE}[INFO]${RESET} $1"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error() { echo -e "${RED}[ERROR]${RESET} $1"; }

# =========================
# OpenVPN manager (Ubuntu/Debian)
# Install / Remove / Reinstall
# Creates server + one client profile
# Extracts cert/key blocks strictly between BEGIN/END markers
# Auto-detects public interface (best effort)
# Author: neikiri
# GitHub: https://github.com/neikiri
# =========================

OPENVPN_DIR="/etc/openvpn"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_NAME="server"
VPN_NET="10.8.0.0"
VPN_MASK="255.255.255.0"
VPN_CIDR="10.8.0.0/24"
VPN_PORT="1194"
VPN_PROTO="udp"
SYSCTL_CONF="/etc/sysctl.d/99-openvpn.conf"
SERVER_CONF="/etc/openvpn/server.conf"
TA_KEY="/etc/openvpn/ta.key"
STATUS_LOG="/etc/openvpn/openvpn-status.log"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root (sudo)."
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

is_private_ipv4() {
  local ip="$1"
  if [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^127\. ]] || [[ "$ip" =~ ^169\.254\. ]] \
     || [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] \
     || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    return 0
  fi
  return 1
}

detect_default_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_global_ipv4_of_iface() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

detect_public_iface() {
  local def iface ip
  def="$(detect_default_iface || true)"

  if [[ -n "$def" ]]; then
    ip="$(get_global_ipv4_of_iface "$def" || true)"
    if [[ -n "$ip" ]] && ! is_private_ipv4 "$ip"; then
      echo "$def"
      return
    fi
  fi

  for iface in $(ls /sys/class/net); do
    [[ "$iface" == "lo" ]] && continue
    ip="$(get_global_ipv4_of_iface "$iface" || true)"
    if [[ -n "$ip" ]] && ! is_private_ipv4 "$ip"; then
      echo "$iface"
      return
    fi
  done

  echo "$def"
}

get_public_ip() {
  local ip=""

  # Try multiple HTTPS endpoints
  if has_cmd curl; then
    for url in \
      "https://api.ipify.org" \
      "https://ifconfig.me/ip" \
      "https://checkip.amazonaws.com" \
      "https://icanhazip.com"
    do
      ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d ' \r\n' || true)"
      if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
      fi
    done
  fi

  # DNS fallback (no HTTPS needed)
  if has_cmd dig; then
    ip="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tr -d ' \r\n' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  fi

  echo ""
  return 0
}


extract_pem_block() {
  local file="$1"
  local begin="$2"
  local end="$3"
  awk -v b="$begin" -v e="$end" '
    $0 ~ b {p=1}
    p {print}
    $0 ~ e {p=0}
  ' "$file"
}

write_server_conf() {
  cat > "$SERVER_CONF" <<EOF
port ${VPN_PORT}
proto ${VPN_PROTO}
dev tun

ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0

server ${VPN_NET} ${VPN_MASK}
ifconfig-pool-persist ipp.txt

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

keepalive 10 120
cipher AES-256-GCM

user nobody
group nogroup
persist-key
persist-tun

status openvpn-status.log
verb 5
EOF
}

enable_ip_forward() {
  echo "net.ipv4.ip_forward=1" > "$SYSCTL_CONF"
  sysctl --system >/dev/null
}

iptables_add_rules() {
  local iface="$1"

  if [[ ! -d "/sys/class/net/$iface" ]]; then
    echo "ERROR: invalid interface '$iface' (refusing to add iptables rules)"
    return 1
  fi

  # Allow OpenVPN port
  iptables -C INPUT -p udp --dport "$VPN_PORT" -j ACCEPT 2>/dev/null \
    || iptables -I INPUT -p udp --dport "$VPN_PORT" -j ACCEPT

  # Allow VPN clients to forward traffic to internet
  iptables -C FORWARD -i tun0 -o "$iface" -s "$VPN_CIDR" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i tun0 -o "$iface" -s "$VPN_CIDR" -j ACCEPT

  # Allow established traffic back to VPN clients
  iptables -C FORWARD -i "$iface" -o tun0 -d "$VPN_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 2 -i "$iface" -o tun0 -d "$VPN_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT

  # NAT VPN subnet to public interface
  iptables -t nat -C POSTROUTING -s "$VPN_CIDR" -o "$iface" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$VPN_CIDR" -o "$iface" -j MASQUERADE
}

save_firewall_rules() {
  info "Saving firewall rules..."

  mkdir -p /etc/iptables

  iptables-save > /etc/iptables/rules.v4

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi

  ok "Firewall rules saved"
}

iptables_remove_rules() {
  local iface="$1"

  while iptables -C INPUT -p udp --dport "$VPN_PORT" -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p udp --dport "$VPN_PORT" -j ACCEPT || true
  done

  if [[ -n "${iface:-}" ]]; then
    while iptables -C FORWARD -i tun0 -o "$iface" -s "$VPN_CIDR" -j ACCEPT 2>/dev/null; do
      iptables -D FORWARD -i tun0 -o "$iface" -s "$VPN_CIDR" -j ACCEPT || true
    done

    while iptables -C FORWARD -i "$iface" -o tun0 -d "$VPN_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
      iptables -D FORWARD -i "$iface" -o tun0 -d "$VPN_CIDR" -m state --state RELATED,ESTABLISHED -j ACCEPT || true
    done

    while iptables -t nat -C POSTROUTING -s "$VPN_CIDR" -o "$iface" -j MASQUERADE 2>/dev/null; do
      iptables -t nat -D POSTROUTING -s "$VPN_CIDR" -o "$iface" -j MASQUERADE || true
    done
  fi
}

stop_and_disable_service() {
  systemctl stop "openvpn@${SERVER_NAME}" >/dev/null 2>&1 || true
  systemctl disable "openvpn@${SERVER_NAME}" >/dev/null 2>&1 || true
}

do_remove() {
  need_root
  echo "== Remove OpenVPN server =="

  local iface
  iface="$(detect_public_iface || true)"

  # Stop/disable service
  stop_and_disable_service

  # Remove firewall rules (best effort)
  iptables_remove_rules "${iface:-}"
  save_firewall_rules

  # Remove sysctl forward config
  rm -f "$SYSCTL_CONF" || true
  sysctl --system >/dev/null || true

  # Remove OpenVPN config + EasyRSA PKI
  rm -rf "$EASYRSA_DIR" || true
  rm -rf "$OPENVPN_DIR" || true

  # Remove packages
  apt purge -y openvpn easy-rsa dnsutils || true
  apt autoremove -y || true

  echo "Full removal completed (configs + /etc/openvpn + packages)."
}


do_reinstall() {
  do_remove
  do_install
}


install_packages() {
  info "Installing packages..."
  apt update -y
  apt install -y curl
  apt install -y openvpn easy-rsa iptables dnsutils iptables-persistent netfilter-persistent
  ok "Packages installed"
}

setup_pki_and_keys() {
  local client="$1"

  make-cadir "$EASYRSA_DIR" >/dev/null 2>&1 || true
  cd "$EASYRSA_DIR"

  export EASYRSA_BATCH=1

  ./easyrsa init-pki
  ./easyrsa build-ca nopass
  ./easyrsa build-server-full "$SERVER_NAME" nopass
  ./easyrsa build-client-full "$client" nopass

  ./easyrsa gen-dh
  openvpn --genkey secret ta.key

  cp pki/ca.crt pki/issued/${SERVER_NAME}.crt pki/private/${SERVER_NAME}.key \
  pki/dh.pem ta.key "$OPENVPN_DIR/"

 echo "Copied keys to $OPENVPN_DIR:"
 ls -lah "$OPENVPN_DIR"/ta.key "$OPENVPN_DIR"/ca.crt "$OPENVPN_DIR"/server.crt "$OPENVPN_DIR"/server.key "$OPENVPN_DIR"/dh.pem


}

generate_client_ovpn() {
  local client="$1"
  local server_ip="$2"

  local target_user
  local target_home
  target_user="$(get_target_user)"
  target_home="$(get_target_home "$target_user")"

  local out="${target_home}/${client}.ovpn"

  mkdir -p "$target_home"
  rm -f "$out"

  cat > "$out" <<EOF
client
dev tun
proto ${VPN_PROTO}
remote ${server_ip} ${VPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3

<ca>
$(extract_pem_block "${EASYRSA_DIR}/pki/ca.crt" "BEGIN CERTIFICATE" "END CERTIFICATE")
</ca>
<cert>
$(extract_pem_block "${EASYRSA_DIR}/pki/issued/${client}.crt" "BEGIN CERTIFICATE" "END CERTIFICATE")
</cert>
<key>
$(awk '/BEGIN (RSA )?PRIVATE KEY/{p=1}p;/END (RSA )?PRIVATE KEY/{p=0}' \
"${EASYRSA_DIR}/pki/private/${client}.key")
</key>
<tls-auth>
$(awk '
  /-----BEGIN OpenVPN Static key V1-----/ {p=1}
  p {print}
  /-----END OpenVPN Static key V1-----/ {p=0}
' "$TA_KEY")
</tls-auth>
key-direction 1
EOF

  chmod 600 "$out"
  chown "$target_user:$target_user" "$out"

  ok "Client config created: $out"
  ls -lah "$out"
}

enable_and_start_service() {
  systemctl enable openvpn@server
  systemctl restart openvpn@server
}


debug_openvpn() {
  info "Checking OpenVPN config files..."

  ls -lah /etc/openvpn || true

  if [[ ! -f "$SERVER_CONF" ]]; then
    error "Server config not found: $SERVER_CONF"
    exit 1
  fi

  if [[ ! -f "$OPENVPN_DIR/ca.crt" || ! -f "$OPENVPN_DIR/server.crt" || ! -f "$OPENVPN_DIR/server.key" || ! -f "$OPENVPN_DIR/ta.key" ]]; then
    error "Some OpenVPN key/cert files are missing"
    exit 1
  fi

  ok "OpenVPN config files look present"
}

validate_iface() {
  local iface="$1"
  [[ -n "$iface" ]] && [[ -d "/sys/class/net/$iface" ]]
}

validate_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  [[ $a -le 255 && $b -le 255 && $c -le 255 && $d -le 255 ]]
}

get_target_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    echo "$SUDO_USER"
  else
    echo "root"
  fi
}

get_target_home() {
  local user="$1"
  getent passwd "$user" | cut -d: -f6
}

do_install() {
  need_root
  echo "== Install OpenVPN server =="

  read -r -p "Client name: " CLIENT
  CLIENT="${CLIENT:-client}"

  install_packages
  
  # Detect public interface AFTER packages are installed
  info "Detecting public interface..."

  IFACE="$(detect_public_iface | xargs)"

  if validate_iface "$IFACE"; then
    ok "Detected interface: $IFACE"
  else
    warn "Interface not detected automatically"
    IFACE=""
  fi

  while ! validate_iface "$IFACE"; do
    echo "Detected interface: ${IFACE:-<none>}"
    read -r -p "Enter outbound interface name (e.g. ens32): " IFACE
    IFACE="$(echo "$IFACE" | xargs)"
  done

  echo "Using interface: $IFACE"



  # Detect public IP AFTER packages are installed
  SERVER_IP="$(get_public_ip | xargs)"
	if ! validate_ipv4 "$SERVER_IP"; then
	  SERVER_IP=""
	fi

	while ! validate_ipv4 "$SERVER_IP"; do
	  echo "Detected public IP: ${SERVER_IP:-<none>}"
	  read -r -p "Enter server public IPv4 (e.g. 203.0.113.10): " SERVER_IP
	  SERVER_IP="$(echo "$SERVER_IP" | xargs)"
	done

	echo "Using server IP: $SERVER_IP"


  setup_pki_and_keys "$CLIENT"
  write_server_conf
  debug_openvpn
  enable_ip_forward
  iptables_add_rules "$IFACE"
  save_firewall_rules
  enable_and_start_service
  generate_client_ovpn "$CLIENT" "$SERVER_IP"

  TARGET_USER="$(get_target_user)"
  TARGET_HOME="$(get_target_home "$TARGET_USER")"
  
  if [[ ! -f "${TARGET_HOME}/${CLIENT}.ovpn" ]]; then
	  error "ERROR: ${TARGET_HOME}/${CLIENT}.ovpn was not created."
	  exit 1
  fi

  ok "Installation completed."
}

menu() {
  clear
  echo -e "${CYAN}${BOLD}==========================${RESET}"
  echo -e "${CYAN}${BOLD}OpenVPN Manager by neikiri${RESET}"
  echo -e "${CYAN}${BOLD}==========================${RESET}"
  echo -e "${GREEN}1) Install${RESET}"
  echo -e "${YELLOW}2) Remove${RESET}"
  echo -e "${BLUE}3) Reinstall${RESET}"
  echo -e "${RED}4) Exit${RESET}"
  echo

  read -r -p "$(echo -e ${BOLD}Select option [1-4]: ${RESET})" CH

  case "$CH" in
    1) do_install ;;
    2) do_remove ;;
    3) do_reinstall ;;
    4) exit 0 ;;
    *) echo -e "${RED}Invalid option${RESET}" ;;
  esac
}

usage() {
  echo "Usage:"
  echo "  sudo $0"
  echo "  sudo $0 install"
  echo "  sudo $0 remove"
  echo "  sudo $0 reinstall"
  echo "  sudo $0 --help"
}

case "${1:-menu}" in
  install)
    do_install
    ;;
  remove)
    do_remove
    ;;
  reinstall)
    do_reinstall
    ;;
  menu)
    menu
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    error "Unknown argument: $1"
    usage
    exit 1
    ;;
esac