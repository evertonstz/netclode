import { useState, useRef, useEffect } from "react";
import type { AgentEvent } from "@netclode/protocol";
import type { ChatMessage } from "../stores/sessionStore";
import styles from "./ChatPanel.module.css";

function EventDetails({ event }: { event: AgentEvent }) {
  switch (event.kind) {
    case "tool_start":
      return (
        <div className={styles.eventDetails}>
          <div className={styles.eventDetailRow}>
            <span className={styles.eventDetailLabel}>Input:</span>
            <pre className={styles.eventDetailCode}>
              {JSON.stringify(event.input, null, 2)}
            </pre>
          </div>
        </div>
      );
    case "tool_end":
      return (
        <div className={styles.eventDetails}>
          {event.result && (
            <div className={styles.eventDetailRow}>
              <span className={styles.eventDetailLabel}>Result:</span>
              <pre className={styles.eventDetailCode}>{event.result}</pre>
            </div>
          )}
          {event.error && (
            <div className={styles.eventDetailRow}>
              <span className={styles.eventDetailLabel}>Error:</span>
              <pre className={styles.eventDetailError}>{event.error}</pre>
            </div>
          )}
        </div>
      );
    case "file_change":
      return (
        <div className={styles.eventDetails}>
          <div className={styles.eventDetailRow}>
            <span className={styles.eventDetailLabel}>Path:</span>
            <code className={styles.eventDetailPath}>{event.path}</code>
          </div>
          <div className={styles.eventDetailRow}>
            <span className={styles.eventDetailLabel}>Action:</span>
            <span className={styles.eventDetailValue}>{event.action}</span>
          </div>
          {(event.linesAdded !== undefined || event.linesRemoved !== undefined) && (
            <div className={styles.eventDetailRow}>
              <span className={styles.eventDetailLabel}>Changes:</span>
              <span className={styles.eventDetailValue}>
                {event.linesAdded !== undefined && <span className={styles.linesAdded}>+{event.linesAdded}</span>}
                {event.linesRemoved !== undefined && <span className={styles.linesRemoved}>-{event.linesRemoved}</span>}
              </span>
            </div>
          )}
        </div>
      );
    case "command_start":
      return (
        <div className={styles.eventDetails}>
          <div className={styles.eventDetailRow}>
            <span className={styles.eventDetailLabel}>Command:</span>
            <pre className={styles.eventDetailCode}>{event.command}</pre>
          </div>
          {event.cwd && (
            <div className={styles.eventDetailRow}>
              <span className={styles.eventDetailLabel}>CWD:</span>
              <code className={styles.eventDetailPath}>{event.cwd}</code>
            </div>
          )}
        </div>
      );
    case "command_end":
      return (
        <div className={styles.eventDetails}>
          <div className={styles.eventDetailRow}>
            <span className={styles.eventDetailLabel}>Exit code:</span>
            <span className={event.exitCode === 0 ? styles.exitSuccess : styles.exitError}>
              {event.exitCode}
            </span>
          </div>
          {event.output && (
            <div className={styles.eventDetailRow}>
              <span className={styles.eventDetailLabel}>Output:</span>
              <pre className={styles.eventDetailCode}>{event.output}</pre>
            </div>
          )}
        </div>
      );
    case "thinking":
      return (
        <div className={styles.eventDetails}>
          <div className={styles.eventDetailRow}>
            <pre className={styles.eventDetailThinking}>{event.content}</pre>
          </div>
        </div>
      );
    case "port_detected":
      return (
        <div className={styles.eventDetails}>
          <div className={styles.eventDetailRow}>
            <span className={styles.eventDetailLabel}>Port:</span>
            <span className={styles.eventDetailValue}>{event.port}</span>
          </div>
          {event.process && (
            <div className={styles.eventDetailRow}>
              <span className={styles.eventDetailLabel}>Process:</span>
              <span className={styles.eventDetailValue}>{event.process}</span>
            </div>
          )}
          {event.previewUrl && (
            <div className={styles.eventDetailRow}>
              <span className={styles.eventDetailLabel}>Preview:</span>
              <a href={event.previewUrl} target="_blank" rel="noopener noreferrer" className={styles.eventDetailLink}>
                {event.previewUrl}
              </a>
            </div>
          )}
        </div>
      );
    default:
      return null;
  }
}

function getEventIcon(kind: AgentEvent["kind"]): string {
  switch (kind) {
    case "tool_start": return "🔧";
    case "tool_end": return "✓";
    case "file_change": return "📄";
    case "command_start": return "▶";
    case "command_end": return "■";
    case "thinking": return "💭";
    case "port_detected": return "🌐";
    default: return "•";
  }
}

