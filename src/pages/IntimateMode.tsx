import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Layout } from '../components/Layout'
import { ErrorAlert, OfflineBanner, Spinner } from '../components/feedback'
import { useAuth } from '../context/AuthContext'
import { api } from '../lib/api'
import { supabase } from '../lib/supabase'
import type { ChatMessage, IntimateModeSnapshot } from '../lib/types'

export function IntimateModePage() {
  const { roomId = '' } = useParams()
  const navigate = useNavigate()
  const { session: authSession } = useAuth()
  const myId = authSession?.user.id ?? ''

  const [room, setRoom] = useState<IntimateModeSnapshot | null>(null)
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [isAdult, setIsAdult] = useState(false)
  const [acceptsMode, setAcceptsMode] = useState(false)
  const [acceptsPrivacyPledge, setAcceptsPrivacyPledge] = useState(false)
  const [excitement, setExcitement] = useState<number | null>(null)
  const [draft, setDraft] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const bottomRef = useRef<HTMLDivElement | null>(null)

  const refreshRoom = useCallback(async () => {
    try {
      setRoom(await api.getIntimateMode(roomId))
      setError(null)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Conversation introuvable.')
    } finally {
      setLoading(false)
    }
  }, [roomId])

  const loadMessages = useCallback(async (duoId: string) => {
    try {
      setMessages(await api.listIntimateModeMessages(duoId, roomId))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Messages indisponibles.')
    }
  }, [roomId])

  useEffect(() => {
    void refreshRoom()
  }, [refreshRoom])

  useEffect(() => {
    if (!room) return
    if (room.state === 'active') void loadMessages(room.duo_id)

    const channel = supabase
      .channel(`intimate-mode-${room.id}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'intimate_mode_rooms', filter: `id=eq.${room.id}` },
        () => void refreshRoom(),
      )
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'messages', filter: `duo_id=eq.${room.duo_id}` },
        (payload) => {
          const message = payload.new as ChatMessage
          if (message.intimate_mode_id !== room.id) return
          setMessages((previous) =>
            previous.some((item) => item.id === message.id) ? previous : [...previous, message],
          )
        },
      )
      .subscribe()

    return () => {
      void supabase.removeChannel(channel)
    }
  }, [room, refreshRoom, loadMessages])

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  async function submitCheckin(event: FormEvent) {
    event.preventDefault()
    if (!room) return
    setBusy(true)
    setError(null)
    try {
      setRoom(
        await api.submitIntimateModeCheckin(
          room.id,
          isAdult,
          acceptsMode,
          acceptsPrivacyPledge,
          excitement ?? 0,
        ),
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Impossible de préparer ce mode.')
    } finally {
      setBusy(false)
    }
  }

  async function sendMessage(event: FormEvent) {
    event.preventDefault()
    if (!room || !draft.trim()) return
    const body = draft
    setDraft('')
    setBusy(true)
    setError(null)
    try {
      const sent = await api.sendIntimateModeMessage(room.id, body)
      setMessages((previous) =>
        previous.some((message) => message.id === sent.id) ? previous : [...previous, sent],
      )
    } catch (err) {
      setDraft(body)
      setError(err instanceof Error ? err.message : 'Envoi impossible.')
    } finally {
      setBusy(false)
    }
  }

  async function endMode() {
    if (!room) return
    setBusy(true)
    setError(null)
    try {
      setRoom(await api.endIntimateMode(room.id))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Impossible de terminer le mode.')
    } finally {
      setBusy(false)
    }
  }

  if (loading) {
    return (
      <Layout title="Conversation intime" hideNav>
        <Spinner label="Chargement…" />
      </Layout>
    )
  }

  if (!room) {
    return (
      <Layout title="Conversation intime" hideNav>
        <ErrorAlert message={error} />
        <button className="btn btn--soft" onClick={() => navigate('/')}>Retour</button>
      </Layout>
    )
  }

  const returnToDuo = () => navigate(`/duo/${room.duo_id}`)

  return (
    <Layout title="Conversation très intime" hideNav>
      <div className="row row--between" style={{ marginBottom: '1rem', alignItems: 'center' }}>
        <button className="link-btn small" onClick={returnToDuo}>← Mon Duo</button>
        {room.state === 'active' && (
          <button className="btn btn--safety btn--small" onClick={() => void endMode()} disabled={busy}>
            Terminer le mode
          </button>
        )}
      </div>
      <OfflineBanner />
      <ErrorAlert message={error} />

      {room.state === 'consent' && !room.has_submitted && (
        <form className="card stack intimate-mode-card" onSubmit={submitCheckin}>
          <div className="row row--between">
            <h1>Avant d’aller plus loin</h1>
            <button className="link-btn small" type="button" onClick={() => void endMode()} disabled={busy}>
              Annuler
            </button>
          </div>
          <p className="muted">
            Es-tu prêt(e) à parler librement de sexualité, de tes désirs et de tes
            fantasmes ? Ce mode est réservé aux adultes. Aucun message ne sera
            envoyé tant que vous n’aurez pas tous les deux choisi de participer.
          </p>
          <label className="row">
            <input type="checkbox" checked={isAdult} onChange={(event) => setIsAdult(event.target.checked)} />
            <span>Je déclare être majeur(e).</span>
          </label>
          <div className="alert alert--warn small">
            L’application ne vérifie pas officiellement l’âge déclaré.
          </div>
          <label className="row">
            <input type="checkbox" checked={acceptsMode} onChange={(event) => setAcceptsMode(event.target.checked)} />
            <span>Je souhaite participer à cette conversation très intime.</span>
          </label>
          <label className="row">
            <input
              type="checkbox"
              checked={acceptsPrivacyPledge}
              onChange={(event) => setAcceptsPrivacyPledge(event.target.checked)}
            />
            <span>Je m’engage à ne pas partager les confidences, captures ou extraits de cette conversation.</span>
          </label>
          <div className="alert alert--warn small">
            Cet engagement est une promesse entre vous, pas une garantie technique :
            l’application ne peut pas empêcher une capture ou un partage. Les
            messages resteront dans l’historique privé du chat de votre duo.
          </div>
          <label className="field">
            <span className="label">Mon degré d’excitation actuel : {excitement ?? '—'}%</span>
            <input
              className="input"
              type="range"
              min="0"
              max="100"
              value={excitement ?? 50}
              onChange={(event) => setExcitement(Number(event.target.value))}
              aria-label="Mon envie actuelle de participer"
            />
            <span className="small muted">
              Cette réponse est privée, temporaire et ne remplace jamais ton consentement.
            </span>
          </label>
          <button
            className="btn"
            type="submit"
            disabled={busy || (isAdult && acceptsMode && acceptsPrivacyPledge && excitement === null)}
          >
            {busy ? 'Enregistrement…' : 'Confirmer mon choix'}
          </button>
        </form>
      )}

      {room.state === 'consent' && room.has_submitted && (
        <div className="card stack center intimate-mode-card">
          <h1>Choix enregistré</h1>
          <p className="muted">
            Ton niveau reste privé. Le mode ne démarrera que si vous êtes tous les deux prêts.
          </p>
          <button className="btn btn--soft" onClick={() => void endMode()} disabled={busy}>
            Annuler mon accord
          </button>
        </div>
      )}

      {room.state === 'active' && (
        <>
          <div className="card stack intimate-mode-card">
            <h1>À vous deux</h1>
            <p className="muted">
              Vous pouvez parler librement et arrêter à tout moment. Un « non »,
              un silence ou un changement d’avis met fin au mode sans avoir à se justifier.
            </p>
            <p className="small muted">
              Les messages sont conservés dans le chat privé du duo, y compris après la fin de ce mode.
            </p>
          </div>
          <div className="chat">
            {messages.map((message) => (
              <div
                key={message.id}
                className={`msg ${message.sender_id === myId ? 'msg--mine' : 'msg--theirs'}`}
              >
                <div className="answer-box">{message.body}</div>
                <div className="msg__meta">
                  {new Date(message.created_at).toLocaleTimeString('fr-FR', {
                    hour: '2-digit',
                    minute: '2-digit',
                  })}
                </div>
              </div>
            ))}
            <div ref={bottomRef} />
          </div>
          <form className="chat-composer" onSubmit={sendMessage}>
            <input
              className="input"
              value={draft}
              maxLength={2000}
              onChange={(event) => setDraft(event.target.value)}
              placeholder="Écris ce que tu souhaites partager…"
              aria-label="Message intime"
            />
            <button className="btn btn--inline" type="submit" disabled={busy || !draft.trim()}>
              Envoyer
            </button>
          </form>
        </>
      )}

      {room.state === 'fallback' && (
        <div className="card stack intimate-mode-card">
          <h1>On reste dans votre zone de confort</h1>
          {room.fallback_session_id ? (
            <>
              <p className="muted">
                La conversation très intime ne démarre pas. Vous pouvez continuer
                avec la partie « Très intime — 18+ ».
              </p>
              <button
                className="btn"
                onClick={() => navigate(`/session/${room.fallback_session_id}`, { replace: true })}
              >
                Continuer dans « Très intime — 18+ »
              </button>
            </>
          ) : (
            <>
              <p className="muted">
                La conversation très intime ne démarre pas. Retournez au duo
                pour choisir ensemble la suite.
              </p>
              <button className="btn btn--soft" onClick={returnToDuo}>Retourner à mon duo</button>
            </>
          )}
        </div>
      )}

      {room.state === 'ended' && (
        <div className="card stack intimate-mode-card">
          <h1>Mode terminé</h1>
          <p className="muted">
            Les messages restent dans l’historique du chat privé du duo.
          </p>
          <button className="btn" onClick={() => navigate(`/chat/${room.duo_id}`)}>
            Ouvrir le chat
          </button>
        </div>
      )}
    </Layout>
  )
}
