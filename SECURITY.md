# Security Policy

## Reporting a vulnerability

If you find a security vulnerability in SigalSwap -- in the Noir contracts, the
TypeScript SDK, or anything else in this repository -- please report it
**privately**. Do **not** open a public issue, pull request, or discussion for a
security vulnerability.

**Email: contact@sigalswap.com**

Helpful details to include:

- A description of the issue and its potential impact
- Steps to reproduce, or a proof of concept
- The affected component(s) and the relevant commit or file paths

We aim to acknowledge a report within **48 hours** and to send a substantive
response within **7 days**.

## Scope

SigalSwap is **pre-launch and has not yet had a professional external audit**.
The contracts are not deployed to mainnet, so no user funds are at risk today --
but we want to find issues early, while they are still cheap to fix on what will
become immutable contracts.

**In scope:**

- The Noir contracts under `protocol/` (Pair, Factory, Router, LP Token)
- The TypeScript SDK under `packages/sdk/`
- The privacy guarantees and threat model described under `docs/`

**Out of scope:**

- The Aztec network, the Noir compiler, and the `aztec-nr` libraries -- report
  those to the [Aztec project](https://github.com/AztecProtocol/aztec-packages)
- Third-party token contracts and end-user wallets
- Behaviors that are documented and by design, e.g. that per-swap amounts are
  public (see `docs/privacy-model.md`), or privileged-actor scenarios already
  covered by the admin threat model (`docs/admin-compromise.md`)

## Coordinated disclosure

Please give us a reasonable window to investigate and remediate before disclosing
publicly. We are happy to credit reporters who would like acknowledgement.

There is no formal bug-bounty program yet; we may introduce one before mainnet
launch.
