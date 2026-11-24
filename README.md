# ckb-node-shield

[shirudo](https://github.com/shirudo-dev/shirudo) shields that sandbox a
[CKB](https://github.com/nervosnetwork/ckb) full node (`ckb`) and a
[Fiber](https://github.com/nervosnetwork/fiber) node (`fnn`) in the
kernel, with BPF LSM programs. They limit what an attacker who gets code
running inside the node can do next. They do not fix the bug the
attacker used.

One package holds two sandboxes, `ckb` and `fnn`, each with its own
rules. A task that executed one of the binaries, and every task it
starts, is held to that sandbox's rules:

| Rule | `ckb` sandbox | `fnn` sandbox |
|---|---|---|
| `exec = []` | runs no other program: no shell, no `curl`, no dropped miner | same |
| network, Option A (default) | any peer | any peer |
| network, Option B (commented out) | only listed peers | only listed peers + your CKB RPC |
| no create/rename/write of these **names** | `ckb.toml`, `ckb-miner.toml`, `default.db-options`, `ckb`, `ckb-cli` | `config.yml` (holds the RPC `biscuit_public_key`), `fnn`, `fnn-cli` |
| ...and in both | `*.so`, `authorized_keys`, `.bashrc`/`.profile`/`.zshrc`, `*.service`/`*.timer`/`*.socket`, `crontab`, `cron.*`, `ld.so.preload`, `sudoers`, `passwd`, `shadow` | same |

Every refusal is `EACCES`. The nodes' own work is unaffected:
- `ckb` still writes its DB, peer store, logs and indexer, and runs P2P and RPC.
- `fnn` still writes `fiber/store`, its startup backups and logs, and runs P2P and RPC.

## Requirements

A target running shirudo: a BPF-LSM kernel with signed BPF programs, a TPM
and the shirudo runtime. See shirudo's `Documentation/start/install.rst`.
Tested on shirudo's test VM (shirudo `0e595d8`, kernel `7.4-shirudo-ci`)
with CKB `v0.210.0` and Fiber `v0.10.1`. See [Tested](#tested).

## Choosing the network option

`sandbox.toml` ships both options per sandbox, with Option B commented out:

- **Option A, public node (default).** Outbound connections may go
  anywhere. Leave the Option B lines commented.
- **Option B, private node.**
  1. Uncomment `[networks]` and `local`, plus the lists the sandbox names.
  2. Uncomment that sandbox's `network = [...]` line.
  3. Put in your own CIDRs.

  An outbound `connect()` to anything unlisted fails with `EACCES`. So
  does creating a raw or packet socket.

  Keep `127.0.0.0/8`, because the local DNS resolver is there. Inbound
  connections, such as peers dialing you or RPC clients, are never
  restricted.

  For `fnn`, list the CKB RPC it reads the chain from
  (`fiber_ckb_rpc`). A hostname behind a CDN changes IPs, so Option B
  suits an `fnn` pointed at your own CKB node.

Rebuild after changing the rules. `shirudo bpm config update` can also
re-sign a built package with new rules without recompiling.

## Install paths

The `Beefile` labels these paths. Any that don't exist on a host are
skipped with a journal warning:

```
ckb: /usr/local/bin/ckb  /usr/bin/ckb  /opt/ckb/ckb  /usr/local/ckb/ckb
fnn: /usr/local/bin/fnn  /usr/bin/fnn  /opt/fiber/fnn  /opt/fnn/fnn
```

If a binary lives elsewhere, for example `~/.fiber/bin/fnn`, add its
path to the policy's `paths` and rebuild. A path can't use a wildcard
in a directory name, only in the final file name.

## Build

From a shirudo operator checkout:

```sh
SHIRUDO_SRC=/path/to/shirudo KEYS=/path/to/keys ./build.sh 0.2.0
```

This links the checkout's `vendor/` (libbpf headers and `vmlinux.h`)
into the package and shirudo's `bpf/` headers into the build directory,
then runs `shirudo bpm build`. A Beefile is a strict TOML subset, so
keep each array on one line.

`KEYS` holds **your** fleet's signing key. Targets accept only upatches
signed with the key in their own `.bpf` keyring, so every operator
builds and signs this package. There is no shared binary to trust.
Publish it with `shirudo bpm push` and `shirudo bpm tree append`, like
any shirudo package.

## Operating notes

- **Restart the nodes after the first load.** A task enters the sandbox
  at its next `execve()` of a labeled file. A process already running
  when the shield loads is not in it.
- **Load again after every upgrade.** A new binary is a new file with no
  label, so the node runs unsandboxed until the shield is reloaded.
- **`ckb`: run `ckb init` before loading.** Inside the sandbox,
  `ckb init --force` cannot rewrite `ckb.toml`, by design.
- **`fnn`: start it once before loading.** The first start encrypts
  `ckb/key` in place and creates `fiber/sk`.
- **`fnn`'s funding key is not protected by name.** `fnn` writes files
  named `key` and `sk` into `fiber/backups/<time>/` on every start, and
  a rule matches a file name, not its directory, so denying them would
  break the node. Protect `ckb/key` with ownership instead. Run `fnn` as
  its own user and make `ckb/` and `ckb/key` owned by root, with the key
  readable by fnn's group (`root:fnn 0440`, directory `root:fnn 0750`).
  An exploited `fnn` can then read the key, as it must, but can't swap
  in its own.
- **Reading secrets is out of scope.** These sandboxes restrict
  execution, connections and writes, not reads. A compromised node can
  read its own keys. Option B is what stops it sending them to an
  unlisted host.
- `ckb miner` is the same binary as `ckb`, so it is sandboxed too. It
  only talks RPC.
- A file descriptor opened before the process entered the sandbox can
  still be written to.
- The shield is not a boundary against root **outside** the sandbox.

## Tested

```sh
FNN=<fnn> FNN_CONFIG=<testnet config.yml> \
  tests/vm-test.sh <upatch dir> <ckb binary> [<Option B upatch dir>]
```

This runs as root on a shirudo test VM: 41 checks, all passing,
repeatable.

1. **The `ckb` rules work.** A probe, which is a copy of `bash`
   installed at the labeled path, tries to:
   - run another program
   - write or truncate `ckb.toml`
   - create `authorized_keys`, a `.service` file and a `.so` file

   Each attempt must fail with `EACCES`. Ordinary writes and loopback
   connections must still work. With the shield unloaded, the same
   probe must succeed at everything. That control shows the refusals
   come from the shield.
2. **A real `ckb` still works.** v0.210.0 on a dev chain inside the
   sandbox:
   - the RPC answers
   - `ckb miner` mines, and the tip advances
   - nothing in normal running is refused
   - `ckb init --force` is refused
3. **Option B works.** In a build with `ckb_peers = ["192.0.2.0/24"]`, a
   connection to the QEMU host (unlisted) is refused and loopback still
   connects. The unloaded control reaches the same host.
4. **The `fnn` rules work.** The same probe approach at the `fnn` path:
   - exec, `config.yml`, `authorized_keys` and `.service` writes are
     refused
   - backup writes to `.../key` and `.../sk` stay allowed
   - `ckb.toml` is not refused, because that is only `ckb`'s rule
5. **A real `fnn` still works.** v0.10.1 on testnet, with an unfunded
   throwaway key, inside the sandbox:
   - `node_info` answers
   - the startup backup is written
   - nothing is refused

## License

`ckb-node-shield.bpf.c` and `gen_policy.py` are shirudo's `app-sandbox`
sources, unchanged apart from the header comment, under
`GPL-2.0 OR BSD-2-Clause`. The Beefile, rules, tests and docs are under
the same terms. `LICENSES/` holds both texts. The kernel side has to be
GPL-compatible to use BPF LSM helpers.
