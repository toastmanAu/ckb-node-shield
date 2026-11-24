#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
#
# usage (as root on a shirudo target, NOT a production node):
#   vm-test.sh <upatch dir> <ckb binary> [<Option B upatch dir>]
#
# <upatch dir> holds ckb-node-shield.upatch + .unload.upatch built from
# the default rules (Option A). The optional third directory holds a
# build with Option B uncommented and peers = ["192.0.2.0/24"].
#
# Phase 1 (rules bite): a copy of bash at the labeled path is the probe.
#   Every action runs twice, first with the shield unloaded (must succeed,
#   the control) and then loaded (must be refused or allowed as the rule
#   says). The control shows a refusal comes from the shield, not the host.
# Phase 2 (node still works): the real ckb on a dev chain, inside the
#   sandbox, must sync its RPC, mine blocks and refuse `ckb init --force`.
# Phase 3 (Option B, if given): outbound to an unlisted address is
#   refused, loopback still allowed. NET_DENY_TARGET (default 10.0.2.2/22,
#   QEMU's host address) must accept connections, which the control checks.

set -u

upatches=${1:?upatch directory}
ckb_src=${2:?ckb binary}
netb=${3:-}
deny_target=${NET_DENY_TARGET:-10.0.2.2/22}
runtime=${SHIRUDO:-shirudo-runtime}
bin=/usr/local/bin/ckb
work=/tmp/ckb-node-shield-test
node=/var/lib/ckb-node-shield-test
pass=0 fail=0

ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }

load()   { "$runtime" upatch load "${1:-$upatches}/ckb-node-shield.upatch" >/dev/null; }
unload() { "$runtime" upatch unload "${1:-$upatches}/ckb-node-shield.unload.upatch" >/dev/null 2>&1 || true; }

# probe <expect: allow|deny> <label> <bash command>
probe()
{
	local expect=$1 label=$2 cmd=$3 out rc
	out=$("$bin" -c "$cmd" 2>&1); rc=$?
	if [ "$expect" = allow ]; then
		[ $rc -eq 0 ] && ok "$label: allowed" || bad "$label: expected allowed, rc=$rc $out"
	else
		# bash reports EACCES as "Permission denied" (rc 1 on a redirect,
		# 126 on exec). Any other failure is not the shield's refusal.
		if [ $rc -ne 0 ] && grep -q 'Permission denied' <<<"$out"; then
			ok "$label: refused (EACCES)"
		else
			bad "$label: expected EACCES, rc=$rc $out"
		fi
	fi
}

fresh_work()
{
	rm -rf "$work"; mkdir -p "$work"
	echo '# original' > "$work/ckb.toml"
}

# The actions the sandbox has rules for, plus one it must leave alone.
actions()
{
	local mode=$1 deny=deny
	[ "$mode" = control ] && deny=allow
	fresh_work
	probe "$deny" "[$mode] exec /bin/true"             '/bin/true'
	probe "$deny" "[$mode] append to ckb.toml"         "echo pwned >> $work/ckb.toml"
	probe "$deny" "[$mode] create authorized_keys"     ": > $work/authorized_keys"
	probe "$deny" "[$mode] create evil.service"        ": > $work/evil.service"
	probe "$deny" "[$mode] create libevil.so"          ": > $work/libevil.so"
	probe "$deny" "[$mode] truncate ckb.toml"          ": > $work/ckb.toml"
	probe allow   "[$mode] write data/run.log"         "mkdir -p $work/data 2>/dev/null; echo ok > $work/run.log"
	probe allow   "[$mode] connect to 127.0.0.1"       'exec 3<>/dev/tcp/127.0.0.1/22 && exec 3>&-'
}

cleanup()
{
	pkill -x ckb 2>/dev/null; sleep 1
	unload
	[ -z "$netb" ] || unload "$netb"
	rm -f "$bin"; rm -rf "$work" "$node"
}
trap cleanup EXIT

echo "== phase 1: probe (bash at $bin)"
unload
install -m 0755 /bin/bash "$bin"
actions control
load || { bad "load the shield"; exit 1; }
actions sandbox
unload

echo "== phase 2: real ckb ($("$ckb_src" --version 2>/dev/null))"
install -m 0755 "$ckb_src" "$bin"
rm -rf "$node"; mkdir -p "$node"
# Init BEFORE the load: inside the sandbox ckb may not write ckb.toml.
"$bin" init -C "$node" --chain dev \
	--ba-code-hash 0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8 \
	--ba-hash-type type --ba-arg 0x0000000000000000000000000000000000000000 >/dev/null \
	|| { bad "ckb init (unsandboxed)"; exit 1; }
load || { bad "load the shield"; exit 1; }

out=$("$bin" init -C "$node" --chain dev --force 2>&1)
if [ $? -ne 0 ] && grep -qi 'permission denied' <<<"$out"; then
	ok "[real ckb] init --force refused (ckb.toml protected)"
else
	bad "[real ckb] init --force was not refused: $out"
fi

"$bin" run -C "$node" >"$node/run.out" 2>&1 &
"$bin" miner -C "$node" >"$node/miner.out" 2>&1 &
rpc() { curl -s -H 'content-type: application/json' \
	-d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
	http://127.0.0.1:8114 | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p'; }
tip=
for _ in $(seq 1 30); do sleep 2; tip=$(rpc); [ -n "$tip" ] && [ $((tip)) -ge 3 ] && break; done
if [ -n "$tip" ] && [ $((tip)) -ge 3 ]; then
	ok "[real ckb] node + miner in the sandbox, tip $((tip))"
else
	bad "[real ckb] node did not mine (tip='${tip}'); see $node/run.out"
	tail -5 "$node/run.out" "$node/miner.out"
fi
[ -s "$node/data/logs/run.log" ] && ok "[real ckb] wrote its own logs" || bad "[real ckb] no run.log"
grep -q 'Permission denied' "$node/run.out" && bad "[real ckb] node hit EACCES during normal run" \
	|| ok "[real ckb] no EACCES in node output"

if [ -n "$netb" ]; then
	echo "== phase 3: Option B (private network) probe"
	pkill -x ckb 2>/dev/null; sleep 1
	unload
	install -m 0755 /bin/bash "$bin"
	probe allow "[control] connect to $deny_target" "exec 3<>/dev/tcp/$deny_target && exec 3>&-"
	load "$netb" || { bad "load the Option B shield"; exit 1; }
	probe deny  "[option B] connect to unlisted $deny_target" "exec 3<>/dev/tcp/$deny_target && exec 3>&-"
	probe allow "[option B] connect to 127.0.0.1 (listed)" 'exec 3<>/dev/tcp/127.0.0.1/22 && exec 3>&-'
	probe deny  "[option B] exec still refused" '/bin/true'
	unload "$netb"
fi

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
