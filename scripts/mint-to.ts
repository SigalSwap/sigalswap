#!/usr/bin/env npx tsx
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

/**
 * Mint test tokens to a specified address on the local sandbox.
 *
 * Usage:
 *   npx --prefix packages/sdk tsx scripts/mint-to.ts <address> [amount]
 *
 * Defaults to minting 100,000 of each token (ETH + USDC).
 * Reads token addresses from site/app/.env.local.
 */

import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import { readFileSync } from "fs";
import { setupWallet } from "../packages/sdk/src/e2e/setup.js";
import { TokenContract, TokenContractArtifact } from "../packages/sdk/src/artifacts/Token.js";
import { AztecAddress } from "@aztec/aztec.js/addresses";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ENV_PATH = resolve(__dirname, "../site/app/.env.local");
const TX_OPTS = { timeout: 120 };

function readEnv(key: string): string {
  const content = readFileSync(ENV_PATH, "utf-8");
  const match = content.match(new RegExp(`^${key}=(.+)$`, "m"));
  return match?.[1]?.trim() ?? "";
}

async function main() {
  const recipient = process.argv[2];
  if (!recipient) {
    console.error("Usage: mint-to.ts <address> [amount]");
    process.exit(1);
  }

  const amount = BigInt(process.argv[3] ?? "100000");
  const recipientAddr = AztecAddress.fromString(recipient);

  const token0Addr = readEnv("VITE_PAIR_0_TOKEN0_ADDRESS");
  const token1Addr = readEnv("VITE_PAIR_0_TOKEN1_ADDRESS");
  const token0Symbol = readEnv("VITE_PAIR_0_TOKEN0_SYMBOL");
  const token1Symbol = readEnv("VITE_PAIR_0_TOKEN1_SYMBOL");

  if (!token0Addr || !token1Addr) {
    console.error("Token addresses not found in site/app/.env.local. Run deploy-sandbox.ts first.");
    process.exit(1);
  }

  console.log(`Minting ${amount} of each token to ${recipient}...`);

  const { wallet, senderAddress } = await setupWallet();

  // Register token contracts in this PXE so we can call mint_to_private.
  // The contracts are deployed on-chain but this fresh PXE doesn't know about them.
  // We register using the artifact + the on-chain instance fetched by the wallet.
  for (const addr of [token0Addr, token1Addr]) {
    const address = AztecAddress.fromString(addr);
    const meta = await wallet.getContractMetadata(address);
    if (meta.instance) {
      await wallet.registerContract(meta.instance, TokenContractArtifact);
      console.log(`  Registered token at ${addr}`);
    } else {
      console.error(`  Could not find contract instance for ${addr} -- is the sandbox running?`);
      process.exit(1);
    }
  }

  const token0 = TokenContract.at(AztecAddress.fromString(token0Addr), wallet);
  const token1 = TokenContract.at(AztecAddress.fromString(token1Addr), wallet);

  console.log(`  Minting ${amount} ${token0Symbol}...`);
  await token0.methods.mint_to_private(recipientAddr, amount).send({ from: senderAddress, wait: TX_OPTS });

  console.log(`  Minting ${amount} ${token1Symbol}...`);
  await token1.methods.mint_to_private(recipientAddr, amount).send({ from: senderAddress, wait: TX_OPTS });

  console.log(`\nDone! Minted ${amount} ${token0Symbol} + ${amount} ${token1Symbol} to ${recipient}`);
}

main().catch((e) => {
  console.error("Failed:", e.message ?? e);
  process.exit(1);
});
