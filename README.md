# DART

**Delegated Authorization and Revocation Technology**

A research prototype for emergency revocation of authority delegated to AI agents that act on smart-contract wallets and vaults, in the case where the user cannot act.

## Research problem

When a user authorizes an agent to perform limited financial actions, revocation usually depends on the user still being able to sign. If the agent or its key is compromised and the user has lost the master key, is coerced, or is otherwise unavailable, there is no emergency stop that does not also hand a third party the power to grant new authority or to move assets. DART studies whether a revocation-only guardian can contain that damage without becoming an administrator.

## Core invariant

- **USER** grants.
- **AGENT** acts only within the delegated scope.
- **GUARDIAN** may revoke.
- **GUARDIAN** may not grant authority, execute or spend, impersonate the user, restore revoked authority, become owner or admin, change roles, or escalate privileges.

## Prototype scope

This repository implements a **minimal Solidity vault** (`DARTVault`) used as the practical part of a Batxillerat Treball de Recerca.

What it **is**:

- one contract with simulated internal value (not ETH or tokens);
- scoped delegation: allowed recipient, per-action amount, time window;
- one-way revocation;
- auditable events for grant, execute, and revoke.

What it **is not**:

- a production wallet or an audited financial contract;
- a complete cryptographic delegation protocol;
- an EIP-712 or ERC-4337 implementation;
- a real-money system, a testnet deployment, or an AI anomaly detector;
- a proof of universal security.

## Authorization surface

- `user` and `guardian` are fixed in the constructor and never change.
- The agent is chosen **per delegation**, not as a global role.
- After deployment, the only state-changing functions are:
  - `createDelegation` — user only;
  - `execute` — the delegated agent only, and only inside scope and time;
  - `revokeDelegation` — user or guardian.
- There is no restore, update, owner, admin, proxy, or upgrade path.
- `getDelegation` and the Solidity-generated public getters are read-only.

## Formal model versus this implementation

The Treball de Recerca formalizes a delegation and a revocation as signed certificates, in the form:

```text
D = Sign_skU(U, A, S, t0, t1, nonce)
R = Sign_skG(H(D), tr, reason)
```

**This prototype does not verify those certificates in the contract.**

Instead:

- Ethereum transaction authentication (`msg.sender`) stands in for actor identity;
- `delegationId` identifies stored delegation state;
- a `revoked` flag stands in for membership of `H(D)` in the revoked set;
- scope is `allowedRecipient` + `maxAmountPerAction` + `[validAfter, validUntil]`.

In the Foundry tests, `makeAddr` creates synthetic local addresses and `vm.prank` only sets `msg.sender` for the next call. That is a test-harness mechanism, **not** a cryptographic signature.

## Requirements

Minimum, to compile, test, and reproduce the captured runs:

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`)
- Python 3 (standard library only for `analysis/baselines.py`)
- Matplotlib, only if you want to regenerate `results/accumulated-damage.png` with `analysis/plot_results.py`

`forge-std` is pinned as a git submodule at **v1.16.2**. Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/TommyDanMa/dart.git
cd dart
```

If the clone is already done without submodules:

```bash
git submodule update --init --recursive
```

### Recorded experimental environment

These versions are what the captured evidence was produced with. They are not claimed as the only supported set.

- forge 1.8.3 (`cae51ad458`)
- solc 0.8.37 (pinned in `foundry.toml`; optimizer off)
- forge-std v1.16.2 (`bf647bd`)
- Python 3.9.6 for the captured baseline run

## Reproduction

From the repository root:

```bash
forge build
forge test --match-contract DARTVault -vv
forge test --match-contract DARTVault --gas-report
python3 analysis/baselines.py
python3 analysis/plot_results.py
```

`results/` already contains the evidence captured for the Treball de Recerca (`test-output.txt`, `gas-report.txt`, baseline CSVs, power-surface table, accumulated-damage figure). Re-running the commands above is for checking consistency. The Python scripts write into `results/`; a new run will refresh timestamps and the recorded Python path in `baseline-config.txt` even when the numeric results are unchanged. Treat the files already in `results/` as the reported snapshot. If a re-run disagrees on counts or damage figures, do not overwrite the snapshot until the discrepancy is understood.

## Results (defined local scenarios only)

Captured Foundry suite (`results/test-output.txt`):

- 69 passed, 0 failed, 0 skipped
- 13/13 tests on the normal grant–execute flow
- forbidden attempts accepted: 0/2 out of scope, 0/2 outside the time window, 0/9 after revocation, 0/3 guardian grants, 0/1 guardian execute/spend

Captured baseline comparison (`results/baseline-config.txt`, `results/baseline-results.csv`), main scenario (simulated balance 100, 10 units per step, compromise and user unavailability from `t = 3`, DART/admin revocation effective before `t = 4`):

| Model | Accumulated damage |
|---|---|
| A · user-only revocation | 70 |
| B · short-lived credential | 30 |
| C · central administrator | 10 |
| D · DART guardian | 10 |

C and D match on damage in this scenario because they receive the same simulated emergency response. The relevant difference is the authority surface: the DART guardian can revoke and cannot grant or execute; the central-administrator archetype can do all three (`results/power-surface.md`). This is not a claim that DART always outperforms every alternative, and it is not a proof of universal security, cryptographic unforgeability, or real-world emergency detection.

## Repository layout

| Path | Contents |
|---|---|
| `src/DARTVault.sol` | Prototype contract |
| `test/DARTVault.t.sol` | Foundry tests |
| `analysis/` | Deterministic baseline simulator and damage plot |
| `results/` | Captured test output, gas report, CSVs, and damage figure |
| `diagrams/architecture.mmd` | Prototype architecture (Mermaid source) |
| `docs/` | Original 2025 whitepaper PDF |
| `figures/` | Figures extracted from that whitepaper |
| `foundry.toml` | Compiler pin (`solc` 0.8.37) |

## Academic context

This repository holds the practical prototype and supporting evidence for a Batxillerat Treball de Recerca. It is a modelling study with local deterministic tests, not a product.

## Limitations

- Simulated value only; no real funds and no testnet deployment.
- Tests and the baseline comparison are local and deterministic.
- The contract authenticates with `msg.sender`; it does not implement in-contract verification of `Sign_skU` / `Sign_skG`.
- No external audit.
- The guardian can cause denial of service by revoking valid delegations (the cost of “revoke only”).
- A per-operation limit still allows repeated permitted actions until revocation.
- Revocation is not retroactive: value already spent remains spent.

## Original whitepaper

The PDF in `docs/` is the earlier proposal *Distributed Ledger System for Managing Delegated Authority and Revocations* (2025). That document sketches a broader, multi-domain system. The Treball de Recerca **narrows** it: one vault, simulated value, unidirectional revocation, and comparison against explicit alternative models. The whitepaper is background, not a description of `DARTVault`.

## Licensing

This repository already contains `LICENSE` (GNU Affero GPL v3) from the 2025 whitepaper snapshot. `src/DARTVault.sol` carries `SPDX-License-Identifier: MIT`. Those two statements are not the same decision. No new repository-wide license was added here. Resolve the mismatch before making the repository public.
