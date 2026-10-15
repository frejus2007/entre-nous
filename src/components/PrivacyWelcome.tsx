import { useState } from 'react'

const STORAGE_KEY = 'entre-nous:conversation-rules:v2'

const RULES = [
  {
    icon: '🔞',
    title: 'Entre adultes consentants',
    body: 'Cette conversation sexuelle est réservée à deux adultes qui ont envie d’y participer.',
  },
  {
    icon: '🤝',
    title: 'Il faut être deux à vouloir',
    body: 'Commencez seulement si vous êtes tous les deux d’accord. Le silence ou l’hésitation ne vaut pas un oui.',
  },
  {
    icon: '💬',
    title: 'Parlez de vos limites',
    body: 'Dites simplement ce qui vous plaît, ce que vous acceptez et ce que vous ne voulez pas aborder.',
  },
  {
    icon: '🫶',
    title: 'Pas de pression, pas de jugement',
    body: 'Chacun avance à son rythme. Respectez les envies et les limites de l’autre, sans insister.',
  },
  {
    icon: '🛑',
    title: 'Stop signifie stop',
    body: 'À tout moment, l’un de vous peut dire stop ou changer d’avis. La discussion s’arrête immédiatement, sans justification.',
  },
]

export function PrivacyWelcome({ onContinue }: { onContinue: () => void }) {
  const [step, setStep] = useState(0)
  const rule = RULES[step]
  const isLast = step === RULES.length - 1

  function continueToApp() {
    try {
      localStorage.setItem(STORAGE_KEY, 'read')
    } catch {
      // Continue for this visit if browser storage is unavailable.
    }
    onContinue()
  }

  return (
    <main className="privacy-welcome">
      <div className="privacy-welcome__brand">Entre Nous</div>
      <section className="privacy-welcome__card" aria-labelledby="privacy-welcome-title">
        <div className="privacy-welcome__progress" aria-label={`Règle ${step + 1} sur ${RULES.length}`}>
          {RULES.map((item, index) => (
            <span
              key={item.title}
              className={`privacy-welcome__progress-step${index <= step ? ' is-current' : ''}`}
            />
          ))}
        </div>
        <p className="privacy-welcome__eyebrow">Nos règles · {step + 1}/{RULES.length}</p>
        <div className="privacy-welcome__icon" aria-hidden="true">{rule.icon}</div>
        <h1 id="privacy-welcome-title">{rule.title}</h1>
        <p className="muted">{rule.body}</p>
        <div className="privacy-welcome__actions">
          {step > 0 && (
            <button className="btn btn--ghost" type="button" onClick={() => setStep((value) => value - 1)}>
              Retour
            </button>
          )}
          <button
            className="btn"
            type="button"
            onClick={() => (isLast ? continueToApp() : setStep((value) => value + 1))}
          >
            {isLast ? 'J’ai lu, continuer' : 'Compris, suivant'}
          </button>
        </div>
      </section>
      <p className="privacy-welcome__footer">
        Une discussion intime se fait à deux, dans le respect et avec un accord libre.
      </p>
    </main>
  )
}
