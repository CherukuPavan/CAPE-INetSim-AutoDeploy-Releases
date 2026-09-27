#!/usr/bin/env bash

resolve_cape_root_from_path() {
  local p="$1" i
  [[ -n "$p" && "$p" != "/" ]] || return 1
  p="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
  [[ -f "$p" ]] && p="$(dirname "$p")"
  for i in 1 2 3 4 5 6; do
    if [[ -f "$p/conf/kvm.conf" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
    [[ "$p" == "/" ]] && break
    p="$(dirname "$p")"
  done
  return 1
}

cape_all_systemd_units() {
  {
    systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null | awk '{print $1}'
    systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}'
  } | sed '/^$/d' | sort -u
}

cape_unit_root() {
  local unit="$1" wd exec_text token root
  wd="$(systemctl show "$unit" -p WorkingDirectory --value 2>/dev/null || true)"
  root="$(resolve_cape_root_from_path "$wd" 2>/dev/null || true)"
  if [[ -n "$root" ]]; then
    printf '%s\n' "$root"
    return 0
  fi

  exec_text="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)"
  while IFS= read -r token; do
    [[ "$token" == /* ]] || continue
    root="$(resolve_cape_root_from_path "$token" 2>/dev/null || true)"
    if [[ -n "$root" ]]; then
      printf '%s\n' "$root"
      return 0
    fi
  done < <(printf '%s\n' "$exec_text" | grep -oE '/[^ ;{}]+' || true)
  return 1
}

cape_service_roots() {
  local unit root
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    root="$(cape_unit_root "$unit" 2>/dev/null || true)"
    [[ -n "$root" ]] && printf '%s\n' "$root"
  done < <(cape_all_systemd_units)
}

cape_process_roots() {
  local proc cwd root
  for proc in /proc/[0-9]*; do
    [[ -d "$proc" ]] || continue
    cwd="$(readlink -f "$proc/cwd" 2>/dev/null || true)"
    [[ -n "$cwd" ]] || continue
    root="$(resolve_cape_root_from_path "$cwd" 2>/dev/null || true)"
    [[ -n "$root" ]] && printf '%s\n' "$root"
  done | sort -u
}

cape_fallback_roots() {
  local root
  if [[ -n "${CAPE_ROOT:-}" ]]; then
    resolve_cape_root_from_path "$CAPE_ROOT" 2>/dev/null || true
  fi
  find /opt /srv /usr/local /home /var/lib -maxdepth 7 -type f -path '*/conf/kvm.conf' -print 2>/dev/null |
    while IFS= read -r path; do
      root="${path%/conf/kvm.conf}"
      [[ -f "$root/conf/cuckoo.conf" ]] && printf '%s\n' "$root"
    done
}

discover_cape_root() {
  local -a service_roots=() process_roots=() fallback_roots=()
  mapfile -t service_roots < <(cape_service_roots | sed '/^$/d' | sort -u)
  if (("${#service_roots[@]}" == 1)); then
    CAPE_ROOT="${service_roots[0]}"
    CAPE_ROOT_SOURCE="systemd"
    pass "Live CAPE installation discovered from systemd metadata"
    return 0
  elif (("${#service_roots[@]}" > 1)); then
    mapfile -t process_roots < <(cape_process_roots)
    if (("${#process_roots[@]}" == 1)); then
      CAPE_ROOT="${process_roots[0]}"
      CAPE_ROOT_SOURCE="running-process"
      pass "Live CAPE installation disambiguated from running process state"
      return 0
    fi
    CAPE_ROOT=""
    CAPE_ROOT_SOURCE="ambiguous-systemd"
    add_error "CAPE-related systemd units resolve to multiple roots: ${service_roots[*]}"
    return 0
  fi

  mapfile -t process_roots < <(cape_process_roots)
  if (("${#process_roots[@]}" == 1)); then
    CAPE_ROOT="${process_roots[0]}"
    CAPE_ROOT_SOURCE="running-process"
    pass "Live CAPE installation discovered from running process state"
    return 0
  elif (("${#process_roots[@]}" > 1)); then
    CAPE_ROOT=""
    CAPE_ROOT_SOURCE="ambiguous-process"
    add_error "Running processes resolve to multiple CAPE roots: ${process_roots[*]}"
    return 0
  fi

  mapfile -t fallback_roots < <(cape_fallback_roots | sed '/^$/d' | sort -u)
  if (("${#fallback_roots[@]}" == 1)); then
    CAPE_ROOT="${fallback_roots[0]}"
    CAPE_ROOT_SOURCE="configuration-search"
    pass "CAPE installation discovered from configuration files"
  elif (("${#fallback_roots[@]}" == 0)); then
    CAPE_ROOT=""
    CAPE_ROOT_SOURCE="not-found"
    add_error "No unique CAPE root containing conf/kvm.conf and conf/cuckoo.conf was found"
  else
    CAPE_ROOT=""
    CAPE_ROOT_SOURCE="ambiguous-filesystem"
    add_error "Multiple CAPE configuration roots found without an authoritative service/process: ${fallback_roots[*]}"
  fi
}

cape_choose_service_candidate() {
  local candidates="$1" unit
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      printf '%s\n' "$unit"
      return 0
    fi
  done <<<"$candidates"
  printf '%s\n' "$candidates" | sed '/^$/d' | head -1
}

discover_cape_services() {
  CAPE_SERVICES=()
  CAPE_SCHEDULER_SERVICE=""
  CAPE_PROCESSOR_SERVICE=""
  CAPE_WEB_SERVICE=""
  CAPE_ROOTER_SERVICE=""
  CAPE_ROOTER_EXECUTABLE=""

  local unit root wd exec_text name lower sched="" processor="" web="" rooter=""
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    root="$(cape_unit_root "$unit" 2>/dev/null || true)"
    [[ "$root" == "$CAPE_ROOT" ]] || continue

    wd="$(systemctl show "$unit" -p WorkingDirectory --value 2>/dev/null || true)"
    exec_text="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)"
    name="${unit%.service}"
    lower="$(printf '%s %s %s' "$name" "$wd" "$exec_text" | tr '[:upper:]' '[:lower:]')"
    CAPE_SERVICES+=("$unit:$(systemctl is-active "$unit" 2>/dev/null || true)")

    if [[ "$lower" == *rooter.py* || "$lower" == *" rooter"* ]]; then
      rooter+="$unit"$'\n'
    elif [[ "$lower" == *process.py* || "$lower" == *processor* ]]; then
      processor+="$unit"$'\n'
    elif [[ "$lower" == *manage.py* || "$lower" == *gunicorn* || "$lower" == *uwsgi* || "$lower" == *"/web"* ]]; then
      web+="$unit"$'\n'
    elif [[ "$lower" == *cuckoo.py* || "$lower" == *scheduler* || "$lower" == *" cape "* ]]; then
      sched+="$unit"$'\n'
    fi
  done < <(cape_all_systemd_units)

  CAPE_SCHEDULER_SERVICE="$(cape_choose_service_candidate "$sched")"
  CAPE_PROCESSOR_SERVICE="$(cape_choose_service_candidate "$processor")"
  CAPE_WEB_SERVICE="$(cape_choose_service_candidate "$web")"
  CAPE_ROOTER_SERVICE="$(cape_choose_service_candidate "$rooter")"

  if [[ -z "$CAPE_SCHEDULER_SERVICE" ]]; then
    add_error "No CAPE scheduler systemd service could be associated with $CAPE_ROOT"
  fi

  # Rooter service may not exist on a fresh CAPE host. Discover the executable
  # independently; deployment can create an AutoDeploy-owned unit when needed.
  if [[ -n "$CAPE_ROOTER_SERVICE" ]]; then
    exec_text="$(systemctl show "$CAPE_ROOTER_SERVICE" -p ExecStart --value 2>/dev/null || true)"
    CAPE_ROOTER_EXECUTABLE="$(printf '%s\n' "$exec_text" | grep -oE '/[^ ;{}]*rooter\.py' | head -1 || true)"
    # systemd's rendered ExecStart can be lossy for paths containing spaces.
    # Never accept a parsed token unless it is the real file; fall back to the
    # live CAPE tree, where the exact pathname can be resolved safely.
    [[ -n "$CAPE_ROOTER_EXECUTABLE" && -f "$CAPE_ROOTER_EXECUTABLE" ]] || CAPE_ROOTER_EXECUTABLE=""
  fi
  if [[ -z "$CAPE_ROOTER_EXECUTABLE" ]]; then
    CAPE_ROOTER_EXECUTABLE="$(find "$CAPE_ROOT" -maxdepth 5 -type f -name rooter.py -path '*/utils/*' -print -quit 2>/dev/null || true)"
  fi
  [[ -n "$CAPE_ROOTER_EXECUTABLE" ]] || add_error "CAPE Rooter executable could not be discovered under the live CAPE root"
}

discover_cape_git() {
  CAPE_COMMIT="unknown"; CAPE_BRANCH="unknown"; CAPE_DIRTY="unknown"
  [[ -n "${CAPE_ROOT:-}" ]] || return 0
  if git -C "$CAPE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CAPE_COMMIT="$(git -C "$CAPE_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    CAPE_BRANCH="$(git -C "$CAPE_ROOT" branch --show-current 2>/dev/null || true)"
    [[ -n "$CAPE_BRANCH" ]] || CAPE_BRANCH="detached"
    if [[ -n "$(git -C "$CAPE_ROOT" status --porcelain 2>/dev/null || true)" ]]; then CAPE_DIRTY="yes"; else CAPE_DIRTY="no"; fi
  fi
}

discover_cape_database_backend() {
  CAPE_DB_BACKEND="unknown"
  [[ -n "${CAPE_ROOT:-}" && -f "$CAPE_ROOT/conf/cuckoo.conf" ]] || return 0
  CAPE_DB_BACKEND="$(ad_python - "$CAPE_ROOT/conf/cuckoo.conf" <<'PY'
import configparser,sys,urllib.parse
c=configparser.ConfigParser(interpolation=None,strict=False)
c.read(sys.argv[1])
value=c.get("database","connection",fallback="").strip()
if not value:
    print("sqlite")
else:
    scheme=urllib.parse.urlsplit(value).scheme.lower()
    base=scheme.split("+",1)[0]
    print(base or "unknown")
PY
)"
}

discover_cape_machine_records() {
  CAPE_MACHINE_RECORDS=()
  [[ -n "${CAPE_ROOT:-}" ]] || return 0

  local -a parsed=()
  mapfile -t parsed < <(ad_python - "$CAPE_ROOT/conf/kvm.conf" <<'PY'
import configparser,json,sys
p=sys.argv[1]
cfg=configparser.ConfigParser(interpolation=None, strict=False)
cfg.optionxform=str.lower
cfg.read(p)
ignore={'kvm','resultserver','timeouts'}

configured=[]
if cfg.has_section('kvm'):
    raw=cfg.get('kvm','machines',fallback='').strip()
    configured=[x.strip() for x in raw.replace('\n',',').split(',') if x.strip()]

def error(msg):
    print("__AUTODEPLOY_ERROR__"+msg)

if configured:
    seen=set()
    for sec in configured:
        if sec in seen:
            error(f"Duplicate CAPE machine in [kvm] machines list: {sec}")
            continue
        seen.add(sec)
        if not cfg.has_section(sec):
            error(f"CAPE [kvm] machines lists missing section: {sec}")
            continue
        d={k.lower():v.strip() for k,v in cfg.items(sec)}
        if d.get('enabled','yes').lower() in ('no','false','0'):
            error(f"CAPE [kvm] machines lists disabled section: {sec}")
            continue
        platform=d.get('platform','').strip().lower()
        if platform and not platform.startswith('windows'):
            error(f"Active CAPE KVM machine is not Windows-compatible: {sec} ({platform})")
            continue
        if not any(k in d for k in ('ip','label','snapshot','platform','interface')):
            error(f"Active CAPE KVM machine section has no machine fields: {sec}")
            continue
        print(json.dumps({
            'section':sec,
            'label':d.get('label',sec),
            'ip':d.get('ip',''),
            'snapshot':d.get('snapshot',''),
            'interface':d.get('interface',''),
            'platform':d.get('platform',''),
            'resultserver_ip':d.get('resultserver_ip',''),
            'resultserver_port':d.get('resultserver_port','')
        }, separators=(',',':')))
else:
    # Legacy fallback only when CAPE does not declare [kvm] machines. In this
    # mode explicit non-Windows sections are ignored because there is no
    # authoritative active-machine list to prove they are scheduled by KVM.
    for sec in cfg.sections():
        if sec.lower() in ignore:
            continue
        d={k.lower():v.strip() for k,v in cfg.items(sec)}
        if not any(k in d for k in ('ip','label','snapshot','platform','interface')):
            continue
        if d.get('enabled','yes').lower() in ('no','false','0'):
            continue
        platform=d.get('platform','').strip().lower()
        if platform and not platform.startswith('windows'):
            continue
        print(json.dumps({
            'section':sec,
            'label':d.get('label',sec),
            'ip':d.get('ip',''),
            'snapshot':d.get('snapshot',''),
            'interface':d.get('interface',''),
            'platform':d.get('platform',''),
            'resultserver_ip':d.get('resultserver_ip',''),
            'resultserver_port':d.get('resultserver_port','')
        }, separators=(',',':')))
PY
)

  local item
  for item in "${parsed[@]}"; do
    if [[ "$item" == __AUTODEPLOY_ERROR__* ]]; then
      add_error "${item#__AUTODEPLOY_ERROR__}"
    else
      CAPE_MACHINE_RECORDS+=("$item")
    fi
  done
  if (("${#CAPE_MACHINE_RECORDS[@]}" == 0)); then
    add_error "No enabled Windows-compatible CAPE analysis-machine sections were discovered"
  fi
}
record_field(){ ad_python -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"; }

select_machine_by_request() {
  local req="$1" rec section label
  SELECTED_MACHINE_JSON=""
  for rec in "${CAPE_MACHINE_RECORDS[@]}"; do
    section="$(record_field "$rec" section)"; label="$(record_field "$rec" label)"
    if [[ "$req" == "$section" || "$req" == "$label" ]]; then SELECTED_MACHINE_JSON="$rec"; break; fi
  done
  [[ -n "$SELECTED_MACHINE_JSON" ]] || add_error "Requested CAPE machine '$req' was not found"
}

set_selected_machine_fields() {
  [[ -n "${SELECTED_MACHINE_JSON:-}" ]] || return 0
  CAPE_MACHINE_SECTION="$(record_field "$SELECTED_MACHINE_JSON" section)"
  CAPE_MACHINE_LABEL="$(record_field "$SELECTED_MACHINE_JSON" label)"
  CAPE_MACHINE_IP="$(record_field "$SELECTED_MACHINE_JSON" ip)"
  CAPE_MACHINE_SNAPSHOT="$(record_field "$SELECTED_MACHINE_JSON" snapshot)"
  CAPE_MACHINE_INTERFACE="$(record_field "$SELECTED_MACHINE_JSON" interface)"
  CAPE_MACHINE_PLATFORM="$(record_field "$SELECTED_MACHINE_JSON" platform)"
  CAPE_MACHINE_RESULTSERVER_IP="$(record_field "$SELECTED_MACHINE_JSON" resultserver_ip)"
  CAPE_MACHINE_RESULTSERVER_PORT="$(record_field "$SELECTED_MACHINE_JSON" resultserver_port)"
}

discover_resultserver() {
  CAPE_RESULTSERVER_IP=""
  CAPE_RESULTSERVER_PORT=""
  CONTROL_HOST_IP=""
  [[ -n "${CAPE_ROOT:-}" && -n "${CAPE_MACHINE_IP:-}" ]] || return 0

  local global_ip global_port route_line
  read -r global_ip global_port < <(ad_python - "$CAPE_ROOT/conf/cuckoo.conf" <<'PY'
import configparser,sys
c=configparser.ConfigParser(interpolation=None,strict=False)
c.read(sys.argv[1])
print(c.get('resultserver','ip',fallback=''), c.get('resultserver','port',fallback='2042'))
PY
)
  route_line="$(ip -4 route get "$CAPE_MACHINE_IP" 2>/dev/null | head -1 || true)"
  CONTROL_HOST_IP="$(awk '{for(i=1;i<=NF;i++) if($i=="src" && i<NF){print $(i+1);exit}}' <<<"$route_line")"

  CAPE_RESULTSERVER_IP="${CAPE_MACHINE_RESULTSERVER_IP:-}"
  if [[ -z "$CAPE_RESULTSERVER_IP" || "$CAPE_RESULTSERVER_IP" == "0.0.0.0" ]]; then
    if [[ -n "$global_ip" && "$global_ip" != "0.0.0.0" ]] &&
       ad_python - "$global_ip" <<'PY' >/dev/null 2>&1
import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1])
raise SystemExit(0 if ip.version==4 and not ip.is_loopback and not ip.is_unspecified else 1)
PY
    then
      CAPE_RESULTSERVER_IP="$global_ip"
    else
      CAPE_RESULTSERVER_IP="$CONTROL_HOST_IP"
    fi
  fi
  CAPE_RESULTSERVER_PORT="${CAPE_MACHINE_RESULTSERVER_PORT:-$global_port}"
  [[ -n "$CAPE_RESULTSERVER_PORT" ]] || CAPE_RESULTSERVER_PORT=2042

  [[ -n "$CAPE_RESULTSERVER_IP" ]] || add_error "Could not derive a guest-reachable CAPE ResultServer IP"
  [[ "$CAPE_RESULTSERVER_PORT" =~ ^[0-9]+$ ]] || add_error "Invalid ResultServer port: $CAPE_RESULTSERVER_PORT"

  if [[ -n "$CAPE_RESULTSERVER_IP" ]]; then
    local resultserver_local=no addr
    while IFS= read -r addr; do
      [[ "$addr" == "$CAPE_RESULTSERVER_IP" ]] && { resultserver_local=yes; break; }
    done < <(ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
    if [[ "$resultserver_local" != yes ]]; then
      add_error "CAPE ResultServer IP $CAPE_RESULTSERVER_IP is not host-local; v1 refuses a routed ResultServer path that could weaken the Windows egress guard"
    fi
  fi
}
