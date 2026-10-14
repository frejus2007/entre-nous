import { useState, useEffect, type FormEvent } from 'react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import { api } from '../lib/api'
import type { QuestionCategory } from '../lib/types'
import { Link, Navigate } from 'react-router-dom'

type ImportResult = {
  inserted: number
  duplicates: number
  skipped: number
  total: number
}

const CATEGORIES: { value: QuestionCategory; label: string }[] = [
  { value: 'brise_glace', label: 'Brise-glace' },
  { value: 'personnalite', label: 'Personnalité' },
  { value: 'amour', label: 'Amour' },
  { value: 'secrets', label: 'Secrets' },
  { value: 'pimente', label: 'Pimenté' },
  { value: 'tres_intime', label: 'Très intime (18+)' },
  { value: 'avenir', label: 'Avenir' },
]

export default function Admin() {
  const { session, loading } = useAuth()
  const user = session?.user ?? null
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null)
  const [checking, setChecking] = useState(true)
  const [passcode, setPasscode] = useState('')
  const [unlocking, setUnlocking] = useState(false)
  const [category, setCategory] = useState<QuestionCategory>('brise_glace')
  const [questionsText, setQuestionsText] = useState('')
  const [importing, setImporting] = useState(false)
  const [result, setResult] = useState<ImportResult | null>(null)
  const [error, setError] = useState<string | null>(null)
  const preview = questionsText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith('#'))
    .slice(0, 500)

  useEffect(() => {
    async function checkAdmin() {
      if (!user) {
        setIsAdmin(false)
        setChecking(false)
        return
      }
      try {
        const { data, error } = await supabase.rpc('is_admin')
        if (error) throw error
        setIsAdmin(!!data)
      } catch (e: any) {
        setError(e.message)
        setIsAdmin(false)
      } finally {
        setChecking(false)
      }
    }
    checkAdmin()
  }, [user])

  const handleUnlock = async (e: FormEvent) => {
    e.preventDefault()
    setUnlocking(true)
    setError(null)
    try {
      await api.claimAdmin(passcode)
      setIsAdmin(true)
      setPasscode('')
    } catch (err: any) {
      setError(err instanceof Error ? err.message : 'Code incorrect.')
    } finally {
      setUnlocking(false)
    }
  }

  const handleFileChange = async (f: File | null) => {
    setResult(null)
    setError(null)
    if (!f) return
    try {
      const text = await f.text()
      setQuestionsText(text)
    } catch (e: any) {
      setError('Impossible de lire le fichier : ' + e.message)
    }
  }

  const handleImport = async () => {
    if (!questionsText.trim()) return
    setImporting(true)
    setError(null)
    setResult(null)
    try {
      const all = questionsText
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith('#'))

      if (all.length === 0) {
        throw new Error('Aucune question valide à ajouter.')
      }

      const { data, error } = await supabase.rpc('admin_import_questions', {
        p_category: category,
        p_questions: all,
      })
      if (error) {
        if (error.message?.includes('operator does not exist')) {
          throw new Error("La base Supabase nécessite la mise à jour SQL de la fonction admin_import_questions. Veuillez exécuter le script supabase/migrations/0008_fixes.sql dans l'éditeur SQL de Supabase.")
        }
        throw error
      }
      setResult(data as ImportResult)
    } catch (e: any) {
      setError(e.message)
    } finally {
      setImporting(false)
    }
  }

  if (loading || checking) {
    return (
      <div className="card" style={{ maxWidth: 500, margin: '3rem auto' }}>
        <p className="muted center">Vérification des droits…</p>
      </div>
    )
  }

  if (!user) {
    return <Navigate to="/" replace />
  }

  if (isAdmin === false) {
    return (
      <main className="container" style={{ maxWidth: 520, margin: '2rem auto' }}>
        <div className="card stack">
          <div className="row row--between">
            <Link to="/" className="link-btn small">← Accueil</Link>
            <span className="badge badge--warn">Accès restreint</span>
          </div>
          <h1>Espace Administrateur</h1>
          <p className="small muted">
            Cet espace permet d’ajouter des questions au catalogue. Pour y accéder, saisis le mot de passe administrateur.
          </p>
          {error && <div className="alert alert--warn">{error}</div>}
          <form onSubmit={handleUnlock} className="stack">
            <label className="field">
              <span className="label">Mot de passe</span>
              <input
                type="password"
                className="input"
                value={passcode}
                onChange={(e) => setPasscode(e.target.value)}
                placeholder="Ex. entrenous-admin"
              />
            </label>
            <button className="btn" type="submit" disabled={unlocking || !passcode.trim()}>
              {unlocking ? 'Déverrouillage…' : 'Accéder à l’administration'}
            </button>
          </form>
        </div>
      </main>
    )
  }


  return (
    <div className="home">
      <main className="home-main" style={{ maxWidth: 880, width: '96%' }}>
        <div style={{ marginBottom: '1rem' }}>
          <Link to="/" className="link-btn small">← Accueil</Link>
        </div>
        <header className="home-header" style={{ marginBottom: '1.5rem' }}>
          <h1>Administration</h1>
          <p>Ajoute tes questions manuellement ou importe-les depuis un fichier .txt.</p>
        </header>

        {error && (
          <div
            role="alert"
            style={{
              background: '#fee2e2',
              color: '#991b1b',
              padding: '.75rem 1rem',
              borderRadius: 12,
              marginBottom: '1rem',
            }}
          >
            {error}
          </div>
        )}

        <section
          style={{
            background: 'var(--bg-card)',
            border: '1px solid var(--border)',
            borderRadius: 16,
            padding: '1.25rem',
            boxShadow: 'var(--shadow)',
            display: 'flex',
            flexDirection: 'column',
            gap: '1.25rem',
          }}
        >
          <div>
            <label style={{ display: 'block', fontWeight: 600, marginBottom: '.5rem' }}>
              Catégorie
            </label>
            <select
              value={category}
              onChange={(e) => setCategory(e.target.value as QuestionCategory)}
              style={{
                width: '100%',
                padding: '.65rem .75rem',
                borderRadius: 12,
                border: '1px solid var(--border)',
                background: '#fff',
                fontSize: '1rem',
              }}
            >
              {CATEGORIES.map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label htmlFor="questions-text" style={{ display: 'block', fontWeight: 600, marginBottom: '.5rem' }}>
              Questions
            </label>
            <textarea
              id="questions-text"
              value={questionsText}
              onChange={(e) => {
                setQuestionsText(e.target.value)
                setResult(null)
              }}
              rows={8}
              placeholder={'Écris ou colle une question par ligne.\nExemple : Quel est ton meilleur souvenir ?'}
              style={{
                width: '100%',
                padding: '.75rem',
                borderRadius: 12,
                border: '1px solid var(--border)',
                font: 'inherit',
                resize: 'vertical',
              }}
            />
            <p style={{ fontSize: '.9rem', opacity: .7, marginTop: '.4rem' }}>
              Une question par ligne. Lignes vides et lignes commençant par # ignorées.
            </p>
            <label style={{ display: 'block', fontWeight: 600, margin: '1rem 0 .5rem' }}>
              Ou charger un fichier .txt
            </label>
            <input
              type="file"
              accept=".txt,text/plain"
              onChange={(e) => handleFileChange(e.target.files?.[0] || null)}
            />
          </div>

          {preview.length > 0 && (
            <div>
              <label style={{ display: 'block', fontWeight: 600, marginBottom: '.5rem' }}>
                Aperçu ({preview.length}{questionsText.split(/\r?\n/).length > 500 ? ', 500 premières max' : ''})
              </label>
              <div
                style={{
                  maxHeight: 240,
                  overflow: 'auto',
                  background: '#0f172a05',
                  border: '1px solid var(--border)',
                  borderRadius: 12,
                  padding: '.75rem 1rem',
                }}
              >
                {preview.map((l, i) => (
                  <div key={i}>{l}</div>
                ))}
              </div>
            </div>
          )}

          {result && (
            <div
              style={{
                background: '#f0fdf4',
                color: '#166534',
                border: '1px solid #bbf7d0',
                borderRadius: 12,
                padding: '.75rem 1rem',
              }}
            >
              <strong>Ajout terminé</strong>
              <div>
                Insérées : <strong>{result.inserted}</strong> • Doublons :{' '}
                <strong>{result.duplicates}</strong> • Ignorées :{' '}
                <strong>{result.skipped}</strong> • Total : <strong>{result.total}</strong>
              </div>
            </div>
          )}

          <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
            <button
              onClick={handleImport}
              disabled={!questionsText.trim() || importing}
              className="btn-primary"
              style={{ minWidth: 140 }}
            >
              {importing ? 'Ajout...' : 'Ajouter les questions'}
            </button>
          </div>
        </section>
      </main>
    </div>
  )
}
