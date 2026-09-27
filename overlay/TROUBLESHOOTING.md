# CAPE-INetSim-AutoDeploy — Troubleshooting

Do not manually delete bridges, VMs, disks, firewall rules, Rooter sockets, CAPE patches, state files or snapshots after a failed transaction. The ownership ledger is what makes automatic repair and rollback safe.

## Collect evidence

    sudo ./install --collect

The collector is read-only with respect to CAPE, libvirt guests, networking, firewall and services and produces a redacted support archive.

## Pre-change safe stop

Inspect `/var/lib/cape-inetsim-autodeploy/autodeploy-inventory.json`. Typical blocking conditions are an ambiguous CAPE root, ambiguous CAPE-to-libvirt target mapping, unsupported storage/snapshot state, insufficient resources, source-layout incompatibility, or AutoDeploy-reserved resources whose ownership cannot be proven.

## Rooter

Rooter is accepted only when the discovered service is active, the socket path read from CAPE configuration exists, and a real Unix-datagram JSON probe receives a valid structured response. An `active` systemd state by itself is not success. Rooter readiness diagnostics are written under `/var/lib/cape-inetsim-autodeploy/logs/`.

## GUI

The accepted appliance has one visible normal account, `capeinetsim`, local console password `123`, and a Xubuntu/XFCE session. Deployment tests LightDM, Xorg, XFCE session, panel and desktop stability, then restores the password greeter. SPICE/Virtio must also be present. A login loop, black display, missing display driver, AccountsService problem, or unstable session blocks commit.

## INetSim services

Guest configuration normalizes one enabled declaration each for DNS, HTTP, HTTPS, SMTP and FTP. Readiness requires UDP/53 and TCP/21,25,80,443 on the isolated address.

## CAPE network report is empty

Run:

    sudo ./install --selftest

The self-test submits a benign PowerShell task with a unique hostname on `route=inetsim`, waits until CAPE reports it, and requires DNS evidence, HTTP evidence and a non-empty PCAP linked to INetSim. If CAPE has Internet routing configured, it also runs a separate `route=internet` control and requires no marker or INetSim attribution there.

## Interrupted upgrade/repair

Rerun the same immutable installer. The decision engine selects resume, repair or recovery from persisted ownership state. If CAPE-managed files changed after their recorded hashes, AutoDeploy refuses to overwrite them; collect evidence and reconcile source drift deliberately.

Useful state: `/var/lib/cape-inetsim-autodeploy/state.env`, `resources.tsv`, `backups/`, `generated/`, `logs/`, and `autodeploy-inventory.json`. Do not hand-edit the ledger or state file.
