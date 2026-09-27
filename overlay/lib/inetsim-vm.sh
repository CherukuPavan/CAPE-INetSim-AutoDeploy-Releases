#!/usr/bin/env bash

INETSIM_DOMAIN_NAME="${INETSIM_DOMAIN_NAME:-cape-inetsim-appliance}"
INETSIM_MEMORY_MIB="${INETSIM_MEMORY_MIB:-2048}"

choose_libvirt_storage_pool() {
  local p state xml typ avail path
  if [[ -n "${LIBVIRT_STORAGE_POOL:-}" && -n "${LIBVIRT_STORAGE_PATH:-}" && -d "$LIBVIRT_STORAGE_PATH" ]]; then
    state="$(virsh pool-info "$LIBVIRT_STORAGE_POOL" 2>/dev/null | awk -F: '/^State:/ {gsub(/^[ \t]+/,"",$2);print $2}')"
    avail="$(df -Pk "$LIBVIRT_STORAGE_PATH" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ "$state" == running && "$avail" =~ ^[0-9]+$ && "$avail" -ge 20971520 ]]; then
      return 0
    fi
    LIBVIRT_STORAGE_POOL=""
    LIBVIRT_STORAGE_PATH=""
  fi

  local -a ordered=()
  virsh pool-info default >/dev/null 2>&1 && ordered+=(default)
  while IFS= read -r p; do [[ -n "$p" && "$p" != default ]] && ordered+=("$p"); done < <(virsh pool-list --all --name 2>/dev/null)
  for p in "${ordered[@]}"; do
    state="$(virsh pool-info "$p" 2>/dev/null | awk -F: '/^State:/ {gsub(/^[ \t]+/,"",$2);print $2}')"
    [[ "$state" == running ]] || continue
    xml="$(virsh pool-dumpxml "$p" 2>/dev/null || true)"
    typ="$(ad_python -c 'import sys,xml.etree.ElementTree as E; r=E.fromstring(sys.stdin.read()); print(r.get("type",""))' <<<"$xml" 2>/dev/null || true)"
    [[ "$typ" == dir ]] || continue
    path="$(ad_python -c 'import sys,xml.etree.ElementTree as E; r=E.fromstring(sys.stdin.read()); x=r.find("./target/path"); print(x.text if x is not None else "")' <<<"$xml" 2>/dev/null || true)"
    [[ -n "$path" && -d "$path" ]] || continue
    avail="$(df -Pk "$path" | awk 'NR==2{print $4}')"
    [[ "$avail" =~ ^[0-9]+$ && "$avail" -ge 20971520 ]] || continue
    LIBVIRT_STORAGE_POOL="$p"
    LIBVIRT_STORAGE_PATH="$path"
    return 0
  done
  fail "No active directory libvirt storage pool with at least 20 GiB free was found"
  return 1
}

inject_qga_channel() {
  ad_python -c '
import sys,xml.etree.ElementTree as ET
r=ET.fromstring(sys.stdin.read())
devices=r.find("devices")
if devices is None: raise SystemExit("domain XML has no devices")
for c in devices.findall("channel"):
    t=c.find("target")
    if t is not None and t.get("name")=="org.qemu.guest_agent.0":
        print(ET.tostring(r,encoding="unicode"))
        raise SystemExit
c=ET.SubElement(devices,"channel",{"type":"unix"})
ET.SubElement(c,"target",{"type":"virtio","name":"org.qemu.guest_agent.0"})
print(ET.tostring(r,encoding="unicode"))
'
}


INETSIM_GRAPHICS_CHANGED=no

