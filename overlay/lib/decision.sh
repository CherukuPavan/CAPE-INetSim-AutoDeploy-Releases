#!/usr/bin/env bash

deployment_decision_detect_unowned_artifacts() {
  local found=()
  virsh dominfo cape-inetsim-appliance >/dev/null 2>&1 && found+=("domain:cape-inetsim-appliance")
  virsh net-info cape-inetsim-isolated >/dev/null 2>&1 && found+=("network:cape-inetsim-isolated")
  [[ -e /etc/systemd/system/cape-inetsim-rooter.service ]] && found+=("unit:cape-inetsim-rooter.service")
  [[ -e /etc/sysctl.d/99-cape-inetsim-autodeploy-routing.conf ]] && found+=("sysctl:routing")
  [[ -e /etc/nftables.d/cape-inetsim-autodeploy.nft ]] && found+=("firewall:nft")
  if (("${#found[@]}")); then
    printf '%s\n' "${found[@]}"
    return 0
  fi
  return 1
}

deployment_decision_classify() {
  DEPLOYMENT_DECISION=""
  DEPLOYMENT_DECISION_REASON=""

  if [[ ! -f "$AD_STATE_FILE" ]]; then
    local orphaned=""
    orphaned="$(deployment_decision_detect_unowned_artifacts 2>/dev/null || true)"
    if [[ -n "$orphaned" ]]; then
      DEPLOYMENT_DECISION="blocked-unowned"
      DEPLOYMENT_DECISION_REASON="AutoDeploy-named resources exist without an ownership ledger: $(tr '\n' ',' <<<"$orphaned" | sed 's/,$//')"
    else
      DEPLOYMENT_DECISION="fresh"
      DEPLOYMENT_DECISION_REASON="No previous AutoDeploy state exists"
    fi
    return 0
  fi

  local facts
  facts="$( (
    state_load >/dev/null 2>&1 || exit 9
    printf '%s|%s|%s|%s\n' "${DEPLOYMENT_PHASE:-}" "${RELEASE_TAG:-}" "${RELEASE_SOURCE_COMMIT:-}" "${STATE_SCHEMA:-}"
  ) 2>/dev/null || true )"
  if [[ -z "$facts" ]]; then
    DEPLOYMENT_DECISION="broken-state"
    DEPLOYMENT_DECISION_REASON="Existing AutoDeploy state cannot be validated"
    return 0
  fi

  local phase old_tag old_commit schema
  IFS='|' read -r phase old_tag old_commit schema <<<"$facts"
  case "$phase" in
    committed)
      if [[ -n "${CAPE_INETSIM_RELEASE_SOURCE_COMMIT:-}" &&
            -n "$old_commit" &&
            "$old_commit" != "$CAPE_INETSIM_RELEASE_SOURCE_COMMIT" ]]; then
        DEPLOYMENT_DECISION="upgrade"
        DEPLOYMENT_DECISION_REASON="Committed deployment $old_tag will be ownership-safely upgraded"
      else
        DEPLOYMENT_DECISION="verify"
        DEPLOYMENT_DECISION_REASON="Current release is already committed"
      fi
      ;;
    repair-incomplete|repairing)
      DEPLOYMENT_DECISION="repair"
      DEPLOYMENT_DECISION_REASON="Previous repair was interrupted or incomplete"
      ;;
    rollback-incomplete)
      DEPLOYMENT_DECISION="recover"
      DEPLOYMENT_DECISION_REASON="Previous rollback is incomplete; ownership-aware recovery is required"
      ;;
    rolled-back)
      DEPLOYMENT_DECISION="fresh"
      DEPLOYMENT_DECISION_REASON="Previous transaction is fully rolled back"
      ;;
    planned|isolated-network-ready|appliance-defined|appliance-configured|staged|maintenance-acquired|windows-nic-attached|windows-configured|windows-running-snapshot|windows-working-snapshot|windows-snapshots-ready|windows-all-ready|cape-configured|extension-installed|handoff-complete)
      DEPLOYMENT_DECISION="resume"
      DEPLOYMENT_DECISION_REASON="Interrupted deployment can resume from phase $phase"
      ;;
    *)
      DEPLOYMENT_DECISION="broken-state"
      DEPLOYMENT_DECISION_REASON="Unsupported deployment phase $phase in state schema $schema"
      ;;
  esac
}

deployment_decision_require_safe() {
  case "${DEPLOYMENT_DECISION:-}" in
    fresh|verify|upgrade|repair|recover|resume) return 0 ;;
    blocked-unowned|broken-state)
      fail "${DEPLOYMENT_DECISION_REASON:-AutoDeploy decision engine blocked deployment}"
      return 1 ;;
    *)
      fail "Deployment decision engine returned unknown state: ${DEPLOYMENT_DECISION:-missing}"
      return 1 ;;
  esac
}
