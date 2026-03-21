# Delegated Authority Revocation System (DARS)

**TL;DR**  
Users assign cryptographic agents on-chain (e.g. AI agents, proxies, advisors) for specific domains (finance, voting, civic, defense, etc.). A designated **Revocation Guardian** (trusted institution per domain) can **only revoke** those delegations - never assign new ones or act on behalf of the user. This design preserves full user autonomy while providing an audited emergency failsafe against key loss, compromise, or rogue agents.

## Why this project?
Typical blockchain delegation systems allow the user (principal) to revoke an agent's authority… unless the **user's own private key is lost, stolen, or compromised**. In that case, a malicious or compromised agent can continue acting indefinitely - a critical failure mode in high-stakes domains (financial loss, fraudulent votes, unauthorized military orders, etc.).

DARS solves this by introducing a **constrained, auditable revocation-only key** held by a trusted third party (the Guardian), without giving that party any power to assign agents or impersonate the user.  

## High-level Design
- **Ledger-stored state**: `principal → domain → agent → status / limits` — fully queryable and auditable via on-chain events.
- **Separation of powers**:
  - **User key** (master): can assign, replace, or update agents.
  - **Guardian key** (per domain): can only revoke (or optionally suspend) an existing agent. No capability to assign, transfer assets, vote, or perform any user action.
- **Multi-domain support**: Different Guardians per domain (e.g. bank for finance, election board for voting, military authority for defense).
- **Optional extension**: Permission Packs for AI agents — scoped permissions, expiry dates, autonomy levels (advisory → proactive).

## Current status 
This repository currently contains:
- The full whitepaper (PDF) with architecture diagrams (FIG. 1–4)

**Coming soon** (Q2–Q3 2026 as part of the TR prototype):
- Solidity smart contracts (`AgentRegistry.sol`, `PermissionPacks.sol`)
- Unit tests (Foundry / Hardhat)
- Deployment script to Sepolia testnet
- Simple demo frontend or CLI to simulate assign/revoke
- Integration simulation with AI agent (LangChain-style)
- Hardware extension concept (physical root-of-trust via Arduino/YubiKey)

## Quickstart (to be updated when contracts are ready)
```bash
# Planned workflow with Foundry (once implemented)
git clone https://github.com/[your-username]/dars.git
cd dars
forge install
forge build
forge test
```
For now, explore the whitepaper in /docs/ and the figures in /figures/.
## License
<img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3">
© 2025–2026 TomateDM. Licensed under the GNU Affero General Public License v3.0.
If this code is ever deployed as a public service (e.g. API for AI agent delegation), the full source must be made available.

## Roadmap

Q2 2026: First working Solidity contracts + basic tests + testnet deployment
Q3 2026: Demo video + simulation of revocation in a financial/voting scenario
Future (post-TR): Hardware root-of-trust integration, proposal for open standard in AI agent IAM

⭐ Star this repo if you're interested in secure delegation for AI agents and blockchain identity systems.
Contributions, feedback, and ideas are very welcome — especially around tests, documentation, or domain-specific extensions.
This project is part of my Treball de Recerca (Batxillerat) — developing a hybrid blockchain + hardware solution to prevent authorization drift and credential abuse in the era of autonomous AI agents (2026+).

## License
