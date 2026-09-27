#!/usr/bin/env bash

AD_STATE_ROOT="${AD_STATE_ROOT:-/var/lib/cape-inetsim-autodeploy}"
AD_STATE_FILE="${AD_STATE_FILE:-$AD_STATE_ROOT/state.env}"
AD_RESOURCE_LEDGER="${AD_RESOURCE_LEDGER:-$AD_STATE_ROOT/resources.tsv}"
AD_BACKUP_ROOT="${AD_BACKUP_ROOT:-$AD_STATE_ROOT/backups}"
AD_GENERATED_ROOT="${AD_GENERATED_ROOT:-$AD_STATE_ROOT/generated}"
AD_LOG_ROOT="${AD_LOG_ROOT:-$AD_STATE_ROOT/logs}"
AD_LOCK_FILE="${AD_LOCK_FILE:-/run/lock/cape-inetsim-autodeploy.lock}"

state_init_paths() {
  install -d -m 0700 "$AD_STATE_ROOT" "$AD_BACKUP_ROOT" "$AD_GENERATED_ROOT" "$AD_LOG_ROOT"
  if [[ ! -e "$AD_RESOURCE_LEDGER" ]]; then
    printf 'deployment_id\tkind\tname\taction\tcreated_by_autodeploy\tdetail\n' >"$AD_RESOURCE_LEDGER"
    chmod 0600 "$AD_RESOURCE_LEDGER"
  else
    local header
    header="$(head -1 "$AD_RESOURCE_LEDGER" 2>/dev/null || true)"
    [[ "$header" == $'deployment_id\tkind\tname\taction\tcreated_by_autodeploy\tdetail' ]] || {
      fail "Unsupported resource-ledger schema at $AD_RESOURCE_LEDGER"
      return 1
    }
  fi
}

