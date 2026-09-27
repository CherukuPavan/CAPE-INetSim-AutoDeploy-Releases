#!/usr/bin/env bash

ROLLBACK_FAILURES=0
ROLLBACK_CRITICAL_FAILURES=0

rollback_try() {
  local label="$1"; shift
  info "Rollback: $label"
  if ! "$@"; then
    fail "Rollback step failed: $label"
    ROLLBACK_FAILURES=$((ROLLBACK_FAILURES+1))
    return 0
  fi
}

rollback_try_critical() {
  local before="$ROLLBACK_FAILURES"
  rollback_try "$@"
  if ((ROLLBACK_FAILURES > before)); then
    ROLLBACK_CRITICAL_FAILURES=$((ROLLBACK_CRITICAL_FAILURES+1))
  fi
}

rollback_cutover_resources_exist() {
  state_has_owned_kind cape-file && return 0
  state_has_owned_kind extension && return 0
  state_has_owned_kind windows-config && return 0
  state_has_owned_kind domain-interface && return 0
  state_has_owned_kind snapshot && return 0
  state_has_owned_kind management-dhcp-host && return 0
  state_has_owned_kind routing-sysctl-file && return 0
  state_has_owned_kind routing-sysctl-runtime && return 0
  state_has_owned_kind systemd-unit && return 0
  return 1
}

rollback_prepare_cape_maintenance() {
  rollback_cutover_resources_exist || return 0
  [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]] && return 0

  # If failure happens after final handoff started, cape.service may already be
  # running. Close the scheduler BEFORE creating a new DB maintenance marker.
  # Otherwise CAPE can mutate machine lock metadata between acquire/release and
  # make the recovery guard impossible to release cleanly.
  local maintenance_needed=no
  if systemctl is-active --quiet "${CAPE_SCHEDULER_SERVICE:-__missing_scheduler__}" || systemctl is-active --quiet "${CAPE_PROCESSOR_SERVICE:-__missing_processor__}"; then
    maintenance_needed=yes
  fi
  if systemctl is-active --quiet "${CAPE_SCHEDULER_SERVICE:-__missing_scheduler__}"; then
    services_stop_scheduler_for_handoff || return 1
  fi
  if [[ "$maintenance_needed" == yes ]]; then
    cape_wait_and_acquire_maintenance "${ROLLBACK_WAIT_SECONDS:-3600}"
  fi
}

rollback_restore_cutover() {
  rollback_cutover_resources_exist || return 0

  if [[ -d "${EXTENSION_ROOT:-}" ]]; then
    rollback_try_critical "restore extension-protected CAPE web files" extension_rollback
  fi

  if state_has_owned_kind cape-file; then
    rollback_try_critical "restore CAPE configuration/source files" cape_restore_integration_files
  fi

  if state_has_owned_kind windows-config || state_has_owned_kind domain-interface || state_has_owned_kind snapshot || state_has_owned_kind domain-interface-filter || state_has_owned_kind management-dhcp-host; then
    local i
    CAPE_TARGETS_COUNT="$(targets_count)"
    for ((i=CAPE_TARGETS_COUNT-1;i>=0;i--)); do
      targets_bind "$i"
      rollback_try_critical "restore Windows pre-deployment snapshot/hardware for $CAPE_MACHINE_SECTION/$DOMAIN" windows_rollback_to_safety
      targets_capture_bound "$i"
      state_write_atomic
    done
    ((CAPE_TARGETS_COUNT > 0)) && targets_bind 0
  fi

  # Keep scheduling closed until every deployment-owned staged network resource
  # is removed. Releasing the DB guard or restarting cape.service before that
  # point creates a race in which a new task could start while rollback is still
  # dismantling its network.
  if systemctl is-active --quiet "${CAPE_SCHEDULER_SERVICE:-__missing_scheduler__}"; then
    rollback_try_critical "stop CAPE scheduler before rollback resource removal" services_stop_scheduler_for_handoff
  fi
}

rollback_remove_staged_resources() {
  if ((ROLLBACK_CRITICAL_FAILURES > 0)); then
    warn "Critical rollback restoration failed; preserving containment firewall/network/appliance resources for safe retry"
    return 0
  fi
  rollback_try "remove AutoDeploy INetSim VM/disk" inetsim_vm_rollback
  rollback_try "remove AutoDeploy-owned Rooter unit" services_remove_owned_rooter_unit
  rollback_try "remove AutoDeploy host firewall guard" firewall_rollback
  rollback_try "remove AutoDeploy isolated libvirt network" isolated_network_rollback
  rollback_try "restore AutoDeploy-started libvirt nwfilter runtime" nwfilter_runtime_rollback
}

rollback_finish_cape_handoff() {
  if ((ROLLBACK_CRITICAL_FAILURES > 0)); then
    warn "Critical rollback restoration failed; preserving CAPE maintenance ownership and leaving scheduler closed"
    return 0
  fi

  if [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]]; then
    rollback_try_critical "release CAPE maintenance lock" cape_release_maintenance
  fi
  if ((ROLLBACK_CRITICAL_FAILURES == 0)); then
    rollback_try_critical "restore original IPv4 forwarding state" routing_forwarding_rollback
    rollback_try_critical "restore original CAPE service states" services_restore_desired_state
  fi
}

autodeploy_rollback_internal() {
  if [[ -n "${CAPE_ROOT:-}" ]] && declare -F discover_cape_services >/dev/null 2>&1; then
    discover_cape_services >/dev/null 2>&1 || true
  fi
  ROLLBACK_FAILURES=0
  ROLLBACK_CRITICAL_FAILURES=0
  rollback_prepare_cape_maintenance || {
    fail "Could not acquire a task-safe CAPE rollback point"
    return 1
  }
  rollback_restore_cutover
  rollback_remove_staged_resources
  rollback_finish_cape_handoff

  if ((ROLLBACK_FAILURES == 0)); then
    state_set_phase rolled-back
    pass "Rollback completed"
    return 0
  fi

  DEPLOYMENT_PHASE=rollback-incomplete
  state_write_atomic
  fail "Rollback incomplete: $ROLLBACK_FAILURES step(s) require attention"
  return 1
}
