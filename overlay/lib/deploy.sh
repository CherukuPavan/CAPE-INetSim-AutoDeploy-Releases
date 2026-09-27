#!/usr/bin/env bash

DEPLOY_WAIT_SECONDS="${DEPLOY_WAIT_SECONDS:-3600}"

deploy_phase_rank() {
  case "$1" in
    planned) echo 10 ;;
    isolated-network-ready) echo 20 ;;
    appliance-defined) echo 30 ;;
    appliance-configured) echo 40 ;;
    staged) echo 50 ;;
    maintenance-acquired) echo 60 ;;
    windows-nic-attached) echo 70 ;;
    windows-configured) echo 80 ;;
    windows-running-snapshot|windows-working-snapshot) echo 90 ;;
    windows-snapshots-ready|windows-all-ready) echo 100 ;;
    cape-configured) echo 110 ;;
    extension-installed) echo 120 ;;
    handoff-complete) echo 130 ;;
    committed) echo 140 ;;
    *) echo -1 ;;
  esac
}

deploy_phase_at_least() {
  local current want cr wr
  current="${DEPLOYMENT_PHASE:-}"
  want="$1"
  cr="$(deploy_phase_rank "$current")"
  wr="$(deploy_phase_rank "$want")"
  [[ "$cr" -ge 0 && "$wr" -ge 0 && "$cr" -ge "$wr" ]]
}

deploy_phase_is_resumable() {
  [[ "$(deploy_phase_rank "${DEPLOYMENT_PHASE:-}")" -ge 0 ]]
}

deploy_required_commands() {
  local -a missing=()
  local cmd
  for cmd in virsh qemu-img virt-install curl flock ip systemctl sysctl tar gzip sha256sum base64 timeout nft; do
    have "$cmd" || missing+=("$cmd")
  done
  [[ -n "${AD_HOST_PYTHON:-}" && -x "${AD_HOST_PYTHON:-}" ]] || missing+=("Python>=3.10")
  if (("${#missing[@]}")); then
    fail "Missing required host command(s): ${missing[*]}"
    return 1
  fi
}

