import { useState, useEffect } from 'react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import { Navigate } from 'react-router-dom'


type ImportResult = {
  inserted: number
  duplicates: number
  skipped: number
  total: number
}

const CATEGORIES = [
  { value: 'brise_glace', label: 'Brise-glace' },
  { value: 'personnalite', label: 'Personnalité' },
  { value: 'amour', label: 'Amour' },
  { value: 'secrets', label: 'Secrets' },
  { value: 'pimente', label: 'Pimenté' },
  { value: 'tres_intime', label: 'Très intime (18+)' },
  { value: 'avenir', label: 'Avenir' },
] as const

export default function Admin() {
  const { session, loading } = useAuth()
  const user = session?.user ?? null
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null)
  const [checking, setChecking] = useState(true)
  const [category, setCategory] = useState<(typeof CATEGORIES)[number]['value']>('brise_glace')
  const [file, setFile] = useState<File | null>(null)
  const [preview, setPreview] = useState<string[]>([])
  const [importing, setImporting] = useState(false)
  const [result, setResult] = useState<ImportResult | null>(null)
  const [error, setError] = useState<string | null>(null)

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

  const handleFileChange = async (f: File | null) => {
    setFile(f)
    setResult(null)
    setError(null)
    setPreview([])
    if (!f) return
    try {
      const text = await f.text()
      const lines = text
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter((l) => l.length > 0 && !l.startsWith('#'))
        .slice(0, 500)
      setPreview(lines)
    } catch (e: any) {
      setError('Impossible de lire le fichier : ' + e.message)
    }
  }

  const handleImport = async () => {
    if (!file || !category) return
    setImporting(true)
    setError(null)
    setResult(null)
    try {
      const text = await file.text()
      const all = text
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith('#'))

      if (all.length === 0) {
        throw new Error('Le fichier ne contient aucune question valide.')
      }

      const { data, error } = await supabase.rpc('admin_import_questions', {
        p_category: category,
        p_questions: all,
      })
      if (error) throw error
      setResult(data as ImportResult)
    } catch (e: any) {
      setError(e.message)
    } finally {
      setImporting(false)
    }
  }

  if (loading || checking) {
    return (
      <div className="home">
        <main className="home-main">
          <p>Vérification des droits...</p>
        </main>
      </div>
    )
  }

  if (!user || isAdmin === false) {
    return <Navigate to="/" replace />
  }

  return (
    <div className="home">
      <main className="home-main" style={{ maxWidth: 880, width: '96%' }}>
        <header className="home-header" style={{ marginBottom: '1.5rem' }}>
          <h1>Administration</h1>
          <p>Importer des questions depuis un fichier .txt (une question par ligne)</p>
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
              onChange={(e) => setCategory(e.target.value as any)}
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
            <label style={{ display: 'block', fontWeight: 600, marginBottom: '.5rem' }}>
              Fichier .txt
            </label>
            <input
              type="file"
              accept=".txt,text/plain"
              onChange={(e) => handleFileChange(e.target.files?.[0] || null)}
            />
            <p style={{ fontSize: '.9rem', opacity: .7, marginTop: '.4rem' }}>
              Format : une question par ligne. Lignes vides et `#` ignorées.
            </p>
          </div>

          {preview.length > 0 && (
            <div>
              <label style={{ display: 'block', fontWeight: 600, marginBottom: '.5rem' }}>
                Aperçu (500 premières max)
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
              <strong>Import terminé</strong>
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
              disabled={!file || importing}
              className="btn-primary"
              style={{ minWidth: 140 }}
            >
              {importing ? 'Import...' : 'Importer'}
            </button>
          </div>
        </section>
      </main>
    </div>
  )
}
