#!/usr/bin/env python3
import argparse, hashlib, json, os, pathlib, platform, re, shutil, subprocess, sys, xml.etree.ElementTree as ET

def run(args, timeout=20):
    try:
        p=subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)
        return {"rc":p.returncode,"stdout":p.stdout.strip(),"stderr":p.stderr.strip()}
    except Exception as e:
        return {"rc":-1,"stdout":"","stderr":str(e)}

def cmd(name):
    return shutil.which(name)

def virsh(*args):
    v=cmd("virsh")
    if not v: return {"rc":127,"stdout":"","stderr":"virsh missing"}
    return run([v,"-c","qemu:///system",*args],30)

def parse_interfaces(xml):
    out=[]
    try: root=ET.fromstring(xml)
    except Exception: return out
    for i in root.findall("./devices/interface"):
        src=i.find("source"); mac=i.find("mac"); model=i.find("model")
        out.append({
            "type":i.get("type"),
            "network":src.get("network") if src is not None else None,
            "bridge":src.get("bridge") if src is not None else None,
            "mac":mac.get("address") if mac is not None else None,
            "model":model.get("type") if model is not None else None,
        })
    return out

def selected_state(path):
    p=pathlib.Path(path)
    if not p.is_file(): return {"exists":False}
    text=p.read_text(errors="replace")
    keys=("STATE_SCHEMA","DEPLOYMENT_ID","DEPLOYMENT_PHASE","RELEASE_TAG","RELEASE_SOURCE_COMMIT","CAPE_ROOT","CAPE_TARGETS_COUNT","ISOLATED_SUBNET","ISOLATED_BRIDGE_NAME","INETSIM_IP")
    d={"exists":True}
    for key in keys:
        m=re.search(rf"(?m)^{re.escape(key)}=(.*)$",text)
        if m: d[key.lower()]=m.group(1)[:500]
    return d

ap=argparse.ArgumentParser()
ap.add_argument("--output",required=True)
ap.add_argument("--decision",default="")
ap.add_argument("--decision-reason",default="")
a=ap.parse_args()

cape_root=os.environ.get("CAPE_ROOT","")
services={k:os.environ.get(k,"") for k in ("CAPE_SCHEDULER_SERVICE","CAPE_PROCESSOR_SERVICE","CAPE_WEB_SERVICE","CAPE_ROOTER_SERVICE")}
service_status={}
for role,unit in services.items():
    if unit:
        service_status[role]={"unit":unit,"active":run(["systemctl","is-active",unit])["stdout"],"enabled":run(["systemctl","is-enabled",unit])["stdout"],"exec_start":run(["systemctl","show",unit,"-p","ExecStart","--value"])["stdout"],"working_directory":run(["systemctl","show",unit,"-p","WorkingDirectory","--value"])["stdout"]}

domains=[]
names=virsh("list","--all","--name")["stdout"].splitlines()
for name in filter(None,map(str.strip,names)):
    xml=virsh("dumpxml",name)["stdout"]
    state=virsh("domstate",name)["stdout"]
    domains.append({"name":name,"state":state,"interfaces":parse_interfaces(xml)})

networks=[]
for name in filter(None,map(str.strip,virsh("net-list","--all","--name")["stdout"].splitlines())):
    x=virsh("net-dumpxml",name)["stdout"]
    item={"name":name}
    try:
        root=ET.fromstring(x); b=root.find("bridge"); ip=root.find("ip")
        item.update({"bridge":b.get("name") if b is not None else None,"address":ip.get("address") if ip is not None else None,"forward":root.find("forward") is not None})
    except Exception: item["parse_error"]=True
    networks.append(item)

os_release={}
try:
    for line in pathlib.Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            k,v=line.split("=",1); os_release[k]=v.strip().strip('"')
except Exception: pass