inetsim_refresh_baked_gui_appliance() {
  local artifact new_disk old_disk state i
  state_resource_owned domain "$INETSIM_DOMAIN_NAME" || {
    fail "Refusing GUI appliance refresh because INetSim domain is not AutoDeploy-owned"
    return 1
  }
  state_resource_owned disk "$INETSIM_DISK_PATH" || {
    fail "Refusing GUI appliance refresh because INetSim disk is not AutoDeploy-owned"
    return 1
  }

  artifact="$(appliance_fetch "$APPLIANCE_MANIFEST")" || return 1
  new_disk="$INETSIM_DISK_PATH.gui-refresh-new"
  old_disk="$INETSIM_DISK_PATH.gui-refresh-old"

  rm -f "$new_disk" "$old_disk"
  info "Preparing verified GUI-ready INetSim appliance replacement"
  qemu-img convert -p -O qcow2 "$artifact" "$new_disk"
  qemu-img check "$new_disk" >/dev/null || {
    rm -f "$new_disk"
    fail "Prepared GUI-ready INetSim appliance disk failed qcow2 integrity check"
    return 1
  }

  virsh shutdown "$INETSIM_DOMAIN_NAME" --mode agent >/dev/null 2>&1 || true
  for ((i=0;i<60;i++)); do
    state="$(virsh domstate "$INETSIM_DOMAIN_NAME" 2>/dev/null | tr -d '\r' || true)"
    [[ "$state" == "shut off" ]] && break
    sleep 1
  done
  state="$(virsh domstate "$INETSIM_DOMAIN_NAME" 2>/dev/null | tr -d '\r' || true)"
  [[ "$state" == "shut off" ]] || virsh destroy "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true

  mv "$INETSIM_DISK_PATH" "$old_disk"
  if ! mv "$new_disk" "$INETSIM_DISK_PATH"; then
    mv "$old_disk" "$INETSIM_DISK_PATH" 2>/dev/null || true
    fail "Could not activate GUI-ready INetSim appliance disk"
    return 1
  fi

  local refresh_ready=no refresh_try
  if virsh start "$INETSIM_DOMAIN_NAME" >/dev/null &&
     qga_wait "$INETSIM_DOMAIN_NAME" 240; then
    for refresh_try in $(seq 1 30); do
      if qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c '
        set -eu
        test -f /etc/cape-inetsim-gui-v6
        test -f /usr/lib/xorg/modules/drivers/modesetting_drv.so
        test -f /usr/share/xsessions/xubuntu.desktop
        test "$(dpkg-query -W -f="\${Status}" xubuntu-desktop-minimal 2>/dev/null)" = "install ok installed"
        id capeinetsim >/dev/null 2>&1
        systemctl list-unit-files lightdm.service >/dev/null 2>&1
      ' >/dev/null 2>&1; then
        refresh_ready=yes
        break
      fi
      sleep 2
    done
  fi

  if [[ "$refresh_ready" != yes ]]; then
    local refresh_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-gui-refresh-validation.log"
    {
      echo "=== GUI marker ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/ls -l /etc/cape-inetsim-gui-v6 || true
      echo "=== modesetting driver ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/ls -l /usr/lib/xorg/modules/drivers/modesetting_drv.so || true
      echo "=== xubuntu session ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/ls -l /usr/share/xsessions/xubuntu.desktop || true
      echo "=== xubuntu package status ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c 'dpkg-query -W -f="\${Status}\n" xubuntu-desktop-minimal 2>&1 || true' || true
      echo "=== capeinetsim identity ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/id capeinetsim || true
      echo "=== lightdm unit ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c 'systemctl list-unit-files lightdm.service 2>&1 || true' || true
    } >"$refresh_log" 2>&1

    virsh destroy "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    rm -f "$INETSIM_DISK_PATH"
    mv "$old_disk" "$INETSIM_DISK_PATH"
    virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    qga_wait "$INETSIM_DOMAIN_NAME" 120 >/dev/null 2>&1 || true
    fail "GUI-ready appliance refresh failed validation; original INetSim disk was restored; diagnostics captured at $refresh_log"
    return 1
  fi

  rm -f "$old_disk"
  state_record_resource inetsim-gui-refresh "$INETSIM_DOMAIN_NAME" replaced yes "verified-release-appliance"
  state_write_atomic
  pass "Refreshed INetSim appliance to verified GUI-ready release image"
}

inetsim_ensure_graphics_console() {
  local raw="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-inetsim-graphics.xml"
  local current
  INETSIM_GRAPHICS_CHANGED=no

  current="$(virsh dumpxml --inactive "$INETSIM_DOMAIN_NAME" 2>/dev/null)" || {
    fail "Could not read persistent INetSim domain XML for graphical-console setup"
    return 1
  }

  if ad_python -c '
import sys,xml.etree.ElementTree as ET
r=ET.fromstring(sys.stdin.read())
g=r.find("./devices/graphics")
v=r.find("./devices/video/model")
ok=(g is not None and g.get("type")=="spice" and v is not None and v.get("type")=="virtio")
raise SystemExit(0 if ok else 1)
' <<<"$current"; then
    return 0
  fi

  ad_python -c '
import sys,xml.etree.ElementTree as ET
out=sys.argv[1]
r=ET.fromstring(sys.stdin.read())
d=r.find("devices")
if d is None:
    raise SystemExit("domain XML has no devices")
for x in list(d.findall("graphics")):
    d.remove(x)
for x in list(d.findall("video")):
    d.remove(x)
g=ET.SubElement(d,"graphics",{"type":"spice","autoport":"yes","listen":"127.0.0.1"})
ET.SubElement(g,"listen",{"type":"address","address":"127.0.0.1"})
v=ET.SubElement(d,"video")
ET.SubElement(v,"model",{"type":"virtio","heads":"1","primary":"yes"})
ET.indent(r,space="  ")
ET.ElementTree(r).write(out,encoding="unicode")
' "$raw" <<<"$current"

  virsh define "$raw" >/dev/null || {
    fail "Could not add persistent SPICE/Virtio graphical console to INetSim appliance"
    return 1
  }

  INETSIM_GRAPHICS_CHANGED=yes
  state_record_resource domain-graphics "$INETSIM_DOMAIN_NAME" configured yes "type=spice video=virtio listen=127.0.0.1"
  state_write_atomic
  pass "Configured persistent SPICE/Virtio graphical console for INetSim appliance"
}

