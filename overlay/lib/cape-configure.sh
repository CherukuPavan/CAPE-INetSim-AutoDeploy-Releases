#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/cape-runtime.sh"

cape_post_sha_for_rel() {
  case "$1" in
    modules/auxiliary/sniffer.py) printf '%s\n' "${CAPE_POST_SHA_SNIFFER:-}" ;;
    conf/auxiliary.conf) printf '%s\n' "${CAPE_POST_SHA_AUXILIARY:-}" ;;
    conf/kvm.conf) printf '%s\n' "${CAPE_POST_SHA_KVM:-}" ;;
    conf/processing.conf) printf '%s\n' "${CAPE_POST_SHA_PROCESSING:-}" ;;
    conf/routing.conf) printf '%s\n' "${CAPE_POST_SHA_ROUTING:-}" ;;
    *) return 1 ;;
  esac
}

cape_capture_post_hashes() {
  CAPE_POST_SHA_SNIFFER="$(sha256sum "$CAPE_ROOT/modules/auxiliary/sniffer.py" | awk '{print $1}')"
  CAPE_POST_SHA_AUXILIARY="$(sha256sum "$CAPE_ROOT/conf/auxiliary.conf" | awk '{print $1}')"
  CAPE_POST_SHA_KVM="$(sha256sum "$CAPE_ROOT/conf/kvm.conf" | awk '{print $1}')"
  CAPE_POST_SHA_PROCESSING="$(sha256sum "$CAPE_ROOT/conf/processing.conf" | awk '{print $1}')"
  CAPE_POST_SHA_ROUTING="$(sha256sum "$CAPE_ROOT/conf/routing.conf" | awk '{print $1}')"
  state_write_atomic
}

cape_assert_owned_files_unchanged() {
  local rel expected current failures=0
  for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
    expected="$(cape_post_sha_for_rel "$rel" 2>/dev/null || true)"
    [[ -n "$expected" ]] || continue
    current="$(sha256sum "$CAPE_ROOT/$rel" 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$current" != "$expected" ]]; then
      fail "CAPE file changed after AutoDeploy committed it; refusing to overwrite operator/update drift: $rel"
      failures=$((failures+1))
    fi
  done
  ((failures == 0))
}

patch_sniffer_capture_override() {
  local file="$1"
  ad_python - "$file" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
marker="CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2"
if s.count(marker)==1:
    raise SystemExit(0)
if s.count(marker)>1:
    raise SystemExit("route-aware sniffer marker is ambiguous")
legacy='''        # CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1
        capture_host_key = f"capture_host_{self.machine.label}"
        host = self.options.get(capture_host_key) or self.machine.ip
        if host != self.machine.ip:
            log.info("Using packet-capture host override %s=%s", capture_host_key, host)
        # Selects per-machine interface if available.
        interface = self.machine.interface or self.options.get("interface")
'''
upstream='''        host = self.machine.ip
        # Selects per-machine interface if available.
        interface = self.machine.interface or self.options.get("interface")
'''
new='''        # CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2
        effective_route = str(self.task.route or router_cfg.routing.route or "").strip().lower()
        if effective_route == "inetsim":
            capture_interface_key = f"inetsim_capture_interface_{self.machine.label}"
            capture_host_key = f"inetsim_capture_host_{self.machine.label}"
            interface = self.options.get(capture_interface_key) or self.machine.interface or self.options.get("interface")
            host = self.options.get(capture_host_key) or self.machine.ip
            log.info("Using INetSim packet-capture path %s host=%s for route=inetsim", interface, host)
        else:
            host = self.machine.ip
            interface = self.machine.interface or self.options.get("interface")
'''
for old in (legacy, upstream):
    if old in s:
        if s.count(old)!=1:
            raise SystemExit("sniffer source block is not unique")
        open(p,"w",encoding="utf-8").write(s.replace(old,new,1))
        raise SystemExit(0)
raise SystemExit("known clean/legacy sniffer source block not found; refusing patch")
PY
}

