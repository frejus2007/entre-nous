import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Layout } from '../components/Layout'
import { Spinner } from '../components/feedback'
import { api } from '../lib/api'
import { currentDuo, currentSession } from '../lib/storage'

/**
 * Point d'entrée « Jeu » : retrouve le duo courant et la session en cours,
 * puis redirige vers l'écran adapté. L'état réel vient toujours du serveur,
 * ce qui rend la reprise après reconnexion fiable (§20, §21).
 */
export function GameEntryPage() {
  const navigate = useNavigate()
  const [message, setMessage] = useState('Recherche de ta partie…')

  useEffect(() => {
    let alive = true
    ;(async () => {
      try {
        const duos = await api.myDuos()
        if (!alive) return
        if (duos.length === 0) {
          setMessage('Tu n’as pas encore de duo.')
          navigate('/', { replace: true })
          return
        }

        const duo = duos.find((d) => d.id === currentDuo.get()) ?? duos[0]
        currentDuo.set(duo.id)

        const sessionId = currentSession.get()
        if (sessionId) {
          try {
            const snap = await api.snapshot(sessionId)
            if (!alive) return
            if (snap.session.duo_id === duo.id && snap.session.state !== 'finished') {
              navigate(`/session/${sessionId}`, { replace: true })
              return
            }
          } catch {
            currentSession.clear()
          }
        }

        // Si le second participant arrive ou si le cache local a été vidé,
        // on retrouve la session en cours directement depuis le serveur (§20, §21).
        const activeSnap = await api.getActiveSession(duo.id)
        if (!alive) return
        if (activeSnap && activeSnap.session.state !== 'finished') {
          currentSession.set(activeSnap.session.id)
          navigate(`/session/${activeSnap.session.id}`, { replace: true })
          return
        }

        navigate(`/duo/${duo.id}`, { replace: true })
      } catch {
        if (alive) navigate('/', { replace: true })
      }
    })()
    return () => {
      alive = false
    }
  }, [navigate])

  return (
    <Layout title="Jeu" hideNav>
      <Spinner label={message} />
    </Layout>
  )
}
