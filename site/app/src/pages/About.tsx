// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { Logo } from "@/components/Logo";

export function About() {
  const { t } = useTranslation();

  return (
    <div className="max-w-2xl mx-auto space-y-8 py-8">
      <div className="text-center space-y-4">
        <Logo size={64} className="mx-auto" />
        <h1 className="text-3xl font-bold">{t("about.title")}</h1>
        <p className="text-lg text-muted-foreground">{t("about.subtitle")}</p>
      </div>

      <article className="space-y-6 text-base leading-relaxed text-muted-foreground">
        <p>
          Sigal takes its name from <strong className="text-foreground">Sigalion</strong> (Σιγαλίων),
          an epithet of Harpocrates — the Greco-Roman god of silence, secrets, and confidentiality.
          Adapted from the Egyptian child-god Horus, Harpocrates became one of antiquity's most
          recognizable figures: a youth with finger pressed to lips, the universal gesture for silence.
        </p>
        <p>
          Throughout the ancient Mediterranean world, small terracotta statues of Harpocrates stood
          in household shrines and temple doorways. His image appeared wherever discretion mattered —
          a quiet guardian ensuring that what was spoken in confidence remained protected. The Romans
          painted roses on meeting room ceilings as a nod to his symbolism, giving us the phrase{" "}
          <em className="text-foreground">sub rosa</em>: "under the rose," meaning held in confidence.
        </p>
        <p>
          Sigalion wasn't a god of deception or hiding wrongdoing. He was the protector of sacred
          knowledge, the keeper of mystery rites, the guardian of reputations. Silence, in this
          tradition, wasn't absence — it was{" "}
          <strong className="text-foreground">sovereignty over one's own information</strong>.
        </p>
        <p>
          SigalSwap carries this tradition forward. On a public blockchain, every transaction speaks
          loudly to anyone watching. Sigal restores your finger to your lips. Your swaps exist, they
          settle, they're valid — they simply don't announce themselves to the world.
        </p>
      </article>
    </div>
  );
}
