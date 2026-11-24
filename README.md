# ckb-node-shield

A [shirudo](https://github.com/shirudo-dev/shirudo) shield that sandboxes a
[CKB](https://github.com/nervosnetwork/ckb) full node in the kernel, with
BPF LSM programs. It limits what an attacker who gets code running inside
`ckb` can do next. It does not fix the bug they used.

A task that executed the `ckb` binary, and every task it starts:

| Rule | Effect |
|---|---|
| `exec = []` | It runs no other program: no shell, no `curl`, no miner dropped in `/tmp`. Only `ckb` itself. |
| no `network` key | Connections stay open to any peer, because a public node needs that. |
| `deny.create/rename/write` | It cannot create, rename over or open for writing a file whose **name** is `ckb.toml`, `ckb-miner.toml`, `default.db-options`, `ckb`, `ckb-cli`, `*.so`, `authorized_keys`, `.bashrc`/`.profile`, `*.service`/`*.timer`, `crontab`, `ld.so.preload`, `sudoers`, `passwd` or `shadow`. |

Every refusal is `EACCES`. The node's own work is unaffected: writing
`data/db`, `data/network`, its logs, the indexer, P2P and RPC.

## Requirements

A target running shirudo: a BPF-LSM kernel with signed BPF programs, a TPM
and the shirudo runtime. See shirudo's `Documentation/start/install.rst`.
This shield was tested on shirudo's test VM (shirudo `0e595d8`, kernel
`7.4-shirudo-ci`) against CKB `v0.210.0`. See [Tested](#tested).

## Install paths

The `Beefile` labels these paths, and any that don't exist on a host are
skipped with a journal warning:

```
/usr/local/bin/ckb  /usr/bin/ckb  /opt/ckb/ckb  /usr/local/ckb/ckb
```

If `ckb` lives somewhere else, add that path to the `ckb` policy's `paths`
and rebuild. A directory cannot hold a wildcard, but the last component
can.

## Build

From a shirudo operator checkout, with `shirudo` and `shirudo-build` on
`PATH`:

```sh
SHIRUDO_SRC=/path/to/shirudo KEYS=/path/to/keys ./build.sh 0.1.0
```

This links the checkout's `vendor/` (libbpf headers and `vmlinux.h`) and
runs `shirudo bpm build`. A Beefile is a strict TOML subset, so keep each
array on one line.

`--keys-dir` holds **your** fleet's signing key. Targets accept only
upatches signed with the key in their own `.bpf` keyring, so every
operator builds and signs this package themselves. There is no shared
binary to trust. Publish it with `shirudo bpm push` and
`shirudo bpm tree append`, the same as any shirudo package.

## Operating notes

- **Restart the node after the first load.** A task enters the sandbox
  at its next `execve()` of a labeled file, so a `ckb` process already
  running when the shield loads is not in it.
- **Load again after every CKB upgrade.** A new binary is a new file with
  no label, so the node runs unsandboxed until the shield is reloaded.
- **Run `ckb init` before loading, or unload first.** Inside the sandbox,
  `ckb init --force` cannot rewrite `ckb.toml`. That is by design.
- `ckb miner` is the same binary, so it is sandboxed too. It only talks
  RPC, so nothing changes for it.
- File rules match names, not contents or directories. A descriptor that
  was opened before the process entered the sandbox still writes.
- The shield is not a boundary against root **outside** the sandbox.

## Tested

`tests/vm-test.sh <upatch dir> <ckb binary>` runs as root on a shirudo
test VM: 20 checks, all passing, repeatable. It runs two kinds of check:

1. **The real node still works.** `ckb` v0.210.0 on a dev chain with the
   shield loaded: RPC answers, it mines with `ckb miner`, and the tip
   advances.
2. **The rules bite.** A probe is a copy of `bash` installed at the
   labeled path. Inside the sandbox it tries `exec`, writes to `ckb.toml`
   and `authorized_keys`, and creates a `.service` file. Each attempt must
   fail with `EACCES`. With the shield unloaded, the same probe must
   succeed. This control shows the refusals come from the shield.

## License

`ckb-node-shield.bpf.c` and `gen_policy.py` are shirudo's `app-sandbox`
sources, unchanged apart from the header comment, under
`GPL-2.0 OR BSD-2-Clause` (see `LICENSE.shirudo`). The Beefile, rules,
tests and docs are under the same terms.
