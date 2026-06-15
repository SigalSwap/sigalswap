// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";

export function Terms() {
  const { t } = useTranslation();

  return (
    <div className="max-w-3xl mx-auto py-8">
      <h1 className="text-2xl font-bold mb-2">{t("terms.title")}</h1>
      <p className="text-sm text-muted-foreground mb-8">{t("terms.lastModified")}: April 7, 2026</p>

      <article className="prose-legal space-y-6 text-sm leading-relaxed text-muted-foreground [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-foreground [&_h2]:mt-10 [&_h2]:mb-3 [&_h3]:text-base [&_h3]:font-medium [&_h3]:text-foreground [&_h3]:mt-6 [&_h3]:mb-2 [&_strong]:text-foreground [&_ul]:list-disc [&_ul]:pl-5 [&_ul]:space-y-1">
        <p className="text-foreground font-medium">
          IMPORTANT: PLEASE READ THESE TERMS OF SERVICE CAREFULLY. BY ACCESSING OR
          USING THE SIGALSWAP INTERFACE, YOU AGREE TO BE BOUND BY THESE TERMS. IF YOU
          DO NOT AGREE, DO NOT USE THE INTERFACE.
        </p>
        <p className="text-foreground font-medium">
          THESE TERMS INCLUDE A BINDING ARBITRATION CLAUSE AND CLASS ACTION WAIVER
          (SECTION 14), WHICH AFFECT YOUR LEGAL RIGHTS.
        </p>

        <h2>1. Acceptance of Terms</h2>
        <p>By accessing, browsing, or using the SigalSwap web interface (the "Interface") or any associated software, APIs, or services provided by SigalSwap LLC (the "Company", "we", "us", or "our"), you ("you" or "User") agree to be bound by these Terms of Service ("Terms"). We may update these Terms at any time by posting the revised version on the Interface. Your continued use constitutes acceptance of the updated Terms.</p>

        <h2>2. Description of Services</h2>
        <p>The Interface provides a web-based means of interacting with the SigalSwap Protocol, a set of autonomous smart contracts deployed on the Aztec Network (a Layer 2 blockchain built on Ethereum). The Interface allows Users to:</p>
        <ul>
          <li>Swap digital assets through automated market maker (AMM) liquidity pools</li>
          <li>Provide liquidity to pools and receive liquidity provider (LP) tokens</li>
          <li>Remove liquidity and redeem LP tokens for underlying assets</li>
          <li>View pool information, price quotes, and position values</li>
        </ul>
        <p><strong>The Interface is distinct from the Protocol.</strong> The Protocol consists of autonomous, immutable smart contracts on the Aztec Network that operate independently of the Company. The Company does not control, operate, or administer the Protocol.</p>

        <h2>3. Non-Custodial Nature</h2>
        <p><strong>The Company never custodies, manages, controls, or accesses your digital assets, private keys, recovery phrases, or wallet credentials.</strong></p>
        <p>All transactions are executed by smart contracts on the Aztec Network. Custody and title to digital assets in your wallet remain with you at all times. The Company cannot reverse, cancel, modify, or refund any blockchain transaction.</p>

        <h2>4. Eligibility</h2>
        <p>You represent and warrant that you: (a) are at least 18 years of age; (b) have the legal capacity to enter into a binding agreement; (c) are not a Restricted Person (as defined in Section 8); (d) are not acting on behalf of a Restricted Person; (e) will not use the Interface in violation of any applicable law.</p>

        <h2>5. Fees</h2>
        <h3>5.1 Network Fees</h3>
        <p>All blockchain transactions require network fees (gas) paid directly to the Aztec Network. These fees are not collected by or paid to the Company.</p>
        <h3>5.2 Protocol Fees</h3>
        <p>The SigalSwap Protocol may charge trading fees as determined by its governance parameters. Protocol fees are enforced by the smart contracts and are visible on-chain.</p>
        <h3>5.3 Interface Fees</h3>
        <p>The Company may charge an interface fee on transactions made through the Interface. The fee amount is included in the transaction data that the User signs with their wallet.</p>
        <h3>5.4 Taxes</h3>
        <p>You are solely responsible for determining and paying all taxes applicable to your use of the Interface and the Protocol.</p>

        <h2>6. Assumption of Risk</h2>
        <p>You acknowledge and accept the following risks:</p>
        <ul>
          <li><strong>Experimental Technology.</strong> The Aztec Network, zero-knowledge cryptography, and the SigalSwap Protocol are experimental, novel technologies.</li>
          <li><strong>Total Loss of Funds.</strong> Smart contract bugs, cyberattacks, or other events could result in the permanent, total loss of your digital assets.</li>
          <li><strong>Irreversible Transactions.</strong> All blockchain transactions are final and irreversible.</li>
          <li><strong>Price Volatility.</strong> Digital asset prices are highly volatile. Liquidity pool positions are subject to impermanent loss.</li>
          <li><strong>Regulatory Risk.</strong> Future regulations could restrict or prohibit the use of the Protocol or the Interface.</li>
          <li><strong>No Insurance.</strong> Digital assets held in the Protocol are not insured by any government agency or private insurer.</li>
        </ul>

        <h2>7. Privacy Features</h2>
        <p>The Aztec Network provides privacy features through zero-knowledge cryptography. Privacy is provided on a best-effort basis and is NOT guaranteed. See the full Terms of Service document for detailed privacy limitations and prohibited uses of privacy features.</p>

        <h2>8. Restricted Persons</h2>
        <p>You may not use the Interface if you are a resident of, located in, or organized under the laws of any jurisdiction subject to comprehensive U.S. economic sanctions, or listed on the SDN List or equivalent sanctions lists.</p>

        <h2>9. Prohibited Activities</h2>
        <p>You agree not to use the Interface for any illegal purpose, engage in market manipulation, attempt to exploit or attack the Protocol, or use automated tools that degrade service for other users.</p>

        <h2>10. Intellectual Property</h2>
        <p>The Protocol smart contracts are licensed under BUSL-1.1. The Interface source code is licensed under GPL-3.0. The SDK is licensed under MIT. The SigalSwap name, logo, and branding are trademarks of the Company.</p>

        <h2>11. No Professional Advice; No Fiduciary Duty</h2>
        <p>Nothing in the Interface or these Terms constitutes legal, financial, tax, or investment advice. <strong>The Company owes no fiduciary duties or liabilities to you or any other party.</strong></p>

        <h2>12. Third-Party Services</h2>
        <p>The Interface may interact with third-party services including wallets, token contracts, and blockchain networks. The Company does not control or endorse any third-party service.</p>

        <h2>13. Disclaimer of Warranties; Limitation of Liability</h2>
        <p className="uppercase">The Interface and all related software are provided "as is" and "as available" without warranties of any kind. The Company's total aggregate liability shall not exceed one hundred U.S. dollars ($100.00 USD).</p>

        <h2>14. Dispute Resolution and Arbitration</h2>
        <p>Disputes shall be resolved exclusively by binding arbitration. <strong>YOU WAIVE THE RIGHT TO PARTICIPATE IN ANY CLASS ACTION.</strong> These Terms shall be governed by the laws of the State of Delaware.</p>

        <h2>15–17. General Provisions</h2>
        <p>The Company may cooperate with law enforcement, modify these Terms at any time, and terminate access to the Interface. These Terms constitute the entire agreement between you and the Company.</p>

        <div className="mt-10 pt-6 border-t border-border">
          <p>SigalSwap LLC<br />contact@sigalswap.com</p>
        </div>
      </article>
    </div>
  );
}
