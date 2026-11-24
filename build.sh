#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# usage: SHIRUDO_SRC=<shirudo checkout> KEYS=<keys dir> ./build.sh [version]
# Builds ckb-node-shield-<version>.bee in the current directory, signed
# with the key in $KEYS (signing_key.pem + cert.der).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
: "${SHIRUDO_SRC:?set SHIRUDO_SRC to a shirudo checkout}" "${KEYS:?set KEYS to your signing key dir}"
[ -e "$here/vendor" ] || ln -s "$SHIRUDO_SRC/vendor" "$here/vendor"
export SHIRUDO_BUILD="${SHIRUDO_BUILD:-$SHIRUDO_SRC/tools/shirudo-build/shirudo-build}"
"${SHIRUDO:-$SHIRUDO_SRC/shirudo}" bpm build "$here" --version "${1:-0.1.0}" --keys-dir "$KEYS"
