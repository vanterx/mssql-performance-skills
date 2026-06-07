import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    globals: true,
    include: ["src/__tests__/**/*.test.ts", "scripts/__tests__/**/*.test.ts"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts", "scripts/**/*.ts"],
      exclude: ["src/skills-data.ts", "src/__tests__/**"],
      reporter: ["text", "lcov"],
    },
  },
  resolve: {
    extensions: [".ts", ".js"],
  },
});
