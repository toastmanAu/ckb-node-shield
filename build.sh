#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# usage: SHIRUDO_SRC=<shirudo checkout> KEYS=<keys dir> ./build.sh [version]
# Builds ckb-node-shield-<version>.bee in the current directory, signed
# with the key in $KEYS (signing_key.pem + cert.der).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$(pwd)
: "${SHIRUDO_SRC:?set SHIRUDO_SRC to a shirudo checkout}" "${KEYS:?set KEYS to your signing key dir}"
SHIRUDO_SRC=$(cd "$SHIRUDO_SRC" && pwd)
# The helper finds the libbpf headers and vmlinux.h under vendor/ in the
# package directory, and shirudo's own BPF headers (policy.h) under bpf/
# in the directory it runs in.
[ -e "$here/vendor" ] || ln -s "$SHIRUDO_SRC/vendor" "$here/vendor"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ln -s "$SHIRUDO_SRC/bpf" "$work/bpf"
export SHIRUDO_BUILD="${SHIRUDO_BUILD:-$SHIRUDO_SRC/tools/shirudo-build/shirudo-build}"
bee=$(cd "$work" && "${SHIRUDO:-$SHIRUDO_SRC/shirudo}" bpm build "$here" \
	--version "${1:-0.1.0}" --keys-dir "$KEYS" | tail -n 1)
mv "$bee" "$out/"
echo "$out/$(basename "$bee")"
