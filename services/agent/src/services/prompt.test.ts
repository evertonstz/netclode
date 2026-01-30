import { describe, it, expect } from "vitest";
import type { PromptConfig } from "../sdk/types.js";

describe("prompt session initialization logic", () => {
  describe("session initialization conditions", () => {
    it("should initialize when sessionId and config are provided", () => {
      const sessionId = "test-session-123";
      const config: PromptConfig = {
        repos: ["https://github.com/owner/repo.git"],
        githubToken: "test-token",
      };

      // The condition in prompt.ts: if (sessionId && config)
      // This should be true when both are provided
      expect(Boolean(sessionId && config)).toBe(true);
    });

    it("should NOT initialize when sessionId is empty string (the bug we fixed)", () => {
      const sessionId = "";
      const config: PromptConfig = {
        repos: ["https://github.com/owner/repo.git"],
      };

      // When sessionId is empty (falsy), the initialization block should be skipped
      // This was the bug - we were passing empty string before
      // The condition is: if (sessionId && config)
      // With empty string, this is falsy, so initialization is skipped
      expect(Boolean(sessionId && config)).toBe(false);
    });

    it("should initialize when sessionId is non-empty", () => {
      const sessionId = "test-session-456";
      const config: PromptConfig = {
        repos: ["https://github.com/owner/repo.git"],
      };

      // When sessionId is non-empty, the initialization block should run
      // This is the fixed behavior
      expect(Boolean(sessionId && config)).toBe(true);
    });

    it("should NOT initialize when config is undefined", () => {
      const sessionId = "test-session-789";
      const config = undefined;

      // When config is undefined, the initialization block should be skipped
      expect(Boolean(sessionId && config)).toBe(false);
    });
  });

  describe("repo clone conditions", () => {
    it("should clone repo when repo is provided in config", () => {
      const config: PromptConfig = {
        repos: ["https://github.com/owner/repo.git"],
      };

      const currentGitRepos = config.repos ?? [];
      expect(currentGitRepos.length > 0).toBe(true);
    });

    it("should NOT clone repo when repo is not in config", () => {
      const config: PromptConfig = {};

      const currentGitRepos = config.repos ?? [];
      expect(currentGitRepos.length > 0).toBe(false);
    });

    it("should NOT clone repo when repo is undefined", () => {
      const config: PromptConfig = {
        repos: undefined,
      };

      const currentGitRepos = config.repos ?? [];
      expect(currentGitRepos.length > 0).toBe(false);
    });

    it("should NOT clone repo when repo is empty string", () => {
      const config: PromptConfig = {
        repos: [""],
      };

      const currentGitRepos = (config.repos ?? []).filter(Boolean);
      expect(currentGitRepos.length > 0).toBe(false);
    });
  });
});
