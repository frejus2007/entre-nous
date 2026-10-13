import { useState, type FormEvent } from 'react'
import { useAuth } from '../context/AuthContext'
import { ErrorAlert } from '../components/feedback'

export function AuthPage() {
  const { signInWithEmail, verifyEmailCode } = useAuth()
  const [email, setEmail] = useState('')
  const [token, setToken] = useState('')
  const [step, setStep] = useState<'email' | 'code'>('email')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function handleEmail(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      await signInWithEmail(email.trim())
      setStep('code')
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Connexion impossible.')
    } finally {
      setBusy(false)
    }
  }

  async function handleCode(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      await verifyEmailCode(email.trim(), token.trim())
    } catch {
      setError('Code invalide ou expiré. Réessaie.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="container">
      <div className="card">
        <span className="topbar__brand">Entre Nous</span>
        <h1 style={{ marginTop: 'var(--space-3)' }}>Se connecter</h1>
        <p className="muted">
          Ton compte est ton identité persistante : c’est lui qui permet de
          retrouver ton duo et d’éviter de répéter les questions (§4.3).
        </p>
      </div>

      <div className="card stack">
        <ErrorAlert message={error} />

        {step === 'email' ? (
          <form className="stack" onSubmit={handleEmail}>
            <label className="field">
              <span className="label">Adresse e-mail</span>
              <input
                className="input"
                type="email"
                autoComplete="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="toi@exemple.com"
              />
            </label>
            <p className="small muted">
              Tu recevras un code de connexion à usage unique. Aucune donnée
              privée (réponse, message) ne transite par e-mail.
            </p>
            <button className="btn" type="submit" disabled={busy}>
              {busy ? 'Envoi…' : 'Recevoir mon code'}
            </button>
          </form>
        ) : (
          <form className="stack" onSubmit={handleCode}>
            <label className="field">
              <span className="label">Code reçu par e-mail</span>
              <input
                className="input code-input"
                inputMode="numeric"
                autoComplete="one-time-code"
                required
                value={token}
                onChange={(e) => setToken(e.target.value)}
                placeholder="000000"
              />
            </label>
            <button className="btn" type="submit" disabled={busy}>
              {busy ? 'Vérification…' : 'Me connecter'}
            </button>
            <button
              type="button"
              className="link-btn"
              onClick={() => setStep('email')}
            >
              Utiliser une autre adresse
            </button>
          </form>
        )}
      </div>
    </main>
  )
}
