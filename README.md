# CAPE-INetSim-AutoDeploy Releases

Public **release-distribution endpoint only** for CAPE-INetSim-AutoDeploy.

This repository intentionally does not contain the private development history, internal issue/PR discussion, lab inventories, host-specific evidence, or development branches. Versioned GitHub Releases contain only the files required to verify and run a published AutoDeploy release.

## Security and provenance

Published releases are checksum-pinned and generated from an exact verified private-source commit and appliance candidate. Release promotion is expected to reject host-specific lab identifiers and development-only material before publication.

## Copyright

Copyright © 2026 CherukuPavan. All rights reserved.

No open-source license is granted by this repository. Public availability is for release distribution and verification; it does not grant permission to relicense, redistribute, or represent the work as another party's own work.

Do not place credentials, private lab evidence, machine inventories, development source history, or host-specific configuration in this repository.

## Current test release

The current compatibility-test prerelease is `v1.0.0-rc.7`. Earlier release candidates are superseded and should not be used for qualification.

The intended random-host entry point is the versioned `install` release asset; it downloads and checksum-verifies the stripped runtime bundle and the generalized appliance before deployment.