inetsim_enable_gui_guest() {
  local guest_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-gui-enable.log"
  local restart=no

  inetsim_ensure_graphics_console || return 1
  [[ "$INETSIM_GRAPHICS_CHANGED" == yes ]] && restart=yes

  virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
  qga_wait "$INETSIM_DOMAIN_NAME" 240 || {
    fail "INetSim appliance QEMU Guest Agent did not come online for GUI setup"
    return 1
  }

  # A legacy appliance is replaced rather than apt-mutated at runtime. This
  # keeps fresh/random deployments deterministic and independent of guest
  # Internet access.
  if ! qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c '
       test -f /etc/cape-inetsim-gui-v6 &&
       test -f /usr/lib/xorg/modules/drivers/modesetting_drv.so &&
       test -f /usr/share/xsessions/xubuntu.desktop &&
       dpkg-query -W -f="\${Status}" xubuntu-desktop-minimal 2>/dev/null | grep -Fq "install ok installed" &&
       id capeinetsim >/dev/null 2>&1
     ' >/dev/null 2>&1; then
    info "Existing INetSim appliance predates the validated Xubuntu GUI image; refreshing only the AutoDeploy-owned appliance"
    inetsim_refresh_baked_gui_appliance || return 1
    inetsim_configure_guest || return 1
    inetsim_verify_host || return 1
    restart=yes
  fi

  # Apply one unambiguous local GUI identity and clean all stale X session
  # state before testing the desktop. The Ubuntu cloud bootstrap account is
  # hidden/disabled after image construction.
  qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c '
    set -eu
    test -f /usr/share/xsessions/xubuntu.desktop
    id capeinetsim >/dev/null
    usermod -s /bin/bash -c "CAPE INetSim" capeinetsim
    usermod -aG sudo,video capeinetsim >/dev/null 2>&1 || true

    if id ubuntu >/dev/null 2>&1; then
      usermod -L -s /usr/sbin/nologin ubuntu >/dev/null 2>&1 || true
      install -d -m 0755 /var/lib/AccountsService/users
      cat >/var/lib/AccountsService/users/ubuntu <<"EOF"
[User]
SystemAccount=true
EOF
      chmod 0600 /var/lib/AccountsService/users/ubuntu
    fi

    install -d -m 0755 /var/lib/AccountsService/users
    cat >/var/lib/AccountsService/users/capeinetsim <<"EOF"
[User]
Session=xubuntu
XSession=xubuntu
SystemAccount=false
EOF
    chmod 0600 /var/lib/AccountsService/users/capeinetsim

    cat >/home/capeinetsim/.dmrc <<"EOF"
[Desktop]
Session=xubuntu
EOF
    chown capeinetsim:capeinetsim /home/capeinetsim/.dmrc
    chmod 0600 /home/capeinetsim/.dmrc

    rm -f /home/capeinetsim/.Xauthority /home/capeinetsim/.ICEauthority
    rm -rf /home/capeinetsim/.cache/sessions /home/capeinetsim/.dbus
    chown -R capeinetsim:capeinetsim /home/capeinetsim
    chmod 1777 /tmp

    install -d -m 0755 /etc/lightdm/lightdm.conf.d
    rm -f /etc/lightdm/lightdm.conf.d/50-cape-inetsim-autologin.conf
    rm -f /etc/lightdm/lightdm.conf.d/98-cape-inetsim-selftest.conf
    rm -f /etc/lightdm/lightdm.conf.d/99-cape-inetsim-autologin.conf
    cat >/etc/lightdm/lightdm.conf.d/99-cape-inetsim-console-login.conf <<"EOF"
[Seat:*]
user-session=xubuntu
allow-user-switching=false
allow-guest=false
greeter-hide-users=false
greeter-show-manual-login=false
EOF

    install -d -m 0755 /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/99-cape-inetsim-no-password-auth.conf <<"EOF"
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF

    touch /etc/cape-inetsim-gui-v6
  ' >/dev/null 2>&1 || {
    fail "Could not normalize the INetSim Xubuntu console identity/session"
    return 1
  }

  local password="${CAPE_INETSIM_GUI_PASSWORD:-123}"
  local password_b64
  password_b64="$(printf '%s' "$password" | base64 -w0)"
  qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c "
    set -eu
    pw=\$(printf '%s' '$password_b64' | /usr/bin/base64 -d)
    printf 'root:%s\\ncapeinetsim:%s\\n' \"\$pw\" \"\$pw\" | /usr/sbin/chpasswd
    for user in root capeinetsim; do
      hash=\$(getent shadow \"\$user\" | cut -d: -f2)
      /usr/bin/perl -e 'exit(crypt(\$ARGV[0],\$ARGV[1]) eq \$ARGV[1] ? 0 : 1)' \"\$pw\" \"\$hash\"
    done
  " >/dev/null 2>&1 || {
    fail "Could not apply and cryptographically verify the local INetSim console password"
    return 1
  }
  pass "Configured the INetSim local console user capeinetsim (password supplied by installer; default 123)"

  # Target-host GUI acceptance test. Temporarily let LightDM autologin the exact
  # production user/session, require the real desktop processes to stay alive,
  # then return to the normal password greeter.
  qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c '
    set -eu
    groupadd -f autologin
    usermod -aG autologin capeinetsim
    cat >/etc/lightdm/lightdm.conf.d/98-cape-inetsim-selftest.conf <<"EOF"
