#!/usr/bin/env bash
set -Eeuo pipefail

REPO="@@REPO@@"
TAG="@@TAG@@"
SOURCE_NAME="@@SOURCE_NAME@@"
SOURCE_SHA256="@@SOURCE_SHA256@@"
SOURCE_COMMIT="@@SOURCE_COMMIT@@"
SOURCE_URL="https://github.com/$REPO/releases/download/$TAG/$SOURCE_NAME"

[[ "$TAG" =~ ^v1\.0\.0(-rc\.[0-9]+)?$ ]] || { echo "[FAIL] invalid embedded release tag" >&2; exit 2; }
[[ "$SOURCE_NAME" != */* && "$SOURCE_NAME" == *.tar.gz ]] || { echo "[FAIL] invalid embedded source bundle name" >&2; exit 2; }
[[ "$SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "[FAIL] invalid embedded source SHA-256" >&2; exit 2; }
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "[FAIL] invalid embedded source commit" >&2; exit 2; }

command -v curl >/dev/null 2>&1 || { echo "[FAIL] curl is required" >&2; exit 2; }
command -v tar >/dev/null 2>&1 || { echo "[FAIL] tar is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "[FAIL] sha256sum is required" >&2; exit 2; }
HOST_PYTHON=""
for py in python3 python; do
  candidate="$(command -v "$py" 2>/dev/null || true)"
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3,10) else 1)
PY
  then
    HOST_PYTHON="$candidate"
    break
  fi
done
[[ -n "$HOST_PYTHON" ]] || { echo "[FAIL] Python >= 3.10 is required" >&2; exit 2; }
export AD_HOST_PYTHON="$HOST_PYTHON"

TMP="$(mktemp -d /tmp/cape-inetsim-autodeploy-release.XXXXXX)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "$SOURCE_URL" -o "$TMP/$SOURCE_NAME"
printf '%s  %s\n' "$SOURCE_SHA256" "$TMP/$SOURCE_NAME" | sha256sum -c - >/dev/null

EXPECTED_ROOT="${SOURCE_NAME%.tar.gz}"
[[ "$EXPECTED_ROOT" == CAPE-INetSim-AutoDeploy-* ]] || {
  echo "[FAIL] Release source bundle root name is invalid" >&2
  exit 2
}
"$HOST_PYTHON" - "$TMP/$SOURCE_NAME" "$EXPECTED_ROOT" <<'PY'
import pathlib,sys,tarfile
archive,root=sys.argv[1:]
with tarfile.open(archive,"r:gz") as tf:
    members=tf.getmembers()
    if not members:
        raise SystemExit("release source bundle is empty")
    prefix=root.rstrip("/")+"/"
    for m in members:
        name=m.name
        p=pathlib.PurePosixPath(name)
        if p.is_absolute() or ".." in p.parts:
            raise SystemExit(f"unsafe path in release source bundle: {name}")
        if name != root and not name.startswith(prefix):
            raise SystemExit(f"unexpected top-level path in release source bundle: {name}")
        if m.isdev() or m.isfifo():
            raise SystemExit(f"unsafe special file in release source bundle: {name}")
PY

tar -xzf "$TMP/$SOURCE_NAME" -C "$TMP" --no-same-owner --no-same-permissions
ROOT="$TMP/$EXPECTED_ROOT"
[[ -d "$ROOT" && -f "$ROOT/install" && -f "$ROOT/lib/common.sh" ]] || {
  echo "[FAIL] Release source bundle layout is invalid" >&2
  exit 2
}

chmod +x "$ROOT/install" "$ROOT"/bin/* "$ROOT"/tests/*.sh 2>/dev/null || true
export CAPE_INETSIM_RELEASE_TAG="$TAG"
export CAPE_INETSIM_RELEASE_SOURCE_BUNDLE="$SOURCE_NAME"
export CAPE_INETSIM_RELEASE_SOURCE_SHA256="$SOURCE_SHA256"
export CAPE_INETSIM_RELEASE_SOURCE_COMMIT="$SOURCE_COMMIT"
"$ROOT/install" "$@"
