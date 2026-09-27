# CAPE-INetSim-AutoDeploy — Architecture

## Routing invariant

`route=none/drop` stays blocked. `route=internet` keeps CAPE's normal Internet path. `route=inetsim` is routed by CAPE Rooter from the analysis VM management side to the isolated INetSim bridge.

The route-separated design does not permanently rewrite Windows IP, DNS, gateway, NICs or the configured CAPE snapshot.

## Control flow

1. Checksum-pinned public bootstrap verifies an immutable source bundle.
2. Discovery resolves CAPE root, services, Python, analysis targets, libvirt topology, routes, firewall and prior ownership.
3. The decision engine chooses fresh/verify/resume/upgrade/repair/recover or safe-stop.
4. A complete pre-change JSON inventory is persisted.
5. A transaction and append-only ownership ledger protect every mutation.
6. An unused private subnet and bridge are selected dynamically.
7. The checksum-pinned Xubuntu INetSim appliance is created and validated.
8. A task-safe CAPE maintenance boundary protects configuration handoff.
9. CAPE route/capture integration and Rooter are configured and live-probed.
10. A benign real CAPE analysis proves DNS + HTTP + PCAP + report evidence.
11. Only then is the transaction committed.

## Discovery

CAPE root discovery uses systemd metadata, running processes and bounded configuration-file search. Ambiguity safe-stops. Service roles are classified from units tied to that root and their working directory/ExecStart metadata.

CAPE Python candidates are validated as the actual CAPE service user by importing Django and CAPE modules. Candidate order covers the running service interpreter, direct systemd interpreter, project virtualenvs, Poetry, other virtualenvs and finally the discovered host Python.

## Appliance

The appliance has a management NIC and an isolated NIC. The isolated libvirt network has no NAT/forward element and no physical uplink. Guest forwarding is disabled and a host firewall guard provides defense in depth.

GUI contract: Xubuntu/XFCE, `capeinetsim`, password `123`, AccountsService identity, stable LightDM/Xorg/XFCE, localhost SPICE and Virtio video. Protocol contract: DNS/53 UDP, FTP/21, SMTP/25, HTTP/80 and HTTPS/443.

## Rooter

AutoDeploy discovers the Rooter unit, executable and configured Unix socket. If no usable unit exists but the executable and CAPE runtime are safely discovered, AutoDeploy can create a transaction-owned Rooter unit. A structured live socket response is mandatory before task scheduling is released.

## Transactions and provenance

CAPE files are checksummed and backed up before edits. Resource intent and ownership are journaled around creation. Critical rollback failure preserves containment resources rather than deleting uncertain state.

Public promotion re-verifies the exact source SHA, successful CI, appliance candidate, compressed and raw appliance checksums, stripped runtime contents and anonymous public download surface.
