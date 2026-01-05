import { useParams, useNavigate } from "react-router-dom";
import { useState, useEffect, useCallback } from "react";
import {
  useWebSocket,
  useWebSocketMessages,
} from "../contexts/WebSocketContext";
import { useSessionStore } from "../stores/sessionStore";
import { ChatPanel } from "../components/ChatPanel";
import { Terminal } from "../components/Terminal";
import type { AgentEvent, Session, ServerMessage } from "@netclode/protocol";
import styles from "./WorkspacePage.module.css";

interface Message {
  role: "user" | "assistant";
  content: string;
}

export function WorkspacePage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [messages, setMessages] = useState<Message[]>([]);
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const [isProcessing, setIsProcessing] = useState(false);
  const [session, setSession] = useState<Session | null>(null);
  const { updateSession } = useSessionStore();
  const { send, connected } = useWebSocket();

  const handleMessage = useCallback(
    (msg: ServerMessage) => {
      switch (msg.type) {
        case "session.updated":
          setSession(msg.session);
          updateSession(msg.session);
          break;
        case "agent.message":
          if ("sessionId" in msg && msg.sessionId === id) {
            const isPartial = (msg as any).partial;
            if (isPartial) {
              // Update last message if it's from assistant, or append
              setMessages((prev) => {
                const last = prev[prev.length - 1];
                if (last?.role === "assistant") {
                  return [...prev.slice(0, -1), { ...last, content: last.content + msg.content }];
                }
                return [...prev, { role: "assistant", content: msg.content }];
              });
            } else {
              // Complete message
              setMessages((prev) => [
                ...prev,
                { role: "assistant", content: msg.content },
              ]);
            }
          }
          break;
        case "agent.event":
          if ("sessionId" in msg && msg.sessionId === id) {
            setEvents((prev) => [...prev, msg.event]);
          }
          break;
        case "agent.done":
          if ("sessionId" in msg && msg.sessionId === id) {
            setIsProcessing(false);
          }
          break;
        case "agent.error":
          if ("sessionId" in msg && msg.sessionId === id) {
            setMessages((prev) => [
              ...prev,
              { role: "assistant", content: `Error: ${msg.error}` },
            ]);
            setIsProcessing(false);
          }
          break;
      }
    },
    [id, updateSession]
  );

  useWebSocketMessages(handleMessage);

  // Resume session when entering workspace
  useEffect(() => {
    if (connected && id) {
      send({ type: "session.resume", id });
    }
  }, [connected, id, send]);

  const handleSendPrompt = (text: string) => {
    if (!id) return;
    setMessages((prev) => [...prev, { role: "user", content: text }]);
    setIsProcessing(true);
    setEvents([]);
    send({ type: "prompt", sessionId: id, text });
  };

  const handleInterrupt = () => {
    if (!id) return;
    send({ type: "prompt.interrupt", sessionId: id });
  };

  const handleTerminalInput = (data: string) => {
    if (!id) return;
    send({ type: "terminal.input", sessionId: id, data });
  };

  return (
    <div className={styles.container}>
      <header className={styles.header}>
        <button className={styles.backButton} onClick={() => navigate("/")}>
          ← Back
        </button>
        <span className={styles.sessionId}>
          {session?.name || `Session ${id?.slice(0, 8)}`}
        </span>
        <span className={styles.status} data-status={session?.status}>
          {connected
            ? isProcessing
              ? "Processing..."
              : session?.status || "Connecting..."
            : "Disconnected"}
        </span>
      </header>
      <main className={styles.main}>
        <div className={styles.chatSection}>
          <ChatPanel
            messages={messages}
            events={events}
            onSend={handleSendPrompt}
            onInterrupt={handleInterrupt}
            disabled={!connected || session?.status !== "running"}
            isProcessing={isProcessing}
          />
        </div>
        <div className={styles.terminalSection}>
          <Terminal onInput={handleTerminalInput} />
        </div>
      </main>
    </div>
  );
}
