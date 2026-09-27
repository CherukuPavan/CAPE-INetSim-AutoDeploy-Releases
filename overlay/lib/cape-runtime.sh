#!/usr/bin/env bash

cape_run_as_user() {
  local service_user="$1"
  shift
  (
    cd "$CAPE_ROOT" || exit 1
    if [[ "$service_user" == "$(id -un)" ]]; then
      env -u PYTHONHOME PYTHONPATH="$CAPE_ROOT" PYTHONDONTWRITEBYTECODE=1 "$@"
    else
      runuser -u "$service_user" -- env -u PYTHONHOME \
        PYTHONPATH="$CAPE_ROOT" PYTHONDONTWRITEBYTECODE=1 "$@"
    fi
  )
}

cape_python_candidate_valid() {
  local service_user="$1" candidate="$2"
  [[ "$candidate" == /* && -x "$candidate" ]] || return 1
  cape_run_as_user "$service_user" timeout 20 "$candidate" - <<'PY' >/dev/null 2>&1
import importlib
for name in ("django","lib.cuckoo.common.config","lib.cuckoo.core.database"):
    importlib.import_module(name)
PY
}

cape_execstart_argv0() {
  local unit="$1"
  systemctl show "$unit" -p ExecStart --value 2>/dev/null | ad_python -c '
import re,shlex,sys
s=sys.stdin.read()
m=re.search(r"argv\[\]=(.*?)(?:\s*;\s*ignore_errors=|\s*;\s*start_time=|\s*;\s*\}$)",s)
if not m:
    raise SystemExit
try:
    a=shlex.split(m.group(1))
except ValueError:
    raise SystemExit
if a:
    print(a[0])
' || true
}

cape_running_python() {
  local unit="$1" pid
  pid="$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  ad_python - "$pid" <<'PY'
import os,re,shutil,sys
from pathlib import Path
try:
    proc=Path("/proc")/sys.argv[1]
    argv=proc.joinpath("cmdline").read_bytes().split(b"\0")
    exe=os.fsdecode(argv[0])
    if not re.fullmatch(r"python(?:[0-9]+(?:\.[0-9]+)*)?",os.path.basename(exe)):
        raise ValueError
    if not os.path.isabs(exe):
        cwd=os.readlink(proc/"cwd")
        env=dict(x.split(b"=",1) for x in proc.joinpath("environ").read_bytes().split(b"\0") if b"=" in x)
        path=os.fsdecode(env.get(b"PATH",b""))
        exe=shutil.which(exe,path=path) or ""
    if exe and os.access(exe,os.X_OK):
        print(os.path.realpath(exe) if "/bin/python" not in exe else exe)
except (OSError,ValueError,IndexError):
    pass
PY
}

cape_service_python() {
  local unit="${1:-${CAPE_SCHEDULER_SERVICE:-}}" service_user candidate launcher env_dir path
  [[ -n "$unit" ]] || { fail "CAPE scheduler service is not discovered"; return 1; }
  service_user="$(systemctl show "$unit" -p User --value 2>/dev/null || true)"
  service_user="${service_user:-root}"

  if [[ "$unit" == "${CAPE_SCHEDULER_SERVICE:-}" && -n "${CAPE_RUNTIME_PYTHON:-}" ]] &&
     cape_python_candidate_valid "$service_user" "$CAPE_RUNTIME_PYTHON"; then
    printf '%s\n' "$CAPE_RUNTIME_PYTHON"
    return 0
  fi

  # 1. Running service argv is strongest evidence because it is the exact
  # interpreter CAPE is using now.
  candidate="$(cape_running_python "$unit" 2>/dev/null || true)"
  if cape_python_candidate_valid "$service_user" "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # 2. Direct Python configured in systemd ExecStart.
  launcher="$(cape_execstart_argv0 "$unit")"
  if [[ "$launcher" == /* ]] && [[ "${launcher##*/}" =~ ^python([0-9]+(\.[0-9]+)*)?$ ]] &&
     cape_python_candidate_valid "$service_user" "$launcher"; then
    printf '%s\n' "$launcher"
    return 0
  fi

  # 3. Conventional project-local CAPE virtual environments.
  for path in "$CAPE_ROOT/.venv/bin/python" "$CAPE_ROOT/venv/bin/python" "$CAPE_ROOT/env/bin/python"; do
    if cape_python_candidate_valid "$service_user" "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  # 4. Poetry environment. Prefer the launcher from systemd; otherwise use a
  # discovered Poetry executable without assuming /etc/poetry.
  local poetry=""
  if [[ "${launcher##*/}" == poetry && -x "$launcher" ]]; then
    poetry="$launcher"
  else
    poetry="$(command -v poetry 2>/dev/null || true)"
  fi
  if [[ -n "$poetry" ]]; then
    candidate="$(cape_run_as_user "$service_user" timeout 20 "$poetry" env info --executable 2>/dev/null || true)"
    if cape_python_candidate_valid "$service_user" "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    env_dir="$(cape_run_as_user "$service_user" timeout 20 "$poetry" env info --path 2>/dev/null || true)"
    candidate="$env_dir/bin/python"
    if cape_python_candidate_valid "$service_user" "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # 5. Other virtualenv layouts under the CAPE project.
  while IFS= read -r candidate; do
    if cape_python_candidate_valid "$service_user" "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$CAPE_ROOT" -maxdepth 4 -type f -path '*/bin/python' -perm -0100 -print 2>/dev/null | sort -u)

  # 6. Last resort: the discovered host interpreter, but only if it imports
  # Django and CAPE modules under the CAPE service identity.
  candidate="${AD_HOST_PYTHON:-}"
  if cape_python_candidate_valid "$service_user" "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  fail "Could not identify a validated CAPE Python environment for $unit"
  return 1
}

cape_runtime_python() {
  cape_service_python "${CAPE_SCHEDULER_SERVICE:-}"
}

discover_cape_runtime() {
  [[ -n "${CAPE_SCHEDULER_SERVICE:-}" ]] || {
    fail "CAPE scheduler service was not discovered"
    return 1
  }
  CAPE_SERVICE_USER="$(systemctl show "$CAPE_SCHEDULER_SERVICE" -p User --value 2>/dev/null || true)"
  CAPE_SERVICE_USER="${CAPE_SERVICE_USER:-root}"
  CAPE_SERVICE_GROUP="$(id -gn "$CAPE_SERVICE_USER" 2>/dev/null || printf '%s' "$CAPE_SERVICE_USER")"
  CAPE_RUNTIME_PYTHON="$(cape_runtime_python)" || return 1
  cape_python_candidate_valid "$CAPE_SERVICE_USER" "$CAPE_RUNTIME_PYTHON"
}
