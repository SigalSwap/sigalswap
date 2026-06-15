// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";

export function Privacy() {
  const { t } = useTranslation();

  return (
    <div className="max-w-3xl mx-auto py-8">
      <h1 className="text-2xl font-bold mb-2">{t("privacy.title")}</h1>
      <p className="text-sm text-muted-foreground mb-8">{t("privacy.lastModified")}: April 7, 2026</p>

      <article className="space-y-6 text-sm leading-relaxed text-muted-foreground [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-foreground [&_h2]:mt-10 [&_h2]:mb-3 [&_h3]:text-base [&_h3]:font-medium [&_h3]:text-foreground [&_h3]:mt-6 [&_h3]:mb-2 [&_strong]:text-foreground [&_ul]:list-disc [&_ul]:pl-5 [&_ul]:space-y-1">
        <p>SigalSwap LLC (the "Company", "we", "us", or "our") operates the SigalSwap web interface (the "Interface"). This Privacy Policy describes what information we collect, what we don't collect, and how we handle your data.</p>
        <p className="text-foreground font-medium">We built SigalSwap for people who value privacy. This policy reflects that.</p>

        <h2>1. What We Do NOT Collect</h2>
        <ul>
          <li><strong>No analytics or tracking.</strong> We do not use Google Analytics, Mixpanel, Hotjar, or any other analytics service.</li>
          <li><strong>No cookies.</strong> The Interface does not set cookies of any kind.</li>
          <li><strong>No wallet tracking.</strong> We do not log, store, or associate your wallet address with any identifying information.</li>
          <li><strong>No IP logging.</strong> We do not log your IP address on our application servers.</li>
          <li><strong>No fingerprinting.</strong> We do not use browser fingerprinting, device fingerprinting, or any other tracking technique.</li>
          <li><strong>No advertising.</strong> We do not serve ads or share data with advertisers.</li>
          <li><strong>No social media trackers.</strong> The Interface does not embed social media widgets, pixels, or tracking scripts.</li>
        </ul>

        <h2>2. What We May Collect</h2>
        <h3>2.1 Infrastructure Logs</h3>
        <p>Our hosting provider may automatically collect standard web server logs (IP addresses, request timestamps, HTTP headers) as part of normal server operation. These logs are used solely for security monitoring, abuse prevention, and debugging. They are not correlated with wallet addresses or user identities, and are deleted on a rolling basis.</p>
        <h3>2.2 Blockchain Data</h3>
        <p>When you submit a transaction through the Interface, that transaction is processed by the Aztec Network. On-chain data that is publicly visible is recorded on the blockchain permanently. This is inherent to blockchain technology and is not controlled by the Company.</p>
        <h3>2.3 Voluntary Communications</h3>
        <p>If you contact us via email or other channels, we retain the content of those communications to respond to you. We do not share this information with third parties.</p>

        <h2>3. Third-Party Services</h2>
        <p>The Interface may interact with third-party services that have their own privacy practices, including:</p>
        <ul>
          <li><strong>Wallet providers</strong> — we do not control what data your wallet collects</li>
          <li><strong>RPC/node providers</strong> — if the Interface connects to third-party Aztec nodes, those providers may log connection metadata</li>
          <li><strong>Hosting providers</strong> — our web hosting infrastructure may collect standard server logs</li>
        </ul>

        <h2>4. Privacy on Aztec</h2>
        <p>The Aztec Network provides privacy features through zero-knowledge cryptography. These features are a property of the underlying blockchain, not something added by the Company. Privacy on Aztec is not absolute — certain information may be publicly visible by design, and user identity protection depends on the correct functioning of cryptographic systems and user behavior.</p>

        <h2>5. Data Sharing</h2>
        <p>We do not sell, rent, or trade your personal information to third parties. We may disclose information if required by law, regulation, legal process, or governmental request.</p>

        <h2>6. Data Retention</h2>
        <ul>
          <li><strong>Infrastructure logs:</strong> Deleted on a rolling basis (typically 14–30 days).</li>
          <li><strong>Voluntary communications:</strong> Retained as long as necessary to respond.</li>
          <li><strong>Blockchain data:</strong> Permanent and immutable. We cannot delete on-chain data.</li>
        </ul>

        <h2>7. Children</h2>
        <p>The Interface is not directed to individuals under 18 years of age. We do not knowingly collect information from children.</p>

        <h2>8. International Users</h2>
        <p>The Interface is operated from the United States. If you access the Interface from another jurisdiction, you acknowledge that your information may be processed in the United States.</p>

        <h2>9. Your Rights</h2>
        <p>Depending on your jurisdiction, you may have rights regarding your personal data. Given that we collect minimal data (Section 1), these rights are largely moot. If you have questions, contact us at contact@sigalswap.com.</p>

        <h2>10. Changes to This Policy</h2>
        <p>We may update this Privacy Policy from time to time. Material changes will be indicated by updating the "Last Modified" date.</p>

        <div className="mt-10 pt-6 border-t border-border">
          <p>SigalSwap LLC<br />contact@sigalswap.com</p>
        </div>
      </article>
    </div>
  );
}
