import { useEffect, useRef } from "react";
import { Box } from "@mantine/core";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";

interface TerminalProps {
  onInput: (data: string) => void;
  output?: string;
}

export function Terminal({ onInput, output }: TerminalProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const terminalRef = useRef<XTerm | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);

  useEffect(() => {
    if (!containerRef.current) return;

    const terminal = new XTerm({
      theme: {
        background: "#0a0a0a",
        foreground: "#e5e5e5",
        cursor: "#e5e5e5",
        cursorAccent: "#0a0a0a",
        selectionBackground: "#3b3b3b",
      },
      fontFamily: '"SF Mono", "Fira Code", "Cascadia Code", monospace',
      fontSize: 13,
      lineHeight: 1.2,
      cursorBlink: true,
    });

    const fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);

    terminal.open(containerRef.current);
    fitAddon.fit();

    terminal.onData((data) => {
      onInput(data);
    });

    terminalRef.current = terminal;
    fitAddonRef.current = fitAddon;

    const resizeObserver = new ResizeObserver(() => {
      fitAddon.fit();
    });
    resizeObserver.observe(containerRef.current);

    return () => {
      resizeObserver.disconnect();
      terminal.dispose();
    };
  }, [onInput]);

  useEffect(() => {
    if (output && terminalRef.current) {
      terminalRef.current.write(output);
    }
  }, [output]);

  return (
    <Box
      ref={containerRef}
      h="100%"
      bg="dark.9"
      style={{ overflow: "hidden" }}
    />
  );
}
