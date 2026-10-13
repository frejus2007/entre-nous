import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Layout } from '../components/Layout'
import { ErrorAlert, OfflineBanner, Spinner } from '../components/feedback'
import { api } from '../lib/api'
import { currentDuo } from '../lib/storage'
import type { DuoSummary } from '../lib/types'

export function HomePage() {
  const navigate = useNavigate()
  const [duos, setDuos] = useState<DuoSummary[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const [duoName, setDuoName] = useState('')
  const [pseudo, setPseudo] = useState('')
  const [code, setCode] = useState('')

  const load = useCallback(async () => {
    try {
      setError(null)
      setDuos(await api.myDuos())
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Chargement impossible.')
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  async function handleCreate(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const duo = await api.createDuo(duoName.trim() || undefined, pseudo.trim() || undefined)
      currentDuo.set(duo.duo_id)
      navigate(`/duo/${duo.duo_id}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Création impossible.')
    } finally {
      setBusy(false)
    }
  }

  async function handleJoin(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const res = await api.joinDuo(code.trim().toUpperCase())
      currentDuo.set(res.duo_id)
      navigate(`/duo/${res.duo_id}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Impossible de rejoindre.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Layout title="Accueil">
      <OfflineBanner />
      <ErrorAlert message={error} />

      <div className="card">
        <h1>Deux personnes, de vraies questions</h1>
        <p className="muted">
          Créez un duo privé, répondez par écrit, et discutez dans un chat qui
          n’interfère jamais avec le jeu.
        </p>
      </div>

      <div className="card stack">
        <h2>Créer un duo</h2>
        <form className="stack" onSubmit={handleCreate}>
          <label className="field">
            <span className="label">Nom du duo (optionnel)</span>
            <input
              className="input"
              value={duoName}
              maxLength={60}
              onChange={(e) => setDuoName(e.target.value)}
              placeholder="Ex. Notre coin à nous"
            />
          </label>
          <label className="field">
            <span className="label">Ton prénom ou pseudo</span>
            <input
              className="input"
              value={pseudo}
              maxLength={40}
              onChange={(e) => setPseudo(e.target.value)}
              placeholder="Comment l’autre te verra"
            />
          </label>
          <button className="btn" type="submit" disabled={busy}>
            {busy ? 'Création…' : 'Créer mon duo privé'}
          </button>
        </form>
      </div>

      <div className="card stack">
        <h2>Rejoindre un duo</h2>
        <form className="stack" onSubmit={handleJoin}>
          <label className="field">
            <span className="label">Code d’invitation</span>
            <input
              className="input code-input"
              value={code}
              onChange={(e) => setCode(e.target.value.toUpperCase())}
              maxLength={10}
              placeholder="XXXXXXXXXX"
            />
          </label>
          <button className="btn btn--soft" type="submit" disabled={busy || code.length < 4}>
            Rejoindre
          </button>
        </form>
      </div>

      <div className="card stack">
        <h2>Mes duos</h2>
        {duos === null ? (
          <Spinner label="Chargement de tes duos…" />
        ) : duos.length === 0 ? (
          <p className="muted small">Aucun duo pour l’instant.</p>
        ) : (
          <ul className="list">
            {duos.map((duo) => (
              <li key={duo.id}>
                <Link
                  to={`/duo/${duo.id}`}
                  className="card card--soft"
                  style={{ display: 'block', textDecoration: 'none', color: 'inherit' }}
                  onClick={() => currentDuo.set(duo.id)}
                >
                  <div className="row row--between">
                    <strong>{duo.name ?? 'Duo privé'}</strong>
                    <span className={`badge ${duo.is_full ? 'badge--ok' : 'badge--warn'}`}>
                      {duo.is_full ? '2 participants' : 'En attente'}
                    </span>
                  </div>
                  <div className="small muted">
                    {duo.members.map((m) => m.pseudo).join(' · ') || '—'}
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Layout>
  )
}
