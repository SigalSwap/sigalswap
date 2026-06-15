// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState } from "react";
import { Link } from "react-router-dom";
import { Trans, useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useTerms } from "@/hooks/useTerms";

/**
 * Wraps a transaction action button. If terms haven't been accepted,
 * clicking shows a terms agreement modal instead of executing the action.
 * Once accepted, the children render and work normally.
 *
 * Usage:
 *   <TermsGate onAccepted={handleSwap}>
 *     <Button>Review swap</Button>
 *   </TermsGate>
 */
export function TermsGate({
  children,
  onAccepted,
}: {
  children: React.ReactElement<{ onClick?: (...args: any[]) => void }>;
  onAccepted: () => void;
}) {
  const { accepted, accept } = useTerms();
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);

  function handleClick() {
    if (accepted) {
      onAccepted();
    } else {
      setOpen(true);
    }
  }

  function handleAgree() {
    accept();
    setOpen(false);
    onAccepted();
  }

  const link = "text-primary hover:underline";

  return (
    <>
      {/* Clone the child element and override its onClick */}
      <div onClick={handleClick} className="contents">
        {children}
      </div>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-md bg-card">
          <DialogHeader>
            <DialogTitle>{t("common.termsTitle")}</DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground leading-relaxed">
            <Trans
              i18nKey="common.termsBody"
              components={{
                terms: <Link to="/terms" className={link} onClick={() => setOpen(false)} />,
                privacy: <Link to="/privacy" className={link} onClick={() => setOpen(false)} />,
              }}
            />
          </p>
          <Button className="w-full mt-2" onClick={handleAgree}>
            {t("common.termsAgree")}
          </Button>
        </DialogContent>
      </Dialog>
    </>
  );
}