cpu=run([cmd("lscpu") or "lscpu","-J"]) if cmd("lscpu") else {"rc":127}
memory={}
try:
    for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
        if ":" in line:
            k,v=line.split(":",1)
            if k in ("MemTotal","MemAvailable","SwapTotal","SwapFree"): memory[k]=v.strip()
except Exception: pass

disk=run([cmd("lsblk") or "lsblk","-J","-o","NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL"]) if cmd("lsblk") else {"rc":127}
df=run([cmd("df") or "df","-P","-T"]) if cmd("df") else {"rc":127}
ip_link=run([cmd("ip") or "ip","-j","link"]) if cmd("ip") else {"rc":127}
ip_addr=run([cmd("ip") or "ip","-j","-4","addr"]) if cmd("ip") else {"rc":127}
ip_route=run([cmd("ip") or "ip","-j","-4","route","show","table","all"]) if cmd("ip") else {"rc":127}
nft=run([cmd("nft") or "nft","list","ruleset"],30) if cmd("nft") else {"rc":127}
iptables=run([cmd("iptables-save") or "iptables-save"],30) if cmd("iptables-save") else {"rc":127}

py_envs=[]
for p in filter(None,[os.environ.get("AD_HOST_PYTHON"),os.environ.get("CAPE_RUNTIME_PYTHON")]):
    if p not in py_envs: py_envs.append(p)
if cape_root:
    root=pathlib.Path(cape_root)
    for pat in (".venv/bin/python","venv/bin/python","env/bin/python"):
        p=root/pat
        if p.exists(): py_envs.append(str(p))
    try:
        for p in root.glob("*/bin/python"):
            if str(p) not in py_envs: py_envs.append(str(p))
    except Exception: pass
python_details=[]
for p in py_envs:
    r=run([p,"-c","import sys;print(sys.version.replace(chr(10),' '));print(sys.prefix)"])
    python_details.append({"path":p,"probe":r})

cape_version={"root":cape_root,"root_source":os.environ.get("CAPE_ROOT_SOURCE"),"git_commit":os.environ.get("CAPE_COMMIT"),"git_branch":os.environ.get("CAPE_BRANCH"),"dirty":os.environ.get("CAPE_DIRTY"),"database_backend":os.environ.get("CAPE_DB_BACKEND")}
if cape_root:
    for filename in ("VERSION","version"):
        p=pathlib.Path(cape_root)/filename
        if p.is_file():
            cape_version["version_file"]=p.read_text(errors="replace").strip()[:200]; break

state_root=os.environ.get("AD_STATE_ROOT","/var/lib/cape-inetsim-autodeploy")
inv={
 "schema":1,
 "generated_at":run(["date","-Is"])["stdout"],
 "decision":{"class":a.decision,"reason":a.decision_reason},
 "host":{"hostname":platform.node(),"os_release":os_release,"architecture":platform.machine(),"kernel":platform.release(),"cpu":cpu,"memory":memory,"disk":disk,"df":df,"kvm":{"device_exists":pathlib.Path("/dev/kvm").exists(),"device_access":os.access("/dev/kvm",os.R_OK|os.W_OK) if pathlib.Path("/dev/kvm").exists() else False},"libvirt":{"version":virsh("version"),"uri":virsh("uri")}},
 "cape":{"version":cape_version,"services":service_status,"runtime_python":os.environ.get("CAPE_RUNTIME_PYTHON"),"service_user":os.environ.get("CAPE_SERVICE_USER"),"targets_json":json.loads(os.environ.get("CAPE_TARGETS_JSON","[]") or "[]")},
 "virtualization":{"domains":domains,"networks":networks},
 "network":{"links":ip_link,"addresses":ip_addr,"routes":ip_route},
 "firewall":{"nft":nft,"iptables_save":iptables},
 "python_environments":python_details,
 "autodeploy":selected_state(str(pathlib.Path(state_root)/"state.env")),
}
out=pathlib.Path(a.output)
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(inv,indent=2,sort_keys=True)+"\n")
os.chmod(out,0o600)
print(out)