[Seat:*]
autologin-user=capeinetsim
autologin-user-timeout=0
autologin-session=xubuntu
user-session=xubuntu
EOF
    systemctl set-default graphical.target
    systemctl restart lightdm.service
  ' >/dev/null 2>&1 || {
    fail "Could not start the INetSim desktop acceptance test"
    return 1
  }

  local desktop_ok=no desktop_try
  for desktop_try in $(seq 1 90); do
    if qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c '
         systemctl is-active --quiet lightdm.service &&
         test -S /tmp/.X11-unix/X0 &&
         pgrep -x Xorg >/dev/null &&
         pgrep -u capeinetsim -f "xfce4-session" >/dev/null &&
         pgrep -u capeinetsim -f "xfce4-panel" >/dev/null &&
         pgrep -u capeinetsim -f "xfdesktop" >/dev/null
       ' >/dev/null 2>&1; then
      sleep 5
      if qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c '
           systemctl is-active --quiet lightdm.service &&
           pgrep -u capeinetsim -f "xfce4-session" >/dev/null &&
           pgrep -u capeinetsim -f "xfce4-panel" >/dev/null &&
           pgrep -u capeinetsim -f "xfdesktop" >/dev/null
         ' >/dev/null 2>&1; then
        desktop_ok=yes
        break
      fi
    fi
    sleep 1
  done

  if [[ "$desktop_ok" != yes ]]; then
    {
      echo "=== lightdm status ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/systemctl status lightdm.service --no-pager -l || true
      echo "=== lightdm journal ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/journalctl -u lightdm.service -b -n 250 --no-pager || true
      echo "=== lightdm logs ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c 'for f in /var/log/lightdm/*.log; do echo "--- $f"; tail -n 250 "$f"; done' || true
      echo "=== xsession errors ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c 'cat /home/capeinetsim/.xsession-errors 2>/dev/null || true' || true
      echo "=== home ownership ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c 'ls -ld /home/capeinetsim /home/capeinetsim/.[!.]* 2>/dev/null || true' || true
      echo "=== processes ==="
      qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c 'ps -ef | grep -E "lightdm|Xorg|xfce|xfwm|xfdesktop" | grep -v grep || true' || true
    } >"$guest_log" 2>&1
    qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/rm -f /etc/lightdm/lightdm.conf.d/98-cape-inetsim-selftest.conf >/dev/null 2>&1 || true
    qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/systemctl restart lightdm.service >/dev/null 2>&1 || true
    fail "INetSim real Xubuntu desktop acceptance test failed; diagnostics captured at $guest_log"
    return 1
  fi
  pass "Real Xubuntu/XFCE desktop session started and remained stable inside the INetSim appliance"

  qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c '
    rm -f /etc/lightdm/lightdm.conf.d/98-cape-inetsim-selftest.conf
    loginctl terminate-user capeinetsim >/dev/null 2>&1 || true
    rm -f /home/capeinetsim/.Xauthority /home/capeinetsim/.ICEauthority
    rm -rf /home/capeinetsim/.cache/sessions
    chown -R capeinetsim:capeinetsim /home/capeinetsim
    systemctl restart lightdm.service
  ' >/dev/null 2>&1 || {
    fail "Desktop self-test passed but the normal password greeter could not be restored"
    return 1
  }

  local greeter_ok=no
  for desktop_try in $(seq 1 45); do
    if qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c '
         systemctl is-active --quiet lightdm.service &&
         test -S /tmp/.X11-unix/X0 &&
         pgrep -x Xorg >/dev/null &&
         ! pgrep -u capeinetsim -f "xfce4-session" >/dev/null
       ' >/dev/null 2>&1; then
      greeter_ok=yes
      break
    fi
    sleep 1
  done
  [[ "$greeter_ok" == yes ]] || {
    fail "Xubuntu desktop test passed but LightDM did not return to the password login screen"
    return 1
  }

  local display_uri
  display_uri="$(virsh domdisplay "$INETSIM_DOMAIN_NAME" 2>/dev/null || true)"
  [[ "$display_uri" == spice://* ]] || {
    fail "INetSim appliance has no active SPICE graphical display"
    return 1
  }
  pass "INetSim GUI acceptance passed: one visible capeinetsim account, stable Xubuntu desktop, SPICE/Virtio console"
}

