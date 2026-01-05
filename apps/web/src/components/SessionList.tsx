import type { Session } from "@netclode/protocol";
import styles from "./SessionList.module.css";

interface SessionListProps {
  sessions: Session[];
  onSelect: (id: string) => void;
}

export function SessionList({ sessions, onSelect }: SessionListProps) {
  if (sessions.length === 0) {
    return (
      <div className={styles.empty}>
        <p>No sessions yet. Create one to get started.</p>
      </div>
    );
  }

  return (
    <div className={styles.list}>
      {sessions.map((session) => (
        <button
          key={session.id}
          className={styles.item}
          onClick={() => onSelect(session.id)}
        >
          <div className={styles.info}>
            <span className={styles.name}>{session.name}</span>
            <span className={styles.meta}>
              {session.status} · {formatTime(session.lastActiveAt)}
            </span>
          </div>
          <span className={styles.status} data-status={session.status}>
            {session.status === "running" ? "●" : "○"}
          </span>
        </button>
      ))}
    </div>
  );
}

function formatTime(iso: string): string {
  const date = new Date(iso);
  const now = new Date();
  const diff = now.getTime() - date.getTime();

  if (diff < 60000) return "just now";
  if (diff < 3600000) return `${Math.floor(diff / 60000)} min ago`;
  if (diff < 86400000) return `${Math.floor(diff / 3600000)} hours ago`;
  return date.toLocaleDateString();
}