function getEventSummary(event: AgentEvent): string {
  switch (event.kind) {
    case "tool_start":
      return event.tool;
    case "tool_end":
      return `${event.tool}${event.error ? " (error)" : ""}`;
    case "file_change":
      return `${event.action} ${event.path.split("/").pop()}`;
    case "command_start":
      return event.command.slice(0, 40) + (event.command.length > 40 ? "..." : "");
    case "command_end":
      return `exit ${event.exitCode}`;
    case "thinking":
      return event.content.slice(0, 40) + (event.content.length > 40 ? "..." : "");
    case "port_detected":
      return `Port ${event.port}`;
    default:
      return "";
  }
}

interface ChatPanelProps {
  messages: ChatMessage[];
  events: AgentEvent[];
  onSend: (text: string) => void;
  onInterrupt?: () => void;
  disabled?: boolean;
  isProcessing?: boolean;
}

export function ChatPanel({
  messages,
  events,
  onSend,
  onInterrupt,
  disabled,
  isProcessing,
}: ChatPanelProps) {
  const [input, setInput] = useState("");
  const [expandedEvents, setExpandedEvents] = useState<Set<number>>(new Set());
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const toggleEvent = (index: number) => {
    setExpandedEvents((prev) => {
      const next = new Set(prev);
      if (next.has(index)) {
        next.delete(index);
      } else {
        next.add(index);
      }
      return next;
    });
  };

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, events]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (input.trim() && !disabled && !isProcessing) {
      onSend(input.trim());
      setInput("");
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit(e);
    }
  };

  return (
    <div className={styles.container}>
      <div className={styles.messages}>
        {messages.length === 0 && (
          <div className={styles.empty}>
            <span className={styles.emptyIcon}>💬</span>
            <p>Ask Claude anything...</p>
          </div>
        )}
        {messages.map((msg, i) => (
          <div key={i} className={styles.messageRow} data-role={msg.role}>
            <div className={styles.avatar} data-role={msg.role}>
              {msg.role === "user" ? "👤" : "🧠"}
            </div>
            <div className={styles.messageContent}>
              <span className={styles.role}>
                {msg.role === "user" ? "You" : "Claude"}
              </span>
              <div className={styles.message}>
                <div className={styles.content}>{msg.content}</div>
              </div>
            </div>
          </div>
        ))}
        {events.length > 0 && (
          <div className={styles.events}>
            <span className={styles.eventsLabel}>
              <span className={styles.eventsIcon}>⚡</span>
              Activity ({events.length})
            </span>
            {events.map((event, i) => {
              const isExpanded = expandedEvents.has(i);
              return (
                <div key={i} className={styles.eventCard}>
                  <div
                    className={styles.eventHeader}
                    onClick={() => toggleEvent(i)}
                    role="button"
                    tabIndex={0}
                    onKeyDown={(e) => e.key === "Enter" && toggleEvent(i)}
                  >
                    <span className={styles.eventIcon}>{getEventIcon(event.kind)}</span>
                    <span className={styles.eventKind}>{event.kind}</span>
                    <span className={styles.eventSummary}>{getEventSummary(event)}</span>
                    <span className={styles.eventExpand}>{isExpanded ? "▼" : "▶"}</span>
                  </div>
                  {isExpanded && <EventDetails event={event} />}
                </div>
              );
            })}
          </div>
        )}
        {isProcessing && (
          <div className={styles.thinking}>
            <div className={styles.avatar} data-role="assistant">🧠</div>
            <div className={styles.thinkingBubble}>
              <span className={styles.dot}></span>
              <span className={styles.dot}></span>
              <span className={styles.dot}></span>
            </div>
          </div>
        )}
        <div ref={messagesEndRef} />
      </div>
      <form className={styles.inputForm} onSubmit={handleSubmit}>
        <textarea
          className={styles.input}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={disabled ? "Session not ready..." : "Ask Claude..."}
          disabled={disabled}
          rows={1}
        />
        {isProcessing ? (
          <button
            type="button"
            className={styles.interruptButton}
            onClick={onInterrupt}
            title="Stop"
          >
            ■
          </button>
        ) : (
          <button
            type="submit"
            className={styles.sendButton}
            disabled={disabled || !input.trim()}
            title="Send"
          >
            ↑
          </button>
        )}
      </form>
    </div>
  );
}
