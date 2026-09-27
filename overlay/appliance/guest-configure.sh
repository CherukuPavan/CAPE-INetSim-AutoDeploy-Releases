#!/usr/bin/env bash
set -Eeuo pipefail

usage(){ echo "usage: $0 --management-mac MAC --isolated-mac MAC --ip CIDR --gateway IP [--client-ip IP ...]" >&2; exit 2; }
MGMT_MAC=""; ISO_MAC=""; CIDR=""; GATEWAY=""
CLIENT_IPS=()
while (($#)); do
  case "$1" in
    --management-mac) MGMT_MAC="${2,,}"; shift 2 ;;
    --isolated-mac) ISO_MAC="${2,,}"; shift 2 ;;
    --ip) CIDR="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --client-ip) CLIENT_IPS+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$MGMT_MAC" && -n "$ISO_MAC" && -n "$CIDR" && -n "$GATEWAY" ]] || usage
[[ "$MGMT_MAC" != "$ISO_MAC" ]] || { echo "management and isolated MACs are identical" >&2; exit 29; }

IP="${CIDR%/*}"
PYTHON="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
[[ -n "$PYTHON" ]] || { echo "Python interpreter is required inside the appliance" >&2; exit 28; }
"$PYTHON" - "$CIDR" "$GATEWAY" "${CLIENT_IPS[@]}" <<'PY'
import ipaddress,sys
n=ipaddress.ip_interface(sys.argv[1])
g=ipaddress.ip_address(sys.argv[2])
if not n.ip.is_private: raise SystemExit('isolated address must be private')
if g not in n.network: raise SystemExit('isolated gateway must be on the isolated subnet')
for raw in sys.argv[3:]:
    ipaddress.ip_address(raw)
PY

