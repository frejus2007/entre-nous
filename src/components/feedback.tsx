import { useEffect, useState } from 'react'

/** Affiche un état de chargement centré. */
export function Spinner({ label }: { label?: string }) {
  return (
    <div className="stack center" style={{ padding: '48px 0' }}>
      <div className="spinner" role="status" aria-live="polite" />
      {label && <p className="muted small">{label}</p>}
    </div>
  )
}

export function ErrorAlert({ message }: { message: string | null }) {
  if (!message) return null
  return (
    <div className="alert alert--error" role="alert">
      {message}
    </div>
  )
}

/**
 * Détecte la perte de connexion Internet (§3.2, §14).
 */
export function useOnlineStatus(): boolean {
  const [online, setOnline] = useState(
    typeof navigator === 'undefined' ? true : navigator.onLine,
  )

  useEffect(() => {
    const on = () => setOnline(true)
    const off = () => setOnline(false)
    window.addEventListener('online', on)
    window.addEventListener('offline', off)
    return () => {
      window.removeEventListener('online', on)
      window.removeEventListener('offline', off)
    }
  }, [])

  return online
}

export function OfflineBanner() {
  const online = useOnlineStatus()
  if (online) return null
  return (
    <div className="alert alert--warn" role="status">
      Connexion Internet perdue. Le jeu et le chat reprendront automatiquement au
      retour du réseau — l’état réel est conservé par le serveur.
    </div>
  )
}