deploy_assert_supported_environment() {
  if ((${#DISCOVERY_ERRORS[@]})); then
    fail "Discovery has blocking findings:"
    printf '  - %s\n' "${DISCOVERY_ERRORS[@]}" >&2
    return 1
  fi
  [[ "${COMPAT_STATUS:-}" == plan-compatible ]] || {
    fail "CAPE source layout is not approved for mutation: ${COMPAT_STATUS:-unknown}"
    return 1
  }
  [[ "${LIBVIRT_URI:-}" == qemu:///system ]] || {
    fail "AutoDeploy requires the system libvirt instance (found: ${LIBVIRT_URI:-unknown})"
    return 1
  }
  [[ "${CAPE_DB_BACKEND:-unknown}" == postgresql ]] || {
    fail "v1.0 automated live cutover currently requires CAPE PostgreSQL for atomic scheduler maintenance locking (found: ${CAPE_DB_BACKEND:-unknown}); safe stop, no mutation."
    return 1
  }
  [[ "${CAPE_TARGETS_COUNT:-0}" =~ ^[0-9]+$ && "${CAPE_TARGETS_COUNT:-0}" -gt 0 ]] || {
    fail "No CAPE Windows analysis targets were discovered"
    return 1
  }
  ad_python - "${CAPE_TARGETS_JSON:-[]}" <<'PY' || {
import json,sys
a=json.loads(sys.argv[1])
assert a, "empty target set"
for d in a:
    platform=str(d.get("platform") or "windows-unspecified").lower()
    assert platform.startswith("windows"), f"{d.get('section','?')}: not a Windows CAPE analysis machine"
    assert d.get("domain"), f"{d.get('section','?')}: no libvirt domain"
    assert d.get("snapshot_capable")=="yes", f"{d.get('section','?')}: qcow2 internal snapshots not proven"
    assert d.get("analysis_snapshot_status") in ("proven","not-configured"), f"{d.get('section','?')}: existing CAPE snapshot is not safe/proven"
    assert d.get("management_network"), f"{d.get('section','?')}: management network unknown"
    assert d.get("management_bridge"), f"{d.get('section','?')}: management bridge unknown"
    assert d.get("management_mac"), f"{d.get('section','?')}: management MAC unknown"
    assert d.get("resultserver_ip"), f"{d.get('section','?')}: ResultServer IP unknown"
    assert str(d.get("resultserver_port","")).isdigit(), f"{d.get('section','?')}: ResultServer port invalid"
PY
    fail "One or more CAPE analysis VMs failed the multi-machine safety preflight"
    return 1
  }
  [[ -n "${MANAGEMENT_NETWORK_NAME:-}" ]] || { fail "Management libvirt network is unknown"; return 1; }
  [[ -n "${CAPE_RESULTSERVER_IP:-}" && "${CAPE_RESULTSERVER_PORT:-}" =~ ^[0-9]+$ ]] || {
    fail "CAPE ResultServer path could not be derived"
    return 1
  }

  # A brand-new deployment needs the scheduler/ResultServer alive before the
  # CAPE routing/extension handoff. A completed
  # rollback is also a fresh deployment boundary; only an actually resumable
  # transaction may legitimately have cape.service stopped at handoff.
  local existing_phase=""
  if [[ -f "$AD_STATE_FILE" ]]; then
    existing_phase="$( (state_load >/dev/null 2>&1 && printf '%s' "$DEPLOYMENT_PHASE") || true )"
  fi
  if [[ ! -f "$AD_STATE_FILE" || "$existing_phase" == rolled-back ]]; then
    [[ -n "${CAPE_SCHEDULER_SERVICE:-}" ]] || { fail "CAPE scheduler service was not discovered"; return 1; }
    systemctl is-active --quiet "$CAPE_SCHEDULER_SERVICE" || {
      fail "CAPE scheduler service must be active before a new deployment: $CAPE_SCHEDULER_SERVICE"
      return 1
    }
    if grep -Eq 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V(1|2)' "$CAPE_ROOT/modules/auxiliary/sniffer.py" 2>/dev/null; then
      fail "An untracked AutoDeploy sniffer patch already exists; refusing to claim or overwrite it"
      return 1
    fi
    if grep -RqsE 'CAPE_INETSIM_VM_ROUTE_(NONE_V1|GATED_V2)' "$CAPE_ROOT/web" 2>/dev/null; then
      fail "An untracked CAPE-INetSim VM extension is already installed; refusing to claim or overwrite it"
      return 1
    fi
  fi

  deploy_required_commands
  appliance_manifest_validate "$APPLIANCE_MANIFEST" >/dev/null || {
    fail "Generalized INetSim appliance is not a published, checksum-pinned release artifact"
    return 1
  }
}

deploy_reset_resource_state() {
  ISOLATED_NETWORK_NAME=""
  ISOLATED_BRIDGE_NAME=""
  LIBVIRT_STORAGE_POOL=""
  LIBVIRT_STORAGE_PATH=""
  INETSIM_DOMAIN_NAME="cape-inetsim-appliance"
  INETSIM_DISK_PATH=""
  INETSIM_MANAGEMENT_MAC=""
  INETSIM_ISOLATED_MAC=""
  WINDOWS_ISOLATED_NIC_MODEL=""
  WINDOWS_ISOLATED_MAC=""
  WINDOWS_BACKEND_USED=""
  WINDOWS_ORIGINAL_DOMAIN_STATE=""
  SAFETY_SNAPSHOT=""
  WORKING_SNAPSHOT=""
  FINAL_SNAPSHOT=""
  CAPE_POST_SHA_SNIFFER=""
  CAPE_POST_SHA_AUXILIARY=""
  CAPE_POST_SHA_KVM=""
  CAPE_POST_SHA_PROCESSING=""
  CAPE_POST_SHA_ROUTING=""
  CAPE_SERVICE_WAS_ACTIVE=""
  CAPE_PROCESSOR_WAS_ACTIVE=""
  CAPE_WEB_WAS_ACTIVE=""
  CAPE_ROOTER_WAS_ACTIVE=""
  CAPE_ROOTER_WAS_ENABLED=""
  HOST_IPV4_FORWARD_WAS=""
  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
}

deploy_recovery_mutable_owned_kinds() {
  cat <<'EOF'
cape-file
extension
windows-config
domain-interface
snapshot
management-dhcp-host
domain-interface-filter
cape-maintenance
libvirt-network
disk
domain
inetsim-guest
firewall-management-guard
firewall-file
firewall-unit
firewall-table
routing-sysctl-file
routing-sysctl-runtime
libvirt-service
libvirt-unit-enable
systemd-unit
EOF
}

deploy_verify_recovered_transaction_clean() {
  local kind failures=0
  while IFS= read -r kind; do
    [[ -n "$kind" ]] || continue
    if state_has_owned_kind "$kind"; then
      fail "Recovered transaction still owns mutable resource kind: $kind"
      failures=$((failures+1))
    fi
  done < <(deploy_recovery_mutable_owned_kinds)

  if [[ -e "$CAPE_MAINTENANCE_GUARD_FILE" ]]; then
    fail "Recovered transaction still has a CAPE maintenance guard: $CAPE_MAINTENANCE_GUARD_FILE"
    failures=$((failures+1))
  fi

  ((failures == 0)) || return 1
  services_validate_restored_state || {
    fail "Recovered transaction did not restore expected CAPE service readiness"
    return 1
  }
}

deploy_recover_incomplete_rollback() {
  [[ "${DEPLOYMENT_PHASE:-}" == rollback-incomplete ]] || return 0

  local old_id="${DEPLOYMENT_ID:-unknown}"
  warn "Previous AutoDeploy transaction $old_id is rollback-incomplete; attempting ownership-aware recovery before starting a new deployment."

  autodeploy_rollback_internal || {
    fail "Automatic recovery of rollback-incomplete transaction $old_id did not complete safely"
    return 1
  }

  [[ "${DEPLOYMENT_PHASE:-}" == rolled-back ]] || {
    fail "Recovery returned without reaching rolled-back phase: ${DEPLOYMENT_PHASE:-unknown}"
    return 1
  }

  deploy_verify_recovered_transaction_clean || {
    fail "Recovered transaction $old_id still has owned mutable state; refusing a fresh deployment"
    return 1
  }

  pass "Recovered previous rollback-incomplete transaction $old_id to a clean rolled-back state"
}
deploy_initialize_or_resume_state() {
  local d_root="$CAPE_ROOT" d_commit="$CAPE_COMMIT" d_db="$CAPE_DB_BACKEND"
  local d_targets_json="${CAPE_TARGETS_JSON:-[]}"
  local d_targets_identity
  d_targets_identity="$(targets_identity_sha256)"
  local d_subnet="$ISOLATED_SUBNET" d_bridge_ip="$BRIDGE_IP" d_inetsim_ip="$INETSIM_IP"
  local d_storage_pool="${LIBVIRT_STORAGE_POOL:-}" d_storage_path="${LIBVIRT_STORAGE_PATH:-}"
  local d_release_tag="${CAPE_INETSIM_RELEASE_TAG:-}"
  local d_release_bundle="${CAPE_INETSIM_RELEASE_SOURCE_BUNDLE:-}"
  local d_release_sha="${CAPE_INETSIM_RELEASE_SOURCE_SHA256:-}"
  local d_release_commit="${CAPE_INETSIM_RELEASE_SOURCE_COMMIT:-}"

  if [[ -f "$AD_STATE_FILE" ]]; then
    state_load

    if [[ "${DEPLOYMENT_PHASE:-}" == committed &&
          -n "${RELEASE_SOURCE_COMMIT:-}" &&
          -n "$d_release_commit" &&
          "$RELEASE_SOURCE_COMMIT" != "$d_release_commit" ]]; then
      fail "A different AutoDeploy release is already committed (${RELEASE_TAG:-unknown}, source ${RELEASE_SOURCE_COMMIT}). Roll it back with that exact release before installing this route-separated release."
      return 1
    fi

    if [[ "${DEPLOYMENT_PHASE:-}" == rollback-incomplete ]]; then
      # Auto-recovery is permitted only when the persisted transaction still
      # refers to the exact CAPE installation and target identity discovered
      # for this run. Never auto-clean state after manual topology/source drift.
      [[ "$CAPE_ROOT" == "$d_root" ]] || { fail "Rollback-incomplete state belongs to a different CAPE root"; return 1; }
      [[ "$CAPE_COMMIT" == "$d_commit" ]] || { fail "CAPE commit changed since the rollback-incomplete transaction; refusing automatic recovery"; return 1; }
      [[ "$CAPE_DB_BACKEND" == "$d_db" ]] || { fail "CAPE database backend changed since the rollback-incomplete transaction; refusing automatic recovery"; return 1; }
      [[ "${CAPE_TARGETS_IDENTITY_SHA256:-}" == "$d_targets_identity" ]] || {
        fail "Enabled CAPE analysis-machine identity changed since the rollback-incomplete transaction; refusing automatic recovery"
        return 1
      }
      CAPE_TARGETS_COUNT="$(targets_count)"
      ((CAPE_TARGETS_COUNT > 0)) || { fail "Rollback-incomplete state contains no CAPE analysis targets"; return 1; }
      targets_bind 0
      deploy_recover_incomplete_rollback || return 1
    fi

    if [[ "${DEPLOYMENT_PHASE:-}" != rolled-back ]]; then
      deploy_phase_is_resumable || {
        fail "Existing state is not a resumable deployment phase: ${DEPLOYMENT_PHASE:-unknown}"
        return 1
      }
      [[ "$CAPE_ROOT" == "$d_root" ]] || { fail "Existing deployment state belongs to a different CAPE root"; return 1; }
      [[ "$CAPE_COMMIT" == "$d_commit" ]] || { fail "CAPE commit changed during/after deployment; use verify/repair compatibility flow"; return 1; }
      [[ "$CAPE_DB_BACKEND" == "$d_db" ]] || { fail "CAPE database backend changed during/after deployment; refusing resume"; return 1; }
      [[ "${CAPE_TARGETS_IDENTITY_SHA256:-}" == "$d_targets_identity" ]] || {
        fail "Enabled CAPE analysis-machine identity changed during/after deployment; refusing unsafe resume"
        return 1
      }
      CAPE_TARGETS_COUNT="$(targets_count)"
      ((CAPE_TARGETS_COUNT > 0)) || { fail "Deployment state contains no CAPE analysis targets"; return 1; }
      targets_bind 0
      if deploy_phase_at_least cape-configured; then
        cape_assert_owned_files_unchanged || return 1
      fi
      pass "Resuming deployment state $DEPLOYMENT_ID at phase ${DEPLOYMENT_PHASE:-unknown} for $CAPE_TARGETS_COUNT CAPE machine(s)"
      return 0
    fi
  fi

  CAPE_ROOT="$d_root"
  CAPE_COMMIT="$d_commit"
  CAPE_DB_BACKEND="$d_db"
  CAPE_TARGETS_JSON="$d_targets_json"
  CAPE_TARGETS_COUNT="$(targets_count)"
  CAPE_TARGETS_IDENTITY_SHA256="$d_targets_identity"
  ISOLATED_SUBNET="$d_subnet"
  BRIDGE_IP="$d_bridge_ip"
  INETSIM_IP="$d_inetsim_ip"
  # A rolled-back transaction must never leak its release provenance into a
  # fresh deployment from a newer immutable release.
  RELEASE_TAG="$d_release_tag"
  RELEASE_SOURCE_BUNDLE="$d_release_bundle"
  RELEASE_SOURCE_SHA256="$d_release_sha"
  RELEASE_SOURCE_COMMIT="$d_release_commit"
  deploy_reset_resource_state
  LIBVIRT_STORAGE_POOL="$d_storage_pool"
  LIBVIRT_STORAGE_PATH="$d_storage_path"
  targets_bind 0

  state_init_paths
  state_new_deployment_id
  DEPLOYMENT_PHASE=planned
  isolated_network_defaults
  choose_isolated_bridge_name
  state_write_atomic
  services_capture_original_state
  pass "Initialized deployment transaction $DEPLOYMENT_ID for $CAPE_TARGETS_COUNT CAPE analysis machine(s)"
}

deploy_stage_non_disruptive() {
  local artifact
  info "Staging isolated network and generalized INetSim appliance; CAPE analyses are not interrupted."
  artifact="$(appliance_fetch "$APPLIANCE_MANIFEST")"

  isolated_network_apply
  firewall_apply
  if ! deploy_phase_at_least isolated-network-ready; then
    state_set_phase isolated-network-ready
  fi

  inetsim_copy_appliance_disk "$artifact"
  inetsim_define_domain
  if ! deploy_phase_at_least appliance-defined; then
    state_set_phase appliance-defined
  fi

  inetsim_configure_guest
  inetsim_enable_gui_guest
  if ! deploy_phase_at_least appliance-configured; then
    state_set_phase appliance-configured
  fi

  inetsim_verify_host
  if ! deploy_phase_at_least staged; then
    state_set_phase staged
  fi
}

deploy_validate_staged_resources() {
  local artifact
  artifact="$(appliance_fetch "$APPLIANCE_MANIFEST")"
  isolated_network_apply
  firewall_apply
  inetsim_copy_appliance_disk "$artifact"
  inetsim_define_domain
  virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
  qga_wait "$INETSIM_DOMAIN_NAME" 60 || { fail "INetSim appliance QGA unavailable during resume"; return 1; }
  inetsim_enable_gui_guest
  inetsim_verify_host
}

deploy_ensure_maintenance() {
  if [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]]; then
    cape_verify_maintenance_guard || {
      fail "Existing CAPE maintenance guard does not safely belong to this deployment"
      return 1
    }
    if ! deploy_phase_at_least maintenance-acquired; then
      state_record_resource cape-maintenance all-machines acquired yes "$CAPE_MAINTENANCE_GUARD_FILE"
      state_set_phase maintenance-acquired
    fi
    pass "Verified existing CAPE maintenance ownership"
    return 0
  fi

  cape_wait_and_acquire_maintenance "$DEPLOY_WAIT_SECONDS"
  if ! deploy_phase_at_least maintenance-acquired; then
    state_set_phase maintenance-acquired
  fi
}

deploy_verify_windows_nic() {
  [[ -n "${WINDOWS_ISOLATED_MAC:-}" ]] || { fail "Windows isolated NIC MAC is missing from deployment state"; return 1; }
  state_resource_owned domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" || {
    fail "Windows isolated NIC is not owned by this deployment"
    return 1
  }
  windows_isolated_mac_present "$WINDOWS_ISOLATED_MAC" || {
    fail "Deployment-owned Windows isolated NIC is missing from persistent domain XML"
    return 1
  }
}

deploy_verify_safety_snapshot() {
  [[ -n "${SAFETY_SNAPSHOT:-}" ]] || { fail "Pre-change safety snapshot is missing from state"; return 1; }
  state_resource_owned snapshot "$DOMAIN:$SAFETY_SNAPSHOT" || { fail "Safety snapshot is not deployment-owned"; return 1; }
  windows_snapshot_exists "$SAFETY_SNAPSHOT" || { fail "Safety snapshot is missing from libvirt"; return 1; }
}

deploy_finish_windows_snapshots() {
  local state

  # Capture the final CAPE running-memory snapshot while the already-proven
  # guest-control session is still alive. Some CAPE images (for example the
  # SSL-44 baseline) run CAPE Agent only inside the configured memory snapshot
  # and do not expose it after a cold boot. Never throw away that known-good
  # control plane just to manufacture the rollback snapshot first.
  if [[ -z "${FINAL_SNAPSHOT:-}" ]] || ! windows_snapshot_exists "$FINAL_SNAPSHOT"; then
    state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
    [[ "$state" == running ]] || {
      fail "Verified Windows guest is no longer running before final CAPE snapshot creation (state=${state:-unknown})"
      return 1
    }
    windows_create_running_snapshot
  fi

  # After the running analysis snapshot is durable, power the guest off once
  # through the already-selected backend and capture a configured shutoff
  # rollback snapshot as a child. No second boot/control rediscovery is needed.
  if [[ -z "${WORKING_SNAPSHOT:-}" ]] || ! windows_snapshot_exists "$WORKING_SNAPSHOT"; then
    state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
    [[ "$state" == "shut off" ]] || windows_poweroff_selected_backend
    windows_create_working_snapshot
  fi

  state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
  [[ "$state" == "shut off" ]] || windows_poweroff_selected_backend

  [[ "$(snapshot_state_memory "$WORKING_SNAPSHOT")" == "shutoff|no" ]] || {
    fail "Configured rollback snapshot is not a shutoff/no-memory snapshot for $CAPE_MACHINE_SECTION"
    return 1
  }
  snapshot_is_running_analysis_baseline "$FINAL_SNAPSHOT" || {
    fail "CAPE analysis snapshot is not running-state with internal/external saved memory for $CAPE_MACHINE_SECTION"
    return 1
  }
  target_state_set_phase snapshots-ready
}

deploy_windows_target_cutover() {
  # Per-task route separation: AutoDeploy no longer rewrites Windows networking,
  # attaches a fake-Internet NIC, or manufactures a replacement CAPE snapshot.
  # The existing CAPE analysis baseline remains authoritative. CAPE's rooter
  # selects Internet vs INetSim vs drop for each task on the host.
  case "${TARGET_PHASE:-discovered}" in
    discovered)
      info "Preserving original CAPE analysis VM/network baseline for $CAPE_MACHINE_SECTION ($DOMAIN)"
      FINAL_SNAPSHOT="${CAPE_MACHINE_SNAPSHOT:-}"
      WORKING_SNAPSHOT=""
      SAFETY_SNAPSHOT=""
      WINDOWS_ISOLATED_MAC=""
      WINDOWS_ISOLATED_NIC_MODEL=""
      WINDOWS_BACKEND_USED=""
      WINDOWS_ORIGINAL_DOMAIN_STATE="${DOMAIN_STATE:-unknown}"

      if [[ -n "$FINAL_SNAPSHOT" ]]; then
        virsh snapshot-info "$DOMAIN" "$FINAL_SNAPSHOT" >/dev/null 2>&1 || {
          fail "Configured CAPE snapshot is missing for $CAPE_MACHINE_SECTION: $FINAL_SNAPSHOT"
          return 1
        }
      fi

      target_state_set_phase snapshots-ready
      ;;
    snapshots-ready|cape-configured)
      if [[ -n "${FINAL_SNAPSHOT:-}" ]]; then
        virsh snapshot-info "$DOMAIN" "$FINAL_SNAPSHOT" >/dev/null 2>&1 || {
          fail "Preserved CAPE snapshot disappeared for $CAPE_MACHINE_SECTION: $FINAL_SNAPSHOT"
          return 1
        }
      fi
      ;;
    *)
      fail "Unexpected legacy Windows-mutating deployment phase for $CAPE_MACHINE_SECTION: ${TARGET_PHASE:-missing}; rollback the older deployment before route-separated upgrade"
      return 1
      ;;
  esac

  pass "CAPE analysis VM preserved unchanged: $CAPE_MACHINE_SECTION -> $DOMAIN"
}

