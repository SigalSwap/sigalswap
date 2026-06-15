import { setupWallet } from "../packages/sdk/src/e2e/setup.js";
import { TokenContract, TokenContractArtifact } from "../packages/sdk/src/artifacts/Token.js";
import { AztecAddress } from "@aztec/aztec.js/addresses";

async function main() {
  const { node, wallet, senderAddress } = await setupWallet();
  
  const token0Addr = AztecAddress.fromString("0x0f12e744457f4b46790a17e6c7df34d20b89d5e68b8f9c2233d0ee508558803a");
  const token1Addr = AztecAddress.fromString("0x22bad0aa29a805d714fd2c731e722b70388f1bba0223775f69d929af15b7d597");
  
  for (const addr of [token0Addr, token1Addr]) {
    const instance = await node.getContract(addr);
    await wallet.registerContract(instance!, TokenContractArtifact);
  }
  
  const token0 = TokenContract.at(token0Addr, wallet);
  const token1 = TokenContract.at(token1Addr, wallet);
  
  const userAddr = AztecAddress.fromString("0x2e1666502ebed61119920f91339dd4b74dc163cf8b34a86d9c4dd093d061ca31");
  
  const d0 = await token0.methods.balance_of_private(senderAddress).simulate({ from: senderAddress });
  const d1 = await token1.methods.balance_of_private(senderAddress).simulate({ from: senderAddress });
  console.log("Deployer: ETH=" + d0.result + " USDC=" + d1.result);
  
  const u0 = await token0.methods.balance_of_private(userAddr).simulate({ from: senderAddress });
  const u1 = await token1.methods.balance_of_private(userAddr).simulate({ from: senderAddress });
  console.log("User:     ETH=" + u0.result + " USDC=" + u1.result);
  
  process.exit(0);
}
main().catch(e => { console.error("Failed:", e.message?.slice(0, 200)); process.exit(1); });
