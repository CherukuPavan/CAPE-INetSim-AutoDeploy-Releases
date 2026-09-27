#!/usr/bin/env bash

CAPE_SERVICE_READY_TIMEOUT="${CAPE_SERVICE_READY_TIMEOUT:-90}"
CAPE_SERVICE_READY_POLL="${CAPE_SERVICE_READY_POLL:-1}"
ROUTING_SYSCTL_FILE="${ROUTING_SYSCTL_FILE:-/etc/sysctl.d/99-cape-inetsim-autodeploy-routing.conf}"
AUTODEPLOY_ROOTER_UNIT="${AUTODEPLOY_ROOTER_UNIT:-cape-inetsim-rooter.service}"
AUTODEPLOY_ROOTER_UNIT_FILE="/etc/systemd/system/$AUTODEPLOY_ROOTER_UNIT"

service_active_flag() {
  [[ -n "${1:-}" ]] && systemctl is-active --quiet "$1" 2>/dev/null && printf yes || printf no
}

service_enabled_flag() {
  [[ -n "${1:-}" ]] && systemctl is-enabled --quiet "$1" 2>/dev/null && printf yes || printf no
}

service_present_flag() {
  [[ -n "${1:-}" ]] && systemctl cat "$1" >/dev/null 2>&1 && printf yes || printf no
}

routing_forwarding_apply() {
  local current
  current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"
  [[ "$current" == 0 || "$current" == 1 ]] || {
    fail "Could not read host net.ipv4.ip_forward"
    return 1
  }

  if [[ -z "${HOST_IPV4_FORWARD_WAS:-}" ]]; then
    HOST_IPV4_FORWARD_WAS="$current"
    state_write_atomic
  fi

  if [[ -e "$ROUTING_SYSCTL_FILE" ]] &&
     ! state_resource_owned routing-sysctl-file "$ROUTING_SYSCTL_FILE" &&
     ! state_resource_intended routing-sysctl-file "$ROUTING_SYSCTL_FILE"; then
    fail "Routing sysctl path exists but is not AutoDeploy-owned: $ROUTING_SYSCTL_FILE"
    return 1
  fi

  if ! state_resource_owned routing-sysctl-file "$ROUTING_SYSCTL_FILE"; then
    state_record_intent routing-sysctl-file "$ROUTING_SYSCTL_FILE" creating "net.ipv4.ip_forward=1"
    cat >"$ROUTING_SYSCTL_FILE" <<'EOF'
# CAPE-INetSim-AutoDeploy: CAPE Rooter requires IPv4 forwarding for route=inetsim.
net.ipv4.ip_forward = 1
EOF
    chmod 0644 "$ROUTING_SYSCTL_FILE"
    state_record_resource routing-sysctl-file "$ROUTING_SYSCTL_FILE" created yes "net.ipv4.ip_forward=1"
  fi

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == 1 ]] || {
    fail "Host IPv4 forwarding did not become active"
    return 1
  }

  state_record_resource routing-sysctl-runtime net.ipv4.ip_forward enabled yes "before=${HOST_IPV4_FORWARD_WAS:-unknown}"
  state_write_atomic
  pass "Host IPv4 forwarding is enabled persistently for CAPE route=inetsim"
}

routing_forwarding_verify() {
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == 1 ]] || return 1
  [[ -f "$ROUTING_SYSCTL_FILE" ]] || return 1
  grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$ROUTING_SYSCTL_FILE"
}

routing_forwarding_rollback() {
  if state_resource_owned routing-sysctl-file "$ROUTING_SYSCTL_FILE"; then
    rm -f "$ROUTING_SYSCTL_FILE"
    state_record_resource routing-sysctl-file "$ROUTING_SYSCTL_FILE" removed-by-rollback yes ""
  fi
  if state_resource_owned routing-sysctl-runtime net.ipv4.ip_forward; then
    case "${HOST_IPV4_FORWARD_WAS:-}" in
      0|1)
        sysctl -w "net.ipv4.ip_forward=$HOST_IPV4_FORWARD_WAS" >/dev/null
        state_record_resource routing-sysctl-runtime net.ipv4.ip_forward restored yes "value=$HOST_IPV4_FORWARD_WAS"
        ;;
      *)
        fail "Original net.ipv4.ip_forward state is unavailable"
        return 1
        ;;
    esac
  fi
  state_write_atomic
}

