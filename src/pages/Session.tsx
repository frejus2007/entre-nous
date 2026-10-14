import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Layout } from '../components/Layout'
import { ErrorAlert, OfflineBanner, Spinner } from '../components/feedback'
import { api } from '../lib/api'
import { supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import { currentSession } from '../lib/storage'
import {
  CATEGORY_LABELS,
  CATEGORY_ORDER,
} from '../lib/categories'
import type { QuestionCategory, SessionSnapshot, Turn } from '../lib/types'

export function SessionPage() {
  const { sessionId = '' } = useParams()
  const navigate = useNavigate()
  const { session: authSession } = useAuth()
  const myId = authSession?.user.id ?? ''

  const [snap, setSnap] = useState<SessionSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [answer, setAnswer] = useState('')
  const [clarification, setClarification] = useState('')
  const [showSafety, setShowSafety] = useState(false)
  const [showCustom, setShowCustom] = useState(false)
  const [customText, setCustomText] = useState('')
  const [adult, setAdult] = useState(false)
  const [intimate, setIntimate] = useState(false)
  const [lastValidatedTurn, setLastValidatedTurn] = useState<Turn | null>(null)
  const prevTurnRef = useRef<Turn | null>(null)
  const debounce = useRef<number | null>(null)

  useEffect(() => {
    if (snap?.turn) {
      prevTurnRef.current = snap.turn
    } else if (prevTurnRef.current && (prevTurnRef.current.state === 'awaiting_validation' || prevTurnRef.current.state === 'clarification')) {
      setLastValidatedTurn(prevTurnRef.current)
      prevTurnRef.current = null
    }
  }, [snap?.turn])

  const refresh = useCallback(async () => {
    try {
      setSnap(await api.snapshot(sessionId))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Session introuvable.')
    }
  }, [sessionId])

  useEffect(() => {
    currentSession.set(sessionId)
    void refresh()
  }, [sessionId, refresh])

  // Synchronisation temps réel (§17.3) : les deux appareils voient le même état.
  useEffect(() => {
    if (!sessionId) return
    const schedule = () => {
      if (debounce.current) window.clearTimeout(debounce.current)
      debounce.current = window.setTimeout(() => void refresh(), 250)
    }
    const channel = supabase
      .channel(`session-${sessionId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'sessions', filter: `id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'question_turns', filter: `session_id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'session_question_instances', filter: `session_id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'session_consents', filter: `session_id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'session_participants', filter: `session_id=eq.${sessionId}` }, schedule)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'question_answers' }, schedule)
      .subscribe()
    return () => {
      void supabase.removeChannel(channel)
    }
  }, [sessionId, refresh])

  // Pré-remplit les cases de consentement depuis l'état serveur.
  useEffect(() => {
    if (!snap) return
    const mine = snap.consents.find((c) => c.player_id === myId)
    if (mine) {
      setAdult(mine.is_adult)
      setIntimate(mine.allow_intimate)
    }
  }, [snap, myId])

  const other = useMemo(
    () => snap?.members.find((m) => m.player_id !== myId) ?? null,
    [snap, myId],
  )
  const pseudoOf = useCallback(
    (id: string) => snap?.members.find((m) => m.player_id === id)?.pseudo ?? 'L’autre',
    [snap],
  )

  async function run<T>(fn: () => Promise<T>, successNotice?: string) {
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const result = await fn()
      if (result && typeof result === 'object' && 'session' in result) {
        setSnap(result as unknown as SessionSnapshot)
      }
      if (successNotice) setNotice(successNotice)
      return result
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Action impossible.')
      return null
    } finally {
      setBusy(false)
    }
  }

  if (!snap) {
    return (
      <Layout title="Session" hideNav>
        {error ? (
          <>
            <ErrorAlert message={error} />
            <button className="btn btn--soft" onClick={() => navigate('/')}>
              Retour à l’accueil
            </button>
          </>
        ) : (
          <Spinner label="Chargement de la session…" />
        )}
      </Layout>
    )
  }

  const { session, turn, members } = snap
  const iAmAnswerer = turn?.answerer_id === myId
  const iAmAsker = turn?.asker_id === myId

  return (
    <Layout title="Jeu" hideNav>
      <div className="row row--between" style={{ marginBottom: '1rem', alignItems: 'center' }}>
        <button
          className="link-btn small"
          onClick={() => navigate(`/duo/${session.duo_id}`)}
          style={{ padding: '4px 0', textDecoration: 'none' }}
        >
          ← Mon Duo
        </button>
        <button
          className="btn btn--soft btn--small"
          onClick={() => navigate(`/chat/${session.duo_id}`)}
        >
          💬 Chat privé
        </button>
      </div>

      <OfflineBanner />
      <ErrorAlert message={error} />
      {notice && <div className="alert alert--info">{notice}</div>}

      {session.state === 'waiting' && (
        <WaitingRoom onJoin={() => run(() => api.joinSession(sessionId), 'Tu as rejoint la session.')} busy={busy} pseudo={other?.pseudo} />
      )}

      {session.state === 'ready' && (
        <SetupScreen
          snap={snap}
          myId={myId}
          adult={adult}
          intimate={intimate}
          setAdult={setAdult}
          setIntimate={setIntimate}
          busy={busy}
          onSelectCategory={(category) =>
            run(() => api.setSessionCategory(sessionId, category), 'Catégorie choisie pour la partie.')
          }
          onSaveConsent={() => run(() => api.setConsent(sessionId, adult, intimate))}
          onStart={() => run(() => api.startSession(sessionId))}
        />
      )}

      {(session.state === 'active' || session.state === 'paused') && (
        <GameScreen
          snap={snap}
          turn={turn}
          busy={busy}
          myId={myId}
          pseudoOf={pseudoOf}
          answer={answer}
          setAnswer={setAnswer}
          clarification={clarification}
          setClarification={setClarification}
          showSafety={showSafety}
          setShowSafety={setShowSafety}
          showCustom={showCustom}
          setShowCustom={setShowCustom}
          customText={customText}
          setCustomText={setCustomText}
          onDraw={async () => {
            setLastValidatedTurn(null)
            const res = await run(() => api.drawQuestion(sessionId))
            if (res && typeof res === 'object' && 'ok' in res && res.ok === false) {
              setNotice('Toutes les questions admissibles ont été posées pour ce duo. Le catalogue est épuisé — aucune question ne sera répétée (§8.3).')
            }
          }}
          lastValidatedTurn={lastValidatedTurn}
          onSubmitAnswer={() =>
            run(() => api.submitAnswer(turn!.instance_id, answer), 'Réponse envoyée.').then((r) => {
              if (r) setAnswer('')
            })
          }
          onSubmitClarification={() =>
            run(() => api.submitAnswer(turn!.instance_id, clarification), 'Clarification envoyée.').then((r) => {
              if (r) setClarification('')
            })
          }
          onValidate={(ok) => run(() => api.validateAnswer(turn!.instance_id, ok))}
          onAbandon={(reason) =>
            run(() => api.abandonInstance(turn!.instance_id, reason), 'Interaction clôturée en sécurité.').then((r) => {
              if (r) setShowSafety(false)
            })
          }
          onResume={() => run(() => api.resumeSession(sessionId))}
          onEnd={() => run(() => api.endSession(sessionId))}
          onAddCustom={() =>
            run(
              () => api.addCustomQuestion(sessionId, customText, snap.session.question_category ?? 'personnalite'),
              'Question personnalisée ajoutée et lancée.',
            ).then((r) => {
              if (r) {
                setCustomText('')
                setShowCustom(false)
                setLastValidatedTurn(null)
              }
            })
          }
          iAmAnswerer={iAmAnswerer}
          iAmAsker={iAmAsker}
          members={members}
        />
      )}

      {session.state === 'finished' && (
        <div className="card stack">
          <h1>Session terminée</h1>
          <p className="muted">
            Merci pour ce moment. Les questions personnalisées temporaires ont
            été supprimées côté serveur (§9, §13.9).
          </p>
          <button className="btn" onClick={() => navigate('/')}>
            Retour à l’accueil
          </button>
        </div>
      )}
    </Layout>
  )
}

// =============================================================================
// Sous-écrans
// =============================================================================

function WaitingRoom({
  onJoin,
  busy,
  pseudo,
}: {
  onJoin: () => void
  busy: boolean
  pseudo?: string
}) {
  return (
    <div className="card stack">
      <h1>En attente…</h1>
      <p className="muted">
        La session est créée. {pseudo ? `${pseudo} doit la rejoindre.` : 'Le second participant doit la rejoindre.'}
      </p>
      <button className="btn" onClick={onJoin} disabled={busy}>
        Rejoindre cette session
      </button>
    </div>
  )
}

function SetupScreen({
  snap,
  myId,
  adult,
  intimate,
  setAdult,
  setIntimate,
  busy,
  onSelectCategory,
  onSaveConsent,
  onStart,
}: {
  snap: SessionSnapshot
  myId: string
  adult: boolean
  intimate: boolean
  setAdult: (v: boolean) => void
  setIntimate: (v: boolean) => void
  busy: boolean
  onSelectCategory: (category: QuestionCategory) => void
  onSaveConsent: () => void
  onStart: () => void
}) {
  const both = snap.intimate_enabled
  const isOwner = snap.members.some((member) => member.player_id === myId && member.role === 'owner')
  const selectedCategory = snap.session.question_category
  const hasAvailableCategory = CATEGORY_ORDER.some((cat) => (snap.remaining_by_category[cat] ?? 0) > 0)
  const intimateConsentMissing = selectedCategory === 'tres_intime' && !both
  return (
    <>
      <div className="card stack">
        <h1>Préparer la session</h1>
        <p className="muted">Le propriétaire choisit la catégorie de la partie. Toutes les questions tirées seront dans cette catégorie.</p>
        <label className="field">
          <span className="label">Catégorie de la partie</span>
          <select
            className="input"
            value={selectedCategory ?? ''}
            disabled={!isOwner || busy}
            onChange={(event) => onSelectCategory(event.target.value as QuestionCategory)}
          >
            <option value="" disabled>Choisir une catégorie</option>
            {CATEGORY_ORDER.map((cat) => {
              const remaining = snap.remaining_by_category[cat] ?? 0
              return (
                <option key={cat} value={cat} disabled={remaining === 0}>
                  {CATEGORY_LABELS[cat]} — {remaining} disponible{remaining === 1 ? '' : 's'}
                </option>
              )
            })}
          </select>
        </label>
        {!isOwner && (
          <p className="small muted">En attente du choix du propriétaire de la partie.</p>
        )}
        {!hasAvailableCategory && (
          <div className="alert alert--warn small">
            Aucune question n’est disponible. Ajoute-en dans le catalogue depuis la page Administration.
          </div>
        )}
        {selectedCategory && (
          <div className="alert alert--info small">
            La partie est configurée sur <strong>{CATEGORY_LABELS[selectedCategory]}</strong>.
          </div>
        )}
      </div>

      <div className="card stack">
        <h2>Catégorie Très intime — 18+</h2>
        <div className="alert alert--warn small">
          Une simple déclaration d’âge n’est pas une vérification officielle de
          majorité. L’application ne prétend pas avoir vérifié ton âge : elle
          recueille ton consentement (§7.1).
        </div>
        <label className="row">
          <input type="checkbox" checked={adult} onChange={(e) => setAdult(e.target.checked)} />
          <span>Je déclare être majeur(e).</span>
        </label>
        <label className="row">
          <input
            type="checkbox"
            checked={intimate}
            disabled={!adult}
            onChange={(e) => setIntimate(e.target.checked)}
          />
          <span>J’autorise la catégorie « Très intime — 18+ ».</span>
        </label>
        <p className="small muted">
          La catégorie ne sera active que si <strong>les deux</strong>{' '}
          participants l’autorisent. Chacun peut retirer son consentement à tout
          moment, immédiatement (§7.2). État actuel :{' '}
          {both ? 'active ✓' : 'inactive'}.
        </p>
        {intimateConsentMissing && (
          <div className="alert alert--warn small">
            Les deux participants doivent enregistrer leur consentement avant de démarrer dans cette catégorie.
          </div>
        )}
        <button className="btn btn--soft" onClick={onSaveConsent} disabled={busy}>
          Enregistrer mon consentement
        </button>
        <div className="divider" />
        <button
          className="btn"
          onClick={onStart}
          disabled={busy || !isOwner || !selectedCategory || intimateConsentMissing}
        >
          {busy ? 'Démarrage…' : 'Démarrer le jeu'}
        </button>
      </div>
    </>
  )
}

function GameScreen(props: {
  snap: SessionSnapshot
  turn: Turn | null
  busy: boolean
  myId: string
  pseudoOf: (id: string) => string
  answer: string
  setAnswer: (v: string) => void
  clarification: string
  setClarification: (v: string) => void
  showSafety: boolean
  setShowSafety: (v: boolean) => void
  showCustom: boolean
  setShowCustom: (v: boolean) => void
  customText: string
  setCustomText: (v: string) => void
  onDraw: () => void
  onSubmitAnswer: () => void
  onSubmitClarification: () => void
  onValidate: (ok: boolean) => void
  onAbandon: (reason?: string) => void
  onResume: () => void
  onEnd: () => void
  onAddCustom: () => void
  iAmAnswerer: boolean
  iAmAsker: boolean
  members: SessionSnapshot['members']
  lastValidatedTurn: Turn | null
}) {
  const {
    snap, turn, busy, myId, pseudoOf, answer, setAnswer,
    clarification, setClarification, showSafety, setShowSafety,
    showCustom, setShowCustom, customText, setCustomText,
    onDraw, onSubmitAnswer, onSubmitClarification, onValidate, onAbandon,
    onResume, onEnd, onAddCustom, iAmAnswerer, iAmAsker, lastValidatedTurn,
  } = props

  const mainAnswer = turn?.answers.find((a) => !a.is_clarification) ?? null
  const clarifications = turn?.answers.filter((a) => a.is_clarification) ?? []

  // §10 : alternance « chacun son tour ». next_asker_id désigne le poseur.
  const nextAsker = snap.next_asker_id
  const myTurnToAsk = !nextAsker || nextAsker === myId

  return (
    <>
      <div className="row row--between">
        <span className="badge">{snap.session.state === 'paused' ? 'En pause' : 'En jeu'}</span>
        {snap.session.question_category && (
          <span className="badge">{CATEGORY_LABELS[snap.session.question_category]}</span>
        )}
        <span className="badge badge--off">
          {snap.intimate_enabled ? '18+ actif' : '18+ inactif'}
        </span>
      </div>

      {snap.session.state === 'paused' && (
        <div className="alert alert--warn stack">
          <strong>Session en pause.</strong>
          <span className="small">
            {snap.intimate_enabled
              ? 'La session a été mise en pause.'
              : 'Un consentement 18+ a été retiré : toute question intime en cours est bloquée, et une sortie sûre est proposée. Personne n’est obligé de continuer (§7.2).'}
          </span>
          <div className="row">
            {turn && <button className="btn btn--safety" onClick={() => setShowSafety(true)}>Sortie de sécurité</button>}
            <button className="btn btn--soft" onClick={onResume} disabled={busy}>Reprendre</button>
          </div>
        </div>
      )}

      {snap.session.state === 'active' && !turn && (
        <div className="card stack">
          {lastValidatedTurn && (
            <div className="card card--soft stack" style={{ borderLeft: '4px solid var(--success)', background: 'var(--surface-2)', padding: '0.75rem 1rem' }}>
              <div className="row row--between">
                <span className="badge badge--ok" style={{ fontSize: '0.75rem' }}>Dernière réponse validée ✓</span>
                <span className="small muted">{CATEGORY_LABELS[lastValidatedTurn.category]}</span>
              </div>
              <p className="question-text small" style={{ margin: '4px 0', fontSize: '0.95rem' }}>{lastValidatedTurn.question}</p>
              <div className="answer-box small" style={{ padding: '0.5rem 0.75rem', fontSize: '0.9rem' }}>
                <strong>{pseudoOf(lastValidatedTurn.answerer_id)} :</strong>{' '}
                {lastValidatedTurn.answers[lastValidatedTurn.answers.length - 1]?.body}
              </div>
            </div>
          )}

          {myTurnToAsk ? (
            <div className="turn-banner turn-banner--me">
              <span className="turn-banner__dot" aria-hidden="true" />
              <span>
                C’est <strong>à toi</strong> de poser la question.
              </span>
            </div>
          ) : (
            <div className="turn-banner turn-banner--wait">
              <span className="turn-banner__dot" aria-hidden="true" />
              <span>
                C’est au tour de <strong>{pseudoOf(nextAsker)}</strong> de poser
                la question.
              </span>
            </div>
          )}

          {myTurnToAsk ? (
            <>
              <p className="small muted center">
                Le serveur tire une question jamais posée à votre duo dans la
                catégorie {snap.session.question_category
                  ? CATEGORY_LABELS[snap.session.question_category]
                  : 'choisie pour la partie'}.
              </p>
              <button className="btn" onClick={onDraw} disabled={busy}>
                {busy ? 'Tirage…' : 'Tirer une question'}
              </button>
            </>
          ) : (
            <div className="stack center">
              <div className="spinner" role="status" aria-live="polite" />
              <p className="small muted">
                Tu répondras à sa question. Cette page se met à jour dès qu’il
                l’a posée.
              </p>
            </div>
          )}

          {myTurnToAsk && (
            <>
              <button className="link-btn" onClick={() => setShowCustom(!showCustom)}>
                Ajouter une question personnalisée
              </button>
              {showCustom && (
                <div className="stack">
                  <textarea
                    className="textarea"
                    value={customText}
                    maxLength={400}
                    onChange={(e) => setCustomText(e.target.value)}
                    placeholder="Une question pour cette session uniquement…"
                  />
                  <button className="btn btn--soft" onClick={onAddCustom} disabled={busy || customText.trim().length < 5}>
                    Ajouter
                  </button>
                </div>
              )}
            </>
          )}
        </div>
      )}

      {turn && (
        <div className="card stack">
          <div className="row row--between">
            <span className="badge">{CATEGORY_LABELS[turn.category]}</span>
            {turn.kind === 'custom' && <span className="badge badge--off">Personnalisée</span>}
          </div>

          <div className="small muted">
            <strong>{pseudoOf(turn.asker_id)}</strong> pose la question ·{' '}
            <strong>{pseudoOf(turn.answerer_id)}</strong> doit répondre
          </div>

          <p className="question-text">{turn.question}</p>

          {mainAnswer && (
            <div className="card card--soft stack">
              <div className="small muted">
                Réponse de {pseudoOf(mainAnswer.author_id)}
              </div>
              <div className="answer-box">{mainAnswer.body}</div>
            </div>
          )}

          {clarifications.map((c) => (
            <div key={c.id} className="card card--soft stack">
              <div className="small muted">Clarification de {pseudoOf(c.author_id)}</div>
              <div className="answer-box">{c.body}</div>
            </div>
          ))}

          {/* Le répondant écrit sa réponse */}
          {iAmAnswerer && turn.state === 'awaiting_answer' && (
            <div className="stack">
              <textarea
                className="textarea"
                value={answer}
                maxLength={2000}
                onChange={(e) => setAnswer(e.target.value)}
                placeholder="Ta réponse (obligatoirement écrite)…"
              />
              <p className="small muted">
                Aucune réponse orale n’est acceptée : tout passe par ce champ
                (§10.1).
              </p>
              <button className="btn" onClick={onSubmitAnswer} disabled={busy || answer.trim() === ''}>
                Envoyer ma réponse
              </button>
            </div>
          )}

          {/* L'auteur de la question valide sa satisfaction */}
          {iAmAsker && turn.state === 'awaiting_validation' && (
            <div className="stack">
              <p className="small">Es-tu satisfait(e) de cette réponse ?</p>
              <button className="btn" onClick={() => onValidate(true)} disabled={busy}>
                Oui, je suis satisfait(e)
              </button>
              <button className="btn btn--soft" onClick={() => onValidate(false)} disabled={busy}>
                Non, demande une clarification
              </button>
            </div>
          )}

          {/* Le répondant apporte une clarification */}
          {iAmAnswerer && turn.state === 'clarification' && (
            <div className="stack">
              <div className="alert alert--info small">
                {pseudoOf(turn.asker_id)} souhaite une clarification. La question
                reste la même, le tour ne change pas (§10.3).
              </div>
              <textarea
                className="textarea"
                value={clarification}
                maxLength={2000}
                onChange={(e) => setClarification(e.target.value)}
                placeholder="Complète ta réponse…"
              />
              <button className="btn" onClick={onSubmitClarification} disabled={busy || clarification.trim() === ''}>
                Envoyer la clarification
              </button>
            </div>
          )}

          {/* Attente de l'autre participant */}
          {((iAmAnswerer && turn.state !== 'awaiting_answer') || (iAmAsker && turn.state === 'awaiting_answer') ||
            (!iAmAnswerer && !iAmAsker)) && (
            <p className="small muted">
              En attente de {iAmAsker ? pseudoOf(turn.answerer_id) : pseudoOf(turn.asker_id)}…
            </p>
          )}
        </div>
      )}

      {/* Sortie de sécurité (§10.4) : toujours accessible, jamais un simple « passer » */}
      {turn && (
        <div className="stack">
          {!showSafety ? (
            <button className="btn btn--safety" onClick={() => setShowSafety(true)}>
              Signaler un problème / sortir de cette interaction
            </button>
          ) : (
            <div className="card stack">
              <div className="alert alert--warn small">
                Cette fonction de sécurité clôt l’interaction sans la valider.
                Elle n’est pas un bouton « passer » : elle est là pour te
                protéger, jamais pour éviter une réponse (§10.4).
              </div>
              <button className="btn btn--danger" onClick={() => onAbandon('Sortie de sécurité par un participant')} disabled={busy}>
                Clôturer cette interaction
              </button>
              <button className="link-btn" onClick={() => setShowSafety(false)}>
                Annuler
              </button>
            </div>
          )}
        </div>
      )}

      {snap.session.state === 'active' && (
        <button className="link-btn" onClick={onEnd}>
          Terminer la session
        </button>
      )}
    </>
  )
}
