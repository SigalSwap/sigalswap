/**
 * E2E test setup utilities.
 *
 * Provides helpers to connect to the local Aztec sandbox, create a wallet,
 * deploy contracts, and mint tokens for integration testing.
 */

import { createAztecNodeClient } from '@aztec/aztec.js/node';
import type { AztecNode } from '@aztec/aztec.js/node';
import { AztecAddress } from '@aztec/aztec.js/addresses';
import type { Wallet } from '@aztec/aztec.js/wallet';
import { EmbeddedWallet } from '@aztec/wallets/embedded';
import { registerInitialLocalNetworkAccountsInWallet } from '@aztec/wallets/testing';

import { getContractClassFromArtifact } from '@aztec/aztec.js/contracts';

import { TokenContract } from '../artifacts/Token.js';
import { SigalSwapFactoryContract } from '../artifacts/SigalSwapFactory.js';
import { SigalSwapFactory } from '../factory.js';
import { sortTokensByField } from '../factory.js';
import { SigalSwapPairContract, SigalSwapPairContractArtifact } from '../artifacts/SigalSwapPair.js';
import { SigalSwapLPTokenContract } from '../artifacts/SigalSwapLPToken.js';
import { SigalSwapRouterContract } from '../artifacts/SigalSwapRouter.js';

const SANDBOX_URL = 'http://localhost:8080';
const TX_OPTS = { timeout: 120 };

/** Re-export under the local name used throughout the E2E suite. */
export const sortTokens = sortTokensByField;

/** Connect to sandbox, create wallet, register pre-funded test accounts. */
export async function setupWallet(): Promise<{
  node: AztecNode;
  wallet: Wallet;
  senderAddress: AztecAddress;
}> {
  const node = createAztecNodeClient(SANDBOX_URL);
  const wallet = await EmbeddedWallet.create(node, { ephemeral: true });
  const addresses = await registerInitialLocalNetworkAccountsInWallet(wallet);

  // Register the Schnorr account contract artifact so the PXE can
  // process authwit verification (verify_private_authwit) during transactions
  const { getSchnorrAccountContractArtifact } = await import('@aztec/accounts/schnorr/lazy');
  const accountArtifact = await getSchnorrAccountContractArtifact();
  for (const address of addresses) {
    const meta = await wallet.getContractMetadata(address);
    await wallet.registerContract(meta.instance!, accountArtifact);
  }

  return { node, wallet: wallet as unknown as Wallet, senderAddress: addresses[0] };
}

/** Deploy a Token contract. */
export async function deployToken(
  wallet: Wallet,
  deployer: AztecAddress,
  name: string,
  symbol: string,
): Promise<TokenContract> {
  const { contract } = await TokenContract.deploy(wallet, deployer, name, symbol, 18)
    .send({ from: deployer, universalDeploy: true, wait: TX_OPTS });
  return contract;
}

/** Mint tokens to a recipient's private balance. */
export async function mintPrivate(
  token: TokenContract,
  from: AztecAddress,
  to: AztecAddress,
  amount: bigint,
): Promise<void> {
  await token.methods.mint_to_private(to, amount).send({ from, wait: TX_OPTS });
}

/** Deploy the Factory contract. Sets pair class ID and pre-registers fee tiers 5, 25, 100 bps. */
export async function deployFactory(
  wallet: Wallet,
  admin: AztecAddress,
): Promise<SigalSwapFactoryContract> {
  const { contract } = await SigalSwapFactoryContract.deploy(wallet, admin)
    .send({ from: admin, wait: TX_OPTS });

  // Factory requires pair class ID to be set before any pair can be registered.
  // The first set_pair_class_id call is immediate (no timelock). The version
  // arg must match the VERSION global baked into the pair bytecode
  // (core/src/main.nr); register_pair cross-checks via pair.get_version().
  const pairClass = await getContractClassFromArtifact(SigalSwapPairContractArtifact);
  await contract.methods.set_pair_class_id(pairClass.id, 1)
    .send({ from: admin, wait: TX_OPTS });

  return contract;
}

/**
 * Deploy a pair with its LP Token (derived-address design) and register the
 * pair with the factory. Handles token sorting automatically.
 *
 * Thin wrapper around `SigalSwapFactory.createPair` so the E2E suite
 * exercises the actual SDK method. The wrapper extracts addresses from the
 * passed-in `TokenContract` handles (the test-utility ergonomic) and hands
 * off to the SDK. Idempotent -- safe to call twice with the same inputs
 * (second call no-ops if the pair is already deployed + registered).
 */
export async function deployPairWithLP(
  wallet: Wallet,
  deployer: AztecAddress,
  tokenA: TokenContract,
  tokenB: TokenContract,
  factory: SigalSwapFactoryContract,
  feeTierBps: number,
): Promise<{ pair: SigalSwapPairContract; lpToken: SigalSwapLPTokenContract; token0: AztecAddress; token1: AztecAddress }> {
  const sdkFactory = new SigalSwapFactory(factory, deployer);
  return sdkFactory.createPair(wallet, tokenA.address, tokenB.address, feeTierBps);
}

/** Deploy the Router contract. Uses universalDeploy for cross-contract calls. */
export async function deployRouter(
  wallet: Wallet,
  deployer: AztecAddress,
  factory: SigalSwapFactoryContract,
): Promise<SigalSwapRouterContract> {
  const { contract } = await SigalSwapRouterContract.deploy(wallet, factory.address)
    .send({ from: deployer, universalDeploy: true, wait: TX_OPTS });
  return contract;
}
