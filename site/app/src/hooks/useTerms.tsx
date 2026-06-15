// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState, useCallback } from "react";

const STORAGE_KEY = "sigalswap_terms_accepted";

/**
 * Tracks whether the user has accepted the Terms of Service.
 * Persisted in localStorage so it survives page reloads.
 */
export function useTerms() {
  const [accepted, setAccepted] = useState<boolean>(() => {
    try {
      return localStorage.getItem(STORAGE_KEY) === "true";
    } catch {
      return false;
    }
  });

  const accept = useCallback(() => {
    try {
      localStorage.setItem(STORAGE_KEY, "true");
    } catch {
      // localStorage unavailable — accept for this session only
    }
    setAccepted(true);
  }, []);

  return { accepted, accept };
}
