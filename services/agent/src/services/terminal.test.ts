import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// Store callbacks so tests can trigger PTY events
let onDataCallback: ((data: string) => void) | null = null;
let onExitCallback:
  | ((info: { exitCode: number; signal: number }) => void)
  | null = null;

function createMockPty() {
  return {
    onData: vi.fn((cb: (data: string) => void) => {
      onDataCallback = cb;
    }),
    onExit: vi.fn(
      (cb: (info: { exitCode: number; signal: number }) => void) => {
        onExitCallback = cb;
      }
    ),
    write: vi.fn(),
    resize: vi.fn(),
    kill: vi.fn(),
  };
}

vi.mock("node-pty", () => ({
  default: {
    spawn: vi.fn(() => createMockPty()),
  },
  spawn: vi.fn(() => createMockPty()),
}));

import {
  setTerminalOutputCallback,
  handleTerminalInput,
  registerOutputCallback,
} from "./terminal.js";

describe("terminal service", () => {
  beforeEach(() => {
    setTerminalOutputCallback(null);
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  describe("setTerminalOutputCallback", () => {
    it("accepts a callback function", () => {
      const callback = vi.fn();
      expect(() => setTerminalOutputCallback(callback)).not.toThrow();
    });

    it("accepts null to clear callback", () => {
      const callback = vi.fn();
      setTerminalOutputCallback(callback);
      expect(() => setTerminalOutputCallback(null)).not.toThrow();
    });
  });

  describe("handleTerminalInput", () => {
    it("does not throw for valid input", () => {
      expect(() => handleTerminalInput("ls -la\n")).not.toThrow();
    });

    it("handles empty string input", () => {
      expect(() => handleTerminalInput("")).not.toThrow();
    });

    it("handles special characters", () => {
      expect(() => handleTerminalInput("\x03")).not.toThrow(); // Ctrl+C
      expect(() => handleTerminalInput("\x04")).not.toThrow(); // Ctrl+D
      expect(() => handleTerminalInput("\t")).not.toThrow(); // Tab
    });
  });

  describe("registerOutputCallback", () => {
    it("returns an unregister function", () => {
      const callback = vi.fn();
      const unregister = registerOutputCallback(callback);
      expect(typeof unregister).toBe("function");
    });

    it("unregister function does not throw", () => {
      const callback = vi.fn();
      const unregister = registerOutputCallback(callback);
      expect(() => unregister()).not.toThrow();
    });

    it("can register multiple callbacks", () => {
      const callback1 = vi.fn();
      const callback2 = vi.fn();
      const unregister1 = registerOutputCallback(callback1);
      const unregister2 = registerOutputCallback(callback2);
      expect(typeof unregister1).toBe("function");
      expect(typeof unregister2).toBe("function");
    });
  });

  // These tests rely on the singleton PTY created by handleTerminalInput tests above.
  // The PTY is created once (on first handleTerminalInput call) and the mock captures
  // onData/onExit callbacks at that point.
  describe("PTY output forwarding", () => {
    it("forwards PTY output to global callback via onData", () => {
      // The PTY was already created by prior tests. onDataCallback should be set.
      // If no prior test created it, create it now.
      if (!onDataCallback) {
        handleTerminalInput("init");
      }
      expect(onDataCallback).not.toBeNull();

      const globalCallback = vi.fn();
      setTerminalOutputCallback(globalCallback);

      onDataCallback!("hello world");
      expect(globalCallback).toHaveBeenCalledWith("hello world");
    });

    it("forwards PTY output to registered callbacks via onData", () => {
      if (!onDataCallback) {
        handleTerminalInput("init");
      }
      expect(onDataCallback).not.toBeNull();

      const registeredCallback = vi.fn();
      registerOutputCallback(registeredCallback);

      onDataCallback!("hello world");
      expect(registeredCallback).toHaveBeenCalledWith("hello world");
    });
  });

  describe("PTY exit notification", () => {
    it("sends OSC 9999 exit marker to global callback on PTY exit", () => {
      // PTY should exist from prior tests
      if (!onExitCallback) {
        handleTerminalInput("init");
      }
      expect(onExitCallback).not.toBeNull();

      const globalCallback = vi.fn();
      setTerminalOutputCallback(globalCallback);

      onExitCallback!({ exitCode: 0, signal: 0 });

      expect(globalCallback).toHaveBeenCalledWith(
        expect.stringContaining("\x1b]9999;pty-exit;0\x07")
      );
    });

    it("sends exit marker to registered callbacks and respawns on next input", () => {
      // After the previous test triggered onExit, the PTY is null.
      // Register a callback, then trigger input to create a new PTY.
      const registeredCallback = vi.fn();
      registerOutputCallback(registeredCallback);

      // This creates a new PTY (previous one was nulled by onExit)
      handleTerminalInput("test");
      expect(onExitCallback).not.toBeNull();

      onExitCallback!({ exitCode: 1, signal: 0 });

      expect(registeredCallback).toHaveBeenCalledWith(
        expect.stringContaining("\x1b]9999;pty-exit;1\x07")
      );
    });

    it("includes exit code in the marker", () => {
      const globalCallback = vi.fn();
      setTerminalOutputCallback(globalCallback);

      // Respawn PTY after previous test's exit
      handleTerminalInput("test");
      expect(onExitCallback).not.toBeNull();

      onExitCallback!({ exitCode: 130, signal: 0 });

      expect(globalCallback).toHaveBeenCalledWith(
        expect.stringContaining("\x1b]9999;pty-exit;130\x07")
      );
    });
  });
});
