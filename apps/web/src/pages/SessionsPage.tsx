import { useEffect, useCallback, useState } from "react";
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
  const { sessions, setSessions, addSession, updateSession, removeSession } = useSessionStore();
  const { send, connected } = useWebSocket();
  const [creating, setCreating] = useState(false);

  const handleMessage = useCallback(
    (msg: ServerMessage) => {
      if (msg.type === "session.list") {
        setSessions(msg.sessions);
      } else if (msg.type === "session.created") {
        setCreating(false);
        addSession(msg.session);
        navigate(`/session/${msg.session.id}`);
      } else if (msg.type === "session.updated") {
        updateSession(msg.session);
      } else if (msg.type === "session.deleted") {
        removeSession(msg.id);
      } else if (msg.type === "session.error") {
        setCreating(false);
      }
    },
    [setSessions, addSession, updateSession, removeSession, navigate]
  );

  useWebSocketMessages(handleMessage);

  useEffect(() => {
    if (connected) {
      send({ type: "session.list" });
    }
  }, [connected, send]);

  useEffect(() => {
    if (!connected) {
      setCreating(false);
    }
  }, [connected]);

  const handleCreateSession = () => {
    if (!connected || creating) return;
    setCreating(true);
    send({ type: "session.create" });
  };

  const handleDeleteSession = (id: string) => {
    if (!connected) return;
    send({ type: "session.delete", id });
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
          onDelete={handleDeleteSession}
        />
        <button
          className={styles.createButton}
          onClick={handleCreateSession}
          disabled={!connected || creating}
        >
          {creating ? "Creating..." : "+ New Session"}
        </button>
      </main>
    </div>
  );
}
