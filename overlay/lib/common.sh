#!/usr/bin/env bash
set -o pipefail

AD_NAME="CAPE-INetSim-AutoDeploy"
_AD_COMMON_ROOT="${AUTODEPLOY_ROOT:-}"
if [[ -z "$_AD_COMMON_ROOT" ]]; then
  _AD_COMMON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
fi
AD_VERSION="$(cat "${_AD_COMMON_ROOT:+$_AD_COMMON_ROOT/}VERSION" 2>/dev/null || echo unknown)"
unset _AD_COMMON_ROOT

pass(){ printf '[PASS] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
fail(){ printf '[FAIL] %s\n' "$*"; }
info(){ printf '[INFO] %s\n' "$*"; }
kv(){ printf '%-32s %s\n' "$1" "$2"; }
have(){ command -v "$1" >/dev/null 2>&1; }

ad_select_host_python() {
  local candidate path version_ok
  if [[ -n "${AD_HOST_PYTHON:-}" && -x "${AD_HOST_PYTHON:-}" ]]; then
    printf '%s\n' "$AD_HOST_PYTHON"
    return 0
  fi
  for candidate in python3 python; do
    path="$(command -v "$candidate" 2>/dev/null || true)"
    [[ -n "$path" && -x "$path" ]] || continue
    if "$path" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
    then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

# Resolve the host-side interpreter once from PATH. Runtime code uses the
# discovered absolute executable and never assumes a fixed system or CAPE path.
if [[ -z "${AD_HOST_PYTHON:-}" ]]; then
  AD_HOST_PYTHON="$(ad_select_host_python 2>/dev/null || true)"
fi
export AD_HOST_PYTHON
ad_python() {
  [[ -n "${AD_HOST_PYTHON:-}" && -x "$AD_HOST_PYTHON" ]] || {
    fail "No supported host Python >= 3.10 was discovered"
    return 127
  }
  "$AD_HOST_PYTHON" "$@"
}


nwfilter_definition_roots() {
  if [[ -n "${NWFILTER_DEFINITION_ROOT:-}" ]]; then
    printf '%s\n' "$NWFILTER_DEFINITION_ROOT"
    return 0
  fi
  printf '%s\n' /etc/libvirt/nwfilter /usr/share/libvirt/nwfilter
}

nwfilter_find_definition() {
  local target="$1" root path
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    path="$root/$target.xml"
    [[ -r "$path" ]] || continue
    if ad_python - "$path" "$target" <<'PY'
import sys,xml.etree.ElementTree as ET
path,target=sys.argv[1:]
try:
    root=ET.parse(path).getroot()
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if root.tag=="filter" and root.get("name")==target else 1)
PY
    then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(nwfilter_definition_roots)
  return 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "This operation requires root so CAPE/libvirt state can be handled consistently."
    return 1
  fi
}

require_root_for_plan() {
  require_root || {
    echo "Run: sudo ./install --plan"
    return 1
  }
}

add_error(){ DISCOVERY_ERRORS+=("$*"); }
add_note(){ COMPAT_NOTES+=("$*"); }

ad_safe_token() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}
