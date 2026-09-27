# CAPE-INetSim-AutoDeploy — Installation

## Contract

AutoDeploy targets an existing Linux CAPEv2 KVM/libvirt host with one or more enabled Windows analysis machines. It discovers the live CAPE root, CAPE service units, validated CAPE Python runtime, VM mappings, libvirt networks/bridges, free private subnet, storage, firewall and prior AutoDeploy ownership state before mutation.

No production operation depends on a fixed CAPE path, Linux username, analysis VM name, management bridge, isolated bridge, fake-Internet IP, or Python executable path.

INetSim local console: user `capeinetsim`, password `123`, Xubuntu/XFCE, localhost-only SPICE with Virtio video. SSH password authentication is disabled.

## One command

Use only a checksum-pinned versioned public release:

    curl -fsSL https://github.com/CherukuPavan/CAPE-INetSim-AutoDeploy-Releases/releases/download/<TAG>/install | sudo bash

The bootstrap verifies the immutable source-bundle SHA-256 before executing it. By default every enabled Windows-compatible CAPE KVM analysis machine is covered.

## Before mutation

The installer performs discovery and writes `/var/lib/cape-inetsim-autodeploy/autodeploy-inventory.json`. It records OS, architecture, kernel, CPU, memory, disks, KVM/libvirt, CAPE root/version/services, validated Python runtimes, VMs/NICs, networks/bridges, routes, firewall and previous AutoDeploy state.

The decision engine classifies the host as fresh, verify, resume, upgrade, repair, recover, or a safe-stop state where ownership cannot be proven.

## Deployment gates

AutoDeploy creates only transaction-owned isolated resources, verifies the checksum-pinned appliance, proves QEMU Guest Agent and networking, proves Xubuntu/XFCE + LightDM + SPICE/Virtio, and requires INetSim DNS/HTTP/HTTPS/SMTP/FTP. It preserves the Windows CAPE network/snapshot baseline, waits for a task-safe CAPE point, configures per-task `route=inetsim`, discovers and probes the live Rooter Unix socket, restores CAPE services, then runs a benign CAPE end-to-end route test before commit.

Any failure before commit invokes ownership-aware rollback.

## Operations

Verify:

    sudo ./install --verify

Full live route test:

    sudo ./install --selftest

Status:

    sudo ./install --status

Read-only support bundle:

    sudo ./install --collect

Rollback preview:

    sudo ./install --rollback

Rollback apply:

    sudo ./install --rollback --apply

Rollback restores backed-up CAPE files and original service/forwarding state and removes only resources whose ledger proves AutoDeploy ownership.
