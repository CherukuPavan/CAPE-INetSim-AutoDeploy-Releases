#!/usr/bin/env bash

run_discovery() {
  DISCOVERY_ERRORS=(); COMPAT_NOTES=(); REQUESTED_MACHINE="${REQUESTED_MACHINE:-}"
  discover_cape_root
  discover_cape_git
  discover_cape_database_backend
  discover_cape_services
  discover_cape_machine_records
  discover_libvirt
  plan_isolated_subnet

  # Default mode discovers every enabled Windows-compatible CAPE analysis VM.
  # Each one receives an independently verified management identity and a
  # unique fake-Internet address on the shared isolated network.
  targets_discover_all
  targets_prepare_after_network_plan

  discover_hypervisor_safety_features
  discover_busy_state
  check_cape_layout
  discover_resources
}

print_plan() {
  echo
  echo "============================================================"
  echo " ${AD_NAME} ${AD_VERSION} -- READ-ONLY PLAN"
  echo "============================================================"
  echo
  [[ -n "${CAPE_ROOT:-}" ]] && pass "CAPE installation discovered" || fail "CAPE installation not uniquely discovered"
  [[ -n "${LIBVIRT_URI:-}" ]] && pass "KVM/libvirt discovered" || fail "KVM/libvirt unavailable"
  [[ "${CAPE_TARGETS_COUNT:-0}" =~ ^[0-9]+$ && "${CAPE_TARGETS_COUNT:-0}" -gt 0 ]] &&
    pass "CAPE analysis target set discovered (${CAPE_TARGETS_COUNT} machine(s))" ||
    fail "No deployable CAPE analysis target set discovered"
  [[ -n "${ISOLATED_SUBNET:-}" ]] && pass "Unused isolated-network candidate selected" || fail "No isolated-network candidate selected"

  echo; echo "Discovery"
  kv "CAPE root:" "${CAPE_ROOT:-NOT FOUND}"
  kv "CAPE commit:" "${CAPE_COMMIT:-unknown}"
  kv "CAPE branch:" "${CAPE_BRANCH:-unknown}"
  kv "CAPE working tree dirty:" "${CAPE_DIRTY:-unknown}"
  kv "CAPE database backend:" "${CAPE_DB_BACKEND:-unknown}"
  kv "libvirt URI:" "${LIBVIRT_URI:-unknown}"
  kv "CAPE analysis target count:" "${CAPE_TARGETS_COUNT:-0}"
  echo "  Analysis targets:"
  targets_summary_lines | sed 's/^/    /'
  kv "libvirt clean-traffic nwfilter:" "${MANAGEMENT_NWFILTER_AVAILABLE:-unknown}"
  kv "nwfilter runtime mode:" "${NWFILTER_RUNTIME_MODE:-unknown}"

  echo; echo "Windows control"
  echo "  Backend discovery is recorded independently for every CAPE analysis VM."
  echo "  Powered-off guests are probed again automatically during safe cutover."

  echo; echo "Network plan"
  kv "isolated subnet:" "${ISOLATED_SUBNET:-unavailable}"
  kv "bridge address:" "${BRIDGE_IP:-unavailable}"
  kv "INetSim address:" "${INETSIM_IP:-unavailable}"
  kv "Windows guest networking:" "preserved unchanged"
  kv "Fake Internet selection:" "CAPE route=inetsim (per task)"
  kv "CAPE INetSim capture:" "${ISOLATED_BRIDGE_NAME:-planned isolated bridge}; source remains original CAPE VM IP"

  echo; echo "Deployment decision"
  kv "decision:" "${DEPLOYMENT_DECISION:-unknown}"
  kv "reason:" "${DEPLOYMENT_DECISION_REASON:-unknown}"

  echo; echo "Safety / compatibility"
  kv "CAPE busy signal:" "${CAPE_BUSY:-unknown}"
  kv "busy reason:" "${BUSY_REASON:-unknown}"
  kv "compatibility state:" "${COMPAT_STATUS:-unknown}"
  kv "compatibility notes:" "$(IFS=,; echo "${COMPAT_NOTES[*]:-none}")"
  kv "host RAM total KiB:" "${HOST_MEM_KIB:-unknown}"
  kv "host RAM available KiB:" "${HOST_MEM_AVAILABLE_KIB:-unknown}"
  kv "selected libvirt storage pool:" "${LIBVIRT_STORAGE_POOL:-unknown}"
  kv "selected libvirt storage path:" "${LIBVIRT_STORAGE_PATH:-unknown}"
  kv "selected pool free KiB:" "${LIBVIRT_FREE_KIB:-unknown}"

  echo; echo "Future deployment will create/configure"
  echo "  - generalized Ubuntu INetSim appliance"
  echo "  - isolated libvirt network with no NAT/default gateway"
  echo "  - no changes to Windows NICs, IPs, DNS, gateways, DHCP, or snapshots"
  echo "  - CAPE native route=inetsim mapped to the isolated appliance"
  echo "  - route-aware packet capture: normal interface for internet, isolated bridge for inetsim"
  echo "  - Network Analysis visibility for simulated traffic"
  echo "  - CAPE-INetSim-VM-Extension integration"

  echo
  if ((${#DISCOVERY_ERRORS[@]})); then
    echo "Blocking/ambiguous findings"; printf '  - %s\n' "${DISCOVERY_ERRORS[@]}"; echo
    echo "RESULT: PLAN INCOMPLETE -- SAFE STOP"
  elif [[ "${COMPAT_STATUS:-blocked}" != "plan-compatible" ]]; then
    echo "RESULT: CAPE LAYOUT NOT APPROVED FOR MUTATION -- SAFE STOP"
  else
    echo "RESULT: DEPLOYMENT PLAN DISCOVERED AND COMPATIBLE"
    [[ "${CAPE_BUSY:-unknown}" == "yes" ]] && echo "CUTOVER: must wait for a task-aware safe idle point"
  fi
  echo "NO SYSTEM CONFIGURATION WAS CHANGED"
  echo "============================================================"
}
