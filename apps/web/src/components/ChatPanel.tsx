import { useState, useRef, useEffect } from "react";
import type { AgentEvent } from "@netclode/protocol";
import type { ChatMessage } from "../stores/sessionStore";
import styles from "./ChatPanel.module.css";

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
  const messagesEndRef = useRef<HTMLDivElement>(null);

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
              Activity
            </span>
            {events.slice(-5).map((event, i) => (
              <div key={i} className={styles.event}>
                <span className={styles.eventKind}>{event.kind}</span>
                {"tool" in event && (
                  <span className={styles.eventTool}>{event.tool}</span>
                )}
              </div>
            ))}
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