deploy_windows_cutover() {
  deploy_ensure_maintenance
  local i
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    deploy_windows_target_cutover
    targets_capture_bound "$i"
    state_write_atomic
  done
  targets_bind 0
  state_set_phase windows-all-ready
}

deploy_validate_all_cape_configuration() {
  local saved="${TARGET_INDEX:-}" i failures=0
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    validate_cape_configuration || failures=$((failures+1))
  done
  [[ "$saved" =~ ^[0-9]+$ ]] && targets_bind "$saved"
  ((failures == 0))
}

deploy_cape_cutover() {
  # CAPE's native route=inetsim path depends on host IPv4 forwarding and the
  # privileged Rooter service. Establish those prerequisites while scheduling
  # is still held at a task-safe point, before any task can observe the route.
  deploy_ensure_maintenance
  routing_forwarding_apply

  if ! deploy_phase_at_least cape-configured; then
    cape_configure_inetsim
  else
    deploy_validate_all_cape_configuration
  fi

  services_prepare_route_control_plane
  cape_probe_inetsim_rooter_all

  if ! deploy_phase_at_least extension-installed; then
    extension_install
  fi

  validate_deployment_structural

  if ! deploy_phase_at_least handoff-complete; then
    if [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]]; then
      cape_verify_maintenance_guard
      services_stop_scheduler_for_handoff
      cape_release_maintenance
    elif ! deploy_phase_at_least extension-installed; then
      fail "CAPE maintenance ownership disappeared before configuration handoff"
      return 1
    fi

    services_activate_deployment_state
    state_set_phase handoff-complete
  fi

  validate_deployment_services
}
deploy_rollback_after_error() {
  local rc="$1"
  trap - ERR INT TERM
  set +e
  echo
  fail "Deployment failed (exit $rc). Starting ownership-aware rollback."
  if [[ -f "$AD_STATE_FILE" ]]; then
    state_load >/dev/null 2>&1 || true
    autodeploy_rollback_internal
  fi
  if [[ -x "$AUTODEPLOY_ROOT/bin/cape-inetsim-collect" ]]; then
    echo
    warn "Creating one redacted diagnostic bundle automatically; no terminal-output copy/paste is needed."
    bash "$AUTODEPLOY_ROOT/bin/cape-inetsim-collect" || warn "Automatic diagnostic collection did not complete"
  fi
  set -e
  exit "$rc"
}