state_write_atomic() {
  state_init_paths
  if [[ -n "${TARGET_INDEX:-}" ]] && declare -F targets_capture_bound >/dev/null 2>&1; then
    targets_capture_bound "$TARGET_INDEX"
  fi
  CAPE_TARGETS_COUNT="${CAPE_TARGETS_COUNT:-0}"
  CAPE_TARGETS_IDENTITY_SHA256="${CAPE_TARGETS_IDENTITY_SHA256:-}"
  if declare -F targets_count >/dev/null 2>&1; then
    CAPE_TARGETS_COUNT="$(targets_count)"
  fi
  if [[ -z "$CAPE_TARGETS_IDENTITY_SHA256" ]] && declare -F targets_identity_sha256 >/dev/null 2>&1; then
    CAPE_TARGETS_IDENTITY_SHA256="$(targets_identity_sha256)"
  fi
  local tmp
  tmp="$(mktemp "$AD_STATE_ROOT/.state.XXXXXX")"
  ORIGINAL_CAPE_SNAPSHOT="${ORIGINAL_CAPE_SNAPSHOT:-${CAPE_MACHINE_SNAPSHOT:-}}"
  RELEASE_TAG="${RELEASE_TAG:-${CAPE_INETSIM_RELEASE_TAG:-}}"
  RELEASE_SOURCE_BUNDLE="${RELEASE_SOURCE_BUNDLE:-${CAPE_INETSIM_RELEASE_SOURCE_BUNDLE:-}}"
  RELEASE_SOURCE_SHA256="${RELEASE_SOURCE_SHA256:-${CAPE_INETSIM_RELEASE_SOURCE_SHA256:-}}"
  RELEASE_SOURCE_COMMIT="${RELEASE_SOURCE_COMMIT:-${CAPE_INETSIM_RELEASE_SOURCE_COMMIT:-}}"
  {
    echo '# CAPE-INetSim-AutoDeploy state; shell-quoted values; root-readable only.'
    printf 'STATE_SCHEMA=%q\n' "3"
    printf 'DEPLOYMENT_ID=%q\n' "${DEPLOYMENT_ID:-}"
    printf 'DEPLOYMENT_PHASE=%q\n' "${DEPLOYMENT_PHASE:-discovered}"
    printf 'CAPE_ROOT=%q\n' "${CAPE_ROOT:-}"
    printf 'CAPE_COMMIT=%q\n' "${CAPE_COMMIT:-}"
    printf 'RELEASE_TAG=%q\n' "${RELEASE_TAG:-}"
    printf 'RELEASE_SOURCE_BUNDLE=%q\n' "${RELEASE_SOURCE_BUNDLE:-}"
    printf 'RELEASE_SOURCE_SHA256=%q\n' "${RELEASE_SOURCE_SHA256:-}"
    printf 'RELEASE_SOURCE_COMMIT=%q\n' "${RELEASE_SOURCE_COMMIT:-}"
    printf 'CAPE_DB_BACKEND=%q\n' "${CAPE_DB_BACKEND:-}"
    printf 'CAPE_ROOT_SOURCE=%q\n' "${CAPE_ROOT_SOURCE:-}"
    printf 'CAPE_SCHEDULER_SERVICE=%q\n' "${CAPE_SCHEDULER_SERVICE:-}"
    printf 'CAPE_PROCESSOR_SERVICE=%q\n' "${CAPE_PROCESSOR_SERVICE:-}"
    printf 'CAPE_WEB_SERVICE=%q\n' "${CAPE_WEB_SERVICE:-}"
    printf 'CAPE_ROOTER_SERVICE=%q\n' "${CAPE_ROOTER_SERVICE:-}"
    printf 'CAPE_ROOTER_EXECUTABLE=%q\n' "${CAPE_ROOTER_EXECUTABLE:-}"
    printf 'CAPE_SERVICE_USER=%q\n' "${CAPE_SERVICE_USER:-}"
    printf 'CAPE_SERVICE_GROUP=%q\n' "${CAPE_SERVICE_GROUP:-}"
    printf 'CAPE_RUNTIME_PYTHON=%q\n' "${CAPE_RUNTIME_PYTHON:-}"
    printf 'DEPLOYMENT_DECISION=%q\n' "${DEPLOYMENT_DECISION:-}"
    printf 'UPGRADE_FROM_RELEASE_TAG=%q\n' "${UPGRADE_FROM_RELEASE_TAG:-}"
    printf 'UPGRADE_FROM_RELEASE_COMMIT=%q\n' "${UPGRADE_FROM_RELEASE_COMMIT:-}"
    printf 'CAPE_TARGETS_COUNT=%q\n' "${CAPE_TARGETS_COUNT:-0}"
    printf 'CAPE_TARGETS_IDENTITY_SHA256=%q\n' "${CAPE_TARGETS_IDENTITY_SHA256:-}"
    printf 'CAPE_TARGETS_JSON=%q\n' "${CAPE_TARGETS_JSON:-[]}"
    printf 'CAPE_MACHINE_SECTION=%q\n' "${CAPE_MACHINE_SECTION:-}"
    printf 'CAPE_MACHINE_LABEL=%q\n' "${CAPE_MACHINE_LABEL:-}"
    printf 'CAPE_MACHINE_IP=%q\n' "${CAPE_MACHINE_IP:-}"
    printf 'CAPE_RESULTSERVER_IP=%q\n' "${CAPE_RESULTSERVER_IP:-}"
    printf 'CAPE_RESULTSERVER_PORT=%q\n' "${CAPE_RESULTSERVER_PORT:-}"
    printf 'CONTROL_HOST_IP=%q\n' "${CONTROL_HOST_IP:-}"
    printf 'DOMAIN=%q\n' "${DOMAIN:-}"
    printf 'MANAGEMENT_NETWORK_NAME=%q\n' "${MANAGEMENT_NETWORK_NAME:-}"
    printf 'MANAGEMENT_BRIDGE_NAME=%q\n' "${MANAGEMENT_BRIDGE_NAME:-}"
    printf 'WINDOWS_MANAGEMENT_MAC=%q\n' "${WINDOWS_MANAGEMENT_MAC:-}"
    printf 'MANAGEMENT_NWFILTER_AVAILABLE=%q\n' "${MANAGEMENT_NWFILTER_AVAILABLE:-}"
    printf 'ORIGINAL_CAPE_SNAPSHOT=%q\n' "${ORIGINAL_CAPE_SNAPSHOT:-}"
    printf 'ISOLATED_SUBNET=%q\n' "${ISOLATED_SUBNET:-}"
    printf 'BRIDGE_IP=%q\n' "${BRIDGE_IP:-}"
    printf 'INETSIM_IP=%q\n' "${INETSIM_IP:-}"
    printf 'WINDOWS_FAKE_IP=%q\n' "${WINDOWS_FAKE_IP:-}"
    printf 'ISOLATED_NETWORK_NAME=%q\n' "${ISOLATED_NETWORK_NAME:-}"
    printf 'ISOLATED_BRIDGE_NAME=%q\n' "${ISOLATED_BRIDGE_NAME:-}"
    printf 'LIBVIRT_STORAGE_POOL=%q\n' "${LIBVIRT_STORAGE_POOL:-}"
    printf 'LIBVIRT_STORAGE_PATH=%q\n' "${LIBVIRT_STORAGE_PATH:-}"
    printf 'INETSIM_DOMAIN_NAME=%q\n' "${INETSIM_DOMAIN_NAME:-}"
    printf 'INETSIM_DISK_PATH=%q\n' "${INETSIM_DISK_PATH:-}"
    printf 'INETSIM_MANAGEMENT_MAC=%q\n' "${INETSIM_MANAGEMENT_MAC:-}"
    printf 'INETSIM_ISOLATED_MAC=%q\n' "${INETSIM_ISOLATED_MAC:-}"
    printf 'WINDOWS_ISOLATED_NIC_MODEL=%q\n' "${WINDOWS_ISOLATED_NIC_MODEL:-}"
    printf 'WINDOWS_ISOLATED_MAC=%q\n' "${WINDOWS_ISOLATED_MAC:-}"
    printf 'WINDOWS_BACKEND_USED=%q\n' "${WINDOWS_BACKEND_USED:-}"
    printf 'WINDOWS_ORIGINAL_DOMAIN_STATE=%q\n' "${WINDOWS_ORIGINAL_DOMAIN_STATE:-}"
    printf 'CAPE_SERVICE_WAS_ACTIVE=%q\n' "${CAPE_SERVICE_WAS_ACTIVE:-}"
    printf 'CAPE_PROCESSOR_WAS_ACTIVE=%q\n' "${CAPE_PROCESSOR_WAS_ACTIVE:-}"
    printf 'CAPE_WEB_WAS_ACTIVE=%q\n' "${CAPE_WEB_WAS_ACTIVE:-}"
    printf 'CAPE_ROOTER_WAS_ACTIVE=%q\n' "${CAPE_ROOTER_WAS_ACTIVE:-}"
    printf 'CAPE_ROOTER_WAS_ENABLED=%q\n' "${CAPE_ROOTER_WAS_ENABLED:-}"
    printf 'CAPE_ROOTER_WAS_PRESENT=%q\n' "${CAPE_ROOTER_WAS_PRESENT:-}"
    printf 'HOST_IPV4_FORWARD_WAS=%q\n' "${HOST_IPV4_FORWARD_WAS:-}"
    printf 'CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=%q\n' "${CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY:-no}"
    printf 'SAFETY_SNAPSHOT=%q\n' "${SAFETY_SNAPSHOT:-}"
    printf 'WORKING_SNAPSHOT=%q\n' "${WORKING_SNAPSHOT:-}"
    printf 'FINAL_SNAPSHOT=%q\n' "${FINAL_SNAPSHOT:-}"
    printf 'NORMAL_SNAPSHOT=%q\n' "${NORMAL_SNAPSHOT:-}"
    printf 'CAPE_POST_SHA_SNIFFER=%q\n' "${CAPE_POST_SHA_SNIFFER:-}"
    printf 'CAPE_POST_SHA_AUXILIARY=%q\n' "${CAPE_POST_SHA_AUXILIARY:-}"
    printf 'CAPE_POST_SHA_KVM=%q\n' "${CAPE_POST_SHA_KVM:-}"
    printf 'CAPE_POST_SHA_PROCESSING=%q\n' "${CAPE_POST_SHA_PROCESSING:-}"
    printf 'CAPE_POST_SHA_ROUTING=%q\n' "${CAPE_POST_SHA_ROUTING:-}"
    printf 'STATE_UPDATED_AT=%q\n' "$(date -Is)"
  } >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$AD_STATE_FILE"
}