inetsim_domain_macs() {
  virsh dumpxml "$INETSIM_DOMAIN_NAME" | ad_python -c '
import sys,xml.etree.ElementTree as ET
r=ET.fromstring(sys.stdin.read())
for i in r.findall("./devices/interface"):
    s=i.find("source")
    m=i.find("mac")
    if s is not None:
        print((s.get("network") or "")+"|"+(m.get("address") if m is not None else ""))
'
}

inetsim_domain_matches_plan() {
  local xml
  xml="$(virsh dumpxml "$INETSIM_DOMAIN_NAME" 2>/dev/null)" || return 1
  ad_python -c '
import os,sys,xml.etree.ElementTree as ET
disk,mgmt,isolated=sys.argv[1:]
r=ET.fromstring(sys.stdin.read())
files=[]
for d in r.findall("./devices/disk"):
    if d.get("device")!="disk": continue
    s=d.find("source")
    if s is not None and s.get("file"): files.append(os.path.realpath(s.get("file")))
if os.path.realpath(disk) not in files: raise SystemExit(1)
nets=[]
for i in r.findall("./devices/interface"):
    s=i.find("source")
    if s is not None and s.get("network"): nets.append(s.get("network"))
if nets.count(mgmt)!=1 or nets.count(isolated)!=1: raise SystemExit(1)
qga=False
for ch in r.findall("./devices/channel"):
    t=ch.find("target")
    if t is not None and t.get("name")=="org.qemu.guest_agent.0": qga=True
if not qga: raise SystemExit(1)
' "$INETSIM_DISK_PATH" "$MANAGEMENT_NETWORK_NAME" "$ISOLATED_NETWORK_NAME" <<<"$xml"
}

inetsim_copy_appliance_disk() {
  local artifact="$1"

  if [[ -z "${INETSIM_DISK_PATH:-}" ]]; then
    choose_libvirt_storage_pool
    INETSIM_DISK_PATH="$LIBVIRT_STORAGE_PATH/cape-inetsim-appliance-v1.qcow2"
  else
    [[ -n "${LIBVIRT_STORAGE_PATH:-}" ]] || LIBVIRT_STORAGE_PATH="$(dirname "$INETSIM_DISK_PATH")"
    if [[ -z "${LIBVIRT_STORAGE_POOL:-}" ]]; then
      local p path
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        path="$(virsh pool-dumpxml "$p" 2>/dev/null | ad_python -c 'import sys,xml.etree.ElementTree as E
try: r=E.fromstring(sys.stdin.read())
except Exception: raise SystemExit
x=r.find("./target/path")
print(x.text if x is not None else "")' 2>/dev/null || true)"
        if [[ "$path" == "$LIBVIRT_STORAGE_PATH" ]]; then LIBVIRT_STORAGE_POOL="$p"; break; fi
      done < <(virsh pool-list --all --name 2>/dev/null)
    fi
  fi

  if [[ -e "$INETSIM_DISK_PATH" ]]; then
    if state_resource_owned disk "$INETSIM_DISK_PATH"; then
      qemu-img check "$INETSIM_DISK_PATH" >/dev/null
      return 0
    fi
    if state_resource_intended disk "$INETSIM_DISK_PATH"; then
      qemu-img check "$INETSIM_DISK_PATH" >/dev/null
      state_record_resource disk "$INETSIM_DISK_PATH" recovered-created yes "pool=${LIBVIRT_STORAGE_POOL:-unknown}"
      state_write_atomic
      pass "Recovered deployment-owned INetSim disk after interrupted create"
      return 0
    fi
    fail "INetSim target disk already exists but is not AutoDeploy-owned: $INETSIM_DISK_PATH"
    return 1
  fi

  [[ -d "$(dirname "$INETSIM_DISK_PATH")" ]] || { fail "INetSim disk directory is unavailable: $(dirname "$INETSIM_DISK_PATH")"; return 1; }
  local avail
  avail="$(df -Pk "$(dirname "$INETSIM_DISK_PATH")" | awk 'NR==2{print $4}')"
  [[ "$avail" =~ ^[0-9]+$ && "$avail" -ge 20971520 ]] || { fail "Less than 20 GiB free for INetSim appliance disk"; return 1; }

  state_write_atomic
  state_record_intent disk "$INETSIM_DISK_PATH" creating "pool=${LIBVIRT_STORAGE_POOL:-unknown}"
  rm -f "$INETSIM_DISK_PATH.part"
  qemu-img convert -p -O qcow2 "$artifact" "$INETSIM_DISK_PATH.part"
  qemu-img check "$INETSIM_DISK_PATH.part" >/dev/null
  mv "$INETSIM_DISK_PATH.part" "$INETSIM_DISK_PATH"
  chmod 0644 "$INETSIM_DISK_PATH"
  [[ -n "${LIBVIRT_STORAGE_POOL:-}" ]] && virsh pool-refresh "$LIBVIRT_STORAGE_POOL" >/dev/null 2>&1 || true
  state_record_resource disk "$INETSIM_DISK_PATH" created yes "pool=${LIBVIRT_STORAGE_POOL:-unknown}"
  state_write_atomic
}

