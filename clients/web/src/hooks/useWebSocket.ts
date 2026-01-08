import { useEffect, useRef, useState, useCallback } from "react";
import type { ClientMessage, ServerMessage } from "@netclode/protocol";

interface UseWebSocketOptions {
  onMessage?: (message: ServerMessage) => void;
  url?: string;
}

export function useWebSocket(options: UseWebSocketOptions = {}) {
  const { url = `ws://${window.location.host}/ws` } = options;
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const reconnectTimeoutRef = useRef<number | null>(null);
  const onMessageRef = useRef(options.onMessage);

  // Update ref when onMessage changes (avoids recreating WebSocket)
  useEffect(() => {
    onMessageRef.current = options.onMessage;
  }, [options.onMessage]);

  useEffect(() => {
    let isMounted = true;

    function connect() {
      if (wsRef.current?.readyState === WebSocket.OPEN) return;
      if (wsRef.current?.readyState === WebSocket.CONNECTING) return;

      // Close any existing connection
      if (wsRef.current) {
        wsRef.current.close();
      }

      const ws = new WebSocket(url);

      ws.onopen = () => {
        if (isMounted) {
          setConnected(true);
          console.log("WebSocket connected");
        }
      };

      ws.onclose = () => {
        if (isMounted) {
          setConnected(false);
          console.log("WebSocket disconnected, reconnecting in 2s...");
          reconnectTimeoutRef.current = window.setTimeout(connect, 2000);
        }
      };

      ws.onerror = (error) => {
        console.error("WebSocket error:", error);
      };

      ws.onmessage = (event) => {
        try {
          const message = JSON.parse(event.data) as ServerMessage;
          onMessageRef.current?.(message);
        } catch (error) {
          console.error("Failed to parse WebSocket message:", error);
        }
      };

      wsRef.current = ws;
    }

    connect();

    return () => {
      isMounted = false;
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current);
      }
      if (wsRef.current) {
        wsRef.current.close();
        wsRef.current = null;
      }
    };
  }, [url]);

  const send = useCallback((message: ClientMessage) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(message));
    } else {
      console.warn("WebSocket not connected, message not sent");
    }
  }, []);

  return { connected, send };
}
