import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Layout } from '../components/Layout'
import { useAuth } from '../context/AuthContext'
import { CATEGORY_DESCRIPTIONS, CATEGORY_LABELS, CATEGORY_ORDER } from '../lib/categories'

const DECISIONS = [
  'Les questions personnalisées sont supprimées à la fin ou à l’expiration de la session.',
  'L’historique des questions du catalogue déjà posées est conservé par duo, pour empêcher toute répétition — même après fermeture du navigateur ou reconnexion.',
  'Sur cet appareil, l’application crée automatiquement et sans aucune inscription une identité locale, qui permet de retrouver ton duo.',
  'Les réponses et les messages ne sont accessibles qu’aux deux membres autorisés du duo.',
]

const OPEN = [
  'Suppression ou conservation des réponses écrites à la fin d’une session.',
  'Suppression ou conservation des messages du chat.',
  'Durée d’expiration des sessions inactives.',
  'Procédure de suppression complète d’un duo.',
  'Durée de conservation des signalements.',
]

export function PrivacyPage() {
  const { resetIdentity } = useAuth()
  const [duoId, setDuoId] = useState<string | null>(null)
  const [resetting, setResetting] = useState(false)

  useEffect(() => {
    // Affichage du bouton de suppression si un duo courant est connu.
    const raw = localStorage.getItem('entre-nous:current-duo')
    setDuoId(raw)
  }, [])

  return (
    <Layout title="Confidentialité et sécurité">
      <div className="card stack">
        <h1>Vie privée</h1>
        <p className="muted">
          Tes réponses et tes messages peuvent contenir des informations très
          personnelles. Voici ce que l’application fait — et ne fait pas.
        </p>
      </div>

      <div className="card stack">
        <h2>Ce qui a été décidé</h2>
        <ul className="list">
          {DECISIONS.map((d) => (
            <li key={d} className="card card--soft small">
              ✓ {d}
            </li>
          ))}
        </ul>
      </div>

      <div className="card stack">
        <h2>Captures d’écran</h2>
        <p className="small muted">
          L’application limite les captures autant que la technologie le permet,
          mais une PWA <strong>ne peut pas bloquer toutes les captures</strong>{' '}
          sur tous les téléphones, et personne n’empêche de photographier
          l’écran avec un autre appareil. L’application ne promet donc jamais un
          blocage absolu (§12).
        </p>
        <ul className="list">
          <li className="small muted">• Aucune réponse privée dans les notifications.</li>
          <li className="small muted">• Aucun aperçu de message sensible sur l’écran verrouillé.</li>
          <li className="small muted">• Jamais de réponse ou de message dans l’URL.</li>
          <li className="small muted">• Jamais de réponse intime dans les journaux techniques.</li>
        </ul>
      </div>

      <div className="card stack">
        <h2>Sécurité technique</h2>
        <ul className="list">
          <li className="small muted">• HTTPS obligatoire en production.</li>
          <li className="small muted">• Chaque opération est vérifiée côté serveur (identité et droits).</li>
          <li className="small muted">• Données de chaque duo strictement séparées (RLS + vérifications serveur).</li>
          <li className="small muted">• Tirage et validation résistants aux doubles clics.</li>
          <li className="small muted">• Aucune clé privée dans le code du navigateur.</li>
        </ul>
      </div>

      <div className="card stack">
        <h2>Catégories du jeu</h2>
        <ul className="list">
          {CATEGORY_ORDER.map((cat) => (
            <li key={cat} className="card card--soft">
              <strong className="small">{CATEGORY_LABELS[cat]}</strong>
              <div className="small muted">{CATEGORY_DESCRIPTIONS[cat]}</div>
            </li>
          ))}
        </ul>
      </div>

      <div className="card stack">
        <h2>Décisions encore à confirmer avant production</h2>
        <ul className="list">
          {OPEN.map((d) => (
            <li key={d} className="small muted">
              • {d}
            </li>
          ))}
        </ul>
        <p className="small muted">
          Recommandation par défaut : supprimer réponses et messages à la fin de
          la session, sauf choix explicite de conserver un historique.
        </p>
      </div>

      <div className="card stack">
        <h2>Identité sur cet appareil</h2>
        <p className="small muted">
          Aucun compte, aucun e-mail, aucune inscription : l’application crée ici
          une identité locale automatique. Elle suffit à retrouver ton duo sur ce
          navigateur.
        </p>
        <button
          type="button"
          className="btn btn--soft"
          disabled={resetting}
          onClick={async () => {
            setResetting(true)
            await resetIdentity()
            localStorage.removeItem('entre-nous:current-duo')
            setDuoId(null)
            setResetting(false)
          }}
        >
          {resetting ? 'Réinitialisation…' : 'Réinitialiser l’identité de cet appareil'}
        </button>
        <p className="small muted">
          Utile pour tester à deux depuis un même navigateur. À utiliser avec
          précaution : un nouvel identifiant remplace l’ancien et il faudra
          ressaisir le code du duo.
        </p>
      </div>

      <div className="card stack">
        <h2>Suppression et sortie</h2>
        <p className="small muted">
          Le créateur d’un duo peut le supprimer définitivement depuis l’écran du
          duo : toutes les données privées associées sont effacées par cascade
          côté base (§15.3).
        </p>
        {duoId && (
          <Link className="btn btn--soft" to={`/duo/${duoId}`}>
            Aller à mon duo
          </Link>
        )}
        <Link className="btn btn--ghost" to="/installer">
          Comment installer l’application
        </Link>
      </div>
    </Layout>
  )
}