inetsim_define_domain() {
  [[ -n "${MANAGEMENT_NETWORK_NAME:-}" ]] || { fail "Management libvirt network is unknown"; return 1; }

  if virsh dominfo "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1; then
    inetsim_domain_matches_plan || { fail "Existing domain $INETSIM_DOMAIN_NAME does not match deployment plan"; return 1; }
    if state_resource_owned domain "$INETSIM_DOMAIN_NAME"; then
      virsh autostart "$INETSIM_DOMAIN_NAME" >/dev/null
    elif state_resource_intended domain "$INETSIM_DOMAIN_NAME"; then
      virsh autostart "$INETSIM_DOMAIN_NAME" >/dev/null
      state_record_resource domain "$INETSIM_DOMAIN_NAME" recovered-created yes "disk=$INETSIM_DISK_PATH"
      pass "Recovered deployment-owned INetSim domain after interrupted create"
    else
      fail "Domain $INETSIM_DOMAIN_NAME exists but is not AutoDeploy-owned"
      return 1
    fi

    INETSIM_MANAGEMENT_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$MANAGEMENT_NETWORK_NAME" '$1==n{print $2;exit}')"
    INETSIM_ISOLATED_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$ISOLATED_NETWORK_NAME" '$1==n{print $2;exit}')"
    [[ -n "$INETSIM_MANAGEMENT_MAC" && -n "$INETSIM_ISOLATED_MAC" ]] || { fail "Could not identify appliance NIC MAC addresses"; return 1; }
    state_write_atomic
    return 0
  fi

  local raw="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-inetsim-domain.raw.xml"
  local xml="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-inetsim-domain.xml"
  virt-install --connect qemu:///system --name "$INETSIM_DOMAIN_NAME" --memory "$INETSIM_MEMORY_MIB" --vcpus 2 --import     --disk "path=$INETSIM_DISK_PATH,format=qcow2,bus=virtio"     --network "network=$MANAGEMENT_NETWORK_NAME,model=virtio"     --network "network=$ISOLATED_NETWORK_NAME,model=virtio"     --os-variant generic --graphics "spice,listen=127.0.0.1" --video virtio --noautoconsole --print-xml >"$raw"
  inject_qga_channel <"$raw" >"$xml"

  state_record_intent domain "$INETSIM_DOMAIN_NAME" defining "disk=$INETSIM_DISK_PATH"
  if ! virsh define "$xml" >/dev/null; then return 1; fi
  if ! virsh autostart "$INETSIM_DOMAIN_NAME" >/dev/null; then
    virsh undefine "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    state_record_resource domain "$INETSIM_DOMAIN_NAME" removed-after-failure no ""
    return 1
  fi
  inetsim_domain_matches_plan || { fail "Defined INetSim domain does not match deployment plan"; return 1; }

  state_record_resource domain "$INETSIM_DOMAIN_NAME" created yes "disk=$INETSIM_DISK_PATH"
  INETSIM_MANAGEMENT_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$MANAGEMENT_NETWORK_NAME" '$1==n{print $2;exit}')"
  INETSIM_ISOLATED_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$ISOLATED_NETWORK_NAME" '$1==n{print $2;exit}')"
  [[ -n "$INETSIM_MANAGEMENT_MAC" && -n "$INETSIM_ISOLATED_MAC" ]] || { fail "Could not identify appliance NIC MAC addresses"; return 1; }
  state_write_atomic
}

inetsim_capture_guest_diagnostics() {
  local out="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-guest-diagnostics.txt"
  qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/sh -c '
set +e
echo "=== date ==="; date -Is
echo "=== addresses ==="; ip -br addr
echo "=== routes ==="; ip -4 route; ip -6 route
echo "=== netplan ==="; cat /etc/netplan/90-cape-inetsim.yaml 2>/dev/null
echo "=== listeners ==="; ss -lnupt
echo "=== inetsim status ==="; systemctl status inetsim.service --no-pager -l
echo "=== inetsim journal ==="; journalctl -u inetsim.service -n 120 --no-pager
' >"$out" 2>&1 || true
}

