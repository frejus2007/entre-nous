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

/**
 * Vide le cache PWA (service worker + caches) et l'identité locale, puis
 * recharge : récupère la dernière version publiée de l'application.
 */
async function hardReload() {
  try {
    if ('serviceWorker' in navigator) {
      const regs = await navigator.serviceWorker.getRegistrations()
      await Promise.all(regs.map((r) => r.unregister()))
    }
    if ('caches' in window) {
      const keys = await caches.keys()
      await Promise.all(keys.map((k) => caches.delete(k)))
    }
    localStorage.removeItem('entre-nous-auth')
  } finally {
    window.location.reload()
  }
}

/** L'identité locale automatique n'a pas pu être créée (réglage Supabase). */
function IdentityUnavailable({ message }: { message: string | null }) {
  const invalidKey = /invalid api key/i.test(message ?? '')
  return (
    <main className="container">
      <div className="card stack">
        <h1>Identité indisponible</h1>
        <p className="muted">
          L’application devait créer automatiquement une identité locale sur cet
          appareil, mais le serveur l’a refusée.
        </p>
        <ErrorAlert message={message} />
        {invalidKey ? (
          <p className="small muted">
            La clé Supabase de cette version de l’application est refusée. C’est
            souvent une ancienne version restée en cache sur cet appareil :
            appuie sur le bouton ci-dessous pour charger la dernière version.
          </p>
        ) : (
          <p className="small muted">
            Dans Supabase : <em>Authentication → Sign In / Providers</em>, active{' '}
            <strong>« Allow anonymous sign-ins »</strong>, puis recharge cette page.
          </p>
        )}
        <button type="button" className="btn" onClick={() => void hardReload()}>
          Vider le cache et recharger
        </button>
      </div>
    </main>
  )
}

export function App() {
  const { session, loading, error } = useAuth()

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
                  <Route path="/admin" element={<Admin />} />
            <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}
