# Entre Nous

Application web installable (PWA) pour **deux personnes** : un jeu de questions
par catégories, des **réponses exclusivement écrites**, une **validation de
satisfaction obligatoire**, un **consentement 18+** individuel, et un **chat
privé** indépendant du jeu.

Ce dépôt implémente le *Cahier des charges fonctionnel et technique — v1.0*
(`../Entre_Nous_Cahier_des_charges.pdf`).

## Sommaire

- [Démarrage rapide](#démarrage-rapide)
- [Architecture](#architecture)
- [Base de données](#base-de-données)
- [Règles garanties par le serveur](#règles-garanties-par-le-serveur)
- [Correspondance avec le cahier des charges](#correspondance-avec-le-cahier-des-charges)
- [Décisions encore à confirmer](#décisions-encore-à-confirmer)

## Démarrage rapide

Prérequis : Node 20+ et un projet [Supabase](https://supabase.com).

```bash
npm install
cp .env.example .env.local   # renseigne l'URL + la clé anon
```

### 1. Appliquer le schéma

Il y a deux façons de faire. **La plus simple : le fichier unique `run_all.sql`.**

#### Option A — un seul fichier (recommandé si tu utilises le SQL Editor)

Ouvre `supabase/run_all.sql`, **copie tout son contenu** dans le **SQL Editor**
du tableau de bord Supabase, puis exécute.

Ce fichier regroupe `0001` → `0005` dans le bon ordre et il est **rejouable** :
tu peux le relancer autant de fois que nécessaire, sans erreur
« already exists ». Il sert aussi de **réparation** : si une étape précédente a
échoué, le relancer remet la base dans l'état attendu.

#### Option B — via la CLI Supabase (pour un projet suivi par migrations)

```bash
npm i -g supabase
supabase link --project-ref <ref-du-projet>
supabase db push
```

La CLI applique `supabase/migrations/0001..0005` dans l'ordre. N'exécute
`run_all.sql` **que** si tu n'utilises pas la CLI, pour éviter de doubler les
migrations.

#### Option C — manuellement, fichier par fichier

Dans le SQL Editor, exécute les fichiers de `supabase/migrations/` **un par un,
dans l'ordre** : `0001_schema.sql`, `0002_rls.sql`, `0003_rpc.sql`,
`0004_seed_questions.sql`, `0005_realtime.sql`.

> ⚠️ L'ordre compte : `0002` crée les fonctions d'autorisation utilisées par
> `0003`, et `0003` crée les fonctions RPC dont dépend `0005`. Si tu te trompes
> d'ordre, les migrations affichent désormais un message explicite
> (`MIGRATION_ORDER: applique d'abord …`) au lieu d'une erreur cryptique.
> Le plus sûr reste l'option A.

#### Vérifier que tout est en place

```sql
select proname
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
order by 1;
```

Tu dois y voir notamment `create_duo`, `draw_question`, `submit_answer`,
`validate_answer`, `is_duo_member`. Et côté tables :

```sql
select tablename from pg_tables where schemaname = 'public' order by 1;
```


### 2. Activer la connexion e-mail

Dans *Authentication → Providers*, active **Email**. C'est l'identité
persistante et récupérable qui garantit qu'un duo est reconnu au fil du temps
(cahier des charges §4.3) — un simple pseudonyme ne suffit pas.

### 3. Lancer

```bash
npm run dev      # développement (http://localhost:5173)
npm run build    # build de production
npm run preview  # prévisualiser le build
```

> Le fichier `.env.local` ne contient **que** l'URL et la clé **publique**
> `anon`. La clé `service_role` ne doit **jamais** être exposée au navigateur
> (§16.9).

## Architecture

```
entre-nous/
├─ public/                    # icônes PWA + favicon (générés sans dépendance)
├─ supabase/migrations/       # schéma, RLS, fonctions serveur, données, temps réel
├─ supabase/run_all.sql       # les 5 migrations concaténées, à coller d'un coup (rejouable)
│  ├─ 0001_schema.sql         # tables + types + contraintes
│  ├─ 0002_rls.sql            # Row Level Security (isolation stricte des duos)
│  ├─ 0003_rpc.sql            # LE SERVEUR EST LA SOURCE DE VÉRITÉ (§19)
│  ├─ 0004_seed_questions.sql # catalogue initial (7 catégories)
│  └─ 0005_realtime.sql       # diffusion temps réel + durcissement
└─ src/
   ├─ lib/                    # client Supabase, types, API (RPC), helpers
   ├─ context/AuthContext.tsx # identité persistante (e-mail OTP)
   ├─ components/             # shell, navigation, feedback réseau
   └─ pages/                  # Accueil, Auth, Duo, Session (jeu), Chat, Confidentialité, Installation
```

**Frontend** : React + TypeScript + Vite, `vite-plugin-pwa` (installable,
manifeste, service worker), React Router.

**Backend** : Supabase (PostgreSQL + Auth + Realtime). Toutes les opérations
sensibles passent par des fonctions PostgreSQL `SECURITY DEFINER` exposées en
RPC (`supabase.rpc(...)`), qui vérifient elles-mêmes l'identité et les droits.

## Base de données

Tables (cahier des charges §18) : `players`, `duos`, `duo_members`, `sessions`,
`session_participants`, `questions`, `duo_used_questions`,
`session_custom_questions`, `session_consents`, `session_question_instances`,
`question_turns`, `question_answers`, `messages`, `question_reports`.

- **RLS activée partout.** Aucune policy d'écriture directe sur les tables
  sensibles : tout passe par les RPC.
- `duo_used_questions` a une clé primaire composite `(duo_id, question_id)` :
  une question ne peut pas être enregistrée deux fois pour un duo (§18).
- Un trigger interdit un troisième membre dans un duo (§4.1).
- Un déclencheur sur `auth.users` crée automatiquement la ligne `players`.

## Règles garanties par le serveur

| Règle du cahier des charges | Implémentation |
| --- | --- |
| Tirage aléatoire pondéré (§6.1) | `draw_question()` — poids 18+ 50 %, pimenté 25 %, amour 10 %, secrets 5 %, personnalité 5 %, brise-glace 3 %, avenir 2 % |
| Recalcul / renormalisation (§6.2) | catégories non autorisées, sans consentement ou épuisées exclues avant tirage |
| Jamais de répétition (§8) | marquage `duo_used_questions` **dans la même transaction** que l'attribution ; jamais de recyclage |
| Épuisement explicite (§8.3) | `draw_question()` renvoie `{ ok: false, reason: 'catalog_exhausted' }` |
| Réponses écrites non vides (§10) | `submit_answer()` refuse une réponse vide ; aucun champ vocal |
| Validation par l'auteur de la question (§10.2) | `validate_answer()` — seul `asker_id` peut valider |
| Pas de question suivante avant validation (§19) | `draw_question()` refuse si un tour est ouvert |
| Clarification sans changer de question (§10.3) | état `clarification` persistant |
| Sortie de sécurité (§10.4) | `abandon_instance()` — clôt l'interaction sans la valider, et journalise un signalement |
| Consentement des deux (§7.1) | `set_consent()` + contrôle serveur avant tout tirage 18+ |
| Retrait immédiat (§7.2) | met la session en pause si une question intime est en cours |
| Chat indépendant du jeu (§11.2) | `send_message()` ne touche jamais l'état du jeu |
| Suppression réelle des questions perso (§9) | `DELETE` serveur dans `end_session()` |
| Résistance aux doubles clics (§16.13) | contrainte « un seul tour ouvert » + transactions |
| Reprise après reconnexion (§20) | `get_session_snapshot()` renvoie l'état réel serveur |

## Correspondance avec le cahier des charges

- **PWA (§3)** : manifeste, icônes, thème, service worker, bannière hors-ligne,
  écran d'installation (Android/Chrome et iPhone/Safari).
- **Duos et invitations (§4)** : `create_duo`, `join_duo`, codes aléatoires de
  10 caractères, expiration 7 jours, rotation et révocation par le créateur.
- **Catégories (§5)** : 7 catégories, catalogue respectueux sans contenu
  coercitif.
- **Écrans (§13)** : Accueil, Création/accès duo, Invitation/attente, Préparation
  de session, Jeu, Clarification, Chat, Confidentialité, Fin de session,
  Installation.
- **Design (§14)** : palette violet profond / corail / rose doux, cartes
  arrondies, boutons tactiles (48 px), responsive, navigation « Jeu » / « Chat »
  distincte, contraste non fondé uniquement sur la couleur.

## Décisions encore à confirmer

Le cahier des charges (§15.3) liste des choix à valider avant production :
suppression ou conservation des réponses et des messages, durée d'expiration des
sessions inactives, procédure de suppression complète d'un duo, durée de
conservation des signalements.

Recommandation par défaut retenue ici : **supprimer réponses et messages à la
fin de la session**, sauf choix explicite de conserver un historique.

---

*Prototype — priorité à la confidentialité, au consentement et à la simplicité
d'usage.*