inetsim_configure_guest() {
  local guest_script='/tmp/cape-inetsim-guest-configure'
  local baked_script='/usr/local/sbin/cape-inetsim-guest-configure'
  local guest_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-guest-configure.log"
  local selected_script="" transport="" current_hash="" baked_hash=""

  virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
  qga_wait "$INETSIM_DOMAIN_NAME" 240 || { fail "INetSim appliance QEMU Guest Agent did not come online"; return 1; }

  # Create the trace before attempting transport so a QGA file-copy failure is
  # preserved for the automatic collector instead of disappearing in rollback.
  : >"$guest_log"
  chmod 0600 "$guest_log"
  current_hash="$(sha256sum "$AUTODEPLOY_ROOT/appliance/guest-configure.sh" | awk '{print $1}')"

  # Prefer the configurator shipped by the current immutable runtime bundle.
  # Some qemu-guest-agent policies expose guest-exec but deny guest-file-* RPCs.
  # In that case, safely fall back only to a byte-identical configurator baked
  # into the checksum-pinned appliance produced from the same release source.
  if qga_file_write "$INETSIM_DOMAIN_NAME" "$AUTODEPLOY_ROOT/appliance/guest-configure.sh" "$guest_script" >>"$guest_log" 2>&1; then
    selected_script="$guest_script"
    transport="qga-file-write"
    printf 'CONFIGURATOR_TRANSPORT=%s\n' "$transport" >>"$guest_log"
  else
    printf 'QGA guest-file transport unavailable; checking baked configurator identity.\n' >>"$guest_log"
    baked_hash="$(qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/sha256sum "$baked_script" 2>>"$guest_log" | awk 'NF {print $1; exit}' || true)"
    if [[ ! "$baked_hash" =~ ^[0-9a-f]{64}$ || "$baked_hash" != "$current_hash" ]]; then
      printf 'EXPECTED_CONFIGURATOR_SHA256=%s\n' "$current_hash" >>"$guest_log"
      printf 'BAKED_CONFIGURATOR_SHA256=%s\n' "${baked_hash:-unavailable}" >>"$guest_log"
      inetsim_capture_guest_diagnostics
      fail "Could not upload the current INetSim guest configurator and the baked configurator could not be proven byte-identical to this release"
      return 1
    fi
    selected_script="$baked_script"
    transport="baked-release-match"
    printf 'CONFIGURATOR_TRANSPORT=%s\n' "$transport" >>"$guest_log"
    printf 'CONFIGURATOR_SHA256=%s\n' "$current_hash" >>"$guest_log"
  fi

  local -a configure_args=(
    /bin/bash -x "$selected_script"
    --management-mac "$INETSIM_MANAGEMENT_MAC"
    --isolated-mac "$INETSIM_ISOLATED_MAC"
    --ip "$INETSIM_IP/24"
    --gateway "$BRIDGE_IP"
  )
  local client_ip
  while IFS= read -r client_ip; do
    [[ -n "$client_ip" ]] && configure_args+=(--client-ip "$client_ip")
  done < <(ad_python - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import json,sys
try: a=json.loads(sys.argv[1])
except Exception: a=[]
for d in a:
    ip=str(d.get("ip") or "")
    if ip:
        print(ip)
PY
)

  if ! qga_exec_wait "$INETSIM_DOMAIN_NAME" "${configure_args[@]}" >>"$guest_log" 2>&1; then
    inetsim_capture_guest_diagnostics
    fail "INetSim guest configuration failed; command trace and guest diagnostics were captured automatically"
    return 1
  fi

  qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/rm -f "$guest_script" >/dev/null 2>&1 || true
  state_record_resource inetsim-guest "$INETSIM_DOMAIN_NAME" configured yes "ip=$INETSIM_IP mac=$INETSIM_ISOLATED_MAC transport=$transport log=$guest_log"
  state_write_atomic
}

