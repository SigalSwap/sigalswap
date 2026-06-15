import { createAztecNodeClient } from '@aztec/aztec.js/node';
import { EmbeddedWallet } from '@aztec/wallets/embedded';
import { AztecAddress } from '@aztec/aztec.js/addresses';

async function main() {
  const node = createAztecNodeClient('http://localhost:8080');
  const wallet = await EmbeddedWallet.create(node, { ephemeral: true });
  const addr = AztecAddress.fromString('0x26db22d0173100237be7d2af704df1665d27a826677a30bd896d1b6ff5312bfe');

  const meta = await wallet.getContractMetadata(addr);
  console.log('wallet meta instance:', meta.instance ? 'EXISTS' : 'NULL');

  const instance = await node.getContractInstance(addr);
  console.log('node instance:', instance ? 'EXISTS' : 'NULL');
  if (instance) {
    console.log('contractClassId:', instance.contractClassId?.toString());
  }
  process.exit(0);
}
main();