services_require_discovery() {
  [[ -n "${CAPE_ROOT:-}" ]] || { fail "CAPE root is unavailable for service discovery"; return 1; }
  if [[ -z "${CAPE_SCHEDULER_SERVICE:-}" ]]; then
    discover_cape_services
  fi
  [[ -n "${CAPE_SCHEDULER_SERVICE:-}" ]] || {
    fail "CAPE scheduler service was not discovered"
    return 1
  }
}

services_capture_original_state() {
  services_require_discovery || return 1
  CAPE_SERVICE_WAS_ACTIVE="${CAPE_SERVICE_WAS_ACTIVE:-$(service_active_flag "$CAPE_SCHEDULER_SERVICE")}"
  CAPE_PROCESSOR_WAS_ACTIVE="${CAPE_PROCESSOR_WAS_ACTIVE:-$(service_active_flag "${CAPE_PROCESSOR_SERVICE:-}")}"
  CAPE_WEB_WAS_ACTIVE="${CAPE_WEB_WAS_ACTIVE:-$(service_active_flag "${CAPE_WEB_SERVICE:-}")}"
  CAPE_ROOTER_WAS_PRESENT="${CAPE_ROOTER_WAS_PRESENT:-$(service_present_flag "${CAPE_ROOTER_SERVICE:-}")}"
  CAPE_ROOTER_WAS_ACTIVE="${CAPE_ROOTER_WAS_ACTIVE:-$(service_active_flag "${CAPE_ROOTER_SERVICE:-}")}"
  CAPE_ROOTER_WAS_ENABLED="${CAPE_ROOTER_WAS_ENABLED:-$(service_enabled_flag "${CAPE_ROOTER_SERVICE:-}")}"
  HOST_IPV4_FORWARD_WAS="${HOST_IPV4_FORWARD_WAS:-$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)}"
  state_write_atomic
}

services_stop_scheduler_for_handoff() {
  services_require_discovery || return 1
  if systemctl is-active --quiet "$CAPE_SCHEDULER_SERVICE"; then
    systemctl stop "$CAPE_SCHEDULER_SERVICE"
    CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=yes
    state_write_atomic
  fi
  if systemctl is-active --quiet "$CAPE_SCHEDULER_SERVICE"; then
    fail "CAPE scheduler service did not stop: $CAPE_SCHEDULER_SERVICE"
    return 1
  fi
  pass "CAPE scheduler stopped for final configuration handoff"
}

services_wait_expected_active() {
  local svc="$1"
  local timeout="${2:-$CAPE_SERVICE_READY_TIMEOUT}"
  local poll="${CAPE_SERVICE_READY_POLL:-1}"
  local elapsed=0 state="unknown"
  [[ -n "$svc" ]] || return 0
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=90
  [[ "$poll" =~ ^[1-9][0-9]*$ ]] || poll=1
  while ((elapsed < timeout)); do
    systemctl is-active --quiet "$svc" && return 0
    if systemctl is-failed --quiet "$svc"; then
      state="$(systemctl is-active "$svc" 2>/dev/null || true)"
      fail "Expected CAPE service entered failed state: $svc (state=${state:-unknown})"
      return 1
    fi
    sleep "$poll"
    elapsed=$((elapsed+poll))
  done
  state="$(systemctl is-active "$svc" 2>/dev/null || true)"
  fail "Timed out waiting for service readiness: $svc after ${timeout}s (state=${state:-unknown})"
  return 1
}

services_rooter_socket_path() {
  ad_python - "$CAPE_ROOT/conf/cuckoo.conf" <<'PY'
import configparser,sys
p=sys.argv[1]
c=configparser.ConfigParser(interpolation=None,strict=False)
c.read(p)
print(c.get("cuckoo","rooter",fallback="/tmp/cuckoo-rooter").strip() or "/tmp/cuckoo-rooter")
PY
}