inetsim_verify_host() {
  local verify_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-host-verify.log"
  : >"$verify_log"
  chmod 0600 "$verify_log"

  qga_wait "$INETSIM_DOMAIN_NAME" 30 || {
    printf 'qga_wait=failed\n' >>"$verify_log"
    fail "INetSim appliance QEMU Guest Agent is unavailable during verification"
    return 1
  }
  printf 'qga_wait=ok\n' >>"$verify_log"

  local runtime
  if ! runtime="$(qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/sh -c '
set -eu
printf "ipv4_forward=%s\\n" "$(sysctl -n net.ipv4.ip_forward)"
printf "ipv6_forward=%s\\n" "$(sysctl -n net.ipv6.conf.all.forwarding)"
printf "default4=%s\\n" "$(ip -4 route show default | wc -l)"
printf "default6=%s\\n" "$(ip -6 route show default | wc -l)"
' 2>>"$verify_log")"; then
    printf 'runtime_query=failed\n' >>"$verify_log"
    inetsim_capture_guest_diagnostics
    fail "Could not verify INetSim appliance runtime network isolation"
    return 1
  fi
  printf '%s\n' "$runtime" >>"$verify_log"

  grep -Fxq 'ipv4_forward=0' <<<"$runtime" || { inetsim_capture_guest_diagnostics; fail "INetSim appliance IPv4 forwarding is enabled"; return 1; }
  grep -Fxq 'ipv6_forward=0' <<<"$runtime" || { inetsim_capture_guest_diagnostics; fail "INetSim appliance IPv6 forwarding is enabled"; return 1; }
  grep -Eq '^default4=(0|1)$' <<<"$runtime" || { inetsim_capture_guest_diagnostics; fail "INetSim appliance has more than one IPv4 default route"; return 1; }
  grep -Fxq 'default6=0' <<<"$runtime" || { inetsim_capture_guest_diagnostics; fail "INetSim appliance unexpectedly has an IPv6 default route"; return 1; }

  local ready=no i dns_rc http_rc https_rc smtp_rc ftp_rc
  for ((i=0;i<30;i++)); do
    if ad_python "$AUTODEPLOY_ROOT/tools/dns_probe.py" "$INETSIM_IP" "$INETSIM_IP" >/dev/null 2>&1; then dns_rc=0; else dns_rc=$?; fi
    if curl -fsS --max-time 3 "http://$INETSIM_IP/" >/dev/null 2>&1; then http_rc=0; else http_rc=$?; fi
    if curl -kfsS --max-time 3 "https://$INETSIM_IP/" >/dev/null 2>&1; then https_rc=0; else https_rc=$?; fi
    if ad_python - "$INETSIM_IP" 25 220 >/dev/null 2>&1 <<'PY'
import socket,sys
with socket.create_connection((sys.argv[1],int(sys.argv[2])),3) as s:
    s.settimeout(3)
    raise SystemExit(0 if s.recv(512).startswith(sys.argv[3].encode()) else 1)
PY
    then smtp_rc=0; else smtp_rc=$?; fi
    if ad_python - "$INETSIM_IP" 21 220 >/dev/null 2>&1 <<'PY'
import socket,sys
with socket.create_connection((sys.argv[1],int(sys.argv[2])),3) as s:
    s.settimeout(3)
    raise SystemExit(0 if s.recv(512).startswith(sys.argv[3].encode()) else 1)
PY
    then ftp_rc=0; else ftp_rc=$?; fi
    printf 'probe_attempt=%s dns_rc=%s http_rc=%s https_rc=%s smtp_rc=%s ftp_rc=%s\n' "$((i+1))" "$dns_rc" "$http_rc" "$https_rc" "$smtp_rc" "$ftp_rc" >>"$verify_log"
    if [[ "$dns_rc" -eq 0 && "$http_rc" -eq 0 && "$https_rc" -eq 0 && "$smtp_rc" -eq 0 && "$ftp_rc" -eq 0 ]]; then
      ready=yes
      break
    fi
    sleep 1
  done
  if [[ "$ready" != yes ]]; then
    inetsim_capture_guest_diagnostics
    fail "INetSim DNS/HTTP/HTTPS/SMTP/FTP did not become reachable from the CAPE host"
    return 1
  fi
  pass "INetSim DNS/HTTP/HTTPS/SMTP/FTP respond and runtime forwarding isolation is enforced on $INETSIM_IP"
}

inetsim_vm_rollback() {
  if virsh dominfo "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1; then
    if ! state_resource_owned domain "$INETSIM_DOMAIN_NAME"; then
      if state_resource_intended domain "$INETSIM_DOMAIN_NAME" && inetsim_domain_matches_plan; then
        state_record_resource domain "$INETSIM_DOMAIN_NAME" recovered-created yes "rollback-adoption"
      else
        fail "Refusing to remove non-owned INetSim domain $INETSIM_DOMAIN_NAME"
        return 1
      fi
    fi
    virsh destroy "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    virsh undefine "$INETSIM_DOMAIN_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    state_record_resource domain "$INETSIM_DOMAIN_NAME" removed-by-rollback yes ""
  fi

  # Guest configuration ownership is logically removed with the appliance
  # domain. Close it even when a prior rollback attempt already removed the VM.
  if state_resource_owned inetsim-guest "$INETSIM_DOMAIN_NAME"; then
    if virsh dominfo "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1; then
      fail "INetSim domain $INETSIM_DOMAIN_NAME still exists after rollback removal"
      return 1
    fi
    state_record_resource inetsim-guest "$INETSIM_DOMAIN_NAME" removed-by-rollback yes "domain-absent"
  fi

  if [[ -n "${INETSIM_DISK_PATH:-}" ]]; then
    rm -f "$INETSIM_DISK_PATH.part" 2>/dev/null || true
  fi
  if [[ -n "${INETSIM_DISK_PATH:-}" && -e "$INETSIM_DISK_PATH" ]]; then
    if ! state_resource_owned disk "$INETSIM_DISK_PATH"; then
      if state_resource_intended disk "$INETSIM_DISK_PATH"; then
        qemu-img check "$INETSIM_DISK_PATH" >/dev/null || { fail "Intended INetSim disk is not a valid qcow2 image"; return 1; }
        state_record_resource disk "$INETSIM_DISK_PATH" recovered-created yes "rollback-adoption"
      else
        fail "Refusing to remove non-owned INetSim disk $INETSIM_DISK_PATH"
        return 1
      fi
    fi
    rm -f "$INETSIM_DISK_PATH"
    state_record_resource disk "$INETSIM_DISK_PATH" removed-by-rollback yes ""
  fi
}