deploy_handle_signal() {
  deploy_rollback_after_error 130
}

deploy_run() {
  require_root
  transaction_lock_acquire
  run_discovery
  deployment_decision_classify
  deployment_decision_require_safe
  discover_cape_runtime || {
    fail "CAPE Python/runtime discovery failed before any system mutation"
    return 1
  }
  inventory_write_json
  deploy_assert_supported_environment

  case "$DEPLOYMENT_DECISION" in
    upgrade|repair)
      info "Decision engine selected $DEPLOYMENT_DECISION; entering ownership-safe in-place migration/repair"
      exec "$AUTODEPLOY_ROOT/bin/cape-inetsim-repair"
      ;;
  esac

  deploy_initialize_or_resume_state

  if [[ "${DEPLOYMENT_PHASE:-}" == committed ]]; then
    validate_deployment_structural
    validate_deployment_services
    pass "Deployment is already committed and validates successfully"
    return 0
  fi

  trap 'deploy_rollback_after_error $?' ERR
  trap deploy_handle_signal INT TERM

  cape_preflight_runtime

  if ! deploy_phase_at_least staged; then
    deploy_stage_non_disruptive
  else
    deploy_validate_staged_resources
  fi

  if ! deploy_phase_at_least windows-all-ready; then
    deploy_windows_cutover
  else
    local i
    for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
      targets_bind "$i"
      deploy_windows_target_cutover
    done
    targets_bind 0
  fi

  if ! deploy_phase_at_least handoff-complete; then
    deploy_cape_cutover
  else
    validate_deployment_structural
    validate_deployment_services
  fi

  if [[ "${CAPE_INETSIM_E2E_REQUIRED:-yes}" != no ]]; then
    "$AUTODEPLOY_ROOT/bin/cape-inetsim-selftest"
  else
    warn "Automatic CAPE end-to-end self-test explicitly disabled by CAPE_INETSIM_E2E_REQUIRED=no"
  fi

  state_set_phase committed
  trap - ERR INT TERM
  echo
  pass "CAPE-INetSim-AutoDeploy deployment committed"
  kv "managed CAPE machines:" "${CAPE_TARGETS_COUNT:-0}"
  kv "INetSim server:" "$INETSIM_IP"
  kv "isolated network:" "$ISOLATED_NETWORK_NAME"
  kv "capture bridge:" "$ISOLATED_BRIDGE_NAME"
  echo "Managed analysis VMs:"
  targets_summary_lines | sed 's/^/  /'
}