services_rooter_socket_probe() {
  local socket_path="$1"
  ad_python - "$socket_path" <<'PY'
import json,os,socket,sys,tempfile
server=sys.argv[1]
if not os.path.exists(server):
    raise SystemExit(2)
client_path=None
s=socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM)
s.settimeout(2.0)
try:
    fd,client_path=tempfile.mkstemp(prefix="cape-inetsim-rooter-probe-",dir="/tmp")
    os.close(fd); os.unlink(client_path)
    s.bind(client_path); s.connect(server)
    s.send(json.dumps({"command":"nic_available","args":["lo"],"kwargs":{}}).encode())
    reply=json.loads(s.recv(65536))
    if not isinstance(reply,dict) or reply.get("exception") or reply.get("output") is not True:
        raise SystemExit(3)
finally:
    try: s.close()
    except Exception: pass
    if client_path:
        try: os.unlink(client_path)
        except FileNotFoundError: pass
PY
}

services_rooter_group() {
  discover_cape_runtime || return 1
  local group="${CAPE_SERVICE_GROUP:-}"
  [[ -n "$group" ]] || group="$(id -gn "${CAPE_SERVICE_USER:-root}" 2>/dev/null || true)"
  [[ -n "$group" ]] || group=root
  printf '%s\n' "$group"
}

services_systemd_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

services_ensure_rooter_service() {
  services_require_discovery || return 1
  if [[ -n "${CAPE_ROOTER_SERVICE:-}" ]] && systemctl cat "$CAPE_ROOTER_SERVICE" >/dev/null 2>&1; then
    return 0
  fi

  [[ -n "${CAPE_ROOTER_EXECUTABLE:-}" && -f "$CAPE_ROOTER_EXECUTABLE" ]] || {
    discover_cape_services
  }
  [[ -n "${CAPE_ROOTER_EXECUTABLE:-}" && -f "$CAPE_ROOTER_EXECUTABLE" ]] || {
    fail "CAPE Rooter executable could not be discovered; cannot create route control plane"
    return 1
  }

  discover_cape_runtime || return 1
  local socket_path group py_q rooter_q root_q socket_q
  socket_path="$(services_rooter_socket_path)"
  group="$(services_rooter_group)" || return 1
  py_q="$(services_systemd_escape "$CAPE_RUNTIME_PYTHON")"
  rooter_q="$(services_systemd_escape "$CAPE_ROOTER_EXECUTABLE")"
  root_q="$(services_systemd_escape "$CAPE_ROOT")"
  socket_q="$(services_systemd_escape "$socket_path")"

  if [[ -e "$AUTODEPLOY_ROOTER_UNIT_FILE" ]] &&
     ! state_resource_owned systemd-unit "$AUTODEPLOY_ROOTER_UNIT_FILE" &&
     ! state_resource_intended systemd-unit "$AUTODEPLOY_ROOTER_UNIT_FILE"; then
    fail "AutoDeploy Rooter unit path exists but is not transaction-owned: $AUTODEPLOY_ROOTER_UNIT_FILE"
    return 1
  fi

  if ! state_resource_owned systemd-unit "$AUTODEPLOY_ROOTER_UNIT_FILE"; then
    state_record_intent systemd-unit "$AUTODEPLOY_ROOTER_UNIT_FILE" creating "rooter=$CAPE_ROOTER_EXECUTABLE"
    cat >"$AUTODEPLOY_ROOTER_UNIT_FILE" <<EOF
[Unit]
Description=CAPE Rooter managed by CAPE-INetSim-AutoDeploy
After=network.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory="$root_q"
ExecStart="$py_q" "$rooter_q" "$socket_q" -g "$group"
User=root
Group=root
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$AUTODEPLOY_ROOTER_UNIT_FILE"
    systemctl daemon-reload
    state_record_resource systemd-unit "$AUTODEPLOY_ROOTER_UNIT_FILE" created yes "unit=$AUTODEPLOY_ROOTER_UNIT"
  fi

  CAPE_ROOTER_SERVICE="$AUTODEPLOY_ROOTER_UNIT"
  state_write_atomic
  pass "Created AutoDeploy-owned CAPE Rooter service from discovered CAPE runtime"
}

