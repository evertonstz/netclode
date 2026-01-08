import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      "/ws": {
        target: process.env.CONTROL_PLANE_URL || "http://localhost:3001",
        ws: true,
        changeOrigin: true,
      },
    },
  },
});
