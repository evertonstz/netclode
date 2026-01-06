import type { Session } from "@netclode/protocol";
import styles from "./SessionList.module.css";

interface SessionListProps {
  sessions: Session[];
  onSelect: (id: string) => void;
  onDelete: (id: string) => void;
}

const STATUS_ICONS: Record<string, string> = {
  running: "▶️",
  ready: "✓",
  paused: "⏸",
  error: "⚠",
  creating: "⏳",
};

export function SessionList({ sessions, onSelect, onDelete }: SessionListProps) {
  if (sessions.length === 0) {
    return (
      <div className={styles.empty}>
        <span className={styles.emptyIcon}>📋</span>
        <p>No sessions yet. Create one to get started.</p>
      </div>
    );
  }

  return (
    <div className={styles.list}>
      {sessions.map((session) => (
        <div key={session.id} className={styles.item}>
          <button
            className={styles.selectButton}
            onClick={() => onSelect(session.id)}
          >
            <div className={styles.statusIcon} data-status={session.status}>
              {STATUS_ICONS[session.status] || "○"}
            </div>
            <div className={styles.info}>
              <span className={styles.name}>{session.name}</span>
              <span className={styles.meta}>
                <span className={styles.status} data-status={session.status}>
                  {session.status}
                </span>
                <span>·</span>
                <span>{formatTime(session.lastActiveAt)}</span>
              </span>
            </div>
            <span className={styles.chevron}>›</span>
          </button>
          <button
            className={styles.deleteButton}
            onClick={(e) => {
              e.stopPropagation();
              onDelete(session.id);
            }}
            title="Delete session"
          >
            🗑
          </button>
        </div>
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
