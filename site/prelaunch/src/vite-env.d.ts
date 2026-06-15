/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_ENVIRONMENT: "local" | "testnet" | "production";
  readonly VITE_NODE_URL: string;
  readonly VITE_FACTORY_ADDRESS: string;
  readonly VITE_ROUTER_ADDRESS: string;
  readonly VITE_FEE_RECIPIENT: string;
  readonly VITE_FEE_BIPS: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
