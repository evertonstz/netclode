import { BrowserRouter, Routes, Route } from "react-router-dom";
import { WebSocketProvider } from "./contexts/WebSocketContext";
import { ThemeProvider } from "./contexts/ThemeContext";
import { SessionsPage } from "./pages/SessionsPage";
import { WorkspacePage } from "./pages/WorkspacePage";

export function App() {
  return (
    <ThemeProvider>
      <WebSocketProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/" element={<SessionsPage />} />
            <Route path="/session/:id" element={<WorkspacePage />} />
          </Routes>
        </BrowserRouter>
      </WebSocketProvider>
    </ThemeProvider>
  );
}
