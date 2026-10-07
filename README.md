# qa-apps

Cartesi QA applications that cannot live in the general tester app
([jplgarcia/tester](https://github.com/jplgarcia/tester)):

1. **foreclose-app**: an application with an accounts drive, built so that a guardian can foreclose it and every
   user can take their balance out through the emergency path (machine-tool proof + `withdraw`), without the
   operator's cooperation. One snapshot per network, because the trusted token is baked into the template.
2. **fixtures**: the rollups-node's synthetic terminal-state machines (mcycle overflow, unexpected yield, invalid
   outputs root), rebuilt from the node tag, for node tests that need an application to end in a terminal state.

Plus the scripts to deploy the foreclose-app with a withdrawal config that can actually pay out, and to run the
emergency path. Everything is reproducible: each snapshot was built twice with identical template hashes.

## Target stack and toolchain

| component | version | pin |
|---|---|---|
| rollups-node | v2.0.0-alpha.13 | commit `36155487d8bcb1daca5d683b8fa4ec65feba3ab7` (cloned by the build, commit checked) |
| rollups-contracts | v3.0.0-alpha.10 | addresses in `networks/*.env` |
| emulator (cartesi-machine) | 0.21.0 | `.deb` sha256-pinned by the node's Dockerfile (stage `go-prepare`, our builder image) |
| kernel | linux-6.5.13-ctsi-2-v0.21.0.bin | sha256 `5c900060...8f32f` (= node `test/dependencies.sha256`) |
| rootfs | rootfs-tools.ext2 = machine-guest-tools 0.18.0 | sha256 `6c159937...2802e` (= node `test/dependencies.sha256`) |
| Go (fixture generator only) | 1.27.1 | sha256-pinned by the node's Dockerfile |

All pins live in [`versions.env`](versions.env); the build refuses anything that does not match them.

## Template hashes

Template hash = `cartesi-machine-stored-hash <dir>` = 32 bytes at offset 0x60 of `hash_tree.sht` (what
`cartesi-rollups-cli deploy application` reads). Every row was built twice (`make reproducible`) with the same
result; machine-readable copy in [`hashes.txt`](hashes.txt), checked by `make verify`.

### foreclose-app (one per network)

| network | chain id | trusted token (6 decimals) | template hash |
|---|---|---|---|
| devnet | 31337 | TestUsdc `0x7a051EDffC0884cd88d4a377F4C87BE074CF6c81` | `0x1a7e95387d77a5675cc3a4e9d787df0a20f9affeaa9299c9df4e7c1ea2cf55a1` |
| sepolia | 11155111 | Circle USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | `0xc8d32348961ebb32d94ebfba3385e67825463d5a8b4248a13e386fe4cbdbb202` |
| base-sepolia | 84532 | Circle USDC `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | `0x971967f8144685a4c69865076eeb3913b23f7aefb5925c1fc17909a7ef77251a` |
| op-sepolia | 11155420 | Circle USDC `0x5fd84259d66Cd46123540766Be93DFE6D43130D7` | `0x4a6e93fec79c8cbfa410020218f10f437a149e31fa885336952392f9052ab4d1` |

The devnet hash equals the node's own `applications/erc20-withdrawal-dapp` built from the tag. The devnet TestUsdc
does not exist on testnets; there the app trusts Circle's test USDC. Trusted portal on every network: Erc20Portal
`0x3332DE61a8BB9aC84893b2f552Fe81C9a6dC5419`.

### fixtures (node terminal states)

| fixture | template hash | terminal state it produces | used by |
|---|---|---|---|
| echo | `0x414992c2b62ee801810fac29d354e16afe1835d3d7a4bd91c2bae0419f8e03fd` | none: echoes each input as 1 voucher + 1 delegate-call voucher + 1 notice + 1 report (input of mcycle-overflow; also the node tests' template app) | sibling/control app |
| mcycle-overflow | `0xa4ed1b9dbcbc76c6117a8d8823bd024fb9baa863b5bbc8dc0dfa9d54ce315fdf` | echo clone with mcycle 255 below 2^64: the first input overflows mcycle -> app `MCYCLE_OVERFLOW`, input `OVERFLOW` | TRM-006, INS-007 |
| unexpected-yield | `0xe939f84f00b2918149904e2a46b70e88ed72e3f60625b8891d02935ada92ceb6` | 4 KiB-RAM synthetic machine that answers the first input with an unknown yield reason -> `UNEXPECTED_YIELD` | TRM-006, INS-007 |
| invalid-outputs-root | `0x2fbd699deac71f4156dbc5550eeaf79124bc4e83ab7a3b0f1b4fabac9422138b` | accepts the input but declares a wrong outputs root value -> `INVALID_OUTPUTS_ROOT` at epoch validation (input stays ACCEPTED, no claim) | TRM-005, TRM-006, INS-007 |
| invalid-outputs-root-length | `0xe60974661aba54cdb95766fd8891a16a0b652c0c34c1664f30a648d38ee41b31` | accepted yield whose outputs root is not 32 bytes -> input 0 completes with `INVALID_OUTPUTS_ROOT` | TRM-005, TRM-006, INS-007 |
| invalid-template-outputs-root | `0xfd3f877c37d13722878006d89669d2ae26c956fff79d3f494474bc004e23b902` | template whose outputs root is zero -> `INVALID_OUTPUTS_ROOT` at epoch 0 with no input (seen on PRT) | TRM-005 |

These are exactly the hashes of the node QA cycle's `apps/README.md` (alpha.13 validation). The three
`terminalmachine` fixtures are stored at mcycle 0; echo and the foreclose-apps run to the first `rx-accepted` yield.

## foreclose-app

Source: [`foreclose-app/install.sh`](foreclose-app/install.sh), a verbatim copy of the node's
`test/dapps/erc20-withdrawal/install.sh` (the build checks it is byte-identical to the tag's file, because the script
is part of the template). It is a shell dapp on rootfs-tools:

- **accounts drive**: 4 MiB flash drive labelled `accounts` at `0xc0000000` (accounts drive start index 768), one
  32-byte record per account in the `LibUsdAccount` layout (uint96 little-endian balance | 20-byte address),
  2^17 accounts, `log2_leaves_per_account` 0. Records are kept contiguous (a full withdrawal moves the last record
  into the hole).
- **deposits**: only from the trusted Erc20Portal and only of the trusted token (both baked in as `--env`); anything
  else is rejected. Amounts are positive int64 base units.
- **withdrawal request**: an input `0x01 || uint64be(amount)` from the account owner debits the account and emits an
  ERC-20 `transfer(owner, amount)` voucher.
- **inspect**: `balance 0x<address>` returns a JSON report with the balance and account index.

Machine command (node Makefile target `applications/erc20-withdrawal-dapp`):
```
cartesi-machine --ram-length=128Mi \
  --flash-drive=label:accounts,length:4Mi,mke2fs:false,mount:false,user:dapp \
  --env=TRUSTED_ERC20_PORTAL=<Erc20Portal> --env=TRUSTED_ERC20_TOKEN=<token> \
  --append-init-file=foreclose-app/install.sh --store=<out> --final-hash -- /usr/local/bin/erc20-withdrawal-dapp
```

## Build

Requirements: Docker (BuildKit), git, curl, make, bash. About 3 GB of disk for the builder image and outputs.

```bash
make foreclose-app NETWORK=devnet      # or sepolia | base-sepolia | op-sepolia; prints "<name> <template hash>"
make foreclose-apps                    # the three networks
make fixtures                          # echo + the five terminal fixtures
make all && make reproducible && make verify   # what CI runs
make dist                              # dist/<name>.tar.gz + SHA256SUMS + template-hashes.txt
```

What a build does ([`build/lib.sh`](build/lib.sh)): shallow-clones `v2.0.0-alpha.13` into `.cache/rollups-node`
and refuses any commit other than `36155487`; downloads the kernel and rootfs into `.cache/downloads` and checks
their sha256 against `versions.env` and the tag's `test/dependencies.sha256`; builds the builder image from the
node's own Dockerfile (`--target go-prepare`, tag `qa-apps-builder:36155487`); runs `cartesi-machine` (and, for
fixtures, `go build ./test/tooling/terminalmachine` from the clone) inside it; cross-checks
`cartesi-machine-stored-hash` against `hash_tree.sht@0x60` and that the snapshot loads. Outputs go to `out/`:
`out/<name>/` (the snapshot dir) and `out/<name>.hash`.

Overrides: `OUT`, `CACHE_DIR`, `NODE_SRC` (an existing checkout of the pinned commit), `DOWNLOADS_DIR`,
`BUILDER_IMAGE`. If `docker build` hangs on `docker-credential-desktop` (seen on Docker Desktop for macOS), run with
`DOCKER_CONFIG` pointing at a directory holding `config.json` = `{}` (and a `cli-plugins` link to
`~/.docker/cli-plugins`).

Release archives (from CI on a `v*` tag, see below) extract to `<name>/`, the directory to pass to `deploy`.

## Scripts

All scripts take the chain from `RPC_URL` and the signer from `CARTESI_AUTH_PRIVATE_KEY`, and run the node's own
tools through `CARTESI_CLI` (default `cartesi-rollups-cli`) and `CARTESI_MACHINE_TOOL` (default
`cartesi-rollups-machine-tool`). Those two must be the v2.0.0-alpha.13 binaries of the node that serves the app
(they need its database: deploy registers the app there, replay reads inputs from it). With the node in Docker:
```bash
export CARTESI_CLI="docker exec -i -e CARTESI_AUTH_KIND -e CARTESI_AUTH_PRIVATE_KEY <advancer-container> cartesi-rollups-cli"
export CARTESI_MACHINE_TOOL="docker exec -i <advancer-container> cartesi-rollups-machine-tool"
```
Each script prints its usage with `--help`. Needs `cast` (Foundry) and `jq` on the host.

### Keys

Never commit or hard-code keys. Export `CARTESI_AUTH_PRIVATE_KEY` per step, for the account that signs it
(deployer, guardian, depositor, gas payer). On the devnet the keys are anvil's public test keys
(`cast wallet private-key --mnemonic "test test test test test test test test test test test junk" --mnemonic-index N`).
On testnets they come from the operator's own wallet; fund them from the faucets below. Note that `cast` receives the
key on its command line (visible in the local process list), so run the scripts on a machine you control.

### `scripts/deploy.sh`: deploy with the only correct withdrawal config

A well-formed but wrong withdrawal config deploys fine and makes the funds unrecoverable after a foreclosure (the
config is immutable and foreclosure is irreversible; QA cycle FOR-013). `deploy.sh` therefore builds the config
itself and makes it the only path:

- `accounts_drive_start_index`, `log2_max_num_of_accounts`, `log2_leaves_per_account` come from the snapshot's
  `accounts` flash drive (length must be 2^(5+0+17), start aligned); a hand-typed `--accounts-drive-start-index`
  that disagrees is refused;
- `withdrawal_output_builder` is the `UsdWithdrawalOutputBuilderFactory` CREATE2 builder for the network's token
  (salt `--builder-salt`, default 0), created through the factory when it has no code yet; its `token()` must equal
  the `TRUSTED_ERC20_TOKEN` read from the snapshot;
- the snapshot's token and portal must be the network's; `RPC_URL` must be the network's chain id; every network
  contract must have code; the guardian must be non-zero and the claim staging period positive;
- after `cartesi-rollups-cli deploy application` (Authority, self-hosted factory), the app's `getTemplateHash()` and
  `getWithdrawalConfig()` are read back and compared with the intent;
- a deployment record `deployments/<network>-<name>.json` is written for the other scripts.

`--check-only` runs every check and prints the plan without sending anything.

USD builders (same factory and SafeErc20Transfer on every network, salt 0):

| network | token | builder |
|---|---|---|
| devnet | TestUsdc | `0xB4D253c7a110241561B3eD6d632846dF7d4e9Af7` (exists on the devnet; it is the devnet's `TestUsdWithdrawalOutputBuilder`) |
| sepolia | Circle USDC | `0x4B533eb2C61C47891a95C737E1DC3156DEd29622` (predicted; created by the first deploy if absent) |
| base-sepolia | Circle USDC | `0x262F590a8C527c3Aa4a7abd38EfD1666d02AeDB9` (predicted; created by the first deploy if absent) |
| op-sepolia | Circle USDC | `0x5B7d6Dd76902b5ec1268cAce0327a77D77b3198D` (predicted; created by the first deploy if absent) |

The testnet addresses were read with `calculateUsdWithdrawalOutputBuilderAddress` on each testnet's own factory
(2026-10-07; none of them existed yet); `deploy.sh` recomputes them on the target chain.

### Deploy on the devnet

Any devnet of rollups-contracts v3.0.0-alpha.10 with a v2.0.0-alpha.13 node. The node loads the template from a
path inside its own container, so copy the snapshot there first and pass that path as `--template-path`:
```bash
make foreclose-app NETWORK=devnet
docker exec -u root <advancer> mkdir -p /var/lib/cartesi-rollups-node/apps/foreclose-app-devnet
docker cp out/foreclose-app-devnet/. <advancer>:/var/lib/cartesi-rollups-node/apps/foreclose-app-devnet/
export RPC_URL=http://localhost:8545 CARTESI_CLI=... CARTESI_MACHINE_TOOL=...
CARTESI_AUTH_PRIVATE_KEY=<deployer> scripts/deploy.sh --network devnet --snapshot out/foreclose-app-devnet \
  --template-path /var/lib/cartesi-rollups-node/apps/foreclose-app-devnet --name qa-foreclose \
  --guardian <guardian address> --claim-staging-period 10 --epoch-length 5
```

### Deploy on Sepolia / Base Sepolia / OP Sepolia

1. Run a rollups-node v2.0.0-alpha.13 against the testnet (its database, `CARTESI_BLOCKCHAIN_HTTP_ENDPOINT` = the
   testnet RPC, the alpha.10 contract addresses of `networks/<network>.env`).
2. Deploy with the node's own signer key: the deployer becomes application owner and Authority owner, and an
   Authority accepts claims only from its owner. Fund it, the guardian (a different key) and a gas payer with
   testnet ETH; get USDC for the depositors from the Circle faucet.
3. `make foreclose-app NETWORK=sepolia` (or download the release asset and check its template hash), put the
   snapshot where the node reads templates, then:
```bash
export RPC_URL=<sepolia rpc> CARTESI_CLI=... CARTESI_MACHINE_TOOL=...
CARTESI_AUTH_PRIVATE_KEY=<deployer key from your wallet> scripts/deploy.sh --network sepolia \
  --snapshot out/foreclose-app-sepolia --template-path <path the node sees> --name qa-foreclose \
  --guardian <guardian address> --claim-staging-period <blocks> --check-only    # review, then without --check-only
```
On a public chain pick a claim staging period that gives the guardian time to react (hundreds of blocks), and keep
the deployment record: it is what the emergency runbook uses.

On the L2s (Base Sepolia, OP Sepolia) a block only becomes `finalized` once its batch is finalized on L1, so with the
node's default observation block (`finalized`) inputs, claims and output execution trail the L2 head by much more
than on Sepolia. Account for it when timing the staging period and when measuring latencies.

Faucets: Circle test USDC (Sepolia, Base Sepolia, OP Sepolia) <https://faucet.circle.com>; Sepolia ETH, e.g.
<https://cloud.google.com/application/web3/faucet/ethereum/sepolia> or <https://www.alchemy.com/faucets/ethereum-sepolia>;
Base Sepolia ETH, e.g. <https://portal.cdp.coinbase.com/products/faucet>; OP Sepolia ETH, e.g.
<https://console.optimism.io/faucet> or bridge Sepolia ETH through the OP Sepolia standard bridge.

### `scripts/app.sh`: normal use
```bash
CARTESI_AUTH_PRIVATE_KEY=<user> scripts/app.sh deposit --deployment D.json --amount 100000000 [--mint]   # 100 USDC; --mint devnet only
CARTESI_AUTH_PRIVATE_KEY=<user> scripts/app.sh request-withdrawal --deployment D.json --amount 25000000
CARTESI_AUTH_PRIVATE_KEY=<payer> scripts/app.sh execute --deployment D.json --output-index 0             # once the epoch is CLAIM_ACCEPTED
scripts/app.sh balance --deployment D.json --account 0x...                                              # inspect
```

## Emergency-withdrawal runbook (`scripts/emergency.sh`)

Preconditions: the app was deployed by `deploy.sh` (so its withdrawal config matches the template), and you have the
deployment record `D.json`, access to the node's CLI and machine tool, and a funded gas payer.

1. **Foreclose** (guardian key; irreversible; input box and claims stop):
   `CARTESI_AUTH_PRIVATE_KEY=<guardian> scripts/emergency.sh foreclose --deployment D.json`
   The script refuses if the signer is not `getGuardian()`.
2. **Withdraw each account** (any gas payer; funds always go to the account owner):
   `CARTESI_AUTH_PRIVATE_KEY=<payer> scripts/emergency.sh withdraw --deployment D.json --account 0x<owner> --work /work --host-work <same dir on host>`
   which runs, and checks between steps:
   1. `cartesi-rollups-machine-tool replay --template T --application APP --to-epoch E --store WORK/snap-...`
      with E = the last `CLAIM_ACCEPTED` epoch in the node database (override with `--epoch`; the snapshot is
      reused for later accounts, `--replay` forces a new one);
   2. `cartesi-rollups-machine-tool prove accounts-drive` with the layout read from the app's
      `getWithdrawalConfig()` on chain (never typed by hand), giving the drive-root proof and the account proof;
   3. `cartesi-rollups-cli prove-drive-root` once per app (skipped when the same root is already proved; refused if
      a different root is proved, because the root is set only once);
   4. `cartesi-rollups-cli withdraw`, then checks that the owner received exactly the drive balance decoded from the
      proof and the app was debited the same amount.
   A second withdrawal of the same account is refused before sending (`wereAccountFundsWithdrawn`); sent anyway, the
   contract reverts `AccountFundsAlreadyWithdrawn(accountIndex)`.
3. **Refund unfinalized deposits** (inputs whose epoch was never accepted, e.g. deposited just before the
   foreclosure; they are not in the replayed drive):
   `CARTESI_AUTH_PRIVATE_KEY=<payer> scripts/emergency.sh refund --deployment D.json --input-index N --work /work --host-work <dir>`
   reads the `InputAdded` bytes from the InputBox log (from the app's deployment block), runs
   `cartesi-rollups-cli refund`, and for a token deposit checks the depositor got the exact amount back. Finalized
   inputs revert `CannotRefundFinalizedInput`; a repeat is refused (`wasRefundForInputIssued`).
4. `scripts/emergency.sh status --deployment D.json [--account 0x..]` shows foreclosure, config, proved root,
   withdrawal / refund counts and balances at any time.

Notes: a withdrawal requested in the app before the foreclosure is already debited from the drive; its voucher is
paid by executing it (`executeOutput` is not gated by foreclosure in rollups-contracts alpha.10; not exercised in
the devnet run below). `--work` is the directory as the machine tool and CLI see it, `--host-work` the same
directory on the host (the script reads the proofs there).

## Verification (devnet, 2026-10-07)

Stack `v-qaapps-1` (node image `ghcr.io/cartesi/rollups-node:a13-36155487`, devnet from the alpha.13 tag), scripts as
of commit `c28101f` (later commits only change variable initialisation and `--help`); evidence in the QA cycle's
`evidence/_qa-apps-release/`:
deploy.sh refused a Sepolia snapshot, a wrong chain, a hand-typed drive index 1, a snapshot without a token and a
zero staging period; deployed `qa-foreclose` (template `0x1a7e9538...55a1`, guardian = account 8, staging 10,
config read back on chain); deposits 100 + 50 USDC; 25 USDC withdrawn by voucher; 9 USDC deposited and foreclosed
before its epoch was accepted; emergency withdraw paid exactly 75 and 50 USDC; a second withdraw reverted
`AccountFundsAlreadyWithdrawn(0)`; the 9 USDC deposit was refunded exactly and a finalized one reverted
`CannotRefundFinalizedInput(0)`; the app ended with 0 USDC. A second deploy exercised the builder creation through
the factory. Not run: testnet deployment.

## CI and releases

[`.github/workflows/build.yml`](.github/workflows/build.yml): on every push / PR, shellcheck and, on amd64 and arm64,
`make all`, `make reproducible`, `make verify`. On a `v*` tag it also runs `make dist` and creates a GitHub release
with the snapshot archives, `SHA256SUMS` and `template-hashes.txt`. Local builds so far were on arm64 (Apple
silicon); the amd64 job is the first cross-architecture check of the recorded hashes.

## License and attribution

Apache License 2.0 ([`LICENSE`](LICENSE)), because the foreclose-app and the fixture build derive from
[cartesi/rollups-node](https://github.com/cartesi/rollups-node), (c) Cartesi and individual authors, Apache-2.0.
[`NOTICE`](NOTICE) lists what was copied (only `foreclose-app/install.sh`, unmodified) and what is used from the
pinned clone at build time (Dockerfile stage, `test/tooling/terminalmachine`, Makefile commands). The snapshots also
contain the Cartesi Linux kernel and rootfs-tools releases, under their own licenses.
