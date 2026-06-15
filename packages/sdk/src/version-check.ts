// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import { SigalSwapPairContractArtifact } from './artifacts/SigalSwapPair.js';
import { SigalSwapFactoryContractArtifact } from './artifacts/SigalSwapFactory.js';
import { SigalSwapRouterContractArtifact } from './artifacts/SigalSwapRouter.js';
import { SigalSwapLPTokenContractArtifact } from './artifacts/SigalSwapLPToken.js';

const EXPECTED_AZTEC_MAJOR_MINOR = '4.3';

const checked = new Set<string>();

function checkOne(artifact: unknown): void {
  const a = artifact as { name?: string; aztec_version?: string };
  if (!a.name || checked.has(a.name)) return;
  checked.add(a.name);

  if (typeof a.aztec_version !== 'string') return;

  const [major, minor] = a.aztec_version.split('.');
  const [expectedMajor, expectedMinor] = EXPECTED_AZTEC_MAJOR_MINOR.split('.');
  if (major !== expectedMajor || minor !== expectedMinor) {
    // eslint-disable-next-line no-console
    console.warn(
      `[@sigalswap/sdk] Artifact "${a.name}" was compiled against aztec ${a.aztec_version}, ` +
      `but the SDK is pinned to ${EXPECTED_AZTEC_MAJOR_MINOR}.x. ABI drift may cause runtime errors. ` +
      `Run \`npm run codegen\` after upgrading contract toolchain.`,
    );
  }
}

checkOne(SigalSwapPairContractArtifact);
checkOne(SigalSwapFactoryContractArtifact);
checkOne(SigalSwapRouterContractArtifact);
checkOne(SigalSwapLPTokenContractArtifact);
