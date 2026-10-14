import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Layout } from '../components/Layout'
import { ErrorAlert, OfflineBanner, Spinner } from '../components/feedback'
import { api } from '../lib/api'
import { supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import { currentDuo, currentSession } from '../lib/storage'
import type { ChatMessage, DuoSummary } from '../lib/types'

type PendingStatus = 'sending' | 'failed'
interface PendingMessage {
  localId: string
  body: string
  status: PendingStatus
  createdAt: string
}

export function ChatPage() {
  const { duoId } = useParams()
  const navigate = useNavigate()
  const { session: authSession } = useAuth()
  const myId = authSession?.user.id ?? ''

  const [duo, setDuo] = useState<DuoSummary | null>(null)
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [pending, setPending] = useState<PendingMessage[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const bottomRef = useRef<HTMLDivElement | null>(null)

  // Détermine le duo à afficher.
  useEffect(() => {
    let alive = true
    ;(async () => {
      try {
        const duos = await api.myDuos()
        if (!alive) return
        const wanted = duoId ?? currentDuo.get()
        const found = duos.find((d) => d.id === wanted) ?? duos[0] ?? null
        setDuo(found)
        if (!found) setLoading(false)
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Chargement impossible.')
        setLoading(false)
      }
    })()
    return () => {
      alive = false
    }
  }, [duoId])

  const loadMessages = useCallback(async (id: string) => {
    try {
      setMessages(await api.listMessages(id))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Messages indisponibles.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    if (!duo) return
    currentDuo.set(duo.id)
    void loadMessages(duo.id)
  }, [duo, loadMessages])

  // Réception en temps réel (§11.1).
  useEffect(() => {
    if (!duo) return
    const channel = supabase
      .channel(`chat-${duo.id}`)
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'messages', filter: `duo_id=eq.${duo.id}` },
        (payload) => {
          const msg = payload.new as ChatMessage
          setMessages((prev) => (prev.some((m) => m.id === msg.id) ? prev : [...prev, msg]))
        },
      )
      .subscribe()
    return () => {
      void supabase.removeChannel(channel)
    }
  }, [duo])

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages, pending])

  const send = useCallback(
    async (body: string, localId?: string) => {
      if (!duo) return
      const trimmed = body.trim()
      if (!trimmed) return

      const id = localId ?? `local-${Date.now()}-${Math.random().toString(36).slice(2)}`
      if (!localId) {
        setPending((prev) => [
          ...prev,
          { localId: id, body: trimmed, status: 'sending', createdAt: new Date().toISOString() },
        ])
      } else {
        setPending((prev) => prev.map((p) => (p.localId === id ? { ...p, status: 'sending' } : p)))
      }

      try {
        const sent = await api.sendMessage(duo.id, trimmed, currentSession.get() ?? undefined)
        setMessages((prev) => (prev.some((m) => m.id === sent.id) ? prev : [...prev, sent]))
        setPending((prev) => prev.filter((p) => p.localId !== id))
        setError(null)
      } catch (err) {
        setPending((prev) => prev.map((p) => (p.localId === id ? { ...p, status: 'failed' } : p)))
        setError(err instanceof Error ? err.message : 'Envoi échoué. Réessaie.')
      }
    },
    [duo],
  )

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    const body = draft
    setDraft('')
    void send(body)
  }

  const all = useMemo(
    () =>
      [
        ...messages.map((m) => ({ kind: 'real' as const, at: m.created_at, m })),
        ...pending.map((p) => ({ kind: 'pending' as const, at: p.createdAt, p })),
      ].sort((a, b) => a.at.localeCompare(b.at)),
    [messages, pending],
  )

  if (loading) {
    return (
      <Layout title="Chat">
        <Spinner label="Chargement du chat…" />
      </Layout>
    )
  }

  if (!duo) {
    return (
      <Layout title="Chat">
        <div className="card">
          <p className="muted">Crée ou rejoins d’abord un duo pour discuter.</p>
        </div>
      </Layout>
    )
  }

  return (
    <Layout title="Chat privé" hideNav>
      <div className="row row--between" style={{ marginBottom: '1rem', alignItems: 'center' }}>
        <button
          className="link-btn small"
          onClick={() => navigate(`/duo/${duo.id}`)}
          style={{ padding: '4px 0', textDecoration: 'none' }}
        >
          ← Mon Duo
        </button>
        <button
          className="btn btn--soft btn--small"
          onClick={() => navigate('/jeu')}
        >
          🎲 Jeu
        </button>
      </div>

      <OfflineBanner />
      <ErrorAlert message={error} />

      <div className="alert alert--info small">
        Le chat est privé et totalement séparé du jeu : un message ne compte
        jamais comme réponse officielle et ne valide jamais un tour (§11.2).
      </div>

      <div className="chat">
        {all.length === 0 && (
          <p className="muted small center">Aucun message. Écrivez-vous !</p>
        )}
        {all.map((entry) =>
          entry.kind === 'real' ? (
            <div
              key={entry.m.id}
              className={`msg ${entry.m.sender_id === myId ? 'msg--mine' : 'msg--theirs'}`}
            >
              <div className="answer-box">{entry.m.body}</div>
              <div className="msg__meta">
                <span>{new Date(entry.m.created_at).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}</span>
              </div>
            </div>
          ) : (
            <div
              key={entry.p.localId}
              className={`msg msg--mine ${entry.p.status === 'failed' ? 'msg--failed' : ''}`}
            >
              <div className="answer-box">{entry.p.body}</div>
              <div className="msg__meta">
                {entry.p.status === 'sending' ? (
                  <span>Envoi…</span>
                ) : (
                  <>
                    <span>Échec</span>
                    <button className="link-btn" onClick={() => void send(entry.p.body, entry.p.localId)}>
                      Réessayer
                    </button>
                  </>
                )}
              </div>
            </div>
          ),
        )}
        <div ref={bottomRef} />
      </div>

      <form className="chat-composer" onSubmit={handleSubmit}>
        <input
          className="input"
          value={draft}
          maxLength={2000}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="Écris un message…"
          aria-label="Nouveau message"
        />
        <button className="btn btn--inline" type="submit" disabled={!draft.trim()}>
          Envoyer
        </button>
      </form>
    </Layout>
  )
}
