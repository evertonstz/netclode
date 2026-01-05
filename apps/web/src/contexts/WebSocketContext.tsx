import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  useCallback,
  type ReactNode,
} from "react";
import type { ClientMessage, ServerMessage } from "@netclode/protocol";

interface WebSocketContextValue {
  connected: boolean;
  send: (message: ClientMessage) => void;
  subscribe: (callback: (message: ServerMessage) => void) => () => void;
}

const WebSocketContext = createContext<WebSocketContextValue | null>(null);

export function WebSocketProvider({ children }: { children: ReactNode }) {
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const reconnectTimeoutRef = useRef<number | null>(null);
  const subscribersRef = useRef<Set<(message: ServerMessage) => void>>(
    new Set()
  );

  useEffect(() => {
    let isMounted = true;

    function connect() {
      if (!isMounted) return;
      if (wsRef.current?.readyState === WebSocket.OPEN) return;
      if (wsRef.current?.readyState === WebSocket.CONNECTING) return;

      const url = `ws://${window.location.host}/ws`;
      console.log("Connecting to", url);

      const ws = new WebSocket(url);

      ws.onopen = () => {
        if (isMounted) {
          console.log("WebSocket connected");
          setConnected(true);
        }
      };

      ws.onclose = (e) => {
        if (isMounted) {
          console.log("WebSocket closed:", e.code, e.reason);
          setConnected(false);
          wsRef.current = null;
          // Reconnect after delay
          reconnectTimeoutRef.current = window.setTimeout(connect, 2000);
        }
      };

      ws.onerror = () => {
        // Error will trigger close
      };

      ws.onmessage = (event) => {
        try {
          const message = JSON.parse(event.data) as ServerMessage;
          for (const callback of subscribersRef.current) {
            callback(message);
          }
        } catch (error) {
          console.error("Failed to parse message:", error);
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
  }, []);

  const send = useCallback((message: ClientMessage) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(message));
    } else {
      console.warn("WebSocket not connected");
    }
  }, []);

  const subscribe = useCallback(
    (callback: (message: ServerMessage) => void) => {
      subscribersRef.current.add(callback);
      return () => {
        subscribersRef.current.delete(callback);
      };
    },
    []
  );

  return (
    <WebSocketContext.Provider value={{ connected, send, subscribe }}>
      {children}
    </WebSocketContext.Provider>
  );
}

export function useWebSocket() {
  const context = useContext(WebSocketContext);
  if (!context) {
    throw new Error("useWebSocket must be used within WebSocketProvider");
  }
  return context;
}

export function useWebSocketMessages(
  callback: (message: ServerMessage) => void
) {
  const { subscribe } = useWebSocket();

  useEffect(() => {
    return subscribe(callback);
  }, [subscribe, callback]);
}
