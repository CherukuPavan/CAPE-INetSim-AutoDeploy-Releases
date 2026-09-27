#!/usr/bin/env bash

validate_release_provenance() {
  declare -F appliance_manifest_validate >/dev/null 2>&1 || {
    fail "Appliance manifest validator is unavailable"
    return 1
  }
  appliance_manifest_validate "$APPLIANCE_MANIFEST" >/dev/null || {
    fail "Installed appliance manifest is not a published checksum-pinned release manifest"
    return 1
  }

  # Bootstrap-installed releases preserve the source bundle hash and exact
  # source commit in root-only deployment state. Development checkouts may
  # legitimately omit these fields, but a partially populated provenance tuple
  # is never accepted.
  local populated=0
  [[ -n "${RELEASE_TAG:-}" ]] && populated=$((populated+1))
  [[ -n "${RELEASE_SOURCE_BUNDLE:-}" ]] && populated=$((populated+1))
  [[ -n "${RELEASE_SOURCE_SHA256:-}" ]] && populated=$((populated+1))
  [[ -n "${RELEASE_SOURCE_COMMIT:-}" ]] && populated=$((populated+1))
  if ((populated != 0 && populated != 4)); then
    fail "Release source provenance is incomplete in deployment state"
    return 1
  fi
  if ((populated == 4)); then
    [[ "$RELEASE_TAG" =~ ^v1\.0\.0(-rc\.[0-9]+)?$ ]] || { fail "Release tag provenance is invalid"; return 1; }
    [[ "$RELEASE_SOURCE_BUNDLE" != */* && "$RELEASE_SOURCE_BUNDLE" == *.tar.gz ]] || { fail "Release source-bundle provenance is invalid"; return 1; }
    [[ "$RELEASE_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { fail "Release source SHA-256 provenance is invalid"; return 1; }
    [[ "$RELEASE_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { fail "Release source commit provenance is invalid"; return 1; }
  fi
}

validate_recovery_assets() {
  local rel backup failures=0
  if state_has_owned_kind cape-file; then
    for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
      backup="$AD_BACKUP_ROOT/${DEPLOYMENT_ID}/$rel"
      if [[ ! -f "$backup" || ! -f "$backup.sha256" ]]; then
        fail "Rollback backup is missing for CAPE file: $rel"
        failures=$((failures+1))
        continue
      fi
      if ! (cd "$(dirname "$backup")" && sha256sum -c "$(basename "$backup.sha256")" >/dev/null); then
        fail "Rollback backup checksum failed for CAPE file: $rel"
        failures=$((failures+1))
      fi
    done
  fi

  if state_has_owned_kind extension; then
    [[ -d "${EXTENSION_ROOT:-}" && -x "${EXTENSION_ROOT:-}/scripts/rollback.sh" ]] || {
      fail "Extension rollback tooling is missing"
      failures=$((failures+1))
    }
    if [[ -x "${EXTENSION_ROOT:-}/scripts/rollback.sh" ]]; then
      (cd "$EXTENSION_ROOT" && ./scripts/rollback.sh --check >/dev/null) || {
        fail "Extension rollback protection check failed"
        failures=$((failures+1))
      }
    fi
  fi

  # Per-task route separation does not mutate Windows networking or snapshots,
  # so no deployment-owned Windows safety snapshot is required.
  ((failures == 0))
}
validate_windows_result_path() {
  local f="$1"
  [[ -f "$f" ]] || { fail "Windows verification record missing: $f"; return 1; }
  ad_python - "$f" "${WINDOWS_FAKE_IP:-}" "${INETSIM_IP:-}" <<'PY'
import json,sys
path,expected_fake,expected_dns=sys.argv[1:]
with open(path,encoding="utf-8-sig") as h:
    d=json.load(h)
def req(cond,msg):
    if not cond:
        raise SystemExit(msg)
req(d.get("ok") is True,"Windows result is not ok")
req(int(d.get("default_routes",-1)) == 0,"default route count is not zero")
req(int(d.get("ipv4_default_routes",-1)) == 0,"IPv4 default route count is not zero")
req(int(d.get("ipv6_default_routes",-1)) == 0,"IPv6 default route count is not zero")
legacy=d.get("legacy_network_stack") is True
if legacy:
    req(d.get("ipv6_router_discovery_disabled") is True,"legacy IPv6 router discovery is not disabled")
else:
    req(int(d.get("ipv6_bindings_enabled",-1)) == 0,"IPv6 bindings remain enabled")
req(int(d.get("unexpected_active_adapters",-1)) == 0,"unexpected active adapter remains")
if "temporary_control_routes" in d:
    req(int(d.get("temporary_control_routes",-1)) == 0,"temporary isolated control route remains")
if "isolated_agent_rules" in d:
    req(int(d.get("isolated_agent_rules",-1)) == 0,"temporary isolated CAPE Agent firewall rule remains")
req(d.get("resultserver_reachable") is True,"ResultServer is not reachable")
req(d.get("inetsim_http_reachable") is True,"INetSim HTTP is not reachable")
req(d.get("inetsim_https_reachable") is True,"INetSim HTTPS is not reachable")
req(d.get("public_ip_reachable") is False,"public IPv4 is reachable")
req(d.get("public_ipv6_reachable") is False,"public IPv6 is reachable")
if expected_fake:
    got=d.get("fake_ip",d.get("isolated_ip",""))
    req(got == expected_fake,f"fake IP mismatch: {got!r}")
if expected_dns:
    req(d.get("dns","") == expected_dns,f"DNS mismatch: {d.get('dns')!r}")
PY
}

validate_windows_result_file() {
  [[ -n "${DOMAIN:-}" ]] || { fail "Windows domain is not bound for verification"; return 1; }
  validate_windows_result_path "$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-verify.json"
}

validate_final_snapshot_hardware() {
  local xml
  xml="$(virsh snapshot-dumpxml "$DOMAIN" "$FINAL_SNAPSHOT")" || return 1
  ad_python -c '
import sys,xml.etree.ElementTree as ET
isolated_net,isolated_mac,mgmt_net,mgmt_mac,filter_name,mgmt_ip=sys.argv[1:]
isolated_mac=isolated_mac.lower(); mgmt_mac=mgmt_mac.lower()
r=ET.fromstring(sys.stdin.read())
if (r.findtext("state") or "")!="running": raise SystemExit("snapshot state is not running")
mem=r.find("memory")
memory=(mem.get("snapshot") if mem is not None else "") or ""
if memory not in ("internal","external"):
    raise SystemExit(f"snapshot saved-memory mode is unsupported: {memory or 'missing'}")
dom=r.find("domain")
if dom is None: raise SystemExit("snapshot has no embedded domain XML")
isolated=False
mgmt_guard=False
for i in dom.findall("./devices/interface"):
    s=i.find("source"); m=i.find("mac")
    mac=(m.get("address") or "").lower() if m is not None else ""
    net=s.get("network") if s is not None else ""
    if net==isolated_net and mac==isolated_mac:
        isolated=True
    if net==mgmt_net and mac==mgmt_mac:
        refs=i.findall("filterref")
        if len(refs)==1 and (refs[0].get("filter") or "")==filter_name:
            vals=[p.get("value") or "" for p in refs[0].findall("parameter")
                  if (p.get("name") or "").upper()=="IP"]
            if vals==[mgmt_ip]:
                mgmt_guard=True
if not isolated: raise SystemExit("snapshot does not contain the isolated NIC")
if not mgmt_guard: raise SystemExit("snapshot does not preserve the Windows management anti-spoof guard")
' "$ISOLATED_NETWORK_NAME" "$WINDOWS_ISOLATED_MAC" "$MANAGEMENT_NETWORK_NAME" "$WINDOWS_MANAGEMENT_MAC" "$WINDOWS_MGMT_FILTER_NAME" "$CAPE_MACHINE_IP" <<<"$xml"
}

validate_cape_configuration() {
  ad_python - "$CAPE_ROOT" "$CAPE_MACHINE_SECTION" "$CAPE_MACHINE_LABEL" "${NORMAL_SNAPSHOT:-}" "$MANAGEMENT_BRIDGE_NAME" "$ISOLATED_BRIDGE_NAME" "$CAPE_MACHINE_IP" "$INETSIM_IP" <<'PY'
import configparser,sys
root,section,label,snapshot,mgmt_iface,inetsim_iface,machine_ip,inetsim_ip=sys.argv[1:]
def load(name):
    c=configparser.ConfigParser(interpolation=None,strict=False)
    c.optionxform=str.lower
    c.read(f"{root}/conf/{name}.conf")
    return c
k=load("kvm")
a=load("auxiliary")
p=load("processing")
r=load("routing")
if not k.has_section(section): raise SystemExit("CAPE machine section missing")
if snapshot and k.get(section,"snapshot",fallback="") != snapshot:
    raise SystemExit("CAPE normal-route snapshot mismatch")
if k.get(section,"interface",fallback="") != mgmt_iface:
    raise SystemExit("CAPE machine interface is not the management bridge")
if a.get("sniffer",f"inetsim_capture_interface_{label}",fallback="") != inetsim_iface:
    raise SystemExit("INetSim capture interface mismatch")
if a.get("sniffer",f"inetsim_capture_host_{label}",fallback="") != machine_ip:
    raise SystemExit("INetSim capture host mismatch")
if p.get("network","dnswhitelist",fallback="").lower() != "no":
    raise SystemExit("dnswhitelist not disabled")
if p.get("network","ipwhitelist",fallback="").lower() != "no":
    raise SystemExit("ipwhitelist not disabled")
if r.get("routing","enable_pcap",fallback="").lower() not in ("yes","true","1","on"):
    raise SystemExit("CAPE packet capture is disabled")
if r.get("inetsim","enabled",fallback="").lower() not in ("yes","true","1","on"):
    raise SystemExit("CAPE INetSim route is not enabled")
if r.get("inetsim","server",fallback="") != inetsim_ip:
    raise SystemExit("CAPE INetSim server mismatch")
if r.get("inetsim","interface",fallback="") != inetsim_iface:
    raise SystemExit("CAPE INetSim interface mismatch")
if r.get("inetsim","dnsport",fallback="") != "53":
    raise SystemExit("CAPE INetSim DNS port mismatch")
PY
  grep -q 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2' "$CAPE_ROOT/modules/auxiliary/sniffer.py"
}

validate_resultserver_host() {
  [[ "${CAPE_SERVICE_WAS_ACTIVE:-yes}" == yes ]] || return 0

  local ready_timeout="${CAPE_RESULTSERVER_READY_TIMEOUT:-90}"
  local poll="${CAPE_RESULTSERVER_READY_POLL:-2}"
  local elapsed=0 attempt=0 log=""
  [[ "$ready_timeout" =~ ^[1-9][0-9]*$ ]] || ready_timeout=90
  [[ "$poll" =~ ^[1-9][0-9]*$ ]] || poll=2

  if [[ -n "${AD_LOG_ROOT:-}" && -n "${DEPLOYMENT_ID:-}" ]]; then
    log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-cape-resultserver-readiness.log"
    touch "$log"
    chmod 0600 "$log" 2>/dev/null || true
  fi

  while ((elapsed < ready_timeout)); do
    attempt=$((attempt+1))
    if timeout 2 bash -c "</dev/tcp/$CAPE_RESULTSERVER_IP/$CAPE_RESULTSERVER_PORT" >/dev/null 2>&1; then
      [[ -n "$log" ]] && printf '%s machine=%s endpoint=%s:%s attempt=%s elapsed=%ss status=ready\n' \
        "$(date -Is)" "$CAPE_MACHINE_SECTION" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT" "$attempt" "$elapsed" >>"$log"
      return 0
    fi

    if [[ -n "${CAPE_SCHEDULER_SERVICE:-}" ]] && systemctl is-failed --quiet "$CAPE_SCHEDULER_SERVICE" 2>/dev/null; then
      [[ -n "$log" ]] && printf '%s machine=%s endpoint=%s:%s attempt=%s elapsed=%ss status=cape-failed\n' \
        "$(date -Is)" "$CAPE_MACHINE_SECTION" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT" "$attempt" "$elapsed" >>"$log"
      fail "CAPE scheduler failed while waiting for ResultServer readiness"
      return 1
    fi

    [[ -n "$log" ]] && printf '%s machine=%s endpoint=%s:%s attempt=%s elapsed=%ss status=waiting\n' \
      "$(date -Is)" "$CAPE_MACHINE_SECTION" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT" "$attempt" "$elapsed" >>"$log"
    sleep "$poll"
    elapsed=$((elapsed+poll))
  done

  fail "Timed out waiting ${ready_timeout}s for CAPE ResultServer readiness for $CAPE_MACHINE_SECTION at $CAPE_RESULTSERVER_IP:$CAPE_RESULTSERVER_PORT"
  return 1
}

validate_all_targets_structural() {
  local saved="${TARGET_INDEX:-}" i failures=0
  CAPE_TARGETS_COUNT="$(targets_count)"
  ((CAPE_TARGETS_COUNT > 0)) || { fail "No managed CAPE analysis targets exist in deployment state"; return 1; }

  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    [[ "${TARGET_PHASE:-}" == cape-configured || "${TARGET_PHASE:-}" == snapshots-ready ]] || {
      fail "Target $CAPE_MACHINE_SECTION is not in a structurally complete phase: ${TARGET_PHASE:-unknown}"
      failures=$((failures+1))
      continue
    }
    if [[ -n "${NORMAL_SNAPSHOT:-}" ]]; then
      virsh snapshot-info "$DOMAIN" "$NORMAL_SNAPSHOT" >/dev/null 2>&1 || {
        fail "Normal-route CAPE snapshot is missing for $CAPE_MACHINE_SECTION"
        failures=$((failures+1))
      }
    fi
    validate_cape_configuration || {
      fail "CAPE route-separated configuration validation failed for $CAPE_MACHINE_SECTION"
      failures=$((failures+1))
    }
  done
  [[ "$saved" =~ ^[0-9]+$ ]] && targets_bind "$saved"
  ((failures == 0))
}

validate_all_resultservers() {
  [[ "${CAPE_SERVICE_WAS_ACTIVE:-yes}" == yes ]] || return 0
  local saved="${TARGET_INDEX:-}" i failures=0
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    validate_resultserver_host || failures=$((failures+1))
  done
  [[ "$saved" =~ ^[0-9]+$ ]] && targets_bind "$saved"
  ((failures == 0))
}

validate_deployment_structural() {
  validate_release_provenance
  verify_isolated_network_definition "$ISOLATED_NETWORK_NAME" "$ISOLATED_BRIDGE_NAME" "$ISOLATED_SUBNET" "$BRIDGE_IP"
  firewall_verify
  routing_forwarding_verify || {
    fail "Host IPv4 forwarding prerequisite for CAPE route=inetsim is not active/persistent"
    return 1
  }
  inetsim_verify_host
  validate_all_targets_structural
  grep -Rqs 'CAPE_INETSIM_VM_ROUTE_GATED_V2' "$CAPE_ROOT/web"
  validate_recovery_assets
  pass "Structural deployment, release-provenance and recovery gates passed for all CAPE analysis machines"
}

validate_deployment_services() {
  services_validate_deployment_state
  cape_probe_inetsim_rooter_all
  validate_all_resultservers
  pass "CAPE Rooter bridge visibility, IPv4 forwarding, service and ResultServer health gates passed for all managed analysis machines"
}

