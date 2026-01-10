# Netclode Web

React web client for Netclode.

## Stack

- React 19
- Mantine 8
- Vite 7
- xterm.js
- wouter

## Development

```bash
npm install
npm run dev
```

Runs at `http://localhost:5173`.

## Production

```bash
npm run build
```

Output in `dist/`.

## Architecture

```
src/
├── main.tsx
├── App.tsx
├── components/
│   ├── Chat/
│   ├── Terminal/
│   ├── Sessions/
│   └── Layout/
├── hooks/
│   ├── useWebSocket.ts
│   ├── useSession.ts
│   └── useTerminal.ts
├── stores/
├── types/
│   └── protocol.ts
└── styles/
```

## WebSocket

Same protocol as the iOS app. Connect to `ws://netclode/ws`.

```typescript
const ws = new WebSocket('ws://netclode/ws');

ws.send(JSON.stringify({ type: 'session.list' }));

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  switch (msg.type) {
    case 'session.list':
      setSessions(msg.sessions);
      break;
    case 'agent.message':
      appendMessage(msg.sessionId, msg.content, msg.partial);
      break;
  }
};
```

## Terminal

Uses xterm.js with WebGL renderer:

```typescript
import { Terminal } from '@xterm/xterm';
import { WebglAddon } from '@xterm/addon-webgl';

const terminal = new Terminal();
terminal.loadAddon(new WebglAddon());
```

I/O is proxied through the control plane WebSocket via `terminal.input` and `terminal.output` messages. The actual PTY runs inside the agent VM (node-pty), and the control plane bridges the WebSocket connections.

```
xterm.js ──► WebSocket ──► Control Plane ──► Agent PTY
```

## Deployment

Built by CI, served by nginx in k8s. Static files at `/usr/share/nginx/html`, API proxied to control-plane.

## License

MIT
