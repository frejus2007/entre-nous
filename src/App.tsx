import { useState } from 'react'
import { Navigate, Route, Routes } from 'react-router-dom'
import { useAuth } from './context/AuthContext'
import { isSupabaseConfigured } from './lib/supabase'
import { ErrorAlert, Spinner } from './components/feedback'
import { SetupRequired } from './pages/SetupRequired'
import { HomePage } from './pages/Home'
import { DuoRoomPage } from './pages/DuoRoom'
import { SessionPage } from './pages/Session'
import { ChatPage } from './pages/Chat'
import Admin from './pages/Admin'
import { PrivacyPage } from './pages/Privacy'
import { InstallPage } from './pages/Install'
import { GameEntryPage } from './pages/GameEntry'
import { IntimateModePage } from './pages/IntimateMode'
import { PrivacyWelcome } from './components/PrivacyWelcome'

const PRIVACY_WELCOME_KEY = 'entre-nous:conversation-rules:v2'

/** L'identité locale automatique n'a pas pu être créée (réglage Supabase). */
function IdentityUnavailable({ message }: { message: string | null }) {
  return (
    <main className="container">
      <div className="card stack">
        <h1>Identité indisponible</h1>
        <p className="muted">
          L’application devait créer automatiquement une identité locale sur cet
          appareil, mais le serveur l’a refusée.
        </p>
        <ErrorAlert message={message} />
        <p className="small muted">
          Dans Supabase : <em>Authentication → Sign In / Providers</em>, active{' '}
          <strong>« Allow anonymous sign-ins »</strong>, puis recharge cette page.
        </p>
      </div>
    </main>
  )
}

export function App() {
  const { session, loading, error } = useAuth()
  const [privacyRead, setPrivacyRead] = useState(() => {
    try {
      return localStorage.getItem(PRIVACY_WELCOME_KEY) === 'read'
    } catch {
      return false
    }
  })

  if (!isSupabaseConfigured) {
    return <SetupRequired />
  }

  if (loading) {
    return (
      <main className="container">
        <Spinner label="Préparation de ton espace…" />
      </main>
    )
  }

  if (!session) {
    return <IdentityUnavailable message={error} />
  }

  if (!privacyRead) {
    return <PrivacyWelcome onContinue={() => setPrivacyRead(true)} />
  }

  return (
    <Routes>
      <Route path="/" element={<HomePage />} />
      <Route path="/duo/:duoId" element={<DuoRoomPage />} />
      <Route path="/session/:sessionId" element={<SessionPage />} />
      <Route path="/mode-intime/:roomId" element={<IntimateModePage />} />
      <Route path="/jeu" element={<GameEntryPage />} />
      <Route path="/chat" element={<ChatPage />} />
      <Route path="/chat/:duoId" element={<ChatPage />} />
      <Route path="/confidentialite" element={<PrivacyPage />} />
      <Route path="/installer" element={<InstallPage />} />
                  <Route path="/admin" element={<Admin />} />
            <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}
