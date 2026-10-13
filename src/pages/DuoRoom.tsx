import { useCallback, useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Layout } from '../components/Layout'
import { ErrorAlert, Spinner } from '../components/feedback'
import { api } from '../lib/api'
import { supabase } from '../lib/supabase'
import { currentDuo, currentSession } from '../lib/storage'
import type { DuoSummary } from '../lib/types'

export function DuoRoomPage() {
  const { duoId = '' } = useParams()
  const navigate = useNavigate()

  const [duo, setDuo] = useState<DuoSummary | null>(null)
  const [invite, setInvite] = useState<{
    invite_code: string | null
    invite_expires_at: string | null
    invite_revoked: boolean
  } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [copied, setCopied] = useState(false)

  const load = useCallback(async () => {
    try {
      setError(null)
      const duos = await api.myDuos()
      const found = duos.find((d) => d.id === duoId) ?? null
      setDuo(found)
      if (found) {
        currentDuo.set(found.id)
        setInvite(await api.getDuoInvite(found.id))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Chargement impossible.')
    }
  }, [duoId])

  useEffect(() => {
    void load()
  }, [load])

  // Le second participant peut arriver à tout moment : on écoute en temps réel.
  useEffect(() => {
    if (!duoId) return
    const channel = supabase
      .channel(`duo-members-${duoId}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'duo_members', filter: `duo_id=eq.${duoId}` },
        () => void load(),
      )
      .subscribe()
    return () => {
      void supabase.removeChannel(channel)
    }
  }, [duoId, load])

  async function startGame() {
    if (!duo) return
    setBusy(true)
    setError(null)
    try {
      const snap = await api.createSession(duo.id)
      currentSession.set(snap.session.id)
      navigate(`/session/${snap.session.id}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Impossible de créer la session.')
    } finally {
      setBusy(false)
    }
  }

  async function copyCode() {
    if (!invite?.invite_code) return
    try {
      await navigator.clipboard.writeText(invite.invite_code)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    } catch {
      setError('Copie impossible. Note le code manuellement.')
    }
  }

  async function share() {
    if (!invite?.invite_code) return
    const text = `Rejoins-moi sur Entre Nous avec le code : ${invite.invite_code}`
    if (navigator.share) {
      try {
        await navigator.share({ title: 'Entre Nous', text })
        return
      } catch {
        /* l’utilisateur a annulé */
      }
    }
    await copyCode()
  }

  async function rotate() {
    if (!duo) return
    setBusy(true)
    try {
      const res = await api.rotateInvite(duo.id)
      setInvite({ invite_code: res.invite_code, invite_expires_at: res.invite_expires_at, invite_revoked: false })
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Impossible de régénérer le code.')
    } finally {
      setBusy(false)
    }
  }

  async function revoke() {
    if (!duo) return
    setBusy(true)
    try {
      await api.revokeInvite(duo.id)
      setInvite((prev) => (prev ? { ...prev, invite_code: null, invite_revoked: true } : prev))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Impossible de révoquer le code.')
    } finally {
      setBusy(false)
    }
  }

  if (!duo) {
    return (
      <Layout title="Duo">
        {error ? <ErrorAlert message={error} /> : <Spinner label="Chargement du duo…" />}
      </Layout>
    )
  }

  const expires = invite?.invite_expires_at
    ? new Date(invite.invite_expires_at).toLocaleString('fr-FR')
    : null

  return (
    <Layout title={duo.name ?? 'Duo privé'}>
      <ErrorAlert message={error} />

      <div className="card stack">
        <div className="row row--between">
          <h2 style={{ margin: 0 }}>Participants</h2>
          <span className={`badge ${duo.is_full ? 'badge--ok' : 'badge--warn'}`}>
            {duo.members.length}/2
          </span>
        </div>
        <ul className="list">
          {duo.members.map((m) => (
            <li key={m.player_id} className="card card--soft row row--between">
              <span>{m.pseudo}</span>
              <span className="badge badge--off">{m.role === 'owner' ? 'Créateur' : 'Invité'}</span>
            </li>
          ))}
        </ul>
        {!duo.is_full && (
          <p className="small muted">
            En attente du second participant. La page se met à jour toute seule
            quand il ou elle rejoint.
          </p>
        )}
      </div>

      <div className="card stack">
        <h2>Inviter</h2>
        {invite?.invite_code ? (
          <>
            <div className="big-code">{invite.invite_code}</div>
            <div className="row">
              <button className="btn btn--soft" onClick={copyCode}>
                {copied ? 'Copié ✓' : 'Copier'}
              </button>
              <button className="btn" onClick={share}>
                Partager
              </button>
            </div>
            {expires && <p className="small muted">Valable jusqu’au {expires}.</p>}
            <div className="row">
              <button className="link-btn" onClick={rotate} disabled={busy}>
                Générer un nouveau code
              </button>
              <span className="spacer" />
              <button className="link-btn" onClick={revoke} disabled={busy}>
                Révoquer
              </button>
            </div>
          </>
        ) : (
          <div className="stack">
            <div className="alert alert--warn">
              L’invitation est {invite?.invite_revoked ? 'révoquée' : 'indisponible'}.
            </div>
            <button className="btn btn--soft" onClick={rotate} disabled={busy}>
              Générer un nouveau code
            </button>
          </div>
        )}
        <div className="divider" />
        <p className="small muted">
          Le code est difficile à deviner, il expire et peut être révoqué. Il ne
          donne accès qu’à ce duo et n’expose jamais de réponses ni de messages
          (§4.2).
        </p>
      </div>

      <div className="card stack">
        <h2>Session de jeu</h2>
        <p className="small muted">
          {duo.is_full
            ? 'Vous êtes deux : la session peut démarrer.'
            : 'Le second participant doit rejoindre avant de lancer le jeu.'}
        </p>
        <button className="btn" onClick={startGame} disabled={busy || !duo.is_full}>
          {busy ? 'Préparation…' : 'Préparer une session'}
        </button>
      </div>
    </Layout>
  )
}
