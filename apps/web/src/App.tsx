import { Route, Switch } from "wouter";
import { WebSocketProvider } from "./contexts/WebSocketContext";
import { SessionsPage } from "./pages/SessionsPage";
import { WorkspacePage } from "./pages/WorkspacePage";

export function App() {
  return (
    <WebSocketProvider>
      <Switch>
        <Route path="/" component={SessionsPage} />
        <Route path="/session/:id" component={WorkspacePage} />
      </Switch>
    </WebSocketProvider>
  );
}
