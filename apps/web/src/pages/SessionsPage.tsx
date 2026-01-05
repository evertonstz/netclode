import { useEffect, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { useSessionStore } from "../stores/sessionStore";
import { SessionList } from "../components/SessionList";
import {
  useWebSocket,
  useWebSocketMessages,
} from "../contexts/WebSocketContext";
import type { ServerMessage } from "@netclode/protocol";
import styles from "./SessionsPage.module.css";

export function SessionsPage() {
  const navigate = useNavigate();
  const { sessions, setSessions, addSession } = useSessionStore();
  const { send, connected } = useWebSocket();

  const handleMessage = useCallback(
    (msg: ServerMessage) => {
      if (msg.type === "session.list") {
        setSessions(msg.sessions);
      } else if (msg.type === "session.created") {
        addSession(msg.session);
        navigate(`/session/${msg.session.id}`);
      }
    },
    [setSessions, addSession, navigate]
  );

  useWebSocketMessages(handleMessage);

  useEffect(() => {
    if (connected) {
      send({ type: "session.list" });
    }
  }, [connected, send]);

  const handleCreateSession = () => {
    send({ type: "session.create" });
  };

  return (
    <div className={styles.container}>
      <header className={styles.header}>
        <h1>Netclode</h1>
        <span className={styles.status} data-connected={connected}>
          {connected ? "● Connected" : "○ Disconnected"}
        </span>
      </header>
      <main className={styles.main}>
        <SessionList
          sessions={sessions}
          onSelect={(id) => navigate(`/session/${id}`)}
        />
        <button
          className={styles.createButton}
          onClick={handleCreateSession}
          disabled={!connected}
        >
          + New Session
        </button>
      </main>
    </div>
  );
}
