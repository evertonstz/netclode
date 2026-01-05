export type SessionStatus =
  | "creating"
  | "ready"
  | "running"
  | "paused"
  | "error";

export interface Session {
  id: string;
  name: string;
  status: SessionStatus;
  repo?: string;
  createdAt: string;
  lastActiveAt: string;
}

export interface SessionCreateRequest {
  name?: string;
  repo?: string;
}

export interface SessionListResponse {
  sessions: Session[];
}