services_wait_rooter_ready() {
  local timeout="${1:-$CAPE_SERVICE_READY_TIMEOUT}"
  local poll="${CAPE_SERVICE_READY_POLL:-1}"
  local elapsed=0 socket_path log="" svc="${CAPE_ROOTER_SERVICE:-}"
  [[ -n "$svc" ]] || { fail "CAPE Rooter service is not selected"; return 1; }
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=90
  [[ "$poll" =~ ^[1-9][0-9]*$ ]] || poll=1
  socket_path="$(services_rooter_socket_path)"

  if [[ -n "${AD_LOG_ROOT:-}" && -n "${DEPLOYMENT_ID:-}" ]]; then
    log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-cape-rooter-readiness.log"
    : >"$log"; chmod 0600 "$log" 2>/dev/null || true
  fi

  while ((elapsed < timeout)); do
    if systemctl is-failed --quiet "$svc" 2>/dev/null; then
      [[ -n "$log" ]] && {
        printf '%s elapsed=%ss status=service-failed socket=%s unit=%s\n' "$(date -Is)" "$elapsed" "$socket_path" "$svc"
        systemctl status "$svc" --no-pager -l 2>&1 || true
        journalctl -u "$svc" -n 200 --no-pager 2>&1 || true
      } >>"$log"
      fail "$svc entered failed state before its Rooter socket became ready"
      return 1
    fi

    if systemctl is-active --quiet "$svc" &&
       [[ -S "$socket_path" ]] &&
       services_rooter_socket_probe "$socket_path" >/dev/null 2>&1; then
      [[ -n "$log" ]] && printf '%s elapsed=%ss status=ready socket=%s unit=%s\n' "$(date -Is)" "$elapsed" "$socket_path" "$svc" >>"$log"
      return 0
    fi
    [[ -n "$log" ]] && printf '%s elapsed=%ss status=waiting socket=%s unit=%s\n' "$(date -Is)" "$elapsed" "$socket_path" "$svc" >>"$log"
    sleep "$poll"; elapsed=$((elapsed+poll))
  done

  if [[ -n "$log" ]]; then
    {
      echo "=== rooter service ==="; systemctl status "$svc" --no-pager -l 2>&1 || true
      echo "=== rooter journal ==="; journalctl -u "$svc" -n 250 --no-pager 2>&1 || true
      echo "=== socket ==="; ls -l "$socket_path" 2>&1 || true
      echo "=== unix socket table ==="; ss -xlpn 2>&1 | grep -F "$socket_path" || true
    } >>"$log"
  fi
  fail "Timed out waiting ${timeout}s for a live CAPE Rooter response at $socket_path (unit $svc)"
  return 1
}

services_prepare_route_control_plane() {
  services_ensure_rooter_service || return 1
  routing_forwarding_verify || routing_forwarding_apply || return 1
  systemctl enable "$CAPE_ROOTER_SERVICE" >/dev/null
  systemctl reset-failed "$CAPE_ROOTER_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$CAPE_ROOTER_SERVICE"
  services_wait_expected_active "$CAPE_ROOTER_SERVICE" "$CAPE_SERVICE_READY_TIMEOUT" || return 1
  services_wait_rooter_ready "$CAPE_SERVICE_READY_TIMEOUT" || return 1
  pass "CAPE Rooter control plane and Unix socket are ready for route=inetsim validation"
}

services_start_if_expected() {
  local svc="$1" expected="$2"
  [[ -n "$svc" ]] || return 0
  if [[ "$expected" == yes ]]; then
    systemctl restart "$svc"
    services_wait_expected_active "$svc" "$CAPE_SERVICE_READY_TIMEOUT"
  else
    systemctl stop "$svc" >/dev/null 2>&1 || true
  fi
}

