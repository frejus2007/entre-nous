export function SetupRequired() {
  return (
    <main className="container">
      <div className="card">
        <h1>Mise en route</h1>
        <p className="muted">
          L’application est prête, mais le projet Supabase n’est pas encore
          configuré. Renseigne deux variables d’environnement, puis recharge la
          page.
        </p>
      </div>

      <div className="card">
        <h3>1. Créer le projet Supabase</h3>
        <p className="small muted">
          Sur <span className="muted">supabase.com</span>, crée un projet, puis
          récupère l’URL et la clé publique dans{' '}
          <em>Project Settings → API</em>.
        </p>

        <h3>2. Créer le fichier .env.local</h3>
        <pre className="card card--soft small" style={{ overflowX: 'auto' }}>
{`VITE_SUPABASE_URL="https://xxxx.supabase.co"
VITE_SUPABASE_ANON_KEY="eyJhbGciOi..."`}
        </pre>
        <p className="small muted">
          N’utilise <strong>jamais</strong> la clé <code>service_role</code> côté
          navigateur (§16.9).
        </p>

        <h3>3. Appliquer le schéma</h3>
        <p className="small muted">
          Depuis le dossier du projet :
        </p>
        <pre className="card card--soft small" style={{ overflowX: 'auto' }}>
{`supabase link --project-ref <ref>
supabase db push
# ou colle le contenu de supabase/migrations/*.sql dans le SQL Editor`}
        </pre>

        <h3>4. Activer la connexion par e-mail</h3>
        <p className="small muted">
          Dans <em>Authentication → Providers</em>, active <em>Email</em>. C’est
          l’identité persistante qui garantit l’absence de répétition des
          questions pour un même duo (§4.3, §8.2).
        </p>
      </div>
    </main>
  )
}