iface_for_mac() {
  local want="${1,,}" p
  for p in /sys/class/net/*; do
    [[ -f "$p/address" ]] || continue
    if [[ "$(tr '[:upper:]' '[:lower:]' <"$p/address")" == "$want" ]]; then basename "$p"; return 0; fi
  done
  return 1
}

MGMT_IF="$(iface_for_mac "$MGMT_MAC")" || { echo "management interface for MAC $MGMT_MAC not found" >&2; exit 30; }
ISO_IF="$(iface_for_mac "$ISO_MAC")" || { echo "isolated interface for MAC $ISO_MAC not found" >&2; exit 31; }
[[ "$MGMT_IF" != "$ISO_IF" ]] || { echo "management and isolated interfaces resolved to same device" >&2; exit 32; }

# Both interfaces are rendered by MAC so deploy-time interface names are never
# assumptions. Only management gets DHCP/default routing. Isolated gets no DNS,
# gateway, DHCP or link-local fallback.
cat >/etc/netplan/90-cape-inetsim.yaml <<EOF2
network:
  version: 2
  ethernets:
    cape_inetsim_management:
      match:
        macaddress: "$MGMT_MAC"
      set-name: "$MGMT_IF"
      dhcp4: true
      dhcp6: false
    cape_inetsim_isolated:
      match:
        macaddress: "$ISO_MAC"
      set-name: "$ISO_IF"
      addresses:
        - "$CIDR"
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
EOF2

if (("${#CLIENT_IPS[@]}" > 0)); then
  {
    echo "      routes:"
    for client in "${CLIENT_IPS[@]}"; do
      echo "        - to: ${client}/32"
      echo "          via: ${GATEWAY}"
    done
  } >>/etc/netplan/90-cape-inetsim.yaml
fi
chmod 0600 /etc/netplan/90-cape-inetsim.yaml

# Remove cloud-image generated network definitions so they cannot race/duplicate
# the deployment-owned MAC-based netplan.
find /etc/netplan -maxdepth 1 -type f ! -name '90-cape-inetsim.yaml' -delete
netplan generate
netplan apply

DEFAULT_ROUTE="$(ip -4 route show default)"
DEFAULTS="$(awk 'NF{n++} END{print n+0}' <<<"$DEFAULT_ROUTE")"
[[ "$DEFAULTS" -le 1 ]] || { echo "expected at most one management default route, found $DEFAULTS" >&2; exit 33; }
if [[ "$DEFAULTS" -eq 1 ]]; then
  grep -Fq "dev $MGMT_IF" <<<"$DEFAULT_ROUTE" || { echo "default route is not on management interface $MGMT_IF" >&2; exit 34; }
  ! grep -Fq "dev $ISO_IF" <<<"$DEFAULT_ROUTE" || { echo "isolated interface $ISO_IF unexpectedly has a default route" >&2; exit 35; }
fi

for client in "${CLIENT_IPS[@]}"; do
  route_ready=no
  route_result=""
  for _ in $(seq 1 30); do
    route_result="$(ip -4 route get "$client" 2>/dev/null || true)"
    if grep -Fq "via $GATEWAY dev $ISO_IF" <<<"$route_result"; then
      route_ready=yes
      break
    fi
    sleep 1
  done
  if [[ "$route_ready" != yes ]]; then
    echo "client return route is not isolated after 30 seconds: $client" >&2
    echo "--- route lookup ---" >&2
    printf '%s\n' "$route_result" >&2
    echo "--- route table ---" >&2
    ip -4 route >&2 || true
    exit 37
  fi
done

CONF=/etc/inetsim/inetsim.conf
[[ -f "$CONF.pre-autodeploy" ]] || cp -a "$CONF" "$CONF.pre-autodeploy"
"$PYTHON" - "$CONF" "$IP" <<'PY'
import re
import sys

path, ip = sys.argv[1:]
with open(path, encoding="utf-8", errors="replace") as fh:
    text = fh.read()

def set_one(text, key, value):
    # INetSim package defaults vary by distro/release: a directive can be
    # enabled, commented out, duplicated, or absent entirely. Production
    # configuration must therefore normalize exactly one active declaration
    # rather than assuming the vendor file already contains the key.
    pattern = re.compile(rf"^\s*#?\s*{re.escape(key)}(?:\s+.*)?$", re.I)
    lines = text.splitlines()
    out = []
    enabled = False
    for line in lines:
        if pattern.match(line):
            if not enabled:
                out.append(f"{key} {value}")
                enabled = True
            else:
                out.append(f"# duplicate disabled by CAPE-INetSim-AutoDeploy: {key} {value}")
        else:
            out.append(line)
    if not enabled:
        out.append(f"{key} {value}")
    return "\n".join(out) + "\n"

text = set_one(text, "service_bind_address", ip)
text = set_one(text, "dns_default_ip", ip)

# Production contract: exactly one enabled declaration for every fake-Internet
# protocol CAPE acceptance relies on. Old/commented/duplicate declarations are
# normalized deterministically instead of inheriting image history.
required = ("dns", "http", "https", "smtp", "ftp")
lines = text.splitlines()
for service in required:
    pattern = re.compile(rf"^\s*#?\s*start_service\s+{re.escape(service)}\s*$", re.I)
    out = []
    enabled = False
    for line in lines:
        if pattern.match(line):
            if not enabled:
                out.append(f"start_service {service}")
                enabled = True
            else:
                out.append(f"# duplicate disabled by CAPE-INetSim-AutoDeploy: start_service {service}")
        else:
            out.append(line)
    if not enabled:
        out.append(f"start_service {service}")
    lines = out

with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY

sysctl -w net.ipv4.ip_unprivileged_port_start=53 >/dev/null
sysctl -w net.ipv4.ip_forward=0 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null
[[ "$(sysctl -n net.ipv4.ip_unprivileged_port_start)" == 53 ]]
[[ "$(sysctl -n net.ipv4.ip_forward)" == 0 ]]
[[ "$(sysctl -n net.ipv6.conf.all.forwarding)" == 0 ]]
systemctl enable inetsim.service >/dev/null
systemctl restart inetsim.service

ready=no
ISO_ADDRS=""
UDP_LISTEN=""
TCP_LISTEN=""
for _ in $(seq 1 45); do
  ISO_ADDRS="$(ip -4 addr show dev "$ISO_IF" 2>/dev/null || true)"
  UDP_LISTEN="$(ss -lnup 2>/dev/null || true)"
  TCP_LISTEN="$(ss -lntp 2>/dev/null || true)"
  if grep -Fq "$CIDR" <<<"$ISO_ADDRS" &&
     grep -Fq "$IP:53" <<<"$UDP_LISTEN" &&
     grep -Eq "$IP:21[[:space:]]" <<<"$TCP_LISTEN" &&
     grep -Eq "$IP:25[[:space:]]" <<<"$TCP_LISTEN" &&
     grep -Eq "$IP:80[[:space:]]" <<<"$TCP_LISTEN" &&
     grep -Eq "$IP:443[[:space:]]" <<<"$TCP_LISTEN"; then
    ready=yes
    break
  fi
  sleep 1
done

if [[ "$ready" != yes ]]; then
  echo "INetSim DNS/HTTP/HTTPS/SMTP/FTP services did not become ready within 45 seconds" >&2
  echo "--- inetsim config service declarations ---" >&2
  grep -E '^[[:space:]#]*start_service[[:space:]]+(dns|http|https|smtp|ftp)' "$CONF" >&2 || true
  echo "--- ip -4 addr ---" >&2
  ip -4 addr >&2 || true
  echo "--- ip -4 route ---" >&2
  ip -4 route >&2 || true
  echo "--- listeners ---" >&2
  ss -lnupt >&2 || true
  echo "--- inetsim status ---" >&2
  systemctl status inetsim.service --no-pager -l >&2 || true
  echo "--- inetsim journal ---" >&2
  journalctl -u inetsim.service -n 150 --no-pager >&2 || true
  exit 36
fi

echo "INETSIM_GUEST_CONFIG_OK management=$MGMT_IF isolated=$ISO_IF ip=$CIDR services=dns,http,https,smtp,ftp"
