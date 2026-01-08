import {
  Card,
  Group,
  Text,
  Badge,
  ActionIcon,
  Stack,
  Box,
} from "@mantine/core";
import type { Session } from "@netclode/protocol";

interface SessionListProps {
  sessions: Session[];
  onSelect: (id: string) => void;
  onDelete: (id: string) => void;
}

const STATUS_COLORS: Record<string, string> = {
  running: "green",
  ready: "blue",
  paused: "yellow",
  error: "red",
  creating: "gray",
};

export function SessionList({
  sessions,
  onSelect,
  onDelete,
}: SessionListProps) {
  if (sessions.length === 0) {
    return (
      <Card withBorder p="xl" ta="center">
        <Text size="xl" mb="xs">
          📋
        </Text>
        <Text c="dimmed">No sessions yet. Create one to get started.</Text>
      </Card>
    );
  }

  return (
    <Stack gap="sm">
      {sessions.map((session) => (
        <Card
          key={session.id}
          withBorder
          padding="md"
          style={{ cursor: "pointer" }}
          onClick={() => onSelect(session.id)}
        >
          <Group justify="space-between" wrap="nowrap">
            <Box style={{ flex: 1, minWidth: 0 }}>
              <Group gap="sm" mb={4}>
                <Text fw={500} truncate>
                  {session.name}
                </Text>
                <Badge
                  color={STATUS_COLORS[session.status] || "gray"}
                  size="sm"
                  variant="light"
                >
                  {session.status}
                </Badge>
              </Group>
              <Text size="xs" c="dimmed">
                {formatTime(session.lastActiveAt)}
              </Text>
            </Box>
            <Group gap="xs">
              <ActionIcon
                variant="subtle"
                color="red"
                onClick={(e) => {
                  e.stopPropagation();
                  onDelete(session.id);
                }}
                title="Delete session"
              >
                🗑
              </ActionIcon>
              <Text c="dimmed">›</Text>
            </Group>
          </Group>
        </Card>
      ))}
    </Stack>
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
