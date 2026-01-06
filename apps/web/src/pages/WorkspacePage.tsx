import { useParams, useLocation } from "wouter";
import { useState, useEffect, useCallback, useRef } from "react";
import {
  AppShell,
  Group,
  Button,
  Text,
  Badge,
  Box,
  Grid,
} from "@mantine/core";
import {
  useWebSocket,
  useWebSocketMessages,
} from "../contexts/WebSocketContext";
import { ChatPanel, ChatMessage } from "../components/ChatPanel";
import { Terminal } from "../components/Terminal";
import { ThemeToggle } from "../components/ThemeToggle";
import type { ServerMessage, Session, AgentEvent } from "@netclode/protocol";

export function WorkspacePage() {
  const params = useParams<{ id: string }>();
  const id = params.id;
  const [, navigate] = useLocation();
  const [isProcessing, setIsProcessing] = useState(false);
  const lastOpenedIdRef = useRef<string | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const { send, connected } = useWebSocket();

  const handleMessage = useCallback(
    (msg: ServerMessage) => {
      switch (msg.type) {
        case "session.updated":
          if (msg.session.id === id) {
            setSession(msg.session);
          }
          break;
        case "session.state":
          if (msg.session.id === id) {
            setSession(msg.session);
            setMessages(
              msg.messages.map((m) => ({ role: m.role, content: m.content }))
            );
            setEvents(msg.events.map((e) => e.event));
          }
          break;
        case "agent.message":
          if (msg.sessionId === id) {
            if (msg.partial) {
              setMessages((prev) => {
                const last = prev[prev.length - 1];
                if (last?.role === "assistant") {
                  return [
                    ...prev.slice(0, -1),
                    { ...last, content: last.content + msg.content },
                  ];
                }
                return [...prev, { role: "assistant", content: msg.content }];
              });
            } else {
              setMessages((prev) => [
                ...prev,
                { role: "assistant", content: msg.content },
              ]);
            }
          }
          break;
        case "agent.event":
          if (msg.sessionId === id) {
            setEvents((prev) => [...prev, msg.event]);
          }
          break;
        case "agent.done":
          if (msg.sessionId === id) {
            setIsProcessing(false);
          }
          break;
        case "agent.error":
          if (msg.sessionId === id) {
            setMessages((prev) => [
              ...prev,
              { role: "assistant", content: `Error: ${msg.error}` },
            ]);
            setIsProcessing(false);
          }
          break;
      }
    },
    [id]
  );

  useWebSocketMessages(handleMessage);

  useEffect(() => {
    if (connected && id && lastOpenedIdRef.current !== id) {
      lastOpenedIdRef.current = id;
      setMessages([]);
      setEvents([]);
      send({ type: "session.open", id });
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

  const getStatusText = () => {
    if (!connected) return "Disconnected";
    if (isProcessing) return "Processing";
    return session?.status || "Connecting";
  };

  const getStatusColor = () => {
    if (!connected) return "gray";
    if (isProcessing) return "yellow";
    if (session?.status === "running") return "green";
    if (session?.status === "error") return "red";
    return "blue";
  };

  return (
    <AppShell header={{ height: 60 }} padding={0}>
      <AppShell.Header>
        <Group h="100%" px="md" justify="space-between">
          <Group>
            <Button variant="subtle" onClick={() => navigate("/")}>
              ←
            </Button>
            <Box>
              <Text fw={500}>{session?.name || "Session"}</Text>
              <Text size="xs" c="dimmed">
                {id?.slice(0, 8)}
              </Text>
            </Box>
          </Group>
          <Group>
            <Badge color={getStatusColor()} variant="light">
              {getStatusText()}
            </Badge>
            <ThemeToggle />
          </Group>
        </Group>
      </AppShell.Header>

      <AppShell.Main h="calc(100vh - 60px)">
        <Grid h="100%" gutter={0}>
          <Grid.Col span={6} h="100%">
            <Box h="100%" style={{ borderRight: "1px solid var(--mantine-color-default-border)" }}>
              <ChatPanel
                messages={messages}
                events={events}
                onSend={handleSendPrompt}
                onInterrupt={handleInterrupt}
                disabled={!connected || session?.status !== "running"}
                isProcessing={isProcessing}
              />
            </Box>
          </Grid.Col>
          <Grid.Col span={6} h="100%">
            <Terminal onInput={handleTerminalInput} />
          </Grid.Col>
        </Grid>
      </AppShell.Main>
    </AppShell>
  );
}
