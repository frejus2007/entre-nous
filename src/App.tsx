import { Navigate, Route, Routes } from 'react-router-dom'
import { useAuth } from './context/AuthContext'
import { isSupabaseConfigured } from './lib/supabase'
import { Spinner } from './components/feedback'
import { SetupRequired } from './pages/SetupRequired'
import { AuthPage } from './pages/Auth'
import { HomePage } from './pages/Home'
import { DuoRoomPage } from './pages/DuoRoom'
import { SessionPage } from './pages/Session'
import { ChatPage } from './pages/Chat'
import { PrivacyPage } from './pages/Privacy'
import { InstallPage } from './pages/Install'
import { GameEntryPage } from './pages/GameEntry'

export function App() {
  const { session, loading } = useAuth()

  if (!isSupabaseConfigured) {
    return <SetupRequired />
  }

  if (loading) {
    return (
      <main className="container">
        <Spinner label="Chargement…" />
      </main>
    )
  }

  if (!session) {
    return <AuthPage />
  }

  return (
    <Routes>
      <Route path="/" element={<HomePage />} />
      <Route path="/duo/:duoId" element={<DuoRoomPage />} />
      <Route path="/session/:sessionId" element={<SessionPage />} />
      <Route path="/jeu" element={<GameEntryPage />} />
      <Route path="/chat" element={<ChatPage />} />
      <Route path="/chat/:duoId" element={<ChatPage />} />
      <Route path="/confidentialite" element={<PrivacyPage />} />
      <Route path="/installer" element={<InstallPage />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}
