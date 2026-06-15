import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "path";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 3010,
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
    // npm workspaces hoists deps to the repo root — tell Vite to look there
    modules: [
      path.resolve(__dirname, "node_modules"),
      path.resolve(__dirname, "../../node_modules"),
    ],
  },
});