cape_backup_integration_files() {
  local rel
  for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
    backup_file_once "$CAPE_ROOT/$rel" "$rel"
    # Mark the file as transaction-managed immediately after its protected
    # backup exists. A crash during later multi-file edits must still cause
    # rollback to restore every touched CAPE file.
    state_record_resource cape-file "$CAPE_ROOT/$rel" planned-modification yes "backup=$AD_BACKUP_ROOT/$DEPLOYMENT_ID/$rel"
  done
}

cape_configure_inetsim() {
  local edit="$AUTODEPLOY_ROOT/tools/ini_edit.py"
  [[ -x "$edit" || -f "$edit" ]] || { fail "INI editor missing"; return 1; }
  [[ -n "${ISOLATED_BRIDGE_NAME:-}" ]] || { fail "Isolated bridge name is not set"; return 1; }
  [[ "${CAPE_TARGETS_COUNT:-0}" -gt 0 ]] || { fail "No CAPE analysis targets are available for configuration"; return 1; }

  cape_backup_integration_files
  patch_sniffer_capture_override "$CAPE_ROOT/modules/auxiliary/sniffer.py"

  local saved="${TARGET_INDEX:-}" i
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    [[ -n "${MANAGEMENT_BRIDGE_NAME:-}" ]] || { fail "Management bridge is not set for $CAPE_MACHINE_SECTION"; return 1; }
    [[ -n "${NORMAL_SNAPSHOT:-}" ]] || { fail "Normal-route CAPE snapshot is not set for $CAPE_MACHINE_SECTION"; return 1; }

    ad_python "$edit" "$CAPE_ROOT/conf/auxiliary.conf" sniffer "inetsim_capture_interface_${CAPE_MACHINE_LABEL}" "$ISOLATED_BRIDGE_NAME"
    ad_python "$edit" "$CAPE_ROOT/conf/auxiliary.conf" sniffer "inetsim_capture_host_${CAPE_MACHINE_LABEL}" "$CAPE_MACHINE_IP"
    ad_python "$edit" "$CAPE_ROOT/conf/kvm.conf" "$CAPE_MACHINE_SECTION" snapshot "$NORMAL_SNAPSHOT"
    ad_python "$edit" "$CAPE_ROOT/conf/kvm.conf" "$CAPE_MACHINE_SECTION" interface "$MANAGEMENT_BRIDGE_NAME"

    grep -Fq "inetsim_capture_interface_${CAPE_MACHINE_LABEL} = $ISOLATED_BRIDGE_NAME" "$CAPE_ROOT/conf/auxiliary.conf"
    grep -Fq "inetsim_capture_host_${CAPE_MACHINE_LABEL} = $CAPE_MACHINE_IP" "$CAPE_ROOT/conf/auxiliary.conf"
    local machine_block
    machine_block="$(grep -A160 -F "[$CAPE_MACHINE_SECTION]" "$CAPE_ROOT/conf/kvm.conf" || true)"
    grep -m1 -Fq "snapshot = $NORMAL_SNAPSHOT" <<<"$machine_block"
    grep -m1 -Fq "interface = $MANAGEMENT_BRIDGE_NAME" <<<"$machine_block"

    TARGET_PHASE=cape-configured
    targets_capture_bound "$i"
  done

  ad_python "$edit" "$CAPE_ROOT/conf/processing.conf" network dnswhitelist no
  ad_python "$edit" "$CAPE_ROOT/conf/processing.conf" network ipwhitelist no
  ad_python "$edit" "$CAPE_ROOT/conf/routing.conf" routing enable_pcap yes
  ad_python "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim enabled yes
  ad_python "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim server "$INETSIM_IP"
  ad_python "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim dnsport 53
  ad_python "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim interface "$ISOLATED_BRIDGE_NAME"

  local py
  py="$(cape_runtime_python)"
  "$py" -m py_compile "$CAPE_ROOT/modules/auxiliary/sniffer.py"

  state_record_resource cape-file "$CAPE_ROOT/modules/auxiliary/sniffer.py" modified yes "route-aware-capture-override"
  state_record_resource cape-file "$CAPE_ROOT/conf/auxiliary.conf" modified yes "per-machine-inetsim-capture=${CAPE_TARGETS_COUNT}"
  state_record_resource cape-file "$CAPE_ROOT/conf/kvm.conf" modified yes "managed-machines=${CAPE_TARGETS_COUNT} normal-route-snapshot+management-interface"
  state_record_resource cape-file "$CAPE_ROOT/conf/processing.conf" modified yes "dnswhitelist=no ipwhitelist=no"
  state_record_resource cape-file "$CAPE_ROOT/conf/routing.conf" modified yes "inetsim=enabled per-task route separation enable_pcap=yes"
  cape_capture_post_hashes
  state_set_phase cape-configured

  if [[ "$saved" =~ ^[0-9]+$ ]]; then targets_bind "$saved"; else targets_bind 0; fi
}
cape_probe_inetsim_rooter_target() {
  local py
  py="$(cape_runtime_python)"

  [[ -f "$CAPE_ROOTER_EXECUTABLE" ]] || {
    fail "CAPE Rooter implementation is missing: $CAPE_ROOT/utils/rooter.py"
    return 1
  }
  grep -Fq 'def inetsim_enable(' "$CAPE_ROOTER_EXECUTABLE" || {
    fail "CAPE Rooter does not implement inetsim_enable"
    return 1
  }
  grep -Eq "['\"]inetsim_enable['\"][[:space:]]*:[[:space:]]*inetsim_enable" "$CAPE_ROOTER_EXECUTABLE" || {
    fail "CAPE Rooter does not register the inetsim_enable handler"
    return 1
  }

  (
    cd "$CAPE_ROOT"
    "$py" - "$MANAGEMENT_BRIDGE_NAME" "$ISOLATED_BRIDGE_NAME" <<'PY'
import sys
from lib.cuckoo.core.rooter import rooter

for iface in sys.argv[1:]:
    for command in ("nic_available", "nic_up"):
        response = rooter(command, iface)
        if not isinstance(response, dict):
            raise SystemExit(f"rooter {command}({iface}) returned no structured response")
        if response.get("exception"):
            raise SystemExit(f"rooter {command}({iface}) failed: {response['exception']}")
        if not response.get("output"):
            raise SystemExit(f"rooter {command}({iface}) reported unavailable/down")
PY
  ) || {
    fail "CAPE Rooter cannot see the management/INetSim bridge pair for $CAPE_MACHINE_SECTION"
    return 1
  }

  pass "CAPE Rooter runtime probe passed for $CAPE_MACHINE_SECTION: $MANAGEMENT_BRIDGE_NAME -> $ISOLATED_BRIDGE_NAME"
}

