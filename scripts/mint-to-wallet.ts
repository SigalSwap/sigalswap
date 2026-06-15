#!/usr/bin/env npx tsx
// Mint test tokens to an external wallet address (e.g. Azguard)
// Usage: npx tsx scripts/mint-to-wallet.ts <address>

import { setupWallet, mintPrivate } from "../packages/sdk/src/e2e/setup.js";
import { AztecAddress } from "@aztec/aztec.js/addresses";
import { createAztecNodeClient } from "@aztec/aztec.js/node";
import { TokenContract } from "../packages/sdk/src/artifacts/Token.js";

const MINT_AMOUNT = 1_000_000n;

async function main() {
  const target = process.argv[2];
  if (!target) {
    console.error("Usage: npx tsx scripts/mint-to-wallet.ts <aztec-address>");
    process.exit(1);
  }

  const targetAddr = AztecAddress.fromString(target);
  console.log("Minting to:", targetAddr.toString());

  const { wallet, senderAddress: sender } = await setupWallet();
  console.log("Using deployer:", sender.toString());

  // Read token addresses from site/app/.env.local
  const { readFileSync } = await import("fs");
  const { resolve, dirname } = await import("path");
  const { fileURLToPath } = await import("url");
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const envFile = readFileSync(resolve(__dirname, "../site/app/.env.local"), "utf8");
  const envGet = (key: string) => envFile.match(new RegExp(`^${key}=(.+)$`, "m"))?.[1] ?? "";

  const token0Addr = AztecAddress.fromString(envGet("VITE_PAIR_0_TOKEN0_ADDRESS"));
  const token1Addr = AztecAddress.fromString(envGet("VITE_PAIR_0_TOKEN1_ADDRESS"));

  if (token0Addr.isZero() || token1Addr.isZero()) {
    console.error("Could not read token addresses from site/app/.env.local");
    process.exit(1);
  }

  // Fetch contract instances from the node and register with the ephemeral PXE
  const nodeClient = createAztecNodeClient("http://localhost:8080");
  const instance0 = await nodeClient.getContract(token0Addr);
  const instance1 = await nodeClient.getContract(token1Addr);
  if (!instance0 || !instance1) {
    console.error("Could not fetch token instances from node");
    process.exit(1);
  }
  await wallet.registerContract(instance0, TokenContract.artifact);
  await wallet.registerContract(instance1, TokenContract.artifact);

  const token0 = await TokenContract.at(token0Addr, wallet);
  const token1 = await TokenContract.at(token1Addr, wallet);

  console.log("\nMinting", MINT_AMOUNT.toString(), "of token0 (", token0Addr.toString().slice(0, 10), "...)");
  await mintPrivate(token0, sender, targetAddr, MINT_AMOUNT);

  console.log("Minting", MINT_AMOUNT.toString(), "of token1 (", token1Addr.toString().slice(0, 10), "...)");
  await mintPrivate(token1, sender, targetAddr, MINT_AMOUNT);

  console.log("\n✓ Done. Minted", MINT_AMOUNT.toString(), "of each token to", target);
}

main().catch((e) => {
  console.error("Mint failed:", e.message ?? e);
  process.exit(1);
});
