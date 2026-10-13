import { useEffect, useState } from 'react'
import { Layout } from '../components/Layout'

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>
}

export function InstallPage() {
  const [deferred, setDeferred] = useState<BeforeInstallPromptEvent | null>(null)
  const [installed, setInstalled] = useState(false)

  useEffect(() => {
    const onPrompt = (e: Event) => {
      e.preventDefault()
      setDeferred(e as BeforeInstallPromptEvent)
    }
    const onInstalled = () => setInstalled(true)
    window.addEventListener('beforeinstallprompt', onPrompt)
    window.addEventListener('appinstalled', onInstalled)
    if (window.matchMedia('(display-mode: standalone)').matches) setInstalled(true)
    return () => {
      window.removeEventListener('beforeinstallprompt', onPrompt)
      window.removeEventListener('appinstalled', onInstalled)
    }
  }, [])

  const isIos = /iPhone|iPad|iPod/.test(navigator.userAgent)

  return (
    <Layout title="Installer l’application">
      <div className="card stack">
        <h1>Ajouter à l’écran d’accueil</h1>
        <p className="muted">
          Entre Nous est une application web installable (PWA). Aucun
          téléchargement depuis un magasin d’applications : tu l’ajoutes depuis
          ton navigateur (§3).
        </p>
      </div>

      {installed ? (
        <div className="card">
          <div className="alert alert--info">
            L’application est déjà installée ou ouverte en mode application. 🎉
          </div>
        </div>
      ) : deferred ? (
        <div className="card stack">
          <p className="small muted">Ton navigateur permet l’installation directe.</p>
          <button
            className="btn"
            onClick={async () => {
              await deferred.prompt()
              const choice = await deferred.userChoice
              if (choice.outcome === 'accepted') setDeferred(null)
            }}
          >
            Installer maintenant
          </button>
        </div>
      ) : (
        <div className="card stack">
          <h2>{isIos ? 'Sur iPhone (Safari)' : 'Sur Android (Chrome)'}</h2>
          {isIos ? (
            <ol className="stack">
              <li className="small">Ouvre le site dans <strong>Safari</strong>.</li>
              <li className="small">Touche le bouton <strong>Partager</strong> (carré avec une flèche).</li>
              <li className="small">Choisis <strong>« Sur l’écran d’accueil »</strong>.</li>
              <li className="small">Confirme avec <strong>Ajouter</strong>.</li>
            </ol>
          ) : (
            <ol className="stack">
              <li className="small">Ouvre le site dans <strong>Chrome</strong>.</li>
              <li className="small">Touche le menu <strong>⋮</strong> en haut à droite.</li>
              <li className="small">Choisis <strong>« Installer l’application »</strong> ou <strong>« Ajouter à l’écran d’accueil »</strong>.</li>
              <li className="small">Confirme.</li>
            </ol>
          )}
          <p className="small muted">
            Les possibilités d’installation et de notification varient selon le
            navigateur et le système (§3.3).
          </p>
        </div>
      )}

      <div className="card stack">
        <h2>Bon à savoir</h2>
        <ul className="list">
          <li className="small muted">• Le jeu et le chat nécessitent Internet ; l’état est conservé par le serveur.</li>
          <li className="small muted">• En cas de coupure, l’application reprend exactement où vous en étiez (§3.2).</li>
          <li className="small muted">• Les réponses privées ne sont jamais mises en cache non sécurisé.</li>
        </ul>
      </div>
    </Layout>
  )
}