state_load() {
  [[ -f "$AD_STATE_FILE" && ! -L "$AD_STATE_FILE" ]] || return 1
  local uid mode
  uid="$(stat -c '%u' "$AD_STATE_FILE" 2>/dev/null || echo -1)"
  mode="$(stat -c '%a' "$AD_STATE_FILE" 2>/dev/null || echo 777)"
  if [[ "$(id -u)" -eq 0 ]]; then
    [[ "$uid" -eq 0 ]] || { fail "State file is not root-owned: $AD_STATE_FILE"; return 2; }
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { fail "State file permissions are invalid: $mode"; return 2; }
    local perm=$((8#$mode))
    (( (perm & 0077) == 0 )) || { fail "State file must not be accessible by group/other: mode $mode"; return 2; }
  fi
  # File is created only by AutoDeploy under a root-only directory.
  # shellcheck disable=SC1090
  source "$AD_STATE_FILE"
  [[ "${STATE_SCHEMA:-}" == "3" ]] || { fail "Unsupported state schema: ${STATE_SCHEMA:-missing}"; return 2; }
  [[ -n "${DEPLOYMENT_ID:-}" ]] || { fail "State file is missing deployment ID"; return 2; }
}

state_set_phase() {
  DEPLOYMENT_PHASE="$1"
  state_write_atomic
}

state_record_resource() {
  local kind="$1" name="$2" action="$3" created="$4" detail="${5:-}"
  state_init_paths
  [[ -n "${DEPLOYMENT_ID:-}" ]] || { fail "Cannot record resource without deployment ID"; return 1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$DEPLOYMENT_ID" "$kind" "$name" "$action" "$created" "${detail//$'\t'/ }" >>"$AD_RESOURCE_LEDGER"
}

state_resource_owned() {
  local kind="$1" name="$2"
  [[ -n "${DEPLOYMENT_ID:-}" && -f "$AD_RESOURCE_LEDGER" ]] || return 1
  awk -F '\t' -v d="$DEPLOYMENT_ID" -v k="$kind" -v n="$name" '
    NR>1 && $1==d && $2==k && $3==n {created=$5; action=$4; seen=1}
    END {
      if (!seen) exit 1
      if (created!="yes") exit 1
      if (action ~ /^(removed|restored|released|deleted)/) exit 1
      exit 0
    }' "$AD_RESOURCE_LEDGER"
}

state_resource_intended() {
  local kind="$1" name="$2"
  [[ -n "${DEPLOYMENT_ID:-}" && -f "$AD_RESOURCE_LEDGER" ]] || return 1
  awk -F '\t' -v d="$DEPLOYMENT_ID" -v k="$kind" -v n="$name" '
    NR>1 && $1==d && $2==k && $3==n {created=$5; action=$4; seen=1}
    END {
      if (!seen) exit 1
      if (created!="no") exit 1
      if (action !~ /^(planned|creating|defining|attaching|applying)$/) exit 1
      exit 0
    }' "$AD_RESOURCE_LEDGER"
}

state_record_intent() {
  local kind="$1" name="$2" action="${3:-planned}" detail="${4:-}"
  if state_resource_owned "$kind" "$name" || state_resource_intended "$kind" "$name"; then
    return 0
  fi
  state_record_resource "$kind" "$name" "$action" no "$detail"
}

state_has_owned_kind() {
  local kind="$1"
  [[ -n "${DEPLOYMENT_ID:-}" && -f "$AD_RESOURCE_LEDGER" ]] || return 1
  awk -F '\t' -v d="$DEPLOYMENT_ID" -v k="$kind" '
    NR>1 && $1==d && $2==k {
      key=$3
      created[key]=$5
      action[key]=$4
    }
    END {
      for (key in created) {
        if (created[key]=="yes" && action[key] !~ /^(removed|restored|released|deleted)/) exit 0
      }
      exit 1
    }' "$AD_RESOURCE_LEDGER"
}

state_new_deployment_id() {
  DEPLOYMENT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(hostname -s | tr -cs 'A-Za-z0-9._-' '-')-$$"
}