cape_probe_inetsim_rooter_all() {
  local saved="${TARGET_INDEX:-}" i failures=0
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    cape_probe_inetsim_rooter_target || failures=$((failures+1))
  done
  if [[ "$saved" =~ ^[0-9]+$ ]]; then targets_bind "$saved"; else targets_bind 0; fi
  ((failures == 0))
}

cape_restore_integration_files() {
  local rel expected current backup backup_sha failures=0
  for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
    backup="$AD_BACKUP_ROOT/${DEPLOYMENT_ID}/$rel"
    [[ -e "$backup" ]] || continue
    backup_sha="$(sha256sum "$backup" | awk '{print $1}')"
    current="$(sha256sum "$CAPE_ROOT/$rel" 2>/dev/null | awk '{print $1}' || true)"
    expected="$(cape_post_sha_for_rel "$rel" 2>/dev/null || true)"

    if [[ "$current" == "$backup_sha" ]]; then
      state_record_resource cape-file "$CAPE_ROOT/$rel" restored yes "already-predeployment"
      continue
    fi
    if [[ -n "$expected" && "$current" != "$expected" ]]; then
      fail "Refusing to rollback CAPE file changed after AutoDeploy: $rel"
      failures=$((failures+1))
      continue
    fi
    if restore_backup_file "$CAPE_ROOT/$rel" "$rel"; then
      state_record_resource cape-file "$CAPE_ROOT/$rel" restored yes ""
    else
      failures=$((failures+1))
    fi
  done
  local py
  py="$(cape_runtime_python)"
  "$py" -m py_compile "$CAPE_ROOT/modules/auxiliary/sniffer.py"
  ((failures == 0))
}
