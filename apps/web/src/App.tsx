import { BrowserRouter, Routes, Route } from "react-router-dom";
import { WebSocketProvider } from "./contexts/WebSocketContext";
import { SessionsPage } from "./pages/SessionsPage";
import { WorkspacePage } from "./pages/WorkspacePage";

export function App() {
  return (
    <WebSocketProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/" element={<SessionsPage />} />
          <Route path="/session/:id" element={<WorkspacePage />} />
        </Routes>
      </BrowserRouter>
    </WebSocketProvider>
  );
}