services_activate_deployment_state() {
  services_prepare_route_control_plane || return 1
  services_start_if_expected "${CAPE_PROCESSOR_SERVICE:-}" "${CAPE_PROCESSOR_WAS_ACTIVE:-no}" || return 1
  services_start_if_expected "${CAPE_WEB_SERVICE:-}" "${CAPE_WEB_WAS_ACTIVE:-no}" || return 1
  services_start_if_expected "$CAPE_SCHEDULER_SERVICE" "${CAPE_SERVICE_WAS_ACTIVE:-no}" || return 1
  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
  state_write_atomic
  pass "CAPE services restored and Rooter/IPv4 forwarding are ready for route=inetsim"
}

services_restore_desired_state() {
  services_start_if_expected "${CAPE_PROCESSOR_SERVICE:-}" "${CAPE_PROCESSOR_WAS_ACTIVE:-no}" || return 1
  services_start_if_expected "${CAPE_WEB_SERVICE:-}" "${CAPE_WEB_WAS_ACTIVE:-no}" || return 1

  if [[ -n "${CAPE_ROOTER_SERVICE:-}" ]]; then
    if [[ "${CAPE_ROOTER_WAS_ACTIVE:-no}" == yes ]]; then
      systemctl start "$CAPE_ROOTER_SERVICE" >/dev/null 2>&1 || true
    else
      systemctl stop "$CAPE_ROOTER_SERVICE" >/dev/null 2>&1 || true
    fi
    if [[ "${CAPE_ROOTER_WAS_ENABLED:-no}" == yes ]]; then
      systemctl enable "$CAPE_ROOTER_SERVICE" >/dev/null 2>&1 || true
    else
      systemctl disable "$CAPE_ROOTER_SERVICE" >/dev/null 2>&1 || true
    fi
  fi

  services_start_if_expected "$CAPE_SCHEDULER_SERVICE" "${CAPE_SERVICE_WAS_ACTIVE:-no}" || return 1
  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
  state_write_atomic
}

services_remove_owned_rooter_unit() {
  if state_resource_owned systemd-unit "$AUTODEPLOY_ROOTER_UNIT_FILE"; then
    systemctl stop "$AUTODEPLOY_ROOTER_UNIT" >/dev/null 2>&1 || true
    systemctl disable "$AUTODEPLOY_ROOTER_UNIT" >/dev/null 2>&1 || true
    rm -f "$AUTODEPLOY_ROOTER_UNIT_FILE"
    systemctl daemon-reload
    state_record_resource systemd-unit "$AUTODEPLOY_ROOTER_UNIT_FILE" removed-by-rollback yes ""
    if [[ "${CAPE_ROOTER_SERVICE:-}" == "$AUTODEPLOY_ROOTER_UNIT" ]]; then
      CAPE_ROOTER_SERVICE=""
    fi
    state_write_atomic
  fi
}

services_validate_restored_state() {
  local svc flag
  for pair in "scheduler|${CAPE_SCHEDULER_SERVICE:-}|${CAPE_SERVICE_WAS_ACTIVE:-no}" \
              "processor|${CAPE_PROCESSOR_SERVICE:-}|${CAPE_PROCESSOR_WAS_ACTIVE:-no}" \
              "web|${CAPE_WEB_SERVICE:-}|${CAPE_WEB_WAS_ACTIVE:-no}"; do
    IFS='|' read -r _ svc flag <<<"$pair"
    [[ -n "$svc" ]] || continue
    [[ "$flag" == yes ]] && services_wait_expected_active "$svc" "$CAPE_SERVICE_READY_TIMEOUT" || true
  done
}

services_validate_deployment_state() {
  services_validate_restored_state || return 1
  [[ -n "${CAPE_ROOTER_SERVICE:-}" ]] || { fail "CAPE Rooter service is not selected"; return 1; }
  systemctl is-active --quiet "$CAPE_ROOTER_SERVICE" || {
    fail "$CAPE_ROOTER_SERVICE is not active; route=inetsim cannot function"; return 1;
  }
  systemctl is-enabled --quiet "$CAPE_ROOTER_SERVICE" || {
    fail "$CAPE_ROOTER_SERVICE is not enabled persistently"; return 1;
  }
  services_wait_rooter_ready "$CAPE_SERVICE_READY_TIMEOUT" || return 1
  routing_forwarding_verify || {
    fail "Host IPv4 forwarding prerequisite for route=inetsim is not active/persistent"; return 1;
  }
}
