# CAPE-INetSim-AutoDeploy — Recovery

Recovery is ownership-aware: AutoDeploy restores or removes only resources its state/ledger proves it created or modified. Unknown resources are preserved and cause a safe stop.

## Decision states

- `fresh`: no previous state or owned deployment.
- `verify`: the current committed release is already present.
- `resume`: an interrupted deploy phase can continue.
- `upgrade`: a different committed AutoDeploy release can enter owned migration/repair.
- `repair`: repair was interrupted or is explicitly requested.
- `recover`: rollback is incomplete and must finish first.
- `blocked-unowned`: reserved-looking resources exist without proven ownership.
- `broken-state`: state is invalid or unsupported.

## Automatic failure path

A deployment failure stops further mutation, restores critical CAPE state, keeps scheduling closed during resource removal, removes only owned staged resources, releases maintenance ownership, restores IPv4 forwarding and original service states, and marks the transaction rolled back. If a critical restore fails, containment state is preserved and the phase becomes `rollback-incomplete`.

Repair/upgrade similarly records pre-repair runtime state and restores scheduler/processor/web/Rooter/forwarding state on failure. Release provenance is promoted only after all new release gates pass.

## Commands

Rollback preview:

    sudo ./install --rollback

Rollback apply:

    sudo ./install --rollback --apply

Read-only evidence:

    sudo ./install --collect

## Metadata

Default recovery root is `/var/lib/cape-inetsim-autodeploy/`. `state.env` holds transaction state, `resources.tsv` is the ownership/action ledger, `autodeploy-inventory.json` is the latest pre-change inventory, `backups/` contains checksummed CAPE backups, and `logs/` contains Rooter/GUI/guest/repair/acceptance evidence.

Never delete or hand-edit `state.env` or `resources.tsv` merely to bypass a failure. Doing so destroys the evidence required to distinguish owned resources from operator resources.
