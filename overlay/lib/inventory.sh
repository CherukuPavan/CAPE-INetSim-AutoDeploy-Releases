#!/usr/bin/env bash

inventory_write_json() {
  state_init_paths || return 1
  local output="${1:-$AD_STATE_ROOT/autodeploy-inventory.json}"
  export CAPE_ROOT CAPE_ROOT_SOURCE CAPE_COMMIT CAPE_BRANCH CAPE_DIRTY CAPE_DB_BACKEND
  export CAPE_SCHEDULER_SERVICE CAPE_PROCESSOR_SERVICE CAPE_WEB_SERVICE CAPE_ROOTER_SERVICE
  export CAPE_SERVICE_USER CAPE_SERVICE_GROUP CAPE_RUNTIME_PYTHON CAPE_TARGETS_JSON
  export AD_STATE_ROOT AD_HOST_PYTHON
  ad_python "$AUTODEPLOY_ROOT/tools/inventory.py" \
    --output "$output" \
    --decision "${DEPLOYMENT_DECISION:-unknown}" \
    --decision-reason "${DEPLOYMENT_DECISION_REASON:-unknown}" >/dev/null
  chmod 0600 "$output"
  pass "Pre-change inventory written: $output"
}
