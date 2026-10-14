-- =============================================================================
-- Entre Nous — run_all.sql
-- Fichier unique regroupant 0001 -> 0006, dans le bon ordre.
--
-- UTILISATION : colle tout ce fichier dans le SQL Editor Supabase et exécute-le.
-- Il est REJOUABLE : tu peux le relancer autant de fois que nécessaire sans
-- erreur (« already exists »), car chaque étape est idempotente.
--
-- (Pour un projet géré par la CLI Supabase, ce fichier n'est PAS une migration :
--  utilise plutôt `supabase db push`, qui applique supabase/migrations/ dans
--  l'ordre 0001 -> 0006.)
-- =============================================================================


-- ############################################################################
-- ##  migrations/0001_schema.sql
-- ############################################################################

-- =============================================================================
-- Entre Nous — 0001_schema.sql
-- Schéma initial (cahier des charges §18 « Modèle de données prévisionnel »).
-- Toutes les tables sont préfixées par RLS activée dans 0002_rls.sql.
-- =============================================================================

create extension if not exists "pgcrypto";

-- -----------------------------------------------------------------------------
-- Types énumérés (créés seulement s'ils n'existent pas déjà — fichier rejouable)
-- -----------------------------------------------------------------------------

-- §5 : les sept catégories du catalogue.
do $$ begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'question_category'
  ) then
    create type public.question_category as enum (
      'brise_glace',      -- Brise-glace
      'personnalite',     -- Personnalité et habitudes
      'amour',            -- Amour et séduction
      'secrets',          -- Secrets et confidences
      'pimente',          -- Pimenté
      'tres_intime',      -- Très intime — 18+
      'avenir'            -- Avenir et relations
    );
  end if;
end $$;

-- §20 : états d'une session.
do $$ begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'session_state'
  ) then
    create type public.session_state as enum (
      'waiting',   -- le deuxième participant n'a pas encore rejoint
      'ready',     -- les deux participants sont présents et prêts
      'active',    -- le jeu est actif
      'paused',    -- session suspendue temporairement
      'finished',  -- session terminée
      'expired'    -- session expirée
    );
  end if;
end $$;

-- §18 : origine d'une question attribuée.
do $$ begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'instance_kind'
  ) then
    create type public.instance_kind as enum ('catalog', 'custom');
  end if;
end $$;

-- §10 : état de validation d'un tour.
do $$ begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'turn_state'
  ) then
    create type public.turn_state as enum (
      'awaiting_answer',      -- le répondant doit écrire sa réponse
      'awaiting_validation',  -- la réponse est affichée, l'asker valide
      'clarification',        -- l'asker n'est pas satisfait, clarification attendue
      'validated',            -- tour clos après validation de satisfaction
      'abandoned'             -- tour clos via la sortie de sécurité (§10.4), sans validation
    );
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- players — identités internes (§18)
-- id == auth.users.id : une identité persistante et non falsifiable (§4.3).
-- -----------------------------------------------------------------------------
create table if not exists public.players (
  id          uuid primary key references auth.users (id) on delete cascade,
  pseudo      text not null default 'Anonyme'
              check (char_length(btrim(pseudo)) between 1 and 40),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- duos — duos privés (§4)
-- -----------------------------------------------------------------------------
create table if not exists public.duos (
  id                uuid primary key default gen_random_uuid(),
  name              text check (name is null or char_length(btrim(name)) between 1 and 60),
  -- Code d'invitation aléatoire, difficile à deviner (§4.2).
  invite_code       text not null unique,
  invite_expires_at timestamptz,
  invite_revoked    boolean not null default false,
  created_by        uuid not null references public.players (id) on delete cascade,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- duo_members — participants autorisés (max 2 par duo) (§4.1)
-- -----------------------------------------------------------------------------
create table if not exists public.duo_members (
  duo_id     uuid not null references public.duos (id) on delete cascade,
  player_id  uuid not null references public.players (id) on delete cascade,
  role       text not null default 'member' check (role in ('owner', 'member')),
  joined_at  timestamptz not null default now(),
  primary key (duo_id, player_id)
);

create index if not exists duo_members_player_idx on public.duo_members (player_id);

-- -----------------------------------------------------------------------------
-- sessions — sessions de jeu (§20)
-- -----------------------------------------------------------------------------
create table if not exists public.sessions (
  id           uuid primary key default gen_random_uuid(),
  duo_id       uuid not null references public.duos (id) on delete cascade,
  state        public.session_state not null default 'waiting',
  started_at   timestamptz,
  finished_at  timestamptz,
  expires_at   timestamptz,
  created_by   uuid not null references public.players (id) on delete cascade,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists sessions_duo_idx on public.sessions (duo_id, created_at desc);

-- -----------------------------------------------------------------------------
-- session_participants — participants autorisés d'une session (§18)
-- -----------------------------------------------------------------------------
create table if not exists public.session_participants (
  session_id uuid not null references public.sessions (id) on delete cascade,
  player_id  uuid not null references public.players (id) on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (session_id, player_id)
);

-- -----------------------------------------------------------------------------
-- questions — catalogue global (§8)
-- -----------------------------------------------------------------------------
create table if not exists public.questions (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,             -- identifiant unique et stable (§8.1)
  category   public.question_category not null,
  body       text not null check (char_length(btrim(body)) between 5 and 400),
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists questions_category_idx on public.questions (category) where is_active;

-- -----------------------------------------------------------------------------
-- duo_used_questions — historique permanent par duo (§8.2)
-- La clé primaire composite garantit qu'une question ne peut être enregistrée
-- qu'une seule fois pour un duo (contrainte d'unicité exigée au §18).
-- -----------------------------------------------------------------------------
create table if not exists public.duo_used_questions (
  duo_id      uuid not null references public.duos (id) on delete cascade,
  question_id uuid not null references public.questions (id) on delete cascade,
  used_at     timestamptz not null default now(),
  primary key (duo_id, question_id)
);

-- -----------------------------------------------------------------------------
-- session_custom_questions — questions personnalisées temporaires (§9)
-- -----------------------------------------------------------------------------
create table if not exists public.session_custom_questions (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references public.sessions (id) on delete cascade,
  created_by  uuid not null references public.players (id) on delete cascade,
  category    public.question_category not null default 'personnalite',
  body        text not null check (char_length(btrim(body)) between 5 and 400),
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- session_consents — consentement 18+ (§7)
-- -----------------------------------------------------------------------------
create table if not exists public.session_consents (
  session_id    uuid not null references public.sessions (id) on delete cascade,
  player_id     uuid not null references public.players (id) on delete cascade,
  is_adult      boolean not null default false,
  allow_intimate boolean not null default false,
  updated_at    timestamptz not null default now(),
  primary key (session_id, player_id),
  -- On ne peut pas « autoriser l'intime » sans se déclarer majeur.
  check (not allow_intimate or is_adult)
);

-- -----------------------------------------------------------------------------
-- session_question_instances — question attribuée (§10.2 étape 1)
-- -----------------------------------------------------------------------------
create table if not exists public.session_question_instances (
  id                uuid primary key default gen_random_uuid(),
  session_id        uuid not null references public.sessions (id) on delete cascade,
  kind              public.instance_kind not null,
  question_id       uuid references public.questions (id) on delete set null,
  custom_question_id uuid references public.session_custom_questions (id) on delete set null,
  category          public.question_category not null,
  asker_id          uuid not null references public.players (id) on delete cascade,
  answerer_id       uuid not null references public.players (id) on delete cascade,
  created_at        timestamptz not null default now(),
  check (
    (kind = 'catalog' and question_id is not null and custom_question_id is null)
    or
    (kind = 'custom'  and custom_question_id is not null and question_id is null)
  ),
  check (asker_id <> answerer_id)
);

create index if not exists instances_session_idx on public.session_question_instances (session_id, created_at desc);

-- -----------------------------------------------------------------------------
-- question_turns — état de validation des tours (§10)
-- -----------------------------------------------------------------------------
create table if not exists public.question_turns (
  instance_id uuid primary key references public.session_question_instances (id) on delete cascade,
  session_id  uuid not null references public.sessions (id) on delete cascade,
  state       public.turn_state not null default 'awaiting_answer',
  updated_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- question_answers — réponses et clarifications écrites (§10)
-- -----------------------------------------------------------------------------
create table if not exists public.question_answers (
  id               uuid primary key default gen_random_uuid(),
  instance_id      uuid not null references public.session_question_instances (id) on delete cascade,
  author_id        uuid not null references public.players (id) on delete cascade,
  body             text not null check (char_length(btrim(body)) between 1 and 2000),
  is_clarification boolean not null default false,
  created_at       timestamptz not null default now()
);

create index if not exists answers_instance_idx on public.question_answers (instance_id, created_at);

-- -----------------------------------------------------------------------------
-- messages — chat privé (§11)
-- -----------------------------------------------------------------------------
create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  duo_id      uuid not null references public.duos (id) on delete cascade,
  session_id  uuid references public.sessions (id) on delete set null,
  sender_id   uuid not null references public.players (id) on delete cascade,
  body        text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at  timestamptz not null default now()
);

create index if not exists messages_duo_idx on public.messages (duo_id, created_at desc);

-- -----------------------------------------------------------------------------
-- question_reports — signalements (§10.4 sortie de sécurité, §18)
-- -----------------------------------------------------------------------------
create table if not exists public.question_reports (
  id          uuid primary key default gen_random_uuid(),
  duo_id      uuid not null references public.duos (id) on delete cascade,
  session_id  uuid references public.sessions (id) on delete set null,
  instance_id uuid references public.session_question_instances (id) on delete set null,
  reported_by uuid not null references public.players (id) on delete cascade,
  reason      text not null check (char_length(btrim(reason)) between 1 and 500),
  created_at  timestamptz not null default now(),
  resolved    boolean not null default false
);

-- =============================================================================
-- Helpers génériques (triggers)
-- =============================================================================

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace trigger trg_players_updated
  before update on public.players
  for each row execute function public.touch_updated_at();

create or replace trigger trg_duos_updated
  before update on public.duos
  for each row execute function public.touch_updated_at();

create or replace trigger trg_sessions_updated
  before update on public.sessions
  for each row execute function public.touch_updated_at();

create or replace trigger trg_consents_updated
  before update on public.session_consents
  for each row execute function public.touch_updated_at();

create or replace trigger trg_turns_updated
  before update on public.question_turns
  for each row execute function public.touch_updated_at();

-- =============================================================================
-- Création automatique d'un player lors de l'inscription Supabase Auth
-- =============================================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.players (id, pseudo)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'pseudo'), ''),
      'Joueur ' || substr(new.id::text, 1, 4)
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- =============================================================================
-- Contraintes métier garanties par la base (en plus des fonctions RPC)
-- =============================================================================

-- §4.1 : un duo ne peut contenir que deux participants autorisés.
create or replace function public.enforce_duo_max_two()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.duo_members where duo_id = new.duo_id) >= 2 then
    raise exception 'DUO_FULL'
      using hint = 'Un duo ne peut contenir que deux participants.';
  end if;
  return new;
end;
$$;

create or replace trigger trg_duo_max_two
  before insert on public.duo_members
  for each row execute function public.enforce_duo_max_two();

-- ############################################################################
-- ##  migrations/0002_rls.sql
-- ############################################################################

-- =============================================================================
-- Entre Nous — 0002_rls.sql
-- Sécurité par ligne (Row Level Security).
-- Principe (§15, §16) : un duo est une frontière d'isolation stricte.
--   * un joueur ne voit que les duos dont il est membre ;
--   * un joueur ne voit que les sessions de ses duos ;
--   * réponses, messages et consentements ne sont lisibles que par les
--     deux participants autorisés du duo.
-- Toutes les écritures sensibles passent par des fonctions RPC (0003_rpc.sql) :
-- les policies d'écriture directe sont volontairement absentes.
-- =============================================================================

-- =============================================================================
-- Garde-fou d'ordre d'application : 0002 dépend des tables créées par 0001.
-- =============================================================================
do $$
begin
  if to_regclass('public.duos') is null or to_regclass('public.players') is null then
    raise exception 'MIGRATION_ORDER: applique d''abord 0001_schema.sql. Les tables public.players / public.duos sont absentes.';
  end if;
end;
$$;

alter table public.players                  enable row level security;
alter table public.duos                      enable row level security;
alter table public.duo_members               enable row level security;
alter table public.sessions                  enable row level security;
alter table public.session_participants      enable row level security;
alter table public.questions                 enable row level security;
alter table public.duo_used_questions        enable row level security;
alter table public.session_custom_questions  enable row level security;
alter table public.session_consents          enable row level security;
alter table public.session_question_instances enable row level security;
alter table public.question_turns            enable row level security;
alter table public.question_answers          enable row level security;
alter table public.messages                  enable row level security;
alter table public.question_reports          enable row level security;

-- =============================================================================
-- Helpers d'autorisation
-- SECURITY DEFINER + search_path figé : ils évitent les récursions RLS
-- (ex. vérifier l'appartenance à un duo depuis une policy qui lit duo_members).
-- =============================================================================

create or replace function public.is_duo_member(p_duo uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.duo_members
    where duo_id = p_duo and player_id = auth.uid()
  );
$$;

create or replace function public.is_duo_owner(p_duo uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.duo_members
    where duo_id = p_duo and player_id = auth.uid() and role = 'owner'
  );
$$;

create or replace function public.is_session_member(p_session uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.sessions s
    join public.duo_members dm on dm.duo_id = s.duo_id
    where s.id = p_session and dm.player_id = auth.uid()
  );
$$;

revoke all on function public.is_duo_member(uuid) from public, anon;
revoke all on function public.is_duo_owner(uuid) from public, anon;
revoke all on function public.is_session_member(uuid) from public, anon;
grant execute on function public.is_duo_member(uuid) to authenticated;
grant execute on function public.is_duo_owner(uuid) to authenticated;
grant execute on function public.is_session_member(uuid) to authenticated;

-- =============================================================================
-- Idempotence : on supprime les policies existantes avant de les recréer, afin
-- que ce fichier puisse être rejoué sans erreur « policy already exists ».
-- =============================================================================
do $$
declare
  p record;
begin
  for p in
    select * from (values
      ('players', 'players_select_self'),
      ('players', 'players_select_co_members'),
      ('players', 'players_update_self'),
      ('duos', 'duos_select_member'),
      ('duo_members', 'duo_members_select_member'),
      ('sessions', 'sessions_select_member'),
      ('session_participants', 'session_participants_select_member'),
      ('questions', 'questions_select_active'),
      ('duo_used_questions', 'duo_used_questions_select_member'),
      ('session_custom_questions', 'custom_questions_select_member'),
      ('session_consents', 'consents_select_member'),
      ('session_question_instances', 'instances_select_member'),
      ('question_turns', 'turns_select_member'),
      ('question_answers', 'answers_select_member'),
      ('messages', 'messages_select_member'),
      ('question_reports', 'reports_select_author')
    ) as t(tbl, pol)
  loop
    execute format('drop policy if exists %I on public.%I', p.pol, p.tbl);
  end loop;
end;
$$;

-- =============================================================================
-- players
-- =============================================================================
create policy players_select_self
  on public.players for select
  to authenticated
  using (id = auth.uid());

-- Un joueur peut voir le pseudo des membres de ses duos (affichage du duo).
create policy players_select_co_members
  on public.players for select
  to authenticated
  using (
    exists (
      select 1
      from public.duo_members me
      join public.duo_members them on them.duo_id = me.duo_id
      where me.player_id = auth.uid() and them.player_id = players.id
    )
  );

create policy players_update_self
  on public.players for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- =============================================================================
-- duos — lisibles par les membres uniquement
-- =============================================================================
create policy duos_select_member
  on public.duos for select
  to authenticated
  using (public.is_duo_member(id));

-- =============================================================================
-- duo_members
-- =============================================================================
create policy duo_members_select_member
  on public.duo_members for select
  to authenticated
  using (public.is_duo_member(duo_id));

-- =============================================================================
-- sessions
-- =============================================================================
create policy sessions_select_member
  on public.sessions for select
  to authenticated
  using (public.is_duo_member(duo_id));

-- =============================================================================
-- session_participants
-- =============================================================================
create policy session_participants_select_member
  on public.session_participants for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- questions — catalogue global en lecture seule pour les utilisateurs connectés
-- =============================================================================
create policy questions_select_active
  on public.questions for select
  to authenticated
  using (is_active);

-- =============================================================================
-- duo_used_questions — historique privé du duo
-- =============================================================================
create policy duo_used_questions_select_member
  on public.duo_used_questions for select
  to authenticated
  using (public.is_duo_member(duo_id));

-- =============================================================================
-- session_custom_questions
-- =============================================================================
create policy custom_questions_select_member
  on public.session_custom_questions for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- session_consents — chaque participant voit les deux consentements de sa
-- session (nécessaire pour savoir si la catégorie 18+ est active), mais seul
-- le sien est modifiable, et uniquement via RPC.
-- =============================================================================
create policy consents_select_member
  on public.session_consents for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- session_question_instances
-- =============================================================================
create policy instances_select_member
  on public.session_question_instances for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- question_turns
-- =============================================================================
create policy turns_select_member
  on public.question_turns for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- question_answers
-- =============================================================================
create policy answers_select_member
  on public.question_answers for select
  to authenticated
  using (
    public.is_session_member(
      (select session_id from public.session_question_instances i where i.id = instance_id)
    )
  );

-- =============================================================================
-- messages — lisibles par les membres du duo
-- =============================================================================
create policy messages_select_member
  on public.messages for select
  to authenticated
  using (public.is_duo_member(duo_id));

-- =============================================================================
-- question_reports — visibles par leur auteur (les admins passeront par
-- la clé service_role, hors de portée du navigateur).
-- =============================================================================
create policy reports_select_author
  on public.question_reports for select
  to authenticated
  using (reported_by = auth.uid());

-- ############################################################################
-- ##  migrations/0003_rpc.sql
-- ############################################################################

-- =============================================================================
-- Entre Nous — 0003_rpc.sql
-- Fonctions serveur : LE SERVEUR EST LA SOURCE DE VÉRITÉ (§19).
-- Toutes les opérations sensibles (création de duo, tirage pondéré, réponses,
-- validation de satisfaction, consentement, chat) passent par ces fonctions.
-- Elles sont SECURITY DEFINER : elles contournent volontairement la RLS APRÈS
-- avoir vérifié elles-mêmes l'identité et les autorisations de l'appelant.
-- =============================================================================

-- =============================================================================
-- Garde-fou d'ordre d'application.
-- Ce fichier dépend des fonctions d'autorisation créées dans 0002_rls.sql.
-- Sans ce contrôle, l'erreur affichée serait « function public.is_duo_member
-- does not exist », difficile à diagnostiquer.
-- =============================================================================
do $$
begin
  if to_regprocedure('public.is_duo_member(uuid)') is null
     or to_regprocedure('public.is_duo_owner(uuid)') is null
     or to_regprocedure('public.is_session_member(uuid)') is null then
    raise exception 'MIGRATION_ORDER: applique d''abord 0002_rls.sql. Les fonctions d''autorisation (public.is_duo_member / is_duo_owner / is_session_member) sont absentes.';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Helpers internes
-- -----------------------------------------------------------------------------

create or replace function public.assert_duo_member(p_duo uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.duo_members
    where duo_id = p_duo and player_id = auth.uid()
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;
end;
$$;

create or replace function public.assert_session_member(p_session uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not exists (
    select 1
    from public.sessions s
    join public.duo_members dm on dm.duo_id = s.duo_id
    where s.id = p_session and dm.player_id = auth.uid()
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;
end;
$$;

-- Code d'invitation : 10 caractères base32 sans caractères ambigus.
create or replace function public.generate_invite_code()
returns text
language plpgsql
volatile
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result text := '';
  i int;
begin
  for i in 1..10 loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end;
$$;

-- =============================================================================
-- Table des poids par catégorie (§6.1)
-- =============================================================================
create or replace function public.category_weight(p_category public.question_category)
returns numeric
language sql
immutable
as $$
  select case p_category
    when 'tres_intime'  then 50
    when 'pimente'      then 25
    when 'amour'        then 10
    when 'secrets'      then 5
    when 'personnalite' then 5
    when 'brise_glace'  then 3
    when 'avenir'       then 2
  end::numeric;
$$;

-- Alternance des tours (§10) : « chacun à son tour ».
-- Les rôles s'inversent à chaque tour : le tout premier poseur est le
-- créateur de la session, puis on alterne. On se base sur le nombre de tours
-- déjà entamés (parité), ce qui est déterministe et insensible à l'horloge.
create or replace function public.next_asker_id(p_session uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with s as (
    select created_by, duo_id from public.sessions where id = p_session
  ),
  n as (
    select count(*)::int as c
    from public.session_question_instances
    where session_id = p_session
  )
  select case
    when (select c from n) % 2 = 0 then (select created_by from s)
    else (
      select dm.player_id
      from public.duo_members dm
      where dm.duo_id = (select duo_id from s)
        and dm.player_id <> (select created_by from s)
      order by dm.joined_at
      limit 1
    )
  end;
$$;

-- =============================================================================
-- DUOS
-- =============================================================================

-- Crée un duo privé et son code d'invitation. (§4.1)
create or replace function public.create_duo(
  p_name text default null,
  p_pseudo text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_duo_id  uuid;
  v_code    text;
  v_expires timestamptz := now() + interval '7 days';
  v_count   int;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  -- Limite anti-abus raisonnable (§16.8).
  select count(*) into v_count from public.duos where created_by = v_uid;
  if v_count >= 20 then
    raise exception 'TOO_MANY_DUOS';
  end if;

  insert into public.players (id, pseudo)
  values (v_uid, coalesce(nullif(btrim(coalesce(p_pseudo, '')), ''), 'Anonyme'))
  on conflict (id) do update
    set pseudo = case
      when btrim(coalesce(excluded.pseudo, '')) <> '' and excluded.pseudo <> 'Anonyme'
      then excluded.pseudo else public.players.pseudo end;

  loop
    v_code := public.generate_invite_code();
    exit when not exists (select 1 from public.duos where invite_code = v_code);
  end loop;

  insert into public.duos (name, invite_code, invite_expires_at, created_by)
  values (nullif(btrim(coalesce(p_name, '')), ''), v_code, v_expires, v_uid)
  returning id into v_duo_id;

  insert into public.duo_members (duo_id, player_id, role)
  values (v_duo_id, v_uid, 'owner');

  return jsonb_build_object(
    'duo_id', v_duo_id,
    'invite_code', v_code,
    'invite_expires_at', v_expires
  );
end;
$$;

-- Rejoint un duo via son code d'invitation. (§4.2)
create or replace function public.join_duo(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_duo   public.duos;
  v_code  text := upper(btrim(coalesce(p_code, '')));
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_code = '' then raise exception 'EMPTY_CODE'; end if;

  select * into v_duo from public.duos where invite_code = v_code;
  if v_duo.id is null then raise exception 'INVALID_INVITE'; end if;
  if v_duo.invite_revoked then raise exception 'INVITE_REVOKED'; end if;
  if v_duo.invite_expires_at is not null and v_duo.invite_expires_at < now() then
    raise exception 'INVITE_EXPIRED';
  end if;

  insert into public.players (id, pseudo) values (v_uid, 'Anonyme')
  on conflict (id) do nothing;

  if exists (select 1 from public.duo_members where duo_id = v_duo.id and player_id = v_uid) then
    return jsonb_build_object('duo_id', v_duo.id, 'already_member', true);
  end if;

  insert into public.duo_members (duo_id, player_id, role)
  values (v_duo.id, v_uid, 'member');  -- le trigger refusera si le duo est plein

  return jsonb_build_object('duo_id', v_duo.id, 'already_member', false);
end;
$$;

-- Liste des duos du joueur, avec co-membres et état.
create or replace function public.get_my_duos()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(d order by d ->> 'created_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', du.id,
      'name', du.name,
      'created_at', du.created_at,
      'members', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'player_id', dm.player_id,
          'pseudo', coalesce(p.pseudo, 'Anonyme'),
          'role', dm.role
        ) order by dm.joined_at), '[]'::jsonb)
        from public.duo_members dm
        left join public.players p on p.id = dm.player_id
        where dm.duo_id = du.id
      ),
      'is_full', (select count(*) from public.duo_members m where m.duo_id = du.id) >= 2
    ) as d
    from public.duos du
    where public.is_duo_member(du.id)
  ) sub;
$$;

-- Affiche le code d'invitation courant aux membres du duo. (§4.2)
create or replace function public.get_duo_invite(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_duo public.duos;
begin
  perform public.assert_duo_member(p_duo);
  select * into v_duo from public.duos where id = p_duo;
  return jsonb_build_object(
    'invite_code', case when v_duo.invite_revoked then null else v_duo.invite_code end,
    'invite_expires_at', v_duo.invite_expires_at,
    'invite_revoked', v_duo.invite_revoked
  );
end;
$$;

-- Génère un nouveau code et le réactive (propriétaire uniquement). (§4.2)
create or replace function public.rotate_invite(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_expires timestamptz := now() + interval '7 days';
begin
  perform public.assert_duo_member(p_duo);
  if not public.is_duo_owner(p_duo) then raise exception 'NOT_OWNER'; end if;

  loop
    v_code := public.generate_invite_code();
    exit when not exists (select 1 from public.duos where invite_code = v_code);
  end loop;

  update public.duos
     set invite_code = v_code,
         invite_revoked = false,
         invite_expires_at = v_expires
   where id = p_duo;

  return jsonb_build_object('invite_code', v_code, 'invite_expires_at', v_expires);
end;
$$;

-- Révoque l'invitation courante (propriétaire uniquement). (§4.2)
create or replace function public.revoke_invite(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_duo_member(p_duo);
  if not public.is_duo_owner(p_duo) then raise exception 'NOT_OWNER'; end if;
  update public.duos set invite_revoked = true where id = p_duo;
  return jsonb_build_object('invite_revoked', true);
end;
$$;

-- =============================================================================
-- SESSIONS
-- =============================================================================

-- Crée une session de jeu pour un duo (§13.3 : le 2e participant est attendu).
create or replace function public.create_session(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_sess   uuid;
  v_members int;
begin
  perform public.assert_duo_member(p_duo);

  select count(*) into v_members from public.duo_members where duo_id = p_duo;

  insert into public.sessions (duo_id, state, created_by, expires_at)
  values (p_duo, 'waiting', v_uid, now() + interval '24 hours')
  returning id into v_sess;

  insert into public.session_participants (session_id, player_id)
  values (v_sess, v_uid)
  on conflict do nothing;

  -- Si le duo est déjà au complet, les deux participants sont présents.
  if v_members >= 2 then
    insert into public.session_participants (session_id, player_id)
    select v_sess, dm.player_id from public.duo_members dm where dm.duo_id = p_duo
    on conflict do nothing;
    update public.sessions set state = 'ready' where id = v_sess;
  end if;

  return public.get_session_snapshot(v_sess);
end;
$$;

-- Le second participant rejoint la session (état waiting → ready).
create or replace function public.join_session(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duo uuid;
  v_members int;
  v_parts int;
begin
  perform public.assert_session_member(p_session);

  select duo_id into v_duo from public.sessions where id = p_session;

  insert into public.session_participants (session_id, player_id)
  values (p_session, auth.uid())
  on conflict do nothing;

  select count(*) into v_members from public.duo_members where duo_id = v_duo;
  select count(*) into v_parts from public.session_participants where session_id = p_session and player_id in (
    select player_id from public.duo_members where duo_id = v_duo
  );

  if v_members >= 2 and v_parts >= 2 then
    update public.sessions
       set state = 'ready'
     where id = p_session and state = 'waiting';
  end if;

  return public.get_session_snapshot(p_session);
end;
$$;

-- Démarre le jeu (§20 : ready → active).
create or replace function public.start_session(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_members int; v_parts int; v_duo uuid;
begin
  perform public.assert_session_member(p_session);
  select duo_id into v_duo from public.sessions where id = p_session;
  select count(*) into v_members from public.duo_members where duo_id = v_duo;
  select count(*) into v_parts from public.session_participants where session_id = p_session;

  if v_members < 2 or v_parts < 2 then
    raise exception 'WAITING_FOR_PARTNER';
  end if;

  update public.sessions
     set state = 'active', started_at = coalesce(started_at, now())
   where id = p_session;

  return public.get_session_snapshot(p_session);
end;
$$;

create or replace function public.pause_session(p_session uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  perform public.assert_session_member(p_session);
  update public.sessions set state = 'paused' where id = p_session and state = 'active';
  return public.get_session_snapshot(p_session);
end;
$$;

create or replace function public.resume_session(p_session uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  perform public.assert_session_member(p_session);
  update public.sessions set state = 'active' where id = p_session and state = 'paused';
  return public.get_session_snapshot(p_session);
end;
$$;

-- Termine la session et nettoie les données temporaires côté SERVEUR (§9, §13.9).
create or replace function public.end_session(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_session_member(p_session);

  update public.sessions
     set state = 'finished', finished_at = now()
   where id = p_session;

  -- §9 : suppression réelle des questions personnalisées (pas un simple masquage).
  delete from public.session_custom_questions where session_id = p_session;

  return public.get_session_snapshot(p_session);
end;
$$;

-- =============================================================================
-- CONSENTEMENT 18+ (§7)
-- =============================================================================
create or replace function public.set_consent(
  p_session uuid,
  p_is_adult boolean,
  p_allow_intimate boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_open_intimate boolean;
begin
  perform public.assert_session_member(p_session);

  if p_allow_intimate and not p_is_adult then
    raise exception 'ADULT_REQUIRED';
  end if;

  insert into public.session_consents (session_id, player_id, is_adult, allow_intimate)
  values (p_session, v_uid, p_is_adult, p_allow_intimate)
  on conflict (session_id, player_id) do update
    set is_adult = excluded.is_adult,
        allow_intimate = excluded.allow_intimate,
        updated_at = now();

  -- §7.2 : le retrait est immédiat. Si une question 18+ est en cours, sa
  -- progression est bloquée et une sortie sûre devient nécessaire.
  if not p_allow_intimate then
    select exists (
      select 1
      from public.question_turns t
      join public.session_question_instances i on i.id = t.instance_id
      where t.session_id = p_session
        and i.category = 'tres_intime'
        and t.state in ('awaiting_answer', 'awaiting_validation', 'clarification')
    ) into v_open_intimate;

    if v_open_intimate then
      update public.sessions set state = 'paused' where id = p_session;
    end if;
  end if;

  return public.get_session_snapshot(p_session);
end;
$$;

-- =============================================================================
-- TIRAGE PONDÉRÉ (§6) — cœur du jeu
-- =============================================================================
create or replace function public.draw_question(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_duo      uuid;
  v_state    public.session_state;
  v_intimate boolean;
  v_total    numeric := 0;
  v_running  numeric := 0;
  v_pick     numeric;
  rec        record;
  v_chosen   public.question_category;
  v_kind     public.instance_kind;
  v_qid      uuid;
  v_cqid     uuid;
  v_asker    uuid := v_uid;
  v_answerer uuid;
  v_instance uuid;
  v_open     int;
  v_expected uuid;
begin
  perform public.assert_session_member(p_session);

  select duo_id, state into v_duo, v_state from public.sessions where id = p_session;

  if v_state <> 'active' then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;

  -- §19 : interdire l'ouverture d'une nouvelle question tant qu'un tour
  -- n'est pas validé ou abandonné.
  select count(*) into v_open
  from public.question_turns
  where session_id = p_session and state in ('awaiting_answer', 'awaiting_validation', 'clarification');
  if v_open > 0 then
    raise exception 'TURN_IN_PROGRESS';
  end if;

  -- §10 : « chacun à son tour ». Seul le poseur désigné peut tirer la question.
  v_expected := public.next_asker_id(p_session);
  if v_expected is not null and v_uid <> v_expected then
    raise exception 'NOT_YOUR_TURN';
  end if;

  -- Le consentement 18+ n'est actif que si LES DEUX l'ont donné (§7.1).
  select count(*) = 2 into v_intimate
  from public.session_consents
  where session_id = p_session and is_adult and allow_intimate;

  if not coalesce(v_intimate, false) then
    v_intimate := false;
  end if;

  -- Construction des catégories admissibles avec poids et disponibilité (§6.2).
  create temporary table _pool on commit drop as
  select c.cat,
         public.category_weight(c.cat) as weight,
         (
           (select count(*) from public.questions q
              where q.category = c.cat and q.is_active
                and not exists (
                  select 1 from public.duo_used_questions u
                  where u.duo_id = v_duo and u.question_id = q.id))
           +
           (select count(*) from public.session_custom_questions cq
              where cq.session_id = p_session and cq.category = c.cat
                and not exists (
                  select 1 from public.session_question_instances i
                  where i.session_id = p_session and i.custom_question_id = cq.id))
         ) as avail
  from (values
    ('brise_glace'::public.question_category),
    ('personnalite'::public.question_category),
    ('amour'::public.question_category),
    ('secrets'::public.question_category),
    ('pimente'::public.question_category),
    ('tres_intime'::public.question_category),
    ('avenir'::public.question_category)
  ) as c(cat)
  where (c.cat <> 'tres_intime' or v_intimate);

  select coalesce(sum(weight), 0) into v_total from _pool where avail > 0;

  -- §8.3 : plus aucune question admissible → épuisement explicite, jamais de recyclage.
  if v_total = 0 then
    drop table _pool;
    return jsonb_build_object('ok', false, 'reason', 'catalog_exhausted');
  end if;

  -- Tirage pondéré : les poids sont renormalisés de fait (somme des restants).
  v_pick := random() * v_total;
  for rec in select cat, weight from _pool where avail > 0 order by weight desc, cat loop
    v_running := v_running + rec.weight;
    if v_pick < v_running then
      v_chosen := rec.cat;
      exit;
    end if;
  end loop;
  if v_chosen is null then
    select cat into v_chosen from _pool where avail > 0 order by weight desc, cat limit 1;
  end if;

  drop table _pool;

  -- Sélection d'une question concrète dans la catégorie tirée.
  select kind, qid, cqid into v_kind, v_qid, v_cqid
  from (
    select 'catalog'::public.instance_kind as kind, q.id as qid, null::uuid as cqid
    from public.questions q
    where q.category = v_chosen and q.is_active
      and not exists (
        select 1 from public.duo_used_questions u
        where u.duo_id = v_duo and u.question_id = q.id)
    union all
    select 'custom'::public.instance_kind, null, cq.id
    from public.session_custom_questions cq
    where cq.session_id = p_session and cq.category = v_chosen
      and not exists (
        select 1 from public.session_question_instances i
        where i.session_id = p_session and i.custom_question_id = cq.id)
  ) pool
  order by random()
  limit 1;

  -- §10.2 : celui qui tire pose la question, l'autre répond.
  select dm.player_id into v_answerer
  from public.duo_members dm
  where dm.duo_id = v_duo and dm.player_id <> v_uid
  limit 1;

  if v_answerer is null then
    raise exception 'NEED_TWO_PLAYERS';
  end if;

  -- §8.2 + §19 : marquage « utilisée » et attribution dans la même transaction.
  if v_kind = 'catalog' then
    insert into public.duo_used_questions (duo_id, question_id)
    values (v_duo, v_qid)
    on conflict (duo_id, question_id) do nothing;
  end if;

  insert into public.session_question_instances
    (session_id, kind, question_id, custom_question_id, category, asker_id, answerer_id)
  values
    (p_session, v_kind, v_qid, v_cqid, v_chosen, v_asker, v_answerer)
  returning id into v_instance;

  insert into public.question_turns (instance_id, session_id, state)
  values (v_instance, p_session, 'awaiting_answer');

  return public.get_session_snapshot(p_session);
end;
$$;

-- =============================================================================
-- RÉPONSES ÉCRITES (§10)
-- =============================================================================

-- Le répondant désigné soumet sa réponse (ou une clarification).
create or replace function public.submit_answer(
  p_instance uuid,
  p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_inst   public.session_question_instances;
  v_turn   public.question_turns;
  v_body   text := btrim(coalesce(p_body, ''));
begin
  select * into v_inst from public.session_question_instances where id = p_instance;
  if v_inst.id is null then raise exception 'UNKNOWN_INSTANCE'; end if;
  perform public.assert_session_member(v_inst.session_id);

  select * into v_turn from public.question_turns where instance_id = p_instance;

  -- §19 : seule la personne désignée comme répondant peut répondre.
  if v_inst.answerer_id <> v_uid then
    raise exception 'NOT_THE_ANSWERER';
  end if;

  if v_turn.state not in ('awaiting_answer', 'clarification') then
    raise exception 'ANSWER_NOT_EXPECTED';
  end if;

  -- §19 : refuser une réponse vide.
  if v_body = '' then
    raise exception 'EMPTY_ANSWER';
  end if;

  insert into public.question_answers (instance_id, author_id, body, is_clarification)
  values (p_instance, v_uid, v_body, v_turn.state = 'clarification');

  update public.question_turns
     set state = 'awaiting_validation', updated_at = now()
   where instance_id = p_instance;

  return public.get_session_snapshot(v_inst.session_id);
end;
$$;

-- §10.2/§10.3 : SEUL l'auteur de la question valide sa satisfaction.
-- p_satisfied = false → la question reste ouverte, le tour ne change pas,
-- le répondant peut apporter une clarification écrite.
create or replace function public.validate_answer(
  p_instance uuid,
  p_satisfied boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_inst public.session_question_instances;
  v_turn public.question_turns;
begin
  select * into v_inst from public.session_question_instances where id = p_instance;
  if v_inst.id is null then raise exception 'UNKNOWN_INSTANCE'; end if;
  perform public.assert_session_member(v_inst.session_id);

  select * into v_turn from public.question_turns where instance_id = p_instance;

  if v_inst.asker_id <> v_uid then
    raise exception 'NOT_THE_ASKER';
  end if;

  if v_turn.state <> 'awaiting_validation' then
    raise exception 'NOTHING_TO_VALIDATE';
  end if;

  update public.question_turns
     set state = case
                   when p_satisfied then 'validated'::public.turn_state
                   else 'clarification'::public.turn_state
                 end,
         updated_at = now()
   where instance_id = p_instance;

  return public.get_session_snapshot(v_inst.session_id);
end;
$$;

-- §10.4 : sortie de sécurité. Permet de clore une interaction inconfortable
-- sans la valider comme satisfaisante. Transforme un « blocage » en tour clos.
create or replace function public.abandon_instance(
  p_instance uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_inst public.session_question_instances;
  v_turn public.question_turns;
begin
  select * into v_inst from public.session_question_instances where id = p_instance;
  if v_inst.id is null then raise exception 'UNKNOWN_INSTANCE'; end if;
  perform public.assert_session_member(v_inst.session_id);

  if v_inst.asker_id <> v_uid and v_inst.answerer_id <> v_uid then
    raise exception 'NOT_A_PARTICIPANT';
  end if;

  select * into v_turn from public.question_turns where instance_id = p_instance;
  if v_turn.state in ('validated', 'abandoned') then
    return public.get_session_snapshot(v_inst.session_id);
  end if;

  update public.question_turns
     set state = 'abandoned', updated_at = now()
   where instance_id = p_instance;

  insert into public.question_reports (duo_id, session_id, instance_id, reported_by, reason)
  select s.duo_id, v_inst.session_id, p_instance, v_uid,
         coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Sortie de sécurité')
  from public.sessions s where s.id = v_inst.session_id;

  -- Si le jeu avait été mis en pause par retrait de consentement, on le relance.
  update public.sessions set state = 'active'
   where id = v_inst.session_id and state = 'paused';

  return public.get_session_snapshot(v_inst.session_id);
end;
$$;

-- =============================================================================
-- QUESTIONS PERSONNALISÉES (§9)
-- =============================================================================
create or replace function public.add_custom_question(
  p_session uuid,
  p_body text,
  p_category public.question_category default 'personnalite'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_state public.session_state;
begin
  perform public.assert_session_member(p_session);

  select state into v_state from public.sessions where id = p_session;
  if v_state not in ('ready', 'active', 'paused') then
    raise exception 'SESSION_NOT_EDITABLE';
  end if;

  if char_length(v_body) < 5 then raise exception 'QUESTION_TOO_SHORT'; end if;

  -- Validation serveur minimale (§9) : pas de contenu coercitif évident.
  if v_body ~* '(photo|nue|nus|photo intime|menace|sinon je)' then
    raise exception 'QUESTION_NOT_ALLOWED';
  end if;

  insert into public.session_custom_questions (session_id, created_by, category, body)
  values (p_session, v_uid, p_category, v_body);

  return public.get_session_snapshot(p_session);
end;
$$;

-- =============================================================================
-- CHAT PRIVÉ (§11)
-- Ne modifie JAMAIS l'état du jeu (§19).
-- =============================================================================
create or replace function public.send_message(
  p_duo uuid,
  p_body text,
  p_session uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_recent int;
  v_msg  public.messages;
begin
  perform public.assert_duo_member(p_duo);

  if v_body = '' then raise exception 'EMPTY_MESSAGE'; end if;
  if char_length(v_body) > 2000 then raise exception 'MESSAGE_TOO_LONG'; end if;

  -- Limite anti-spam simple (§16.8).
  select count(*) into v_recent
  from public.messages
  where sender_id = v_uid and created_at > now() - interval '1 minute';
  if v_recent >= 30 then raise exception 'RATE_LIMITED'; end if;

  if p_session is not null and not exists (
    select 1 from public.sessions where id = p_session and duo_id = p_duo
  ) then
    p_session := null;
  end if;

  insert into public.messages (duo_id, session_id, sender_id, body)
  values (p_duo, p_session, v_uid, v_body)
  returning * into v_msg;

  return to_jsonb(v_msg);
end;
$$;

-- =============================================================================
-- SNAPSHOT COMPLET DE SESSION (§20, §21 : reprise après reconnexion)
-- =============================================================================
create or replace function public.get_session_snapshot(p_session uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_duo   uuid;
  v_sess  public.sessions;
  v_inst  public.session_question_instances;
  v_turn  public.question_turns;
  v_body  text;
  v_intimate boolean;
begin
  perform public.assert_session_member(p_session);

  select * into v_sess from public.sessions where id = p_session;
  v_duo := v_sess.duo_id;

  select count(*) = 2 into v_intimate
  from public.session_consents
  where session_id = p_session and is_adult and allow_intimate;

  -- Tour courant = tour non clos le plus récent.
  select i.* into v_inst
  from public.session_question_instances i
  join public.question_turns t on t.instance_id = i.id
  where i.session_id = p_session and t.state in ('awaiting_answer', 'awaiting_validation', 'clarification')
  order by i.created_at desc
  limit 1;

  if v_inst.id is not null then
    select * into v_turn from public.question_turns where instance_id = v_inst.id;
    v_body := coalesce(
      (select q.body from public.questions q where q.id = v_inst.question_id),
      (select cq.body from public.session_custom_questions cq where cq.id = v_inst.custom_question_id),
      ''
    );
  end if;

  return jsonb_build_object(
    'session', to_jsonb(v_sess),
    'duo', (select jsonb_build_object('id', d.id, 'name', d.name) from public.duos d where d.id = v_duo),
    'intimate_enabled', coalesce(v_intimate, false),
    'next_asker_id', public.next_asker_id(p_session),
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'player_id', dm.player_id,
        'pseudo', coalesce(p.pseudo, 'Anonyme'),
        'role', dm.role,
        'present', exists (
          select 1 from public.session_participants sp
          where sp.session_id = p_session and sp.player_id = dm.player_id
        )
      ) order by dm.joined_at), '[]'::jsonb)
      from public.duo_members dm
      left join public.players p on p.id = dm.player_id
      where dm.duo_id = v_duo
    ),
    'consents', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'player_id', sc.player_id,
        'is_adult', sc.is_adult,
        'allow_intimate', sc.allow_intimate
      )), '[]'::jsonb)
      from public.session_consents sc where sc.session_id = p_session
    ),
    'turn', case when v_inst.id is null then null else jsonb_build_object(
      'instance_id', v_inst.id,
      'category', v_inst.category,
      'kind', v_inst.kind,
      'question', v_body,
      'asker_id', v_inst.asker_id,
      'answerer_id', v_inst.answerer_id,
      'state', v_turn.state,
      'answers', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', a.id,
          'author_id', a.author_id,
          'body', a.body,
          'is_clarification', a.is_clarification,
          'created_at', a.created_at
        ) order by a.created_at), '[]'::jsonb)
        from public.question_answers a where a.instance_id = v_inst.id
      )
    ) end,
    'remaining_by_category', (
      select coalesce(jsonb_object_agg(cat, cnt), '{}'::jsonb)
      from (
        select c.cat::text as cat,
               (select count(*) from public.questions q
                  where q.category = c.cat and q.is_active
                    and not exists (
                      select 1 from public.duo_used_questions u
                      where u.duo_id = v_duo and u.question_id = q.id)) as cnt
        from (values
          ('brise_glace'::public.question_category),
          ('personnalite'::public.question_category),
          ('amour'::public.question_category),
          ('secrets'::public.question_category),
          ('pimente'::public.question_category),
          ('tres_intime'::public.question_category),
          ('avenir'::public.question_category)
        ) as c(cat)
      ) counts
    )
  );
end;
$$;

-- =============================================================================
-- SUPPRESSION COMPLÈTE D'UN DUO (§15.3)
-- =============================================================================
create or replace function public.delete_duo(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_duo_member(p_duo);
  if not public.is_duo_owner(p_duo) then raise exception 'NOT_OWNER'; end if;

  -- ON DELETE CASCADE propage la suppression à tout le contenu privé
  -- (sessions, réponses, messages, consentements, historique, signalements).
  delete from public.duos where id = p_duo;

  return jsonb_build_object('deleted', true);
end;
$$;

-- =============================================================================
-- Droits d'exécution : uniquement les utilisateurs authentifiés.
-- =============================================================================
do $$
declare f record;
begin
  for f in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'create_duo','join_duo','get_my_duos','get_duo_invite','rotate_invite',
        'revoke_invite','create_session','join_session','start_session',
        'pause_session','resume_session','end_session','set_consent',
        'draw_question','submit_answer','validate_answer','abandon_instance',
        'add_custom_question','send_message','get_session_snapshot','delete_duo'
      )
  loop
    execute format('revoke all on function public.%I(%s) from public, anon', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.args);
  end loop;
end;
$$;

-- ############################################################################
-- ##  migrations/0004_seed_questions.sql
-- ############################################################################

-- =============================================================================
-- Entre Nous — 0004_seed_questions.sql
-- Catalogue initial (§5). Rédaction respectueuse, sans contenu coercitif,
-- sans demande de photo intime, sans menace ni humiliation (§5).
-- Les codes sont stables : une question ne change jamais d'identifiant (§8.1).
-- =============================================================================

insert into public.questions (code, category, body) values

-- Brise-glace
('bg-001', 'brise_glace', 'Quel est le meilleur compliment qu''on t''ait fait ?'),
('bg-002', 'brise_glace', 'Si tu pouvais prendre un café avec n''importe qui, qui choisirais-tu et pourquoi ?'),
('bg-003', 'brise_glace', 'Quelle est la première chose qui t''a donné envie d''échanger avec moi ?'),
('bg-004', 'brise_glace', 'Quel souvenir d''enfance te fait sourire instantanément ?'),
('bg-005', 'brise_glace', 'Quelle chanson te met toujours de bonne humeur ?'),
('bg-006', 'brise_glace', 'Quel est ton plaisir simple du quotidien ?'),
('bg-007', 'brise_glace', 'Si ta journée pouvait recommencer, que changerais-tu ?'),
('bg-008', 'brise_glace', 'Qu''est-ce qui te fait rire même quand tu n''as pas envie de rire ?'),

-- Personnalité et habitudes
('ph-001', 'personnalite', 'Te décrirais-tu plutôt comme quelqu''un de spontané ou de réfléchi ?'),
('ph-002', 'personnalite', 'Comment se passe une journée parfaite pour toi, du réveil au coucher ?'),
('ph-003', 'personnalite', 'Quelle habitude aimerais-tu avoir et quelle habitude voudrais-tu perdre ?'),
('ph-004', 'personnalite', 'Quand tu es stressé, qu''est-ce qui t''aide le plus ?'),
('ph-005', 'personnalite', 'Préfères-tu être seul pour recharger ou entouré de monde ?'),
('ph-006', 'personnalite', 'Quelle est ta plus grande qualité, selon toi ?'),
('ph-007', 'personnalite', 'Sur quel sujet as-tu des convictions très fortes ?'),
('ph-008', 'personnalite', 'Qu''est-ce qui te met en colère chez les autres, mais que tu t''autorises parfois ?'),

-- Amour et séduction
('as-001', 'amour', 'Qu''est-ce qui te fait te sentir réellement aimé ?'),
('as-002', 'amour', 'Décris ce que tu trouves séduisant chez quelqu''un.'),
('as-003', 'amour', 'Quel est ton « langage de l''amour » : paroles, gestes, temps, cadeaux ou contact ?'),
('as-004', 'amour', 'Quelle est la chose la plus romantique qu''on ait faite pour toi, ou que tu aies faite ?'),
('as-005', 'amour', 'Qu''est-ce qui te fait te sentir en sécurité dans une relation ?'),
('as-006', 'amour', 'Quelles attentions du quotidien comptent le plus pour toi ?'),
('as-007', 'amour', 'Sur quoi as-tu besoin d''être rassuré(e) ?'),
('as-008', 'amour', 'Quel moment simple aimerais-tu partager plus souvent avec moi ?'),

-- Secrets et confidences
('sc-001', 'secrets', 'Quel rêve n''as-tu jamais osé dire à voix haute ?'),
('sc-002', 'secrets', 'Quelle erreur du passé t''a le plus appris ?'),
('sc-003', 'secrets', 'Quel est un secret pas très glorieux que tu peux confier sans risque ?'),
('sc-004', 'secrets', 'De quoi as-tu le plus peur en ce moment ?'),
('sc-005', 'secrets', 'Qu''est-ce que tu n''as jamais dit à personne et que tu aimerais déposer ici ?'),
('sc-006', 'secrets', 'Quelle période de ta vie a été la plus difficile, et qu''en as-tu gardé ?'),
('sc-007', 'secrets', 'Qu''est-ce qui te rend vulnérable et que tu caches souvent ?'),
('sc-008', 'secrets', 'Quelle confidence changerait quelque chose entre nous, selon toi ?'),

-- Pimenté
('pi-001', 'pimente', 'Qu''est-ce qui t''attire physiquement chez moi ?'),
('pi-002', 'pimente', 'Quel compliment un peu osé aimerais-tu me faire maintenant ?'),
('pi-003', 'pimente', 'Qu''est-ce qui crée la tension, pour toi, entre deux personnes ?'),
('pi-004', 'pimente', 'Où aimerais-tu qu''on se retrouve, juste nous deux, sans contrainte ?'),
('pi-005', 'pimente', 'Quel geste tendre et audacieux te ferait sourire instantanément ?'),
('pi-006', 'pimente', 'Qu''est-ce que tu trouves irrésistible quand je le fais ?'),
('pi-007', 'pimente', 'Quel moment à deux voudrais-tu prolonger sans fin ?'),
('pi-008', 'pimente', 'Qu''est-ce qui te plaît dans le fait d''être désiré(e) ?'),

-- Très intime — 18+ (rédaction respectueuse, consentement requis)
('ti-001', 'tres_intime', 'Comment aimes-tu que l''on te parle dans un moment d''intimité ?'),
('ti-002', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté(e) et en confiance lors d''un moment intime ?'),
('ti-003', 'tres_intime', 'Comment exprimes-tu, ou vérifies-tu, que l''autre est d''accord ?'),
('ti-004', 'tres_intime', 'Quelles attentions font que tu te sens vraiment désiré(e) ?'),
('ti-005', 'tres_intime', 'Y a-t-il une limite que tu aimerais que l''on clarifie entre nous ?'),
('ti-006', 'tres_intime', 'Qu''est-ce qui, selon toi, rend un moment intime vraiment réussi ?'),
('ti-007', 'tres_intime', 'Comment aimes-tu prendre soin de l''autre après un moment intime ?'),
('ti-008', 'tres_intime', 'Qu''aimerais-tu que l''on explore, uniquement si nous sommes tous les deux d''accord ?'),

-- Avenir et relations
('av-001', 'avenir', 'Qu''aimerais-tu que notre relation soit devenue dans un an ?'),
('av-002', 'avenir', 'Quelles sont tes limites non négociables dans une relation ?'),
('av-003', 'avenir', 'Comment vois-tu une relation saine au quotidien ?'),
('av-004', 'avenir', 'Qu''aimerais-tu qu''on décide ensemble, et pas chacun de son côté ?'),
('av-005', 'avenir', 'Qu''est-ce qui te ferait dire que notre duo a réussi ?'),
('av-006', 'avenir', 'Quel projet aimerais-tu qu''on envisage sérieusement ?'),
('av-007', 'avenir', 'Comment gères-tu les désaccords, et que souhaites-tu de moi dans ces moments ?'),
('av-008', 'avenir', 'Quelle promesse simple pourrais-tu me faire et tenir ?')

on conflict (code) do nothing;

-- ############################################################################
-- ##  migrations/0006_seed_catalog.sql
-- ############################################################################

-- =============================================================================
-- Entre Nous — 0006_seed_catalog.sql
-- Catalogue étendu (§5). Rédaction respectueuse : sans contenu coercitif,
-- sans demande de photo intime, sans menace ni humiliation (§5, §9).
-- Objectif : 300+ questions par catégorie. Rejouable (on conflict do nothing).
-- Total : 2235 questions.
-- GÉNÉRÉ par supabase/tools/build_catalog.py — ne pas éditer à la main.
-- =============================================================================

-- Brise-glace (379 questions)
insert into public.questions (code, category, body) values
  ('bg-101', 'brise_glace', 'Quelle petite chose t''a rendu heureux aujourd''hui ?'),
  ('bg-102', 'brise_glace', 'Quel est ton rituel du matin préféré ?'),
  ('bg-103', 'brise_glace', 'Si tu avais une journée entière sans obligations, tu ferais quoi ?'),
  ('bg-104', 'brise_glace', 'Quel film pourrais-tu revoir sans jamais t''en lasser ?'),
  ('bg-105', 'brise_glace', 'Quelle est la dernière chose qui t''a fait rire aux éclats ?'),
  ('bg-106', 'brise_glace', 'Quel animal te ressemble le plus, et pourquoi ?'),
  ('bg-107', 'brise_glace', 'Quelle odeur te ramène instantanément en enfance ?'),
  ('bg-108', 'brise_glace', 'Quel est ton péché mignon côté nourriture ?'),
  ('bg-109', 'brise_glace', 'Si tu pouvais vivre dans un pays demain, lequel choisirais-tu ?'),
  ('bg-110', 'brise_glace', 'Quelle chanson fredonnes-tu sans t''en rendre compte ?'),
  ('bg-111', 'brise_glace', 'Quel talent aimerais-tu maîtriser en un claquement de doigts ?'),
  ('bg-112', 'brise_glace', 'Quel est le meilleur conseil qu''on t''ait donné ?'),
  ('bg-113', 'brise_glace', 'Quel objet ne quitte jamais ton sac ou tes poches ?'),
  ('bg-114', 'brise_glace', 'Quel jeu d''enfance te manque encore aujourd''hui ?'),
  ('bg-115', 'brise_glace', 'Si tu écrivais un livre, ce serait sur quoi ?'),
  ('bg-116', 'brise_glace', 'Quelle saison te met de meilleure humeur ?'),
  ('bg-117', 'brise_glace', 'Quel est ton endroit préféré pour te détendre ?'),
  ('bg-118', 'brise_glace', 'Quelle appli utilises-tu plus que tu ne devrais ?'),
  ('bg-119', 'brise_glace', 'Quel est ton plus vieux souvenir ?'),
  ('bg-120', 'brise_glace', 'Quel compliment te gêne autant qu''il te fait plaisir ?'),
  ('bg-121', 'brise_glace', 'Quelle mauvaise habitude assumes-tu totalement ?'),
  ('bg-122', 'brise_glace', 'Quel est ton petit-déjeuner parfait ?'),
  ('bg-123', 'brise_glace', 'Quelle ville rêves-tu de visiter au moins une fois ?'),
  ('bg-124', 'brise_glace', 'Quel super-pouvoir choisirais-tu, et pourquoi celui-là ?'),
  ('bg-125', 'brise_glace', 'Quel est le surnom qu''on te donne ou que tu aimerais qu''on te donne ?'),
  ('bg-126', 'brise_glace', 'Quelle série t''a le plus marqué récemment ?'),
  ('bg-127', 'brise_glace', 'Quel est ton moyen de transport préféré ?'),
  ('bg-128', 'brise_glace', 'Quel bruit te dérange le plus ?'),
  ('bg-129', 'brise_glace', 'Quelle est la chose la plus spontanée que tu aies faite ?'),
  ('bg-130', 'brise_glace', 'Quel dessert te fait craquer à tous les coups ?'),
  ('bg-131', 'brise_glace', 'Quel est ton jour de la semaine préféré ?'),
  ('bg-132', 'brise_glace', 'Si tu pouvais changer un souvenir, lequel serait-ce ?'),
  ('bg-133', 'brise_glace', 'Quelle compétence inutile maîtrises-tu parfaitement ?'),
  ('bg-134', 'brise_glace', 'Quel est ton plaisir coupable télévisuel ?'),
  ('bg-135', 'brise_glace', 'Quelle boisson te réconforte toujours ?'),
  ('bg-136', 'brise_glace', 'Quel est ton premier réflexe en te levant ?'),
  ('bg-137', 'brise_glace', 'Quelle matière à l''école aimais-tu le plus ?'),
  ('bg-138', 'brise_glace', 'Quel est ton plus grand talent caché ?'),
  ('bg-139', 'brise_glace', 'Quel est ton rituel avant de dormir ?'),
  ('bg-140', 'brise_glace', 'Quel paysage te coupe le souffle ?'),
  ('bg-141', 'brise_glace', 'Quel est ton go-to pour décompresser après une dure journée ?'),
  ('bg-142', 'brise_glace', 'Quel type de musique te met de bonne humeur instantanément ?'),
  ('bg-143', 'brise_glace', 'Quelle est la chose la plus gentille qu''un inconnu ait faite pour toi ?'),
  ('bg-144', 'brise_glace', 'Quel est ton jeu de société favori ?'),
  ('bg-145', 'brise_glace', 'Quel emoji te représente le mieux ?'),
  ('bg-146', 'brise_glace', 'Quelle est ta plus grande fierté personnelle ?'),
  ('bg-147', 'brise_glace', 'Quel est ton premier souvenir de vacances ?'),
  ('bg-148', 'brise_glace', 'Quel menu commanderais-tu les yeux fermés ?'),
  ('bg-149', 'brise_glace', 'Quelle chose te faisait peur enfant et te fait rire maintenant ?'),
  ('bg-150', 'brise_glace', 'Quel est ton moyen préféré de passer un dimanche ?'),
  ('bg-151', 'brise_glace', 'Quelle est la meilleure maison que tu aies visitée ?'),
  ('bg-152', 'brise_glace', 'Quel est ton petit luxe du quotidien ?'),
  ('bg-153', 'brise_glace', 'Quelle langue aimerais-tu parler couramment ?'),
  ('bg-154', 'brise_glace', 'Quel est ton passe-temps le plus récent ?'),
  ('bg-155', 'brise_glace', 'Quelle est ta madeleine de Proust musicale ?'),
  ('bg-156', 'brise_glace', 'Quel est ton endroit préféré dans ta ville ?'),
  ('bg-157', 'brise_glace', 'Quelle est la dernière chose que tu as apprise ?'),
  ('bg-158', 'brise_glace', 'Quel est ton pic-me-up quand tu es de mauvaise humeur ?'),
  ('bg-159', 'brise_glace', 'Quelle tenue te met le plus en confiance ?'),
  ('bg-160', 'brise_glace', 'Quel est ton film d''enfance culte ?'),
  ('bg-161', 'brise_glace', 'Quelle est la chose la plus bizarre que tu aies mangée ?'),
  ('bg-162', 'brise_glace', 'Quel est ton sport préféré à regarder, et à pratiquer ?'),
  ('bg-163', 'brise_glace', 'Quelle est la première chose que tu regardes chez quelqu''un ?'),
  ('bg-164', 'brise_glace', 'Quel est ton meilleur souvenir de fête ?'),
  ('bg-165', 'brise_glace', 'Quelle est ta plus grande peur irrationnelle ?'),
  ('bg-166', 'brise_glace', 'Quel objet du quotidien te faciliterait la vie en mieux ?'),
  ('bg-167', 'brise_glace', 'Quelle est ta chanson de route préférée ?'),
  ('bg-168', 'brise_glace', 'Quel est ton geste de gentillesse préféré à recevoir ?'),
  ('bg-169', 'brise_glace', 'Quelle époque aurais-tu aimé connaître ?'),
  ('bg-170', 'brise_glace', 'Quel est ton plus beau voyage jusqu''ici ?'),
  ('bg-171', 'brise_glace', 'Quelle est ta boisson chaude préférée ?'),
  ('bg-172', 'brise_glace', 'Quel est ton petit-déj de week-end ?'),
  ('bg-173', 'brise_glace', 'Quelle est la chose la plus drôle que tu aies vue dans la rue ?'),
  ('bg-174', 'brise_glace', 'Quel est ton endroit secret pour être tranquille ?'),
  ('bg-175', 'brise_glace', 'Quelle est ta position préférée pour dormir ?'),
  ('bg-176', 'brise_glace', 'Quel talent d''un ami t''impressionne le plus ?'),
  ('bg-177', 'brise_glace', 'Quel est ton goût de glace préféré ?'),
  ('bg-178', 'brise_glace', 'Quelle est la chose la plus courageuse que tu aies faite ?'),
  ('bg-179', 'brise_glace', 'Quel est ton moyen préféré de dire merci ?'),
  ('bg-180', 'brise_glace', 'Quel est ton souvenir préféré en famille ?'),
  ('bg-181', 'brise_glace', 'Quelle est ta plus grande source de motivation ?'),
  ('bg-182', 'brise_glace', 'Quel est ton meilleur achat des derniers mois ?'),
  ('bg-183', 'brise_glace', 'Quelle chose te fait toujours sourire chez un bébé ?'),
  ('bg-184', 'brise_glace', 'Quel est ton loisir créatif ?'),
  ('bg-185', 'brise_glace', 'Quelle est la première chose que tu ferais si tu gagnais au loto ?'),
  ('bg-186', 'brise_glace', 'Quel est ton moment préféré de la journée ?'),
  ('bg-187', 'brise_glace', 'Quel est le meilleur repas que tu aies mangé au restaurant ?'),
  ('bg-188', 'brise_glace', 'Quelle est ta plus vieille amitié, et comment s''est-elle formée ?'),
  ('bg-189', 'brise_glace', 'Quel est ton mot préféré en français ?'),
  ('bg-190', 'brise_glace', 'Quelle est la chose la plus folle que tu ferais par amour ?'),
  ('bg-191', 'brise_glace', 'Quel est ton meilleur souvenir d''école ?'),
  ('bg-192', 'brise_glace', 'Quel personnage de fiction te ressemble le plus ?'),
  ('bg-193', 'brise_glace', 'Quelle est ta plus grande réussite cette année ?'),
  ('bg-194', 'brise_glace', 'Quel est ton objet fétiche d''enfance ?'),
  ('bg-195', 'brise_glace', 'Quelle est ta phobie du quotidien ?'),
  ('bg-196', 'brise_glace', 'Quel est ton meilleur souvenir de plage ?'),
  ('bg-197', 'brise_glace', 'Quel est ton petit défi personnel actuel ?'),
  ('bg-198', 'brise_glace', 'Quelle est ta série doudou pour dormir ?'),
  ('bg-199', 'brise_glace', 'Quel est le compliment que tu aimerais recevoir plus souvent ?'),
  ('bg-200', 'brise_glace', 'Quelle est la chose la plus spontanée que tu aies dite ?'),
  ('bg-201', 'brise_glace', 'Quel est ton rituel du week-end ?'),
  ('bg-202', 'brise_glace', 'Quelle est ta chanson de coup de cœur du moment ?'),
  ('bg-203', 'brise_glace', 'Quel est l''endroit où tu te sens le plus toi-même ?'),
  ('bg-204', 'brise_glace', 'Quelle petite victoire t''a rendu fier cette semaine ?'),
  ('bg-205', 'brise_glace', 'Quel est ton accessoire indispensable ?'),
  ('bg-206', 'brise_glace', 'Quelle est ta plus grande qualité selon les autres ?'),
  ('bg-207', 'brise_glace', 'Quel est ton film préféré pour pleurer un bon coup ?'),
  ('bg-208', 'brise_glace', 'Quelle est la première chose que tu fais en rentrant chez toi ?'),
  ('bg-209', 'brise_glace', 'Quel est ton passe-temps d''enfance encore pratiqué ?'),
  ('bg-210', 'brise_glace', 'Quel est ton jeu vidéo préféré de tous les temps ?'),
  ('bg-211', 'brise_glace', 'Quelle est ta façon préférée de recevoir de l''affection ?'),
  ('bg-212', 'brise_glace', 'Quel est ton meilleur souvenir de concert ?'),
  ('bg-213', 'brise_glace', 'Quelle est ta gourmandise préférée ?'),
  ('bg-214', 'brise_glace', 'Quel est ton proverbe ou citation préféré ?'),
  ('bg-215', 'brise_glace', 'Quelle est la chose la plus utile que tu possèdes ?'),
  ('bg-216', 'brise_glace', 'Quel est ton endroit préféré pour lire ou te reposer ?'),
  ('bg-217', 'brise_glace', 'Quelle est ta chanson triste préférée ?'),
  ('bg-218', 'brise_glace', 'Quel est ton meilleur souvenir de colonie ou de camp ?'),
  ('bg-219', 'brise_glace', 'Quelle est ta plus grande source de fierté ?'),
  ('bg-220', 'brise_glace', 'Quel est ton plat signature à cuisiner ?'),
  ('bg-221', 'brise_glace', 'Quelle est ta plus drôle de maladresse ?'),
  ('bg-222', 'brise_glace', 'Quel est ton format de vacances idéal ?'),
  ('bg-223', 'brise_glace', 'Quelle est la chose qui te stresse le plus au quotidien ?'),
  ('bg-224', 'brise_glace', 'Quel est ton meilleur film policier ?'),
  ('bg-225', 'brise_glace', 'Quelle est ta façon préférée de passer une soirée pluvieuse ?'),
  ('bg-226', 'brise_glace', 'Quel est ton pseudo en ligne préféré, passé ou présent ?'),
  ('bg-227', 'brise_glace', 'Quelle est ta marchandise préférée dans une boulangerie ?'),
  ('bg-228', 'brise_glace', 'Quel est ton premier réflexe au réveil ?'),
  ('bg-229', 'brise_glace', 'Quelle est la chose la plus mignonne que tu aies vue ?'),
  ('bg-230', 'brise_glace', 'Quel est ton souvenir de rentrée scolaire le plus marquant ?'),
  ('bg-231', 'brise_glace', 'Quelle est ta chanson de karaoké ?'),
  ('bg-232', 'brise_glace', 'Quel est ton meilleur tour de magie ?'),
  ('bg-233', 'brise_glace', 'Quelle est la chose que tu admires chez les autres ?'),
  ('bg-234', 'brise_glace', 'Quel est ton plus grand fou rire ?'),
  ('bg-235', 'brise_glace', 'Quelle est ta série à conseiller absolument ?'),
  ('bg-236', 'brise_glace', 'Quel est ton dessert de fête ?'),
  ('bg-237', 'brise_glace', 'Quelle est la chose la plus spontanée que tu aies organisée ?'),
  ('bg-238', 'brise_glace', 'Quel est ton endroit préféré pour regarder le coucher du soleil ?'),
  ('bg-239', 'brise_glace', 'Quelle est ta chaussette préférée, et pourquoi celle-là ?'),
  ('bg-240', 'brise_glace', 'Quel est ton meilleur souvenir de Noël ?'),
  ('bg-241', 'brise_glace', 'Quelle est ta plus grande source d''énergie ?'),
  ('bg-242', 'brise_glace', 'Quel est ton goûter préféré ?'),
  ('bg-243', 'brise_glace', 'Quelle est la chose qui t''émerveille encore aujourd''hui ?'),
  ('bg-244', 'brise_glace', 'Quel est ton meilleur souvenir de voyage à deux ?'),
  ('bg-245', 'brise_glace', 'Quelle est ta façon préférée de célébrer une réussite ?'),
  ('bg-246', 'brise_glace', 'Quel est ton matériel ou gadget préféré ?'),
  ('bg-247', 'brise_glace', 'Quelle est ta chanson à danser dans le salon ?'),
  ('bg-248', 'brise_glace', 'Quel est ton plus grand talent culinaire ?'),
  ('bg-249', 'brise_glace', 'Quelle est ta promenade préférée ?'),
  ('bg-250', 'brise_glace', 'Quel est ton meilleur souvenir de pique-nique ?'),
  ('bg-251', 'brise_glace', 'Quel est ton surnom d''enfance ?'),
  ('bg-252', 'brise_glace', 'Quelle est la chose la plus amusante que tu aies faite au travail ?'),
  ('bg-253', 'brise_glace', 'Quel est ton goût préféré de thé ?'),
  ('bg-254', 'brise_glace', 'Quelle est ta plus belle surprise reçue ?'),
  ('bg-255', 'brise_glace', 'Quel est ton rituel pour te détendre le soir ?'),
  ('bg-256', 'brise_glace', 'Quelle est ta chanson préférée pour les trajets en voiture ?'),
  ('bg-257', 'brise_glace', 'Quel est ton meilleur souvenir d''un repas entre amis ?'),
  ('bg-258', 'brise_glace', 'Quelle est la chose qui te fait te sentir chez toi ?'),
  ('bg-259', 'brise_glace', 'Quel est ton héros ou modèle d''enfance ?'),
  ('bg-260', 'brise_glace', 'Quelle est ta plus grande pudeur, ou fierté, en public ?'),
  ('bg-261', 'brise_glace', 'Quel est ton animal préféré, et pourquoi ?'),
  ('bg-262', 'brise_glace', 'Quelle est ta façon préférée de dire « je t''aime » ?'),
  ('bg-263', 'brise_glace', 'Quel est ton meilleur souvenir de cours de récré ?'),
  ('bg-264', 'brise_glace', 'Quel est ton jeu de cartes préféré ?'),
  ('bg-265', 'brise_glace', 'Quelle est la chose la plus gentille que tu aies faite pour quelqu''un ?'),
  ('bg-266', 'brise_glace', 'Quel est ton endroit préféré pour un premier rendez-vous ?'),
  ('bg-267', 'brise_glace', 'Quelle est ta boisson de soirée préférée ?'),
  ('bg-268', 'brise_glace', 'Quel est ton meilleur souvenir de saison des pluies ?'),
  ('bg-269', 'brise_glace', 'Quelle est la chose que tu trouves injustement sous-estimée ?'),
  ('bg-270', 'brise_glace', 'Quel est ton fruit préféré ?'),
  ('bg-271', 'brise_glace', 'Quelle est ta façon préférée de te réveiller en douceur ?'),
  ('bg-272', 'brise_glace', 'Quel est ton plus beau paysage nocturne ?'),
  ('bg-273', 'brise_glace', 'Quelle est ta chanson de fin de soirée ?'),
  ('bg-274', 'brise_glace', 'Quel est ton meilleur souvenir de terrasse en été ?'),
  ('bg-275', 'brise_glace', 'Quelle est la chose qui te fait toujours rire dans les comédies ?'),
  ('bg-276', 'brise_glace', 'Quel est ton légume préféré ?'),
  ('bg-277', 'brise_glace', 'Quelle est ta façon préférée de passer un jour férié ?'),
  ('bg-278', 'brise_glace', 'Quel est ton meilleur souvenir de camping ?'),
  ('bg-279', 'brise_glace', 'Quelle est la chose la plus utile que tu aies apprise de tes parents ?'),
  ('bg-280', 'brise_glace', 'Quel est ton fromage préféré ?'),
  ('bg-281', 'brise_glace', 'Quelle est ta chanson de motivation ?'),
  ('bg-282', 'brise_glace', 'Quel est ton meilleur souvenir de cours de sport ?'),
  ('bg-283', 'brise_glace', 'Quelle est la chose qui te détend instantanément ?'),
  ('bg-284', 'brise_glace', 'Quel est ton objet préféré sur ton bureau ?'),
  ('bg-285', 'brise_glace', 'Quelle est ta façon préférée de prendre soin de toi ?'),
  ('bg-286', 'brise_glace', 'Quel est ton meilleur souvenir de spectacle vivant ?'),
  ('bg-287', 'brise_glace', 'Quelle est la chose la plus drôle que tu aies dite sans le vouloir ?'),
  ('bg-288', 'brise_glace', 'Quel est ton snack préféré devant un film ?'),
  ('bg-289', 'brise_glace', 'Quelle est ta façon préférée de passer le temps dans les transports ?'),
  ('bg-290', 'brise_glace', 'Quel est ton meilleur souvenir de première fois (dans n''importe quel domaine) ?'),
  ('bg-291', 'brise_glace', 'Quelle est la chose qui te motive à te lever le matin ?'),
  ('bg-292', 'brise_glace', 'Quel est ton parfum ou senteur préféré ?'),
  ('bg-293', 'brise_glace', 'Quelle est ta façon préférée de décorer ta chambre ?'),
  ('bg-294', 'brise_glace', 'Quel est ton meilleur souvenir de piscine ou de mer ?'),
  ('bg-295', 'brise_glace', 'Quelle est la chose la plus spontanée que tu aies achetée ?'),
  ('bg-296', 'brise_glace', 'Quel est ton magazine ou site préféré ?'),
  ('bg-297', 'brise_glace', 'Quelle est ta façon préférée de dire pardon ?'),
  ('bg-298', 'brise_glace', 'Quel est ton meilleur souvenir de Noël en famille ?'),
  ('bg-299', 'brise_glace', 'Quelle est la chose qui te fait te sentir courageux ?'),
  ('bg-300', 'brise_glace', 'Quel est ton jeu de plein air préféré ?'),
  ('bg-301', 'brise_glace', 'Quelle est ta plus belle découverte musicale récente ?'),
  ('bg-302', 'brise_glace', 'Quel est ton meilleur souvenir de fête foraine ?'),
  ('bg-303', 'brise_glace', 'Quelle est la chose la plus précieuse que tu possèdes ?'),
  ('bg-304', 'brise_glace', 'Quel est ton repas de réconfort ?'),
  ('bg-305', 'brise_glace', 'Quelle est ta façon préférée de passer un anniversaire ?'),
  ('bg-306', 'brise_glace', 'Quel est ton meilleur souvenir de lac ou de rivière ?'),
  ('bg-307', 'brise_glace', 'Quelle est la chose qui te fait rire chez les animaux ?'),
  ('bg-308', 'brise_glace', 'Quel est ton smoothie ou jus préféré ?'),
  ('bg-309', 'brise_glace', 'Quelle est ta façon préférée de te relaxer devant un écran ?'),
  ('bg-310', 'brise_glace', 'Quel est ton meilleur souvenir de voyage scolaire ?'),
  ('bg-311', 'brise_glace', 'Quelle est la chose la plus touchante qu''on t''ait dite ?'),
  ('bg-312', 'brise_glace', 'Quel est ton accessoire de mode préféré ?'),
  ('bg-313', 'brise_glace', 'Quelle est ta façon préférée de rendre service ?'),
  ('bg-314', 'brise_glace', 'Quel est ton meilleur souvenir de bibliothèque ou de librairie ?'),
  ('bg-315', 'brise_glace', 'Quelle est la chose qui te fait te sentir chanceux ?'),
  ('bg-316', 'brise_glace', 'Quel est ton goûter d''enfance préféré ?'),
  ('bg-317', 'brise_glace', 'Quelle est ta façon préférée de commencer une conversation ?'),
  ('bg-318', 'brise_glace', 'Quel est ton meilleur souvenir de rue ou de quartier ?'),
  ('bg-319', 'brise_glace', 'Quelle est la chose la plus drôle que tu aies vue en voyage ?'),
  ('bg-320', 'brise_glace', 'Quel est ton souvenir de pluie le plus marquant ?'),
  ('bg-321', 'brise_glace', 'Quelle est la chose qui te fait toujours relativiser ?'),
  ('bg-322', 'brise_glace', 'Quel est ton plat de fête préféré ?'),
  ('bg-323', 'brise_glace', 'Quelle est ta façon préférée d''aider un ami ?'),
  ('bg-324', 'brise_glace', 'Quel est ton meilleur souvenir de cours de dessin ?'),
  ('bg-325', 'brise_glace', 'Quelle est la chose que tu aimerais recommencer ?'),
  ('bg-326', 'brise_glace', 'Quel est ton bonbon préféré ?'),
  ('bg-327', 'brise_glace', 'Quelle est ta façon préférée de passer une matinée libre ?'),
  ('bg-328', 'brise_glace', 'Quel est ton meilleur souvenir de correspondance écrite ?'),
  ('bg-329', 'brise_glace', 'Quelle est la chose qui te fait sourire dans les vieilles photos ?'),
  ('bg-330', 'brise_glace', 'Quel est ton thé ou infusion de soirée préféré ?'),
  ('bg-331', 'brise_glace', 'Quelle est ta façon préférée de dire bonjour ?'),
  ('bg-332', 'brise_glace', 'Quel est ton meilleur souvenir de cours de musique ?'),
  ('bg-333', 'brise_glace', 'Quelle est la chose la plus mignonne que tu aies reçue ?'),
  ('bg-334', 'brise_glace', 'Quel est ton biscuit préféré ?'),
  ('bg-335', 'brise_glace', 'Quelle est ta façon préférée de t''endormir ?'),
  ('bg-336', 'brise_glace', 'Quel est ton meilleur souvenir de marché ?'),
  ('bg-337', 'brise_glace', 'Quelle est la chose qui te fait te sentir en sécurité ?'),
  ('bg-338', 'brise_glace', 'Quel est ton plat préféré à partager ?'),
  ('bg-339', 'brise_glace', 'Quelle est ta façon préférée de fêter un petit succès ?'),
  ('bg-340', 'brise_glace', 'Quel est ton meilleur souvenir de parc ?'),
  ('bg-341', 'brise_glace', 'Quelle est la chose la plus simple qui t''apaise ?'),
  ('bg-342', 'brise_glace', 'Quel est ton sorbet préféré ?'),
  ('bg-343', 'brise_glace', 'Quelle est ta façon préférée de te faire plaisir sans culpabiliser ?'),
  ('bg-344', 'brise_glace', 'Quel est ton meilleur souvenir de kermesse ?'),
  ('bg-345', 'brise_glace', 'Quelle est la chose qui te fait rire en famille ?'),
  ('bg-346', 'brise_glace', 'Quel est ton grignotage préféré ?'),
  ('bg-347', 'brise_glace', 'Quelle est ta façon préférée de passer la Saint-Sylvestre ?'),
  ('bg-348', 'brise_glace', 'Quel est ton meilleur souvenir de feu d''artifice ?'),
  ('bg-349', 'brise_glace', 'Quelle est la chose qui te fait te sentir fier de toi ?'),
  ('bg-350', 'brise_glace', 'Quel est ton fromage ou fruit de mer préféré ?'),
  ('bg-351', 'brise_glace', 'Quelle est ta façon préférée de t''excuser ?'),
  ('bg-352', 'brise_glace', 'Quel est ton meilleur souvenir de neige ?'),
  ('bg-353', 'brise_glace', 'Quelle est la chose la plus spontanée que tu aies cuisinée ?'),
  ('bg-354', 'brise_glace', 'Quel est ton thé glacé ou limonade préféré ?'),
  ('bg-355', 'brise_glace', 'Quelle est ta façon préférée de passer un après-midi pluvieux ?'),
  ('bg-356', 'brise_glace', 'Quel est ton meilleur souvenir de chemin de fer ?'),
  ('bg-357', 'brise_glace', 'Quelle est la chose qui te fait toujours sourire dans les vidéos d''animaux ?'),
  ('bg-358', 'brise_glace', 'Quel est ton fruit sec préféré ?'),
  ('bg-359', 'brise_glace', 'Quelle est ta façon préférée de te faire consoler ?'),
  ('bg-360', 'brise_glace', 'Quel est ton meilleur souvenir de fête de village ?'),
  ('bg-361', 'brise_glace', 'Quelle est la chose la plus douce qu''on t''ait dite ?'),
  ('bg-362', 'brise_glace', 'Quel est ton en-cas de route préféré ?'),
  ('bg-363', 'brise_glace', 'Quelle est ta façon préférée de te récompenser ?'),
  ('bg-364', 'brise_glace', 'Quel est ton meilleur souvenir de foire au livre ?'),
  ('bg-365', 'brise_glace', 'Quelle est la chose qui te fait te sentir vivant ?'),
  ('bg-366', 'brise_glace', 'Quel est ton plat d''hiver préféré ?'),
  ('bg-367', 'brise_glace', 'Quelle est ta façon préférée de passer un long trajet ?'),
  ('bg-368', 'brise_glace', 'Quel est ton meilleur souvenir de plage au coucher du soleil ?'),
  ('bg-369', 'brise_glace', 'Quelle est la chose la plus drôle que tu aies apprise récemment ?'),
  ('bg-370', 'brise_glace', 'Quel est ton chocolat préféré ?'),
  ('bg-371', 'brise_glace', 'Quelle est ta façon préférée de t''organiser ?'),
  ('bg-372', 'brise_glace', 'Quel est ton meilleur souvenir de cabane ou de tente ?'),
  ('bg-373', 'brise_glace', 'Quelle est la chose qui te fait te sentir aimé ?'),
  ('bg-374', 'brise_glace', 'Quel est ton thé préféré l''après-midi ?'),
  ('bg-375', 'brise_glace', 'Quelle est ta façon préférée de prendre une pause ?'),
  ('bg-376', 'brise_glace', 'Quel est ton meilleur souvenir de jardin ?'),
  ('bg-377', 'brise_glace', 'Quelle est la chose la plus apaisante que tu aies entendue ?'),
  ('bg-378', 'brise_glace', 'Quel est ton petit-déj salé préféré ?'),
  ('bg-379', 'brise_glace', 'Quelle est ta façon préférée de faire plaisir ?'),
  ('bg-380', 'brise_glace', 'Quel est ton meilleur souvenir de randonnée ?'),
  ('bg-381', 'brise_glace', 'Quelle est la chose qui te fait toujours rire dans ta famille ?'),
  ('bg-382', 'brise_glace', 'Quel est ton dessert d''été préféré ?'),
  ('bg-383', 'brise_glace', 'Quelle est ta façon préférée de te concentrer ?'),
  ('bg-384', 'brise_glace', 'Quel est ton meilleur souvenir de pique-nique improvisé ?'),
  ('bg-385', 'brise_glace', 'Quelle est la chose la plus rafraîchissante que tu aies bue ?'),
  ('bg-386', 'brise_glace', 'Quel est ton plat d''été préféré ?'),
  ('bg-387', 'brise_glace', 'Quelle est ta façon préférée de créer une ambiance ?'),
  ('bg-388', 'brise_glace', 'Quel est ton meilleur souvenir de pluie d''été ?'),
  ('bg-389', 'brise_glace', 'Quelle est la chose qui te fait te sentir libre ?'),
  ('bg-390', 'brise_glace', 'Quel est ton gâteau préféré ?'),
  ('bg-391', 'brise_glace', 'Quelle est ta façon préférée de te faire de nouveaux amis ?'),
  ('bg-392', 'brise_glace', 'Quel est ton meilleur souvenir de voyage en solo ?'),
  ('bg-393', 'brise_glace', 'Quelle est la chose la plus douce que tu aies touchée ?'),
  ('bg-394', 'brise_glace', 'Quel est ton plat réconfort d''enfance ?'),
  ('bg-395', 'brise_glace', 'Quelle est ta façon préférée de passer une journée grise ?'),
  ('bg-396', 'brise_glace', 'Quel est ton meilleur souvenir de soirée jeux ?'),
  ('bg-397', 'brise_glace', 'Quelle est la chose qui te fait te sentir utile ?'),
  ('bg-398', 'brise_glace', 'Quel est ton jus de fruit préféré ?'),
  ('bg-399', 'brise_glace', 'Quelle est ta façon préférée de te changer les idées ?'),
  ('bg-400', 'brise_glace', 'Quel est ton meilleur souvenir de vacances à la montagne ?'),
  ('bg-401', 'brise_glace', 'Quelle est la chose la plus amusante que tu aies apprise en voyage ?'),
  ('bg-402', 'brise_glace', 'Quel est ton pain ou viennoiserie préférée ?'),
  ('bg-403', 'brise_glace', 'Quelle est ta façon préférée de célébrer l''amitié ?'),
  ('bg-404', 'brise_glace', 'Quel est ton meilleur souvenir de cinéma ?'),
  ('bg-405', 'brise_glace', 'Quelle est la chose qui te fait te sentir chez toi partout ?'),
  ('bg-406', 'brise_glace', 'Quel est ton plat à emporter préféré ?'),
  ('bg-407', 'brise_glace', 'Quelle est ta façon préférée de te faire pardonner ?'),
  ('bg-408', 'brise_glace', 'Quel est ton meilleur souvenir de brocante ou de vide-grenier ?'),
  ('bg-409', 'brise_glace', 'Quelle est la chose la plus réconfortante qu''on t''ait offerte ?'),
  ('bg-410', 'brise_glace', 'Quel est ton goûter salé préféré ?'),
  ('bg-411', 'brise_glace', 'Quelle est ta façon préférée de te détendre un dimanche soir ?'),
  ('bg-412', 'brise_glace', 'Quel est ton meilleur souvenir de vacances à la mer ?'),
  ('bg-413', 'brise_glace', 'Quelle est la chose qui te fait te sentir en confiance ?'),
  ('bg-414', 'brise_glace', 'Quel est ton plat du dimanche préféré ?'),
  ('bg-415', 'brise_glace', 'Quelle est ta façon préférée de commencer le week-end ?'),
  ('bg-416', 'brise_glace', 'Quel est ton meilleur souvenir de fête d''anniversaire ?'),
  ('bg-417', 'brise_glace', 'Quelle est la chose la plus drôle que tu aies vue en photo ?'),
  ('bg-418', 'brise_glace', 'Quel est ton thé préféré du matin ?'),
  ('bg-419', 'brise_glace', 'Quelle est ta façon préférée de te sentir bien ?'),
  ('bg-420', 'brise_glace', 'Quel est ton meilleur souvenir de sortie scolaire ?'),
  ('bg-421', 'brise_glace', 'Quelle est la chose qui te fait toujours relativiser un souci ?'),
  ('bg-422', 'brise_glace', 'Quel est ton plat préféré quand il fait froid ?'),
  ('bg-423', 'brise_glace', 'Quelle est ta façon préférée de passer un long week-end ?'),
  ('bg-424', 'brise_glace', 'Quel est ton meilleur souvenir de feu de camp ?'),
  ('bg-425', 'brise_glace', 'Quelle est la chose la plus spontanée que tu aies offerte ?'),
  ('bg-426', 'brise_glace', 'Quel est ton fruit d''été préféré ?'),
  ('bg-427', 'brise_glace', 'Quelle est ta façon préférée de te remonter le moral ?'),
  ('bg-428', 'brise_glace', 'Quel est ton meilleur souvenir de voyage en famille ?'),
  ('bg-429', 'brise_glace', 'Quelle est la chose qui te fait te sentir reconnaissant ?'),
  ('bg-430', 'brise_glace', 'Quel est ton plat de comfort food préféré ?'),
  ('bg-431', 'brise_glace', 'Quelle est ta façon préférée de te faire des souvenirs ?'),
  ('bg-432', 'brise_glace', 'Quel est ton meilleur souvenir de première neige ?'),
  ('bg-433', 'brise_glace', 'Quelle est la chose la plus drôle que tu aies entendue en public ?'),
  ('bg-434', 'brise_glace', 'Quel est ton bonbon acidulé préféré ?'),
  ('bg-435', 'brise_glace', 'Quelle est ta façon préférée de passer une soirée calme ?'),
  ('bg-436', 'brise_glace', 'Quel est ton meilleur souvenir de bord de mer ?'),
  ('bg-437', 'brise_glace', 'Quelle est la chose qui te fait te sentir légitime ?'),
  ('bg-438', 'brise_glace', 'Quel est ton plat préféré à la maison ?'),
  ('bg-439', 'brise_glace', 'Quelle est ta façon préférée de te faire du bien ?'),
  ('bg-440', 'brise_glace', 'Quel est ton meilleur souvenir de rentrée des classes ?'),
  ('bg-441', 'brise_glace', 'Quelle est la chose la plus douce que tu aies dite à quelqu''un ?'),
  ('bg-442', 'brise_glace', 'Quel est ton en-cas sucré préféré ?'),
  ('bg-443', 'brise_glace', 'Quelle est ta façon préférée de passer un dimanche matin ?'),
  ('bg-444', 'brise_glace', 'Quel est ton meilleur souvenir de grand air ?'),
  ('bg-445', 'brise_glace', 'Quelle est la chose qui te fait te sentir en paix ?'),
  ('bg-446', 'brise_glace', 'Quel est ton plat préféré en terrasse ?'),
  ('bg-447', 'brise_glace', 'Quelle est ta façon préférée de te faire apprécier ?'),
  ('bg-448', 'brise_glace', 'Quel est ton meilleur souvenir de soirée entre amis ?'),
  ('bg-449', 'brise_glace', 'Quelle est la chose la plus amusante que tu aies expliquée à quelqu''un ?'),
  ('bg-450', 'brise_glace', 'Quel est ton plat préféré de brasserie ?'),
  ('bg-451', 'brise_glace', 'Quelle est ta façon préférée de te faire chouchouter ?'),
  ('bg-452', 'brise_glace', 'Quel est ton meilleur souvenir de fin d''année scolaire ?'),
  ('bg-453', 'brise_glace', 'Quelle est la chose qui te fait te sentir bien dans ton corps ?'),
  ('bg-454', 'brise_glace', 'Quel est ton plat préféré de rue ?'),
  ('bg-455', 'brise_glace', 'Quelle est ta façon préférée de te faire plaisir le matin ?'),
  ('bg-456', 'brise_glace', 'Quel est ton meilleur souvenir de sortie en famille ?'),
  ('bg-457', 'brise_glace', 'Quelle est la chose la plus douce que tu aies vue ?'),
  ('bg-458', 'brise_glace', 'Quel est ton plat préféré du monde ?'),
  ('bg-459', 'brise_glace', 'Quelle est ta façon préférée de te faire des amis en voyage ?'),
  ('bg-460', 'brise_glace', 'Quel est ton meilleur souvenir de week-end improvisé ?'),
  ('bg-461', 'brise_glace', 'Quelle est la chose qui te fait te sentir important ?'),
  ('bg-462', 'brise_glace', 'Quel est ton plat préféré en pique-nique ?'),
  ('bg-463', 'brise_glace', 'Quelle est ta façon préférée de te faire des souvenirs en photo ?'),
  ('bg-464', 'brise_glace', 'Quel est ton meilleur souvenir de journée à la campagne ?'),
  ('bg-465', 'brise_glace', 'Quelle est la chose qui te fait te sentir connecté aux autres ?'),
  ('bg-466', 'brise_glace', 'Quel est ton plat préféré en hiver ?'),
  ('bg-467', 'brise_glace', 'Quelle est ta façon préférée de te faire du bien après le sport ?'),
  ('bg-468', 'brise_glace', 'Quel est ton meilleur souvenir de journée à la plage ?'),
  ('bg-469', 'brise_glace', 'Quelle est la chose qui te fait te sentir reconnaissant envers la vie ?'),
  ('bg-470', 'brise_glace', 'Quel est ton plat préféré en été ?'),
  ('bg-471', 'brise_glace', 'Quelle est ta façon préférée de te faire du bien le soir ?'),
  ('bg-472', 'brise_glace', 'Quel est ton meilleur souvenir de journée en ville ?'),
  ('bg-473', 'brise_glace', 'Quelle est la chose qui te fait te sentir épanoui ?'),
  ('bg-474', 'brise_glace', 'Quel est ton plat préféré du dimanche soir ?'),
  ('bg-475', 'brise_glace', 'Quelle est ta façon préférée de te faire du bien le week-end ?'),
  ('bg-476', 'brise_glace', 'Quel est ton meilleur souvenir de journée à la montagne ?'),
  ('bg-477', 'brise_glace', 'Quelle est la chose qui te fait te sentir aimé sans mots ?'),
  ('bg-478', 'brise_glace', 'Quel est ton plat préféré de fête ?'),
  ('bg-479', 'brise_glace', 'Quelle est ta façon préférée de te faire du bien en famille ?')
on conflict (code) do nothing;

-- Personnalité et habitudes (313 questions)
insert into public.questions (code, category, body) values
  ('ph-101', 'personnalite', 'Qu''est-ce qui te met le plus en confiance au quotidien ?'),
  ('ph-102', 'personnalite', 'Comment réagis-tu face à une grosse pression ?'),
  ('ph-103', 'personnalite', 'Quelle habitude te caractérise le plus ?'),
  ('ph-104', 'personnalite', 'Qu''est-ce qui te donne de l''énergie ?'),
  ('ph-105', 'personnalite', 'Comment prends-tu soin de ta santé mentale ?'),
  ('ph-106', 'personnalite', 'Quelle qualité te sert le plus ?'),
  ('ph-107', 'personnalite', 'Qu''est-ce qui te fait perdre ta concentration ?'),
  ('ph-108', 'personnalite', 'Comment t''encourages-tu quand c''est difficile ?'),
  ('ph-109', 'personnalite', 'Quelle valeur guide tes décisions ?'),
  ('ph-110', 'personnalite', 'Qu''est-ce qui te rend patient ?'),
  ('ph-111', 'personnalite', 'Comment réagis-tu face à l''imprévu ?'),
  ('ph-112', 'personnalite', 'Quelle habitude aimerais-tu garder ?'),
  ('ph-113', 'personnalite', 'Qu''est-ce qui te calme en cas de stress ?'),
  ('ph-114', 'personnalite', 'Comment exprimes-tu ta gratitude ?'),
  ('ph-115', 'personnalite', 'Quelle qualité admire-tu en toi ?'),
  ('ph-116', 'personnalite', 'Qu''est-ce qui te fait te sentir fort ?'),
  ('ph-117', 'personnalite', 'Comment géres-tu ton temps quand c''est plein ?'),
  ('ph-118', 'personnalite', 'Quelle habitude te redonne de l''énergie ?'),
  ('ph-119', 'personnalite', 'Qu''est-ce qui te met à l''aise en groupe ?'),
  ('ph-120', 'personnalite', 'Comment fais-tu face à l''échec ?'),
  ('ph-121', 'personnalite', 'Quelle valeur défends-tu le plus ?'),
  ('ph-122', 'personnalite', 'Qu''est-ce qui te fait sortir de ta zone ?'),
  ('ph-123', 'personnalite', 'Comment t''organises-tu le matin ?'),
  ('ph-124', 'personnalite', 'Quelle habitude te fait te sentir bien ?'),
  ('ph-125', 'personnalite', 'Qu''est-ce qui te donne envie d''avancer ?'),
  ('ph-126', 'personnalite', 'Comment réagis-tu face à la critique ?'),
  ('ph-127', 'personnalite', 'Quelle qualité te sert en amitié ?'),
  ('ph-128', 'personnalite', 'Qu''est-ce qui te fait te sentir ancré ?'),
  ('ph-129', 'personnalite', 'Comment prends-tu une pause quand tu es épuisé ?'),
  ('ph-130', 'personnalite', 'Quelle habitude te redynamise ?'),
  ('ph-131', 'personnalite', 'Qu''est-ce qui te met en confiance dans le couple ?'),
  ('ph-132', 'personnalite', 'Comment exprimes-tu ton désaccord ?'),
  ('ph-133', 'personnalite', 'Quelle valeur te rapproche des autres ?'),
  ('ph-134', 'personnalite', 'Qu''est-ce qui te fait rester motivé ?'),
  ('ph-135', 'personnalite', 'Comment gères-tu la solitude choisie ?'),
  ('ph-136', 'personnalite', 'Quelle habitude te fait te sentir chez toi ?'),
  ('ph-137', 'personnalite', 'Qu''est-ce qui te donne du courage ?'),
  ('ph-138', 'personnalite', 'Comment réagis-tu face à la peur ?'),
  ('ph-139', 'personnalite', 'Quelle qualité te sert au travail ?'),
  ('ph-140', 'personnalite', 'Qu''est-ce qui te fait te sentir en paix ?'),
  ('ph-141', 'personnalite', 'Comment fais-tu pour te recentrer ?'),
  ('ph-142', 'personnalite', 'Te considères-tu plutôt optimiste ou réaliste ?'),
  ('ph-143', 'personnalite', 'Qu''est-ce qui te fait sortir de ta zone de confort ?'),
  ('ph-144', 'personnalite', 'Comment réagis-tu face à l''imprévu ?'),
  ('ph-145', 'personnalite', 'Quelle valeur est non négociable pour toi ?'),
  ('ph-146', 'personnalite', 'Préfères-tu prendre des décisions vite ou tout peser longuement ?'),
  ('ph-147', 'personnalite', 'Es-tu plutôt du matin ou du soir ?'),
  ('ph-148', 'personnalite', 'Comment montres-tu que tu tiens à quelqu''un ?'),
  ('ph-149', 'personnalite', 'Qu''est-ce qui te fait perdre patience le plus vite ?'),
  ('ph-150', 'personnalite', 'Te confies-tu facilement ou avec parcimonie ?'),
  ('ph-151', 'personnalite', 'Quel trait de caractère admires-tu le plus chez les autres ?'),
  ('ph-152', 'personnalite', 'Comment gères-tu la critique ?'),
  ('ph-153', 'personnalite', 'Es-tu plutôt leader ou équipier dans un groupe ?'),
  ('ph-154', 'personnalite', 'Qu''est-ce qui te motive plus : la curiosité ou la sécurité ?'),
  ('ph-155', 'personnalite', 'Comment te comportes-tu quand tu es fatigué ?'),
  ('ph-156', 'personnalite', 'Quel rôle joues-tu dans ton groupe d''amis ?'),
  ('ph-157', 'personnalite', 'Préfères-tu être utile ou être apprécié ?'),
  ('ph-158', 'personnalite', 'Comment réagis-tu quand tu as tort ?'),
  ('ph-159', 'personnalite', 'Quelle habitude aimerais-tu transmettre à tes proches ?'),
  ('ph-160', 'personnalite', 'Qu''est-ce qui te fait te sentir respecté ?'),
  ('ph-161', 'personnalite', 'Es-tu plutôt spontané ou prévoyant ?'),
  ('ph-162', 'personnalite', 'Comment t''organises-tu pour tenir tes engagements ?'),
  ('ph-163', 'personnalite', 'Qu''est-ce qui te rend vraiment fier ?'),
  ('ph-164', 'personnalite', 'Quel est ton plus grand contraste de personnalité ?'),
  ('ph-165', 'personnalite', 'Comment te ressaisis-tu après un échec ?'),
  ('ph-166', 'personnalite', 'Es-tu plutôt têtu ou flexible ?'),
  ('ph-167', 'personnalite', 'Qu''est-ce qui t''aide à prendre du recul ?'),
  ('ph-168', 'personnalite', 'Comment exprimes-tu ta colère, ou comment l''évites-tu ?'),
  ('ph-169', 'personnalite', 'Quel est ton rapport aux règles ?'),
  ('ph-170', 'personnalite', 'Préfères-tu parler ou écouter dans une conversation ?'),
  ('ph-171', 'personnalite', 'Comment décrirais-tu ton humour ?'),
  ('ph-172', 'personnalite', 'Qu''est-ce qui te met en confiance immédiatement ?'),
  ('ph-173', 'personnalite', 'Es-tu plutôt indépendant ou dépendant du groupe ?'),
  ('ph-174', 'personnalite', 'Comment affrontes-tu les conflits ?'),
  ('ph-175', 'personnalite', 'Quel est ton plus grand moteur au quotidien ?'),
  ('ph-176', 'personnalite', 'Préfères-tu le connu rassurant ou l''inconnu excitant ?'),
  ('ph-177', 'personnalite', 'Comment te comportes-tu sous pression ?'),
  ('ph-178', 'personnalite', 'Qu''est-ce qui t''aide à te sentir ancré ?'),
  ('ph-179', 'personnalite', 'Es-tu plutôt prudent ou audacieux ?'),
  ('ph-180', 'personnalite', 'Comment choisis-tu tes amis ?'),
  ('ph-181', 'personnalite', 'Quel est ton rapport à la ponctualité ?'),
  ('ph-182', 'personnalite', 'Préfères-tu donner ou recevoir ?'),
  ('ph-183', 'personnalite', 'Comment réagis-tu aux compliments ?'),
  ('ph-184', 'personnalite', 'Qu''est-ce qui te met rapidement mal à l''aise ?'),
  ('ph-185', 'personnalite', 'Es-tu plutôt cartésien ou intuitif ?'),
  ('ph-186', 'personnalite', 'Comment exprimes-tu ton désaccord ?'),
  ('ph-187', 'personnalite', 'Quel est ton plus grand besoin émotionnel ?'),
  ('ph-188', 'personnalite', 'Préfères-tu planifier ou improviser un voyage ?'),
  ('ph-189', 'personnalite', 'Comment te remets-tu d''une déception ?'),
  ('ph-190', 'personnalite', 'Es-tu plutôt discret ou expansif ?'),
  ('ph-191', 'personnalite', 'Qu''est-ce qui te rend curieux ?'),
  ('ph-192', 'personnalite', 'Comment te comportes-tu avec les inconnus ?'),
  ('ph-193', 'personnalite', 'Préfères-tu la routine ou le changement ?'),
  ('ph-194', 'personnalite', 'Quel est ton rapport aux excuses ?'),
  ('ph-195', 'personnalite', 'Comment gardes-tu ton calme ?'),
  ('ph-196', 'personnalite', 'Es-tu plutôt confiant ou modeste ?'),
  ('ph-197', 'personnalite', 'Qu''est-ce qui éveille ta méfiance ?'),
  ('ph-198', 'personnalite', 'Comment aides-tu quelqu''un qui va mal ?'),
  ('ph-199', 'personnalite', 'Préfères-tu être seul ou accompagné pour réfléchir ?'),
  ('ph-200', 'personnalite', 'Quel est ton plus grand regret, si tu en as un ?'),
  ('ph-201', 'personnalite', 'Comment prends-tu les décisions difficiles ?'),
  ('ph-202', 'personnalite', 'Es-tu plutôt franc ou diplomate ?'),
  ('ph-203', 'personnalite', 'Qu''est-ce qui t''inspire le plus ?'),
  ('ph-204', 'personnalite', 'Comment gères-tu ton temps ?'),
  ('ph-205', 'personnalite', 'Préfères-tu créer ou réparer ?'),
  ('ph-206', 'personnalite', 'Quel est ton rapport à l''argent ?'),
  ('ph-207', 'personnalite', 'Comment te comportes-tu quand on te contredit ?'),
  ('ph-208', 'personnalite', 'Es-tu plutôt attentif aux détails ou aux grandes idées ?'),
  ('ph-209', 'personnalite', 'Qu''est-ce qui te fait rire nerveusement ?'),
  ('ph-210', 'personnalite', 'Comment définis-tu la réussite pour toi ?'),
  ('ph-211', 'personnalite', 'Préfères-tu parler de toi ou écouter parler ?'),
  ('ph-212', 'personnalite', 'Quel est ton rapport aux compromis ?'),
  ('ph-213', 'personnalite', 'Comment restes-tu fidèle à toi-même sous influence ?'),
  ('ph-214', 'personnalite', 'Es-tu plutôt sensible ou rationnel face aux autres ?'),
  ('ph-215', 'personnalite', 'Qu''est-ce qui te donne de l''énergie sociale ?'),
  ('ph-216', 'personnalite', 'Comment réagis-tu face à l''injustice ?'),
  ('ph-217', 'personnalite', 'Préfères-tu être compris ou apprécié ?'),
  ('ph-218', 'personnalite', 'Quel est ton plus grand point faible assumé ?'),
  ('ph-219', 'personnalite', 'Comment te fixes-tu des objectifs ?'),
  ('ph-220', 'personnalite', 'Es-tu plutôt à l''aise avec l''échec ?'),
  ('ph-221', 'personnalite', 'Qu''est-ce qui te rend patient ?'),
  ('ph-222', 'personnalite', 'Comment montres-tu du respect ?'),
  ('ph-223', 'personnalite', 'Préfères-tu beaucoup de connaissances ou peu d''amis proches ?'),
  ('ph-224', 'personnalite', 'Quel est ton rapport à l''autorité ?'),
  ('ph-225', 'personnalite', 'Comment te comportes-tu quand tu t''ennuies ?'),
  ('ph-226', 'personnalite', 'Es-tu plutôt tourné vers le passé, le présent ou le futur ?'),
  ('ph-227', 'personnalite', 'Qu''est-ce qui t''aide à dormir ?'),
  ('ph-228', 'personnalite', 'Comment exprimes-tu ta gratitude ?'),
  ('ph-229', 'personnalite', 'Préfères-tu résoudre les problèmes seul ou en équipe ?'),
  ('ph-230', 'personnalite', 'Quel est ton rapport aux apparences ?'),
  ('ph-231', 'personnalite', 'Comment décides-tu à qui faire confiance ?'),
  ('ph-232', 'personnalite', 'Es-tu plutôt nostalgique ou tourné vers l''avenir ?'),
  ('ph-233', 'personnalite', 'Qu''est-ce qui te fait te sentir fort ?'),
  ('ph-234', 'personnalite', 'Comment accueilles-tu les changements imposés ?'),
  ('ph-235', 'personnalite', 'Préfères-tu la vérité qui blesse ou le silence confortable ?'),
  ('ph-236', 'personnalite', 'Quel est ton rapport aux traditions ?'),
  ('ph-237', 'personnalite', 'Comment réagis-tu quand tu es jaloux ?'),
  ('ph-238', 'personnalite', 'Es-tu plutôt introverti ou extraverti ?'),
  ('ph-239', 'personnalite', 'Qu''est-ce qui t''aide à te recentrer ?'),
  ('ph-240', 'personnalite', 'Comment montres-tu ton affection sans mots ?'),
  ('ph-241', 'personnalite', 'Préfères-tu prendre ou recevoir les devants ?'),
  ('ph-242', 'personnalite', 'Quel est ton rapport à la compétition ?'),
  ('ph-243', 'personnalite', 'Comment te comportes-tu quand on te complimente en public ?'),
  ('ph-244', 'personnalite', 'Es-tu plutôt discipliné ou spontané ?'),
  ('ph-245', 'personnalite', 'Qu''est-ce qui te fait douter de toi ?'),
  ('ph-246', 'personnalite', 'Comment gères-tu les priorités multiples ?'),
  ('ph-247', 'personnalite', 'Préfères-tu être utile ou libre ?'),
  ('ph-248', 'personnalite', 'Quel est ton rapport à la solitude ?'),
  ('ph-249', 'personnalite', 'Comment exprimes-tu ta frustration ?'),
  ('ph-250', 'personnalite', 'Es-tu plutôt intuitif ou méthodique en amour ?'),
  ('ph-251', 'personnalite', 'Qu''est-ce qui te rassure dans l''incertitude ?'),
  ('ph-252', 'personnalite', 'Comment prends-tu soin de ta santé mentale ?'),
  ('ph-253', 'personnalite', 'Préfères-tu qu''on te conseille ou qu''on t''écoute ?'),
  ('ph-254', 'personnalite', 'Quel est ton rapport au changement de plan ?'),
  ('ph-255', 'personnalite', 'Comment réagis-tu face à la peur ?'),
  ('ph-256', 'personnalite', 'Es-tu plutôt généreux ou économe de ton temps ?'),
  ('ph-257', 'personnalite', 'Qu''est-ce qui te fait te sentir respecté au travail ?'),
  ('ph-258', 'personnalite', 'Comment gères-tu une critique injuste ?'),
  ('ph-259', 'personnalite', 'Préfères-tu être autonome ou encadré ?'),
  ('ph-260', 'personnalite', 'Quel est ton rapport aux promesses ?'),
  ('ph-261', 'personnalite', 'Comment reconnais-tu que tu as besoin d''aide ?'),
  ('ph-262', 'personnalite', 'Es-tu plutôt créatif dans la contrainte ou dans la liberté ?'),
  ('ph-263', 'personnalite', 'Qu''est-ce qui te pousse à te dépasser ?'),
  ('ph-264', 'personnalite', 'Comment te comportes-tu quand tu as raison seul contre tous ?'),
  ('ph-265', 'personnalite', 'Préfères-tu la clarté ou garder le mystère ?'),
  ('ph-266', 'personnalite', 'Quel est ton rapport aux regrets ?'),
  ('ph-267', 'personnalite', 'Comment accueilles-tu une bonne nouvelle pour un autre ?'),
  ('ph-268', 'personnalite', 'Es-tu plutôt généreux en paroles ou en actes ?'),
  ('ph-269', 'personnalite', 'Qu''est-ce qui te fait te sentir à ta place ?'),
  ('ph-270', 'personnalite', 'Comment gères-tu l''ennui d''une réunion ?'),
  ('ph-271', 'personnalite', 'Préfères-tu penser à voix haute ou en silence ?'),
  ('ph-272', 'personnalite', 'Quel est ton rapport à la vulnérabilité ?'),
  ('ph-273', 'personnalite', 'Comment réagis-tu quand on t''interrompt ?'),
  ('ph-274', 'personnalite', 'Es-tu plutôt rapide à pardonner ?'),
  ('ph-275', 'personnalite', 'Qu''est-ce qui te fait te sentir écouté ?'),
  ('ph-276', 'personnalite', 'Comment définis-tu ton intégrité ?'),
  ('ph-277', 'personnalite', 'Préfères-tu la stabilité ou l''aventure professionnelle ?'),
  ('ph-278', 'personnalite', 'Quel est ton rapport aux habitudes alimentaires ?'),
  ('ph-279', 'personnalite', 'Comment t''adaptes-tu à une nouvelle équipe ?'),
  ('ph-280', 'personnalite', 'Es-tu plutôt affectueux ou pudique ?'),
  ('ph-281', 'personnalite', 'Qu''est-ce qui te fait te sentir à l''aise en public ?'),
  ('ph-282', 'personnalite', 'Comment gères-tu les malentendus ?'),
  ('ph-283', 'personnalite', 'Préfères-tu être dans le contrôle ou lâcher prise ?'),
  ('ph-284', 'personnalite', 'Quel est ton rapport aux médias et réseaux ?'),
  ('ph-285', 'personnalite', 'Comment reconnais-tu une personne bienveillante ?'),
  ('ph-286', 'personnalite', 'Es-tu plutôt indulgent ou exigeant envers toi-même ?'),
  ('ph-287', 'personnalite', 'Qu''est-ce qui t''aide à dire non ?'),
  ('ph-288', 'personnalite', 'Comment te comportes-tu face à la réussite des autres ?'),
  ('ph-289', 'personnalite', 'Préfères-tu être clair ou laisser planer le doute ?'),
  ('ph-290', 'personnalite', 'Quel est ton rapport à la spiritualité ou aux croyances ?'),
  ('ph-291', 'personnalite', 'Comment structures-tu ta semaine ?'),
  ('ph-292', 'personnalite', 'Es-tu plutôt du genre à anticiper ou à vivre l''instant ?'),
  ('ph-293', 'personnalite', 'Qu''est-ce qui te fait te sentir inspiré ?'),
  ('ph-294', 'personnalite', 'Comment gères-tu un secret qu''on t''a confié ?'),
  ('ph-295', 'personnalite', 'Préfères-tu la franchise brute ou la douceur ?'),
  ('ph-296', 'personnalite', 'Quel est ton rapport aux conventions sociales ?'),
  ('ph-297', 'personnalite', 'Comment réagis-tu quand on te juge ?'),
  ('ph-298', 'personnalite', 'Es-tu plutôt à l''aise avec les émotions fortes ?'),
  ('ph-299', 'personnalite', 'Qu''est-ce qui te fait te sentir grandir ?'),
  ('ph-300', 'personnalite', 'Comment exprimes-tu ta créativité ?'),
  ('ph-301', 'personnalite', 'Préfères-tu travailler avec la tête ou les mains ?'),
  ('ph-302', 'personnalite', 'Quel est ton rapport aux erreurs des autres ?'),
  ('ph-303', 'personnalite', 'Comment te comportes-tu quand tu es malade ?'),
  ('ph-304', 'personnalite', 'Es-tu plutôt fidèle à des rituels ou flexible ?'),
  ('ph-305', 'personnalite', 'Qu''est-ce qui te fait te sentir courageux ?'),
  ('ph-306', 'personnalite', 'Comment gères-tu une grosse déception amicale ?'),
  ('ph-307', 'personnalite', 'Préfères-tu recevoir des conseils ou de l''espace ?'),
  ('ph-308', 'personnalite', 'Quel est ton rapport au silence ?'),
  ('ph-309', 'personnalite', 'Comment t''encourages-tu toi-même ?'),
  ('ph-310', 'personnalite', 'Es-tu plutôt enthousiaste ou réservé en public ?'),
  ('ph-311', 'personnalite', 'Qu''est-ce qui te fait te sentir profondément toi ?'),
  ('ph-312', 'personnalite', 'Comment te comportes-tu dans un conflit familial ?'),
  ('ph-313', 'personnalite', 'Préfères-tu être populaire ou respecté ?'),
  ('ph-314', 'personnalite', 'Quel est ton rapport aux responsabilités ?'),
  ('ph-315', 'personnalite', 'Comment réagis-tu quand tu changes d''avis ?'),
  ('ph-316', 'personnalite', 'Es-tu plutôt prudent avec ton cœur ?'),
  ('ph-317', 'personnalite', 'Qu''est-ce qui te fait te sentir en confiance au travail ?'),
  ('ph-318', 'personnalite', 'Comment définis-tu la loyauté ?'),
  ('ph-319', 'personnalite', 'Préfères-tu la simplicité ou la sophistication ?'),
  ('ph-320', 'personnalite', 'Quel est ton rapport à la politesse ?'),
  ('ph-321', 'personnalite', 'Comment te comportes-tu avec les personnes en difficulté ?'),
  ('ph-322', 'personnalite', 'Es-tu plutôt quelqu''un d''organisé ou de spontané ?'),
  ('ph-323', 'personnalite', 'Qu''est-ce qui te donne envie de te lever ?'),
  ('ph-324', 'personnalite', 'Comment gères-tu ton énergie sociale ?'),
  ('ph-325', 'personnalite', 'Préfères-tu les projets courts ou longs ?'),
  ('ph-326', 'personnalite', 'Quel est ton rapport à la discipline personnelle ?'),
  ('ph-327', 'personnalite', 'Comment exprimes-tu ton mécontentement avec tact ?'),
  ('ph-328', 'personnalite', 'Es-tu plutôt direct ou subtil ?'),
  ('ph-329', 'personnalite', 'Qu''est-ce qui te fait te sentir chez toi en voyage ?'),
  ('ph-330', 'personnalite', 'Comment prends-tu soin de tes amitiés ?'),
  ('ph-331', 'personnalite', 'Préfères-tu être un exemple ou un guide ?'),
  ('ph-332', 'personnalite', 'Quel est ton rapport aux apparences vestimentaires ?'),
  ('ph-333', 'personnalite', 'Comment réagis-tu à l''imprévu en groupe ?'),
  ('ph-334', 'personnalite', 'Es-tu plutôt à l''aise avec le vide de l''agenda ?'),
  ('ph-335', 'personnalite', 'Qu''est-ce qui te fait te sentir productif ?'),
  ('ph-336', 'personnalite', 'Comment gères-tu une critique de quelqu''un que tu aimes ?'),
  ('ph-337', 'personnalite', 'Préfères-tu lire la pièce avant d''entrer ?'),
  ('ph-338', 'personnalite', 'Quel est ton rapport à la colère de l''autre ?'),
  ('ph-339', 'personnalite', 'Comment réconfortes-tu vraiment quelqu''un ?'),
  ('ph-340', 'personnalite', 'Es-tu plutôt ancré dans le corps ou dans la tête ?'),
  ('ph-341', 'personnalite', 'Qu''est-ce qui te fait te sentir respecté dans l''intimité ?'),
  ('ph-342', 'personnalite', 'Comment brises-tu la glace avec un inconnu ?'),
  ('ph-343', 'personnalite', 'Préfères-tu les relations intenses ou tranquilles ?'),
  ('ph-344', 'personnalite', 'Quel est ton rapport à la routine du sommeil ?'),
  ('ph-345', 'personnalite', 'Comment restes-tu toi-même sous la pression ?'),
  ('ph-346', 'personnalite', 'Es-tu plutôt coopératif ou compétitif ?'),
  ('ph-347', 'personnalite', 'Qu''est-ce qui te fait te sentir à ta place dans une famille ?'),
  ('ph-348', 'personnalite', 'Comment gères-tu les divergences de valeurs ?'),
  ('ph-349', 'personnalite', 'Préfères-tu corriger ou accepter ?'),
  ('ph-350', 'personnalite', 'Quel est ton rapport aux compliments sur ton physique ?'),
  ('ph-351', 'personnalite', 'Comment te comportes-tu quand tu dois trancher seul ?'),
  ('ph-352', 'personnalite', 'Es-tu plutôt analytique ou émotif ?'),
  ('ph-353', 'personnalite', 'Qu''est-ce qui te fait te sentir aimable ?'),
  ('ph-354', 'personnalite', 'Comment acceptes-tu de ne pas être parfait ?'),
  ('ph-355', 'personnalite', 'Préfères-tu être cru sincère ou gentiment vague ?'),
  ('ph-356', 'personnalite', 'Quel est ton rapport à la jalousie ?'),
  ('ph-357', 'personnalite', 'Comment gardes-tu la motivation sur le long terme ?'),
  ('ph-358', 'personnalite', 'Es-tu plutôt tourné vers le détail ou la vision ?'),
  ('ph-359', 'personnalite', 'Qu''est-ce qui te fait te sentir important pour les autres ?'),
  ('ph-360', 'personnalite', 'Comment gères-tu les attentes des autres ?'),
  ('ph-361', 'personnalite', 'Préfères-tu être autonome financièrement ou soutenu ?'),
  ('ph-362', 'personnalite', 'Quel est ton rapport à la patience avec toi-même ?'),
  ('ph-363', 'personnalite', 'Comment réagis-tu à une rupture de confiance ?'),
  ('ph-364', 'personnalite', 'Es-tu plutôt loyal au groupe ou à tes convictions ?'),
  ('ph-365', 'personnalite', 'Qu''est-ce qui te fait te sentir puissant en bien ?'),
  ('ph-366', 'personnalite', 'Comment décides-tu d''accorder une seconde chance ?'),
  ('ph-367', 'personnalite', 'Préfères-tu l''intensité ou la douceur au quotidien ?'),
  ('ph-368', 'personnalite', 'Quel est ton rapport à l''échec collectif ?'),
  ('ph-369', 'personnalite', 'Comment exprimes-tu de la reconnaissance ?'),
  ('ph-370', 'personnalite', 'Es-tu plutôt à l''aise avec l''engagement ?'),
  ('ph-371', 'personnalite', 'Qu''est-ce qui te fait te sentir respecté en amitié ?'),
  ('ph-372', 'personnalite', 'Comment t''excuses-tu sincèrement ?'),
  ('ph-373', 'personnalite', 'Préfères-tu prendre soin des autres ou de toi ?'),
  ('ph-374', 'personnalite', 'Quel est ton rapport aux critiques constructives ?'),
  ('ph-375', 'personnalite', 'Comment gères-tu les moments de doute ?'),
  ('ph-376', 'personnalite', 'Es-tu plutôt rassurant ou rassuré ?'),
  ('ph-377', 'personnalite', 'Qu''est-ce qui te fait te sentir chez toi dans ton corps ?'),
  ('ph-378', 'personnalite', 'Comment réagis-tu face au succès soudain ?'),
  ('ph-379', 'personnalite', 'Préfères-tu la lenteur ou la vitesse dans la vie ?'),
  ('ph-380', 'personnalite', 'Quel est ton rapport à la mémoire des bons moments ?'),
  ('ph-381', 'personnalite', 'Comment gardes-tu ton intégrité quand c''est difficile ?'),
  ('ph-382', 'personnalite', 'Es-tu plutôt généreux de compliments ou d''actes ?'),
  ('ph-383', 'personnalite', 'Qu''est-ce qui te fait te sentir en croissance ?'),
  ('ph-384', 'personnalite', 'Comment accueilles-tu un changement de rôle ?'),
  ('ph-385', 'personnalite', 'Préfères-tu être nécessaire ou choisi ?'),
  ('ph-386', 'personnalite', 'Quel est ton rapport à la jalousie dans l''amitié ?'),
  ('ph-387', 'personnalite', 'Comment fais-tu face à la solitude choisie ?'),
  ('ph-388', 'personnalite', 'Es-tu plutôt aventureux ou prudent dans l''inconnu ?'),
  ('ph-389', 'personnalite', 'Qu''est-ce qui te fait te sentir profondément respecté ?'),
  ('ph-390', 'personnalite', 'Comment exprimes-tu un besoin sans le transformer en reproche ?'),
  ('ph-391', 'personnalite', 'Préfères-tu résoudre un conflit tout de suite ou à froid ?'),
  ('ph-392', 'personnalite', 'Quel est ton rapport à la ponctualité des autres ?'),
  ('ph-393', 'personnalite', 'Comment réagis-tu à la maladresse d''un proche ?'),
  ('ph-394', 'personnalite', 'Es-tu plutôt indulgent ou critique envers la société ?'),
  ('ph-395', 'personnalite', 'Qu''est-ce qui te fait te sentir aligné avec tes valeurs ?'),
  ('ph-396', 'personnalite', 'Comment prends-tu soin de ton corps au quotidien ?'),
  ('ph-397', 'personnalite', 'Préfères-tu être guidé par la tête ou le cœur ?'),
  ('ph-398', 'personnalite', 'Quel est ton rapport à la nouveauté technologique ?'),
  ('ph-399', 'personnalite', 'Comment te comportes-tu face à la peur de l''autre ?'),
  ('ph-400', 'personnalite', 'Es-tu plutôt capable de rester seul longtemps ?'),
  ('ph-401', 'personnalite', 'Qu''est-ce qui te fait te sentir aimé au travail ?'),
  ('ph-402', 'personnalite', 'Comment gères-tu un désaccord public ?'),
  ('ph-403', 'personnalite', 'Préfères-tu la franchise à tout prix ou la préservation ?'),
  ('ph-404', 'personnalite', 'Quel est ton rapport à la religion des autres ?'),
  ('ph-405', 'personnalite', 'Comment fais-tu face aux critiques de ta famille ?'),
  ('ph-406', 'personnalite', 'Es-tu plutôt loyal ou indépendant d''esprit ?'),
  ('ph-407', 'personnalite', 'Qu''est-ce qui te fait te sentir plus grand que toi ?'),
  ('ph-408', 'personnalite', 'Comment assumes-tu tes contradictions ?'),
  ('ph-409', 'personnalite', 'Préfères-tu le confort ou la vérité ?'),
  ('ph-410', 'personnalite', 'Quel est ton rapport à la discipline collective ?'),
  ('ph-411', 'personnalite', 'Comment gardes-tu espoir dans les moments sombres ?'),
  ('ph-412', 'personnalite', 'Es-tu plutôt persévérant ou adaptable ?'),
  ('ph-413', 'personnalite', 'Qu''est-ce qui te fait te sentir vivant chaque jour ?')
on conflict (code) do nothing;

-- Amour et séduction (312 questions)
insert into public.questions (code, category, body) values
  ('as-101', 'amour', 'Qu''est-ce qui te fait te sentir choisi chaque jour ?'),
  ('as-102', 'amour', 'Comment aimes-tu qu''on se soutienne dans nos choix ?'),
  ('as-103', 'amour', 'Qu''est-ce qui te fait te sentir aimé au quotidien ?'),
  ('as-104', 'amour', 'Quelle attention te fait te sentir prioritaire ?'),
  ('as-105', 'amour', 'Comment aimes-tu qu''on se dise nos petites joies ?'),
  ('as-106', 'amour', 'Qu''est-ce qui te fait te sentir proche de moi ?'),
  ('as-107', 'amour', 'Quelle façon de prendre soin de toi me toucherait ?'),
  ('as-108', 'amour', 'Comment aimes-tu qu''on se relève ensemble ?'),
  ('as-109', 'amour', 'Qu''est-ce qui te fait te sentir en équipe ?'),
  ('as-110', 'amour', 'Quelle attention te fait te sentir apprécié ?'),
  ('as-111', 'amour', 'Comment aimes-tu qu''on se dise nos craintes ?'),
  ('as-112', 'amour', 'Qu''est-ce qui te fait te sentir aimé même fatigué ?'),
  ('as-113', 'amour', 'Quelle façon de me rassurer te plaît ?'),
  ('as-114', 'amour', 'Comment aimes-tu qu''on se surprenne tendrement ?'),
  ('as-115', 'amour', 'Qu''est-ce qui te fait te sentir respecté dans notre duo ?'),
  ('as-116', 'amour', 'Quelle attention te fait te sentir unique ?'),
  ('as-117', 'amour', 'Comment aimes-tu qu''on se dise nos espoirs ?'),
  ('as-118', 'amour', 'Qu''est-ce qui te fait te sentir en sécurité avec moi ?'),
  ('as-119', 'amour', 'Quelle façon de se réconcilier te plaît ?'),
  ('as-120', 'amour', 'Comment aimes-tu qu''on se donne des rituels ?'),
  ('as-121', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les détails ?'),
  ('as-122', 'amour', 'Quelle attention te fait te sentir désiré ?'),
  ('as-123', 'amour', 'Comment aimes-tu qu''on se dise nos besoins ?'),
  ('as-124', 'amour', 'Qu''est-ce qui te fait te sentir complice ?'),
  ('as-125', 'amour', 'Quelle façon de montrer son amour te correspond ?'),
  ('as-126', 'amour', 'Comment aimes-tu qu''on se dise nos fiertés ?'),
  ('as-127', 'amour', 'Qu''est-ce qui te fait te sentir aimé sans jugement ?'),
  ('as-128', 'amour', 'Quelle attention te fait te sentir entendu ?'),
  ('as-129', 'amour', 'Comment aimes-tu qu''on se dise nos rêves communs ?'),
  ('as-130', 'amour', 'Qu''est-ce qui te fait te sentir choisi encore ?'),
  ('as-131', 'amour', 'Quelle façon de prendre soin l''un de l''autre te plaît ?'),
  ('as-132', 'amour', 'Comment aimes-tu qu''on se dise nos limites ?'),
  ('as-133', 'amour', 'Qu''est-ce qui te fait te sentir aimé tendrement ?'),
  ('as-134', 'amour', 'Quelle attention te fait te sentir à l''aise ?'),
  ('as-135', 'amour', 'Comment aimes-tu qu''on se dise nos envies ?'),
  ('as-136', 'amour', 'Qu''est-ce qui te fait te sentir à ta place ?'),
  ('as-137', 'amour', 'Quelle façon de se comprendre te plaît ?'),
  ('as-138', 'amour', 'Comment aimes-tu qu''on se dise nos petites attentions ?'),
  ('as-139', 'amour', 'Qu''est-ce qui te fait te sentir aimé et respecté ?'),
  ('as-140', 'amour', 'Quelle attention te fait te sentir vivant ?'),
  ('as-141', 'amour', 'Comment aimes-tu qu''on se dise nos projets ?'),
  ('as-142', 'amour', 'Qu''est-ce qui te fait te sentir en confiance ?'),
  ('as-143', 'amour', 'Quelle façon de se taquiner tendrement te plaît ?'),
  ('as-144', 'amour', 'Comment aimes-tu qu''on se dise nos joies ?'),
  ('as-145', 'amour', 'Qu''est-ce qui te fait te sentir aimé au présent ?'),
  ('as-146', 'amour', 'Quelle attention te fait te sentir choisi chaque matin ?'),
  ('as-147', 'amour', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('as-148', 'amour', 'Qu''est-ce qui te fait te sentir aimé chaque soir ?'),
  ('as-149', 'amour', 'Quelle façon de se dire bonsoir te plaît ?'),
  ('as-150', 'amour', 'Comment aimes-tu qu''on se dise nos petits bonheurs ?'),
  ('as-151', 'amour', 'Qu''est-ce qui te fait te sentir aimé et désiré ?'),
  ('as-152', 'amour', 'Quelle attention te fait te sentir précieuse ?'),
  ('as-153', 'amour', 'Comment aimes-tu qu''on se dise nos souvenirs préférés ?'),
  ('as-154', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la durée ?'),
  ('as-155', 'amour', 'Quelle façon de se dire merci te touche ?'),
  ('as-156', 'amour', 'Comment aimes-tu qu''on se dise nos envies d''avenir ?'),
  ('as-157', 'amour', 'Qu''est-ce qui te fait te sentir aimé tel que tu es ?'),
  ('as-158', 'amour', 'Quelle attention te fait te sentir à la maison ?'),
  ('as-159', 'amour', 'Comment aimes-tu qu''on se dise nos espérances ?'),
  ('as-160', 'amour', 'Qu''est-ce qui te fait te sentir aimé et respecté ?'),
  ('as-161', 'amour', 'Quelle façon de se dire pardon te plaît ?'),
  ('as-162', 'amour', 'Comment aimes-tu qu''on se dise nos fiertés à deux ?'),
  ('as-163', 'amour', 'Qu''est-ce qui te fait te sentir aimé pour toujours ?'),
  ('as-164', 'amour', 'Quel geste te fait te sentir aimé sans qu''on te le dise ?'),
  ('as-165', 'amour', 'Qu''est-ce qui te séduit immédiatement chez quelqu''un ?'),
  ('as-166', 'amour', 'Comment aimes-tu qu''on te montre de l''attention ?'),
  ('as-167', 'amour', 'Quel souvenir de nos débuts te fait sourire ?'),
  ('as-168', 'amour', 'Qu''est-ce qui te fait te sentir désiré ?'),
  ('as-169', 'amour', 'De quoi as-tu besoin pour te sentir en sécurité affective ?'),
  ('as-170', 'amour', 'Quel petit détail chez moi te plaît le plus ?'),
  ('as-171', 'amour', 'Comment aimes-tu être taquiné, ou dragué ?'),
  ('as-172', 'amour', 'Quelle attention du quotidien te touche le plus ?'),
  ('as-173', 'amour', 'Qu''est-ce qui te fait tomber amoureux ?'),
  ('as-174', 'amour', 'Comment t''exprimes-tu le mieux ton amour ?'),
  ('as-175', 'amour', 'Quel moment de la journée aimerais-tu partager plus avec moi ?'),
  ('as-176', 'amour', 'Qu''est-ce qui renforce ta confiance dans notre duo ?'),
  ('as-177', 'amour', 'Quel compliment sur notre relation te fait le plus plaisir ?'),
  ('as-178', 'amour', 'Comment aimes-tu être rassuré ?'),
  ('as-179', 'amour', 'Quel type de rendez-vous te fait rêver ?'),
  ('as-180', 'amour', 'Qu''est-ce qui te fait te sentir spécial à mes yeux ?'),
  ('as-181', 'amour', 'Quelle qualité chez moi aimerais-tu me voir davantage montrer ?'),
  ('as-182', 'amour', 'Comment aimes-tu qu''on se dispute et qu''on se réconcilie ?'),
  ('as-183', 'amour', 'Qu''est-ce qui te fait te sentir prioritaire ?'),
  ('as-184', 'amour', 'Quel souvenir de notre premier rendez-vous te reste ?'),
  ('as-185', 'amour', 'Comment aimes-tu qu''on prenne soin de nous ?'),
  ('as-186', 'amour', 'Qu''est-ce qui t''a fait me remarquer au début ?'),
  ('as-187', 'amour', 'Quelle attention te met dans un état de tendresse ?'),
  ('as-188', 'amour', 'Comment veux-tu qu''on célèbre nos moments importants ?'),
  ('as-189', 'amour', 'Qu''est-ce qui te fait te sentir choisi, jour après jour ?'),
  ('as-190', 'amour', 'Quel geste de tendresse te détend instantanément ?'),
  ('as-191', 'amour', 'Comment aimes-tu être câliné ?'),
  ('as-192', 'amour', 'Qu''est-ce qui te fait te sentir aimé même dans les moments difficiles ?'),
  ('as-193', 'amour', 'Quelle promesse compte le plus pour toi ?'),
  ('as-194', 'amour', 'Comment aimes-tu qu''on se retrouve après une absence ?'),
  ('as-195', 'amour', 'Qu''est-ce qui te fait te sentir beau à mes yeux ?'),
  ('as-196', 'amour', 'Quel sujet aimerais-tu qu''on aborde plus souvent à deux ?'),
  ('as-197', 'amour', 'Comment aimes-tu être soutenu dans tes projets ?'),
  ('as-198', 'amour', 'Qu''est-ce qui éveille ta tendresse ?'),
  ('as-199', 'amour', 'Quelle petite attention te fait fondre ?'),
  ('as-200', 'amour', 'Comment aimes-tu les au revoir et les retrouvailles ?'),
  ('as-201', 'amour', 'Qu''est-ce qui te fait te sentir à ma place dans ton cœur ?'),
  ('as-202', 'amour', 'Quel moment simple aimerais-tu transformer en rituel à deux ?'),
  ('as-203', 'amour', 'Comment aimes-tu que je te charme ?'),
  ('as-204', 'amour', 'Qu''est-ce qui te fait te sentir écouté dans le couple ?'),
  ('as-205', 'amour', 'Quelle partie de notre histoire aimerais-tu revivre ?'),
  ('as-206', 'amour', 'Comment aimes-tu qu''on se taquine tendrement ?'),
  ('as-207', 'amour', 'Qu''est-ce qui te fait te sentir fier de nous ?'),
  ('as-208', 'amour', 'Quelle façon d''être aimé t''est indispensable ?'),
  ('as-209', 'amour', 'Comment aimes-tu prendre soin de moi ?'),
  ('as-210', 'amour', 'Qu''est-ce qui te rapproche le plus de moi ?'),
  ('as-211', 'amour', 'Quel geste de soutien te touche le plus ?'),
  ('as-212', 'amour', 'Comment aimes-tu être surpris de façon romantique ?'),
  ('as-213', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans le regard ?'),
  ('as-214', 'amour', 'Quelle activité aimerais-tu qu''on fasse plus souvent à deux ?'),
  ('as-215', 'amour', 'Comment aimes-tu qu''on apaise une tension ?'),
  ('as-216', 'amour', 'Qu''est-ce qui te fait te sentir en phase avec moi ?'),
  ('as-217', 'amour', 'Quel petit mot doux aimerais-tu entendre plus souvent ?'),
  ('as-218', 'amour', 'Comment aimes-tu qu''on se complimente ?'),
  ('as-219', 'amour', 'Qu''est-ce qui te fait te sentir choisi chaque matin ?'),
  ('as-220', 'amour', 'Quelle forme de séduction te plaît chez moi ?'),
  ('as-221', 'amour', 'Comment aimes-tu qu''on se retrouve le soir ?'),
  ('as-222', 'amour', 'Qu''est-ce qui te fait te sentir aimé sans conditions ?'),
  ('as-223', 'amour', 'Quel souvenir de nous te réchauffe le cœur ?'),
  ('as-224', 'amour', 'Comment aimes-tu qu''on partage nos journées ?'),
  ('as-225', 'amour', 'Qu''est-ce qui te fait te sentir à l''aise pour être vulnérable ?'),
  ('as-226', 'amour', 'Quelle attention discrète remarques-tu chez moi ?'),
  ('as-227', 'amour', 'Comment aimes-tu qu''on se dise bonjour ?'),
  ('as-228', 'amour', 'Qu''est-ce qui te fait te sentir aimable et désirable ?'),
  ('as-229', 'amour', 'Quelle chose aimerais-tu qu''on se dise plus souvent ?'),
  ('as-230', 'amour', 'Comment aimes-tu être touché avec tendresse ?'),
  ('as-231', 'amour', 'Qu''est-ce qui te fait te sentir respecté dans l''amour ?'),
  ('as-232', 'amour', 'Quel moment à deux te ressource le plus ?'),
  ('as-233', 'amour', 'Comment aimes-tu qu''on prenne le temps de nous ?'),
  ('as-234', 'amour', 'Qu''est-ce qui te fait te sentir aimé même à distance ?'),
  ('as-235', 'amour', 'Quelle qualité d''écoute attends-tu de moi ?'),
  ('as-236', 'amour', 'Comment aimes-tu qu''on se fasse des surprises ?'),
  ('as-237', 'amour', 'Qu''est-ce qui éveille ton désir de tendresse ?'),
  ('as-238', 'amour', 'Quel signe d''affection te parle le plus ?'),
  ('as-239', 'amour', 'Comment aimes-tu qu''on se parle de nos sentiments ?'),
  ('as-240', 'amour', 'Qu''est-ce qui te fait te sentir en harmonie avec moi ?'),
  ('as-241', 'amour', 'Quelle attention te donne le sourire à coup sûr ?'),
  ('as-242', 'amour', 'Comment aimes-tu qu''on se réconcilie après une bêtise ?'),
  ('as-243', 'amour', 'Qu''est-ce qui te fait te sentir aimé pour ce que tu es ?'),
  ('as-244', 'amour', 'Quel type de geste romantique te touche ?'),
  ('as-245', 'amour', 'Comment aimes-tu qu''on se projette à deux ?'),
  ('as-246', 'amour', 'Qu''est-ce qui te fait te sentir en confiance dans l''intimité ?'),
  ('as-247', 'amour', 'Quelle chose fais-tu pour moi qui montre ton amour ?'),
  ('as-248', 'amour', 'Comment aimes-tu qu''on se taquine sur nos différences ?'),
  ('as-249', 'amour', 'Qu''est-ce qui te fait te sentir choisi et non pas seulement là ?'),
  ('as-250', 'amour', 'Quel moment de complicité préfères-tu ?'),
  ('as-251', 'amour', 'Comment aimes-tu qu''on cultive la complicité ?'),
  ('as-252', 'amour', 'Qu''est-ce qui te fait te sentir aimé au quotidien ?'),
  ('as-253', 'amour', 'Quelle petite chose aimerais-tu que je remarque plus ?'),
  ('as-254', 'amour', 'Comment aimes-tu qu''on se soutienne ?'),
  ('as-255', 'amour', 'Qu''est-ce qui te fait te sentir important dans notre couple ?'),
  ('as-256', 'amour', 'Quel rituel de couple aimerais-tu garder pour toujours ?'),
  ('as-257', 'amour', 'Comment aimes-tu qu''on se détende ensemble ?'),
  ('as-258', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les détails ?'),
  ('as-259', 'amour', 'Quelle forme de romantisme te correspond le plus ?'),
  ('as-260', 'amour', 'Comment aimes-tu qu''on se fasse rire ?'),
  ('as-261', 'amour', 'Qu''est-ce qui te fait te sentir désiré au quotidien ?'),
  ('as-262', 'amour', 'Quel souvenir de nos fous rires te reste ?'),
  ('as-263', 'amour', 'Comment aimes-tu qu''on se donne des nouvelles ?'),
  ('as-264', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la durée ?'),
  ('as-265', 'amour', 'Quelle attention te montre que je pense à toi ?'),
  ('as-266', 'amour', 'Comment aimes-tu qu''on prenne soin de notre intimité ?'),
  ('as-267', 'amour', 'Qu''est-ce qui te fait te sentir bien dans notre rythme ?'),
  ('as-268', 'amour', 'Quel geste de tendresse aimerais-tu plus souvent ?'),
  ('as-269', 'amour', 'Comment aimes-tu qu''on se dise nos besoins ?'),
  ('as-270', 'amour', 'Qu''est-ce qui te fait te sentir aimé quand ça va mal ?'),
  ('as-271', 'amour', 'Quelle chose aimerais-tu qu''on fasse pour notre complicité ?'),
  ('as-272', 'amour', 'Comment aimes-tu qu''on se surprenne ?'),
  ('as-273', 'amour', 'Qu''est-ce qui te fait te sentir en sécurité pour t''ouvrir ?'),
  ('as-274', 'amour', 'Quelle attention nourrit le plus ton cœur ?'),
  ('as-275', 'amour', 'Comment aimes-tu qu''on se retrouve après une journée difficile ?'),
  ('as-276', 'amour', 'Qu''est-ce qui te fait te sentir aimé pour de vrai ?'),
  ('as-277', 'amour', 'Quel petit moment aimerais-tu qu''on s''offre chaque semaine ?'),
  ('as-278', 'amour', 'Comment aimes-tu qu''on se dise nos envies ?'),
  ('as-279', 'amour', 'Qu''est-ce qui te fait te sentir complice avec moi ?'),
  ('as-280', 'amour', 'Quelle façon d''aimer est la tienne ?'),
  ('as-281', 'amour', 'Comment aimes-tu qu''on se rassure ?'),
  ('as-282', 'amour', 'Qu''est-ce qui te fait te sentir aimé profondément ?'),
  ('as-283', 'amour', 'Quelle attention discrète nourrit notre lien ?'),
  ('as-284', 'amour', 'Comment aimes-tu qu''on se dise merci ?'),
  ('as-285', 'amour', 'Qu''est-ce qui te fait te sentir unique à mes yeux ?'),
  ('as-286', 'amour', 'Quel souvenir de nous aimerais-tu encadrer ?'),
  ('as-287', 'amour', 'Comment aimes-tu qu''on se chuchote des douceurs ?'),
  ('as-288', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans le silence ?'),
  ('as-289', 'amour', 'Quelle forme de présence te touche le plus ?'),
  ('as-290', 'amour', 'Comment aimes-tu qu''on se redécouvre ?'),
  ('as-291', 'amour', 'Qu''est-ce qui te fait te sentir choisi dans la durée ?'),
  ('as-292', 'amour', 'Quel geste d''amitié amoureuse te touche ?'),
  ('as-293', 'amour', 'Comment aimes-tu qu''on se dise pardon ?'),
  ('as-294', 'amour', 'Qu''est-ce qui te fait te sentir aimé sans être jugé ?'),
  ('as-295', 'amour', 'Quelle attention te semble la plus sincère ?'),
  ('as-296', 'amour', 'Comment aimes-tu qu''on se projette dans l''intimité ?'),
  ('as-297', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la tendresse ?'),
  ('as-298', 'amour', 'Quel moment de calme à deux préfères-tu ?'),
  ('as-299', 'amour', 'Comment aimes-tu qu''on se dise ce qu''on ressent ?'),
  ('as-300', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la complicité ?'),
  ('as-301', 'amour', 'Quelle petite chose aimerais-tu qu''on partage chaque soir ?'),
  ('as-302', 'amour', 'Comment aimes-tu qu''on se soutienne dans les épreuves ?'),
  ('as-303', 'amour', 'Qu''est-ce qui te fait te sentir aimé sans condition ?'),
  ('as-304', 'amour', 'Quel rituel de tendresse aimerais-tu garder ?'),
  ('as-305', 'amour', 'Comment aimes-tu qu''on se fasse des câlins ?'),
  ('as-306', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans l''attention ?'),
  ('as-307', 'amour', 'Quelle façon de séduire au quotidien te plaît ?'),
  ('as-308', 'amour', 'Comment aimes-tu qu''on se dise bonsoir ?'),
  ('as-309', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la durée ?'),
  ('as-310', 'amour', 'Quel geste te prouve le plus l''amour ?'),
  ('as-311', 'amour', 'Comment aimes-tu qu''on se confie l''un à l''autre ?'),
  ('as-312', 'amour', 'Qu''est-ce qui te fait te sentir aimé quand on est fatigué ?'),
  ('as-313', 'amour', 'Quelle attention te réchauffe le cœur ?'),
  ('as-314', 'amour', 'Comment aimes-tu qu''on se dise « je t''aime » ?'),
  ('as-315', 'amour', 'Qu''est-ce qui te fait te sentir aimé malgré les défauts ?'),
  ('as-316', 'amour', 'Quel moment aimerais-tu qu''on vive ensemble cette année ?'),
  ('as-317', 'amour', 'Comment aimes-tu qu''on se fasse des surprises simples ?'),
  ('as-318', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans le regard de l''autre ?'),
  ('as-319', 'amour', 'Quelle forme d''intimité te ressource ?'),
  ('as-320', 'amour', 'Comment aimes-tu qu''on se dise nos manques ?'),
  ('as-321', 'amour', 'Qu''est-ce qui te fait te sentir aimé au quotidien, concrètement ?'),
  ('as-322', 'amour', 'Quelle attention te semble la plus difficile mais la plus précieuse ?'),
  ('as-323', 'amour', 'Comment aimes-tu qu''on se prouve notre amour ?'),
  ('as-324', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les gestes ?'),
  ('as-325', 'amour', 'Quel moment de douceur aimerais-tu plus souvent ?'),
  ('as-326', 'amour', 'Comment aimes-tu qu''on se dise nos fiertés ?'),
  ('as-327', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la présence ?'),
  ('as-328', 'amour', 'Quelle façon d''être présent te rassure ?'),
  ('as-329', 'amour', 'Comment aimes-tu qu''on se dise nos petites joies ?'),
  ('as-330', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la simplicité ?'),
  ('as-331', 'amour', 'Quel geste de complicité te fait le plus sourire ?'),
  ('as-332', 'amour', 'Comment aimes-tu qu''on se dise nos rêves ?'),
  ('as-333', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la confiance ?'),
  ('as-334', 'amour', 'Quelle attention nourrit la confiance en couple ?'),
  ('as-335', 'amour', 'Comment aimes-tu qu''on se dise nos désaccords ?'),
  ('as-336', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans le respect ?'),
  ('as-337', 'amour', 'Quel moment de complicité aimerais-tu ritualiser ?'),
  ('as-338', 'amour', 'Comment aimes-tu qu''on se dise nos besoins sexuels ?'),
  ('as-339', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la fidélité ?'),
  ('as-340', 'amour', 'Quelle petite chose montre ton attachement ?'),
  ('as-341', 'amour', 'Comment aimes-tu qu''on se dise nos fragilités ?'),
  ('as-342', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans l''intimité émotionnelle ?'),
  ('as-343', 'amour', 'Quel geste de tendresse te fait te sentir soi ?'),
  ('as-344', 'amour', 'Comment aimes-tu qu''on se dise nos attentions préférées ?'),
  ('as-345', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les efforts ?'),
  ('as-346', 'amour', 'Quelle attention te rappelle pourquoi on s''aime ?'),
  ('as-347', 'amour', 'Comment aimes-tu qu''on se rappelle nos souvenirs ?'),
  ('as-348', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans le temps qui passe ?'),
  ('as-349', 'amour', 'Quel projet à deux te motive le plus ?'),
  ('as-350', 'amour', 'Comment aimes-tu qu''on se dise nos envies secrètes ?'),
  ('as-351', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la vulnérabilité ?'),
  ('as-352', 'amour', 'Quelle prise de risque aimerais-tu qu''on fasse à deux ?'),
  ('as-353', 'amour', 'Comment aimes-tu qu''on se dise nos fiertés de couple ?'),
  ('as-354', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les grands moments ?'),
  ('as-355', 'amour', 'Quel geste simple entretient notre flamme ?'),
  ('as-356', 'amour', 'Comment aimes-tu qu''on se dise nos peurs ?'),
  ('as-357', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les petits moments ?'),
  ('as-358', 'amour', 'Quelle attention te montre qu''on tient à nous ?'),
  ('as-359', 'amour', 'Comment aimes-tu qu''on se dise nos limites ?'),
  ('as-360', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la réciprocité ?'),
  ('as-361', 'amour', 'Quel échange te nourrit le plus dans notre couple ?'),
  ('as-362', 'amour', 'Comment aimes-tu qu''on se dise nos désirs pour nous ?'),
  ('as-363', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la solidarité ?'),
  ('as-364', 'amour', 'Quelle attention te fait te sentir à deux ?'),
  ('as-365', 'amour', 'Comment aimes-tu qu''on se dise nos succès ?'),
  ('as-366', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les égards ?'),
  ('as-367', 'amour', 'Quel équilibre aimerais-tu qu''on cultive à deux ?'),
  ('as-368', 'amour', 'Comment aimes-tu qu''on se dise nos imperfections ?'),
  ('as-369', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans l''acceptation ?'),
  ('as-370', 'amour', 'Quelle attention te fait te sentir choisi encore ?'),
  ('as-371', 'amour', 'Comment aimes-tu qu''on se dise nos ambitions ?'),
  ('as-372', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les choix communs ?'),
  ('as-373', 'amour', 'Quel geste de respect entretient notre amour ?'),
  ('as-374', 'amour', 'Comment aimes-tu qu''on se dise nos accords ?'),
  ('as-375', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans les compromis ?'),
  ('as-376', 'amour', 'Quelle attention te fait te sentir en équipe ?'),
  ('as-377', 'amour', 'Comment aimes-tu qu''on se dise nos limites affectives ?'),
  ('as-378', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la douceur ?'),
  ('as-379', 'amour', 'Quel rythme aimerais-tu donner à notre relation ?'),
  ('as-380', 'amour', 'Comment aimes-tu qu''on se dise nos besoins de solitude ?'),
  ('as-381', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans l''espace laissé ?'),
  ('as-382', 'amour', 'Quelle attention te fait te sentir respecté dans ta liberté ?'),
  ('as-383', 'amour', 'Comment aimes-tu qu''on se dise nos envies d''ailleurs ?'),
  ('as-384', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans l''aventure commune ?'),
  ('as-385', 'amour', 'Quel rêve aimerais-tu qu''on partage ?'),
  ('as-386', 'amour', 'Comment aimes-tu qu''on se dise nos projets fous ?'),
  ('as-387', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la folie douce ?'),
  ('as-388', 'amour', 'Quelle attention te fait te sentir jeune ?'),
  ('as-389', 'amour', 'Comment aimes-tu qu''on se dise nos souvenirs préférés ?'),
  ('as-390', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans le passé partagé ?'),
  ('as-391', 'amour', 'Quel lien entre passé et avenir aimerais-tu renforcer ?'),
  ('as-392', 'amour', 'Comment aimes-tu qu''on se dise nos fiertés communes ?'),
  ('as-393', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la construction ?'),
  ('as-394', 'amour', 'Quelle attention te fait te sentir co-propriétaire de notre histoire ?'),
  ('as-395', 'amour', 'Comment aimes-tu qu''on se dise nos rôles dans le couple ?'),
  ('as-396', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la complémentarité ?'),
  ('as-397', 'amour', 'Quel équilibre donne-réception aimerais-tu ?'),
  ('as-398', 'amour', 'Comment aimes-tu qu''on se dise nos attentes ?'),
  ('as-399', 'amour', 'Qu''est-ce qui te fait te sentir aimé quand tout va bien ?'),
  ('as-400', 'amour', 'Quelle attention te fait te sentir aimé dans la joie ?'),
  ('as-401', 'amour', 'Comment aimes-tu qu''on se dise nos gratitudes ?'),
  ('as-402', 'amour', 'Qu''est-ce qui te fait te sentir aimé même dans les désaccords ?'),
  ('as-403', 'amour', 'Quel mode de résolution aimerais-tu pour nous ?'),
  ('as-404', 'amour', 'Comment aimes-tu qu''on se dise nos blessures ?'),
  ('as-405', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la réparation ?'),
  ('as-406', 'amour', 'Quelle attention te fait te sentir à nouveau bien après une tension ?'),
  ('as-407', 'amour', 'Comment aimes-tu qu''on se dise nos pardons ?'),
  ('as-408', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans le renouveau ?'),
  ('as-409', 'amour', 'Quelle attention te fait te sentir aimé chaque saison ?'),
  ('as-410', 'amour', 'Comment aimes-tu qu''on se dise nos envies de changement ?'),
  ('as-411', 'amour', 'Qu''est-ce qui te fait te sentir aimé dans la nouveauté ?'),
  ('as-412', 'amour', 'Quel espace aimerais-tu qu''on invente pour nous ?')
on conflict (code) do nothing;

-- Secrets et confidences (307 questions)
insert into public.questions (code, category, body) values
  ('sc-101', 'secrets', 'Quel non-dit pèse le plus dans ta vie ?'),
  ('sc-102', 'secrets', 'Quelle chose aimerais-tu enfin oser avouer ?'),
  ('sc-103', 'secrets', 'Quel poids portes-tu sans jamais te plaindre ?'),
  ('sc-104', 'secrets', 'Quelle pensée te gêne et que tu chasses ?'),
  ('sc-105', 'secrets', 'Quel souvenir te fait encore monter les larmes ?'),
  ('sc-106', 'secrets', 'Qu''est-ce que tu n''as jamais dit à ton meilleur ami ?'),
  ('sc-107', 'secrets', 'Quelle peur ne te quitte jamais vraiment ?'),
  ('sc-108', 'secrets', 'Quel désir tu n''as jamais nommé ?'),
  ('sc-109', 'secrets', 'Quelle part de ton histoire tu gardes secrète ?'),
  ('sc-110', 'secrets', 'Qu''est-ce qui te fait te sentir rarement compris ?'),
  ('sc-111', 'secrets', 'Quel besoin tu n''as jamais su exprimer ?'),
  ('sc-112', 'secrets', 'Quelle chose t''a marqué pour la vie ?'),
  ('sc-113', 'secrets', 'Quel combat intérieur mènes-tu seul ?'),
  ('sc-114', 'secrets', 'Quelle parole t''a marqué négativement ?'),
  ('sc-115', 'secrets', 'Qu''est-ce que tu n''as jamais osé demander à ton partenaire ?'),
  ('sc-116', 'secrets', 'Quel échec t''a le plus touché ?'),
  ('sc-117', 'secrets', 'Quelle vérité tu portes et que tu tais ?'),
  ('sc-118', 'secrets', 'Quel espoir tu n''as confié à personne ?'),
  ('sc-119', 'secrets', 'Quelle blessure te rend prudent ?'),
  ('sc-120', 'secrets', 'Qu''est-ce qui te fait te sentir à part depuis l''enfance ?'),
  ('sc-121', 'secrets', 'Quel secret de famille t''habite ?'),
  ('sc-122', 'secrets', 'Quelle décision passée te hante encore ?'),
  ('sc-123', 'secrets', 'Quel besoin d''amour tu n''assumes pas ?'),
  ('sc-124', 'secrets', 'Qu''est-ce que tu n''avoues pas par peur du regard ?'),
  ('sc-125', 'secrets', 'Quelle chose te fait te sentir nul certains jours ?'),
  ('sc-126', 'secrets', 'Quel souvenir t''empêche d''avancer ?'),
  ('sc-127', 'secrets', 'Quelle confiance brisée n''a jamais guéri ?'),
  ('sc-128', 'secrets', 'Quel ressentiment tu gardes ?'),
  ('sc-129', 'secrets', 'Qu''est-ce que tu n''as jamais pu oublier ?'),
  ('sc-130', 'secrets', 'Quel manque affectif t''a construit ?'),
  ('sc-131', 'secrets', 'Quelle peur t''a empêché de vivre quelque chose ?'),
  ('sc-132', 'secrets', 'Quel rêve abandonné te revient parfois ?'),
  ('sc-133', 'secrets', 'Quelle chose tu n''as dite qu''à toi-même ?'),
  ('sc-134', 'secrets', 'Quel besoin de réassurance te guide ?'),
  ('sc-135', 'secrets', 'Qu''est-ce qui te fait te sentir fragile sans le montrer ?'),
  ('sc-136', 'secrets', 'Quelle expérience t''a changé profondément ?'),
  ('sc-137', 'secrets', 'Quel secret tu portes depuis l''adolescence ?'),
  ('sc-138', 'secrets', 'Quelle culpabilité t''accompagne ?'),
  ('sc-139', 'secrets', 'Quel jugement des autres t''a marqué ?'),
  ('sc-140', 'secrets', 'Qu''est-ce que tu n''as jamais réussi à pardonner ?'),
  ('sc-141', 'secrets', 'Quelle insécurité te poursuit en amour ?'),
  ('sc-142', 'secrets', 'Quel besoin de contrôle te rassure ?'),
  ('sc-143', 'secrets', 'Qu''est-ce qui te fait te sentir coupable envers un proche ?'),
  ('sc-144', 'secrets', 'Quelle vérité te libérerait de la dire ?'),
  ('sc-145', 'secrets', 'Quel non-dit familial te pèse ?'),
  ('sc-146', 'secrets', 'Quelle peur de l''avenir te freine ?'),
  ('sc-147', 'secrets', 'Quel souvenir tu chéris en secret ?'),
  ('sc-148', 'secrets', 'Qu''est-ce que tu n''as jamais osé tenter ?'),
  ('sc-149', 'secrets', 'Quel besoin de reconnaissance t''a fait souffrir ?'),
  ('sc-150', 'secrets', 'Quelle chose te fait te sentir illégitime dans ta place ?'),
  ('sc-151', 'secrets', 'Quel secret d''argent portes-tu ?'),
  ('sc-152', 'secrets', 'Quelle honte tu n''as jamais surpassée ?'),
  ('sc-153', 'secrets', 'Qu''est-ce qui te fait te sentir différent des autres ?'),
  ('sc-154', 'secrets', 'Quel besoin d''appartenance t''a fait te trahir ?'),
  ('sc-155', 'secrets', 'Quelle relation passée t''a marqué durablement ?'),
  ('sc-156', 'secrets', 'Quel regret de ne pas avoir parlé te pèse ?'),
  ('sc-157', 'secrets', 'Qu''est-ce que tu n''as jamais dit à ceux qui t''ont jugé ?'),
  ('sc-158', 'secrets', 'Quelle peur de l''engagement te taraude ?'),
  ('sc-159', 'secrets', 'Quel besoin de fuite t''habite parfois ?'),
  ('sc-160', 'secrets', 'Quelle chose te fait te sentir pas à ta place ?'),
  ('sc-161', 'secrets', 'Quel secret de cœur tu gardes encore ?'),
  ('sc-162', 'secrets', 'Qu''est-ce qui t''a fait le plus de mal sans que tu le dises ?'),
  ('sc-163', 'secrets', 'Quelle phrase d''un proche te hante ?'),
  ('sc-164', 'secrets', 'Quel besoin d''être rassuré t''habite ?'),
  ('sc-165', 'secrets', 'Quelle chose t''a fait perdre foi en quelqu''un ?'),
  ('sc-166', 'secrets', 'Quel souvenir te fait te sentir vulnérable ?'),
  ('sc-167', 'secrets', 'Qu''est-ce que tu n''as jamais avoué à ta famille ?'),
  ('sc-168', 'secrets', 'Quelle chose te fait te sentir seul au quotidien ?'),
  ('sc-169', 'secrets', 'Quel besoin d''amitié profonde te travaille ?'),
  ('sc-170', 'secrets', 'Quelle jalousie d''enfance te reste ?'),
  ('sc-171', 'secrets', 'Qu''est-ce qui te fait te sentir en dette envers quelqu''un ?'),
  ('sc-172', 'secrets', 'Quel secret de santé portes-tu ?'),
  ('sc-173', 'secrets', 'Quelle peur de la maladie te touche ?'),
  ('sc-174', 'secrets', 'Quel besoin d''aide tu n''oses pas exprimer ?'),
  ('sc-175', 'secrets', 'Qu''est-ce qui te fait te sentir faible ?'),
  ('sc-176', 'secrets', 'Quel souvenir de rejet te suit ?'),
  ('sc-177', 'secrets', 'Quelle chose te fait te sentir indigne ?'),
  ('sc-178', 'secrets', 'Quel besoin de sécurité affective te guide ?'),
  ('sc-179', 'secrets', 'Qu''est-ce que tu n''as jamais dit par fierté ?'),
  ('sc-180', 'secrets', 'Quelle vérité sur ton enfance tu caches ?'),
  ('sc-181', 'secrets', 'Quel besoin de tendresse d''enfance te reste ?'),
  ('sc-182', 'secrets', 'Quelle chose te fait te sentir à part dans ta famille ?'),
  ('sc-183', 'secrets', 'Quel secret intime tu n''as jamais partagé ?'),
  ('sc-184', 'secrets', 'Qu''est-ce qui te fait te sentir en insécurité ?'),
  ('sc-185', 'secrets', 'Quel besoin d''être aimé sans condition te guide ?'),
  ('sc-186', 'secrets', 'Quelle chose te fait te sentir pris au piège ?'),
  ('sc-187', 'secrets', 'Quel besoin de liberté te ronge en silence ?'),
  ('sc-188', 'secrets', 'Qu''est-ce que tu n''as jamais pu dire à un ex ?'),
  ('sc-189', 'secrets', 'Quelle blessure d''abandon te guide ?'),
  ('sc-190', 'secrets', 'Quel besoin de réparation affective te travaille ?'),
  ('sc-191', 'secrets', 'Quelle chose te fait te sentir pas assez ?'),
  ('sc-192', 'secrets', 'Quel secret tu livres ici et nulle part ailleurs ?'),
  ('sc-193', 'secrets', 'Quelle chose n''as-tu jamais osé dire à personne ?'),
  ('sc-194', 'secrets', 'Quel rêve secret gardes-tu pour toi ?'),
  ('sc-195', 'secrets', 'De quoi as-tu le plus peur de parler ?'),
  ('sc-196', 'secrets', 'Quelle erreur regrettes-tu en silence ?'),
  ('sc-197', 'secrets', 'Quel sentiment caches-tu le plus souvent ?'),
  ('sc-198', 'secrets', 'Qu''est-ce que tu n''admets pas facilement ?'),
  ('sc-199', 'secrets', 'Quelle envie secrète t''habite ?'),
  ('sc-200', 'secrets', 'Que ferais-tu si personne ne te jugeait ?'),
  ('sc-201', 'secrets', 'Quelle pensée te revient souvent la nuit ?'),
  ('sc-202', 'secrets', 'Quel souvenir te rend encore vulnérable ?'),
  ('sc-203', 'secrets', 'Qu''est-ce qui te manque sans que tu le dises ?'),
  ('sc-204', 'secrets', 'Quelle confiance n''as-tu jamais trahie ?'),
  ('sc-205', 'secrets', 'Quel secret de famille portes-tu ?'),
  ('sc-206', 'secrets', 'Qu''est-ce qui te fait te sentir seul même entouré ?'),
  ('sc-207', 'secrets', 'Quelle blessure d''enfance t''a marqué ?'),
  ('sc-208', 'secrets', 'Quel besoin tu n''oses pas demander ?'),
  ('sc-209', 'secrets', 'Qu''est-ce qui te ronge discrètement ?'),
  ('sc-210', 'secrets', 'Quelle décision aimerais-tu revenir en arrière ?'),
  ('sc-211', 'secrets', 'Qu''accepterais-tu enfin si tu n''avais pas peur ?'),
  ('sc-212', 'secrets', 'Quel est ton plus grand remords ?'),
  ('sc-213', 'secrets', 'Qu''est-ce qui te fait pleurer quand tu es seul ?'),
  ('sc-214', 'secrets', 'Quelle chose ne dis-tu jamais à voix haute ?'),
  ('sc-215', 'secrets', 'Quel espoir secret nourris-tu ?'),
  ('sc-216', 'secrets', 'Qu''est-ce qui te rend jaloux sans l''avouer ?'),
  ('sc-217', 'secrets', 'Quelle limite n''as-tu jamais osé poser ?'),
  ('sc-218', 'secrets', 'Qu''est-ce qui t''humilie encore un peu ?'),
  ('sc-219', 'secrets', 'Quelle peur te paralyse parfois ?'),
  ('sc-220', 'secrets', 'Quel échec ne s''efface pas ?'),
  ('sc-221', 'secrets', 'Quel trait de toi tu caches en public ?'),
  ('sc-222', 'secrets', 'Quelle promesse n''as-tu pas tenue ?'),
  ('sc-223', 'secrets', 'Qu''est-ce qui te fait peur dans l''amour ?'),
  ('sc-224', 'secrets', 'Quelle part de toi tu ne montres à personne ?'),
  ('sc-225', 'secrets', 'Quel jugement portes-tu sur toi trop durement ?'),
  ('sc-226', 'secrets', 'Quelle chose t''obsède sans raison ?'),
  ('sc-227', 'secrets', 'Qu''est-ce qui te met en colère et que tu refoules ?'),
  ('sc-228', 'secrets', 'Quelle vérité te coûte à dire ?'),
  ('sc-229', 'secrets', 'Quel regret d''amitié portes-tu ?'),
  ('sc-230', 'secrets', 'Qu''est-ce qui te fait te sentir coupable ?'),
  ('sc-231', 'secrets', 'Quelle envie que tu juges inavouable ?'),
  ('sc-232', 'secrets', 'Quel mal-être tu n''as jamais expliqué ?'),
  ('sc-233', 'secrets', 'Qu''est-ce qui te fait te sentir seul face à un choix ?'),
  ('sc-234', 'secrets', 'Quelle chose aimerais-tu effacer ?'),
  ('sc-235', 'secrets', 'Quel mensonge as-tu dit par facilité ?'),
  ('sc-236', 'secrets', 'Qu''est-ce que tu n''as jamais dit à ta famille ?'),
  ('sc-237', 'secrets', 'Quelle peur tu as gardée pour toi ?'),
  ('sc-238', 'secrets', 'Quel désir tu n''exprimes jamais ?'),
  ('sc-239', 'secrets', 'Qu''est-ce qui te fait te sentir illégitime ?'),
  ('sc-240', 'secrets', 'Quelle histoire tu n''as racontée à personne ?'),
  ('sc-241', 'secrets', 'Quel secret te pèse encore ?'),
  ('sc-242', 'secrets', 'Que dirais-tu si on ne te jugeait jamais ?'),
  ('sc-243', 'secrets', 'Quelle chose t''a blessé sans que tu le montres ?'),
  ('sc-244', 'secrets', 'Quel besoin d''amour tu n''oses pas nommer ?'),
  ('sc-245', 'secrets', 'Qu''est-ce qui te fait te sentir petit ?'),
  ('sc-246', 'secrets', 'Quel souvenir tu n''as jamais digéré ?'),
  ('sc-247', 'secrets', 'Quelle vérité tu évites sur toi ?'),
  ('sc-248', 'secrets', 'Quel conflit intérieur portes-tu ?'),
  ('sc-249', 'secrets', 'Qu''est-ce qui te fait te sentir seul même aimé ?'),
  ('sc-250', 'secrets', 'Quel cercle vicieux te retient ?'),
  ('sc-251', 'secrets', 'Quelle chose t''a fait douter de toi pour toujours ?'),
  ('sc-252', 'secrets', 'Quel rôle tu joues pour être accepté ?'),
  ('sc-253', 'secrets', 'Qu''est-ce que tu n''avoues pas dans le couple ?'),
  ('sc-254', 'secrets', 'Quelle crainte te poursuit ?'),
  ('sc-255', 'secrets', 'Quel trait de caractère tu caches ?'),
  ('sc-256', 'secrets', 'Qu''est-ce qui te rend vulnérable et que tu détestes ?'),
  ('sc-257', 'secrets', 'Quelle chose te fait te sentir inférieur ?'),
  ('sc-258', 'secrets', 'Quel échec tu n''as jamais accepté ?'),
  ('sc-259', 'secrets', 'Quelle peur de l''abandon te guide ?'),
  ('sc-260', 'secrets', 'Qu''est-ce que tu refoules depuis longtemps ?'),
  ('sc-261', 'secrets', 'Quelle vérité tu ne veux pas entendre ?'),
  ('sc-262', 'secrets', 'Quel besoin de reconnaissance tu as ?'),
  ('sc-263', 'secrets', 'Qu''est-ce qui te rend triste sans que tu le dises ?'),
  ('sc-264', 'secrets', 'Quelle chose tu n''as jamais pardonnée à toi ?'),
  ('sc-265', 'secrets', 'Quel secret d''amour tu gardes ?'),
  ('sc-266', 'secrets', 'Quelle envie de changer te retient ?'),
  ('sc-267', 'secrets', 'Qu''est-ce qui te fait te sentir honteux ?'),
  ('sc-268', 'secrets', 'Quel souvenir tu n''oses pas regarder en face ?'),
  ('sc-269', 'secrets', 'Quelle phrase ne t''a jamais quitté ?'),
  ('sc-270', 'secrets', 'Quel manque tu n''as jamais comblé ?'),
  ('sc-271', 'secrets', 'Qu''est-ce qui te fait te sentir fragile ?'),
  ('sc-272', 'secrets', 'Quelle chose tu fais semblant d''aimer ?'),
  ('sc-273', 'secrets', 'Quel désaccord intime tu tais ?'),
  ('sc-274', 'secrets', 'Quelle limite tu n''as jamais exprimée ?'),
  ('sc-275', 'secrets', 'Qu''est-ce que tu n''as jamais osé demander ?'),
  ('sc-276', 'secrets', 'Quel doute sur toi tu ne partages pas ?'),
  ('sc-277', 'secrets', 'Quelle chose t''empêche de dormir ?'),
  ('sc-278', 'secrets', 'Quel regret d''enfance tu portes ?'),
  ('sc-279', 'secrets', 'Qu''est-ce qui te fait te sentir rejeté ?'),
  ('sc-280', 'secrets', 'Quelle peur du jugement te freine ?'),
  ('sc-281', 'secrets', 'Quel besoin d''être rassuré tu caches ?'),
  ('sc-282', 'secrets', 'Qu''est-ce qui te fait te sentir pas à la hauteur ?'),
  ('sc-283', 'secrets', 'Quelle confiance tu n''as jamais accordée ?'),
  ('sc-284', 'secrets', 'Quel secret de couple tu portes ?'),
  ('sc-285', 'secrets', 'Quelle jalousie tu n''avoues pas ?'),
  ('sc-286', 'secrets', 'Qu''est-ce qui te fait te sentir seul dans la foule ?'),
  ('sc-287', 'secrets', 'Quelle vérité tu retardes ?'),
  ('sc-288', 'secrets', 'Quel échec refoulé te revient ?'),
  ('sc-289', 'secrets', 'Quelle chose au fond de toi te fait encore mal ?'),
  ('sc-290', 'secrets', 'Quel espoir tu n''oses pas dire ?'),
  ('sc-291', 'secrets', 'Quelle peur de décevoir te poursuit ?'),
  ('sc-292', 'secrets', 'Qu''est-ce qui te fait te sentir indigne d''être aimé ?'),
  ('sc-293', 'secrets', 'Quelle histoire tu caches par pudeur ?'),
  ('sc-294', 'secrets', 'Quel besoin d''attention tu n''exprimes pas ?'),
  ('sc-295', 'secrets', 'Quelle chose te ronge dans le silence ?'),
  ('sc-296', 'secrets', 'Quel pardon tu n''arrives pas à donner à toi-même ?'),
  ('sc-297', 'secrets', 'Qu''est-ce qui te fait te sentir en dette ?'),
  ('sc-298', 'secrets', 'Quelle part de ton passé te hante ?'),
  ('sc-299', 'secrets', 'Quel verdict tu portes sur toi sans preuve ?'),
  ('sc-300', 'secrets', 'Qu''est-ce qui te fait te sentir seul dans ton couple ?'),
  ('sc-301', 'secrets', 'Quelle chose tu n''as jamais dite par peur de blesser ?'),
  ('sc-302', 'secrets', 'Quel besoin de tendresse tu dissimules ?'),
  ('sc-303', 'secrets', 'Quelle peur de l''échec te bloque ?'),
  ('sc-304', 'secrets', 'Qu''est-ce que tu as fait de pire selon toi ?'),
  ('sc-305', 'secrets', 'Quelle envie de tout recommencer te traverse ?'),
  ('sc-306', 'secrets', 'Quel secret te tient éveillé ?'),
  ('sc-307', 'secrets', 'Quelle chose tu n''as jamais réglée ?'),
  ('sc-308', 'secrets', 'Quel deuil non fait tu portes ?'),
  ('sc-309', 'secrets', 'Qu''est-ce qui te fait te sentir coupable sans raison ?'),
  ('sc-310', 'secrets', 'Quelle vérité tu crains de découvrir sur toi ?'),
  ('sc-311', 'secrets', 'Quel besoin d''être vu tu caches ?'),
  ('sc-312', 'secrets', 'Quelle chose te fait te sentir exister seulement parfois ?'),
  ('sc-313', 'secrets', 'Quel poids tu portes seul ?'),
  ('sc-314', 'secrets', 'Qu''est-ce que tu n''as jamais pu dire à ta mère ou ton père ?'),
  ('sc-315', 'secrets', 'Quelle peur d''être un poids te freine ?'),
  ('sc-316', 'secrets', 'Quel souvenir doré te console en secret ?'),
  ('sc-317', 'secrets', 'Quelle envie de fuir te traverse ?'),
  ('sc-318', 'secrets', 'Qu''est-ce qui te fait te sentir à part ?'),
  ('sc-319', 'secrets', 'Quel défaut tu détestes chez toi ?'),
  ('sc-320', 'secrets', 'Quelle confiance tu n''as jamais osé donner ?'),
  ('sc-321', 'secrets', 'Quel amour tu n''as jamais déclaré ?'),
  ('sc-322', 'secrets', 'Qu''est-ce qui te fait te sentir seul au monde ?'),
  ('sc-323', 'secrets', 'Quelle chose tu n''as jamais avouée par honte ?'),
  ('sc-324', 'secrets', 'Quel besoin de sécurité tu caches ?'),
  ('sc-325', 'secrets', 'Quelle blessure te rend méfiant ?'),
  ('sc-326', 'secrets', 'Qu''est-ce que tu n''as jamais pu pardonner à un autre ?'),
  ('sc-327', 'secrets', 'Quel rêve de gamin tu as abandonné ?'),
  ('sc-328', 'secrets', 'Quelle chose te fait te sentir perdu ?'),
  ('sc-329', 'secrets', 'Quel secret tu ne diras peut-être jamais ?'),
  ('sc-330', 'secrets', 'Quelle faiblesse tu caches derrière la force ?'),
  ('sc-331', 'secrets', 'Qu''est-ce qui te fait te sentir trahi ?'),
  ('sc-332', 'secrets', 'Quel regret de parole tu portes ?'),
  ('sc-333', 'secrets', 'Quelle envie de tendresse tu n''oses pas exprimer ?'),
  ('sc-334', 'secrets', 'Qu''est-ce qui te fait te sentir seul dans le plaisir ?'),
  ('sc-335', 'secrets', 'Quel besoin d''être choisi te guide ?'),
  ('sc-336', 'secrets', 'Quelle chose te rassure en secret ?'),
  ('sc-337', 'secrets', 'Quel doute sur notre lien tu n''exprimes jamais ?'),
  ('sc-338', 'secrets', 'Qu''est-ce qui te fait te sentir fragile dans le couple ?'),
  ('sc-339', 'secrets', 'Quelle peur de l''engagement te traverse ?'),
  ('sc-340', 'secrets', 'Quel besoin de liberté tu tais ?'),
  ('sc-341', 'secrets', 'Quelle chose tu n''as jamais demandée par fierté ?'),
  ('sc-342', 'secrets', 'Qu''est-ce qui te fait te sentir exclu ?'),
  ('sc-343', 'secrets', 'Quel manque d''amour d''enfance te poursuit ?'),
  ('sc-344', 'secrets', 'Quelle chose tu n''as jamais dite de peur d''être jugé ?'),
  ('sc-345', 'secrets', 'Quel besoin de reconnaissance tu n''assumes pas ?'),
  ('sc-346', 'secrets', 'Qu''est-ce qui te fait te sentir trop ?'),
  ('sc-347', 'secrets', 'Quelle auto-critique te hante ?'),
  ('sc-348', 'secrets', 'Quel souvenir te fait rougir encore ?'),
  ('sc-349', 'secrets', 'Quelle peur du rejet te guide ?'),
  ('sc-350', 'secrets', 'Qu''est-ce qui te fait te sentir trop sensible ?'),
  ('sc-351', 'secrets', 'Quel désir de plaire te poursuit ?'),
  ('sc-352', 'secrets', 'Quelle chose tu n''avoues jamais à un partenaire ?'),
  ('sc-353', 'secrets', 'Quel besoin d''être prioritaire tu caches ?'),
  ('sc-354', 'secrets', 'Qu''est-ce qui te fait te sentir mal aimé ?'),
  ('sc-355', 'secrets', 'Quelle jalousie secrète te ronge ?'),
  ('sc-356', 'secrets', 'Quel besoin de contrôle tu dissimules ?'),
  ('sc-357', 'secrets', 'Qu''est-ce qui t''a fait perdre confiance en toi ?'),
  ('sc-358', 'secrets', 'Quelle peur d''être abandonné te guide ?'),
  ('sc-359', 'secrets', 'Quel ego blessé te retient ?'),
  ('sc-360', 'secrets', 'Qu''est-ce qui te fait te sentir en danger ?'),
  ('sc-361', 'secrets', 'Quelle chose tu n''as jamais dite pour protéger quelqu''un ?'),
  ('sc-362', 'secrets', 'Quel sacrifice silencieux tu as fait ?'),
  ('sc-363', 'secrets', 'Qu''est-ce qui te fait te sentir oublié ?'),
  ('sc-364', 'secrets', 'Quel besoin d''être rassuré te guide ?'),
  ('sc-365', 'secrets', 'Quelle chose tu n''as jamais assumée ?'),
  ('sc-366', 'secrets', 'Quel regret de non-dit te pèse ?'),
  ('sc-367', 'secrets', 'Qu''est-ce qui te fait te sentir vide parfois ?'),
  ('sc-368', 'secrets', 'Quel besoin de sens te travaille ?'),
  ('sc-369', 'secrets', 'Quelle question tu évites de te poser ?'),
  ('sc-370', 'secrets', 'Quel secret tu partages ici pour la première fois ?'),
  ('sc-371', 'secrets', 'Qu''est-ce que tu n''as jamais osé demander dans l''intimité ?'),
  ('sc-372', 'secrets', 'Quelle chose te fait te sentir honteux sans raison ?'),
  ('sc-373', 'secrets', 'Quel besoin de douceur tu tais ?'),
  ('sc-374', 'secrets', 'Quelle peur de déplaire te freine ?'),
  ('sc-375', 'secrets', 'Qu''est-ce qui te fait te sentir seul dans tes rêves ?'),
  ('sc-376', 'secrets', 'Quel soulagement tu n''as jamais confessé ?'),
  ('sc-377', 'secrets', 'Quelle chose tu fais pour être aimé ?'),
  ('sc-378', 'secrets', 'Quel besoin d''être accepté te guide ?'),
  ('sc-379', 'secrets', 'Qu''est-ce qui te fait te sentir pas désirable ?'),
  ('sc-380', 'secrets', 'Quelle blessure d''amour ancienne te marque ?'),
  ('sc-381', 'secrets', 'Quel besoin de réparation tu portes ?'),
  ('sc-382', 'secrets', 'Quelle chose te fait te sentir coupable en amour ?'),
  ('sc-383', 'secrets', 'Quel besoin d''être pardonné tu caches ?'),
  ('sc-384', 'secrets', 'Qu''est-ce qui te fait te sentir indigne d''amour ?'),
  ('sc-385', 'secrets', 'Quel pardon intérieur tu cherches ?'),
  ('sc-386', 'secrets', 'Quelle chose tu n''as jamais dite à ceux qui t''ont blessé ?'),
  ('sc-387', 'secrets', 'Quel besoin d''être entendu te guide ?'),
  ('sc-388', 'secrets', 'Qu''est-ce qui te fait te sentir incompris ?'),
  ('sc-389', 'secrets', 'Quel désir d''authenticité te pousse ?'),
  ('sc-390', 'secrets', 'Quelle chose te fait te sentir seul malgré tout ?'),
  ('sc-391', 'secrets', 'Quel besoin d''appartenance tu portes ?'),
  ('sc-392', 'secrets', 'Qu''est-ce qui te fait te sentir différent ?'),
  ('sc-393', 'secrets', 'Quel secret de vulnérabilité tu livres aujourd''hui ?'),
  ('sc-394', 'secrets', 'Quelle peur de la solitude te guide ?'),
  ('sc-395', 'secrets', 'Quel besoin de liens profonds te travaille ?'),
  ('sc-396', 'secrets', 'Quelle chose te fait te sentir rejeté sans raison ?'),
  ('sc-397', 'secrets', 'Quel besoin d''être à la hauteur te pousse ?'),
  ('sc-398', 'secrets', 'Qu''est-ce qui te fait te sentir en échec ?'),
  ('sc-399', 'secrets', 'Quel désir de réconciliation te traverse ?'),
  ('sc-400', 'secrets', 'Quelle chose tu n''as jamais osé espérer ?'),
  ('sc-401', 'secrets', 'Quel besoin de tendresse profonde te guide ?'),
  ('sc-402', 'secrets', 'Qu''est-ce qui te fait te sentir aimable malgré tes défauts ?'),
  ('sc-403', 'secrets', 'Quel pardon de soi te reste à faire ?'),
  ('sc-404', 'secrets', 'Quelle chose te fait te sentir enfin toi ?'),
  ('sc-405', 'secrets', 'Quel besoin d''être aimé tel que tu es te guide ?'),
  ('sc-406', 'secrets', 'Qu''est-ce qui te fait te sentir en paix avec toi ?'),
  ('sc-407', 'secrets', 'Quel secret d''espoir tu livres ici ?')
on conflict (code) do nothing;

-- Pimenté (307 questions)
insert into public.questions (code, category, body) values
  ('pi-101', 'pimente', 'Quel petit geste me fait fondre instantanément ?'),
  ('pi-102', 'pimente', 'Quelle ambiance te met dans une humeur coquine ?'),
  ('pi-103', 'pimente', 'Qu''est-ce qui te fait te sentir séduisant au réveil ?'),
  ('pi-104', 'pimente', 'Quelle façon de me taquiner te plaît le plus ?'),
  ('pi-105', 'pimente', 'Quel regard aimerais-tu recevoir plus souvent ?'),
  ('pi-106', 'pimente', 'Qu''est-ce qui te met dans un état de douceur coquine ?'),
  ('pi-107', 'pimente', 'Quelle attention te fait te sentir désiré subtilement ?'),
  ('pi-108', 'pimente', 'Comment aimes-tu qu''on commence un moment tendre ?'),
  ('pi-109', 'pimente', 'Qu''est-ce qui te fait sourire d''un air complice ?'),
  ('pi-110', 'pimente', 'Quelle façon de te complimenter te séduit ?'),
  ('pi-111', 'pimente', 'Quel jeu de séduction élégant préfères-tu ?'),
  ('pi-112', 'pimente', 'Qu''est-ce qui te met dans une ambiance sensuelle ?'),
  ('pi-113', 'pimente', 'Quelle danse pourrait nous rapprocher ?'),
  ('pi-114', 'pimente', 'Quel moment de la soirée te plaît le plus ?'),
  ('pi-115', 'pimente', 'Qu''est-ce qui te rend tendrement osé ?'),
  ('pi-116', 'pimente', 'Quelle tenue te donne envie de séduire ?'),
  ('pi-117', 'pimente', 'Quel geste discret te fait de l''effet en public ?'),
  ('pi-118', 'pimente', 'Qu''est-ce qui te met dans un état de tendresse joueuse ?'),
  ('pi-119', 'pimente', 'Quelle attention te fait te sentir irrésistible ?'),
  ('pi-120', 'pimente', 'Comment aimes-tu qu''on se dise bonsoir quand on est complices ?'),
  ('pi-121', 'pimente', 'Qu''est-ce qui te fait frissonner de plaisir ?'),
  ('pi-122', 'pimente', 'Quel jeu de mots doux te fait sourire ?'),
  ('pi-123', 'pimente', 'Quelle façon de me regarder te plaît le matin ?'),
  ('pi-124', 'pimente', 'Qu''est-ce qui te met dans une humeur câline ?'),
  ('pi-125', 'pimente', 'Quelle attention te fait te sentir convoité ?'),
  ('pi-126', 'pimente', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('pi-127', 'pimente', 'Qu''est-ce qui te rend plus séducteur ?'),
  ('pi-128', 'pimente', 'Quel geste de complicité te fait frissonner ?'),
  ('pi-129', 'pimente', 'Quelle façon de me parler te plaît dans l''intimité ?'),
  ('pi-130', 'pimente', 'Qu''est-ce qui te met dans un état de désir tendre ?'),
  ('pi-131', 'pimente', 'Quelle attention te fait te sentir aimé et désiré ?'),
  ('pi-132', 'pimente', 'Comment aimes-tu qu''on se surprenne tendrement ?'),
  ('pi-133', 'pimente', 'Qu''est-ce qui te fait te sentir séduisant sans effort ?'),
  ('pi-134', 'pimente', 'Quel moment de rapprochement préfères-tu ?'),
  ('pi-135', 'pimente', 'Quelle façon de me prendre la main te plaît ?'),
  ('pi-136', 'pimente', 'Qu''est-ce qui te met dans une humeur taquine ?'),
  ('pi-137', 'pimente', 'Quelle attention te fait te sentir désirable ?'),
  ('pi-138', 'pimente', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('pi-139', 'pimente', 'Qu''est-ce qui te rend plus tendre face à moi ?'),
  ('pi-140', 'pimente', 'Quel jeu de séduction douce préfères-tu ?'),
  ('pi-141', 'pimente', 'Quelle façon de m''embrasser te fait vibrer ?'),
  ('pi-142', 'pimente', 'Qu''est-ce qui te met dans un état de complicité sensuelle ?'),
  ('pi-143', 'pimente', 'Quelle attention te fait te sentir précieux ?'),
  ('pi-144', 'pimente', 'Comment aimes-tu qu''on se complimente dans l''intimité ?'),
  ('pi-145', 'pimente', 'Qu''est-ce qui te fait te sentir séduit et respecté ?'),
  ('pi-146', 'pimente', 'Quel moment de tendresse aimerais-tu prolonger ?'),
  ('pi-147', 'pimente', 'Quelle façon de me charmer te plaît ?'),
  ('pi-148', 'pimente', 'Qu''est-ce qui te met dans une humeur joueuse et tendre ?'),
  ('pi-149', 'pimente', 'Quelle attention te fait fondre en silence ?'),
  ('pi-150', 'pimente', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('pi-151', 'pimente', 'Qu''est-ce qui te rend plus entreprenant tendrement ?'),
  ('pi-152', 'pimente', 'Quel regard complice aimerais-tu plus souvent ?'),
  ('pi-153', 'pimente', 'Quelle façon de me toucher te plaît ?'),
  ('pi-154', 'pimente', 'Qu''est-ce qui te met dans un état d''envie douce ?'),
  ('pi-155', 'pimente', 'Quelle attention te fait te sentir aimé et attirant ?'),
  ('pi-156', 'pimente', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('pi-157', 'pimente', 'Qu''est-ce qui te fait te sentir séduisant à mes yeux ?'),
  ('pi-158', 'pimente', 'Quel geste te fait sourire de désir ?'),
  ('pi-159', 'pimente', 'Quelle façon de me chuchoter te plaît ?'),
  ('pi-160', 'pimente', 'Qu''est-ce qui te met dans une ambiance douce et sensuelle ?'),
  ('pi-161', 'pimente', 'Quelle attention te fait te sentir prioritaire ?'),
  ('pi-162', 'pimente', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('pi-163', 'pimente', 'Qu''est-ce qui te rend plus câlin qu''à l''habitude ?'),
  ('pi-164', 'pimente', 'Quel moment de complicité préfères-tu ?'),
  ('pi-165', 'pimente', 'Quelle façon de me surprendre te plaît ?'),
  ('pi-166', 'pimente', 'Qu''est-ce qui te met dans un état de désir complice ?'),
  ('pi-167', 'pimente', 'Quelle attention te fait te sentir aimé tendrement ?'),
  ('pi-168', 'pimente', 'Comment aimes-tu qu''on se dise nos envies d''attention ?'),
  ('pi-169', 'pimente', 'Qu''est-ce qui te fait te sentir irrésistiblement séduit ?'),
  ('pi-170', 'pimente', 'Qu''est-ce qui t''allume le plus chez une personne ?'),
  ('pi-171', 'pimente', 'Quel genre de regard te fait fondre ?'),
  ('pi-172', 'pimente', 'Quelle tenue me va le mieux selon toi ?'),
  ('pi-173', 'pimente', 'Où aimes-tu qu''on te touche tendrement ?'),
  ('pi-174', 'pimente', 'Quel geste de séduction te fait craquer ?'),
  ('pi-175', 'pimente', 'Qu''est-ce qui te met dans l''ambiance ?'),
  ('pi-176', 'pimente', 'Quel compliment coquin te fait sourire ?'),
  ('pi-177', 'pimente', 'Quelle ambiance aimes-tu pour un moment à deux ?'),
  ('pi-178', 'pimente', 'Qu''est-ce qui te rend irrésistible ?'),
  ('pi-179', 'pimente', 'Quel jeu de séduction te plaît ?'),
  ('pi-180', 'pimente', 'Quelle partie du corps aimes-tu qu''on complimente ?'),
  ('pi-181', 'pimente', 'Qu''est-ce qui te fait rougir de désir ?'),
  ('pi-182', 'pimente', 'Quel rendez-vous galant te ferait rêver ?'),
  ('pi-183', 'pimente', 'Quelle musique te met dans de bonnes dispositions ?'),
  ('pi-184', 'pimente', 'Quel effleurement te fait frissonner ?'),
  ('pi-185', 'pimente', 'Qu''est-ce qui éveille ton désir subtilement ?'),
  ('pi-186', 'pimente', 'Quelle promesse coquine aimerais-tu entendre ?'),
  ('pi-187', 'pimente', 'Quel sourire te désarme ?'),
  ('pi-188', 'pimente', 'Qu''est-ce qui te rend plus entreprenant ?'),
  ('pi-189', 'pimente', 'Quelle caresse te détend et t''électrise à la fois ?'),
  ('pi-190', 'pimente', 'Quel fantasme doux aimerais-tu partager ?'),
  ('pi-191', 'pimente', 'Qu''est-ce qui te donne envie de moi ?'),
  ('pi-192', 'pimente', 'Quel moment de la journée te paraît le plus propice ?'),
  ('pi-193', 'pimente', 'Quelle façon de m''appeler te plaît ?'),
  ('pi-194', 'pimente', 'Qu''est-ce qui te fait te sentir séduisant ?'),
  ('pi-195', 'pimente', 'Quel regard échangé te marque le plus ?'),
  ('pi-196', 'pimente', 'Quelle attention coquine te touche ?'),
  ('pi-197', 'pimente', 'Qu''est-ce qui te met dans l''humeur câline ?'),
  ('pi-198', 'pimente', 'Quel geste de tendresse sensuelle préfères-tu ?'),
  ('pi-199', 'pimente', 'Quelle tenue aimerais-tu me voir porter ?'),
  ('pi-200', 'pimente', 'Qu''est-ce qui te rend câlin et taquin ?'),
  ('pi-201', 'pimente', 'Quel préambule te plaît le plus ?'),
  ('pi-202', 'pimente', 'Quelle façon de t''embrasser te fait vibrer ?'),
  ('pi-203', 'pimente', 'Qu''est-ce qui te fait te sentir désiré au quotidien ?'),
  ('pi-204', 'pimente', 'Quelle confidence coquine aimerais-tu faire ?'),
  ('pi-205', 'pimente', 'Quel jeu de regards te plaît ?'),
  ('pi-206', 'pimente', 'Qu''est-ce qui te met dans un état de désir ?'),
  ('pi-207', 'pimente', 'Quelle ambiance de chambre préfères-tu ?'),
  ('pi-208', 'pimente', 'Quel mot doux te fait de l''effet ?'),
  ('pi-209', 'pimente', 'Qu''est-ce qui te rend impatient de me retrouver ?'),
  ('pi-210', 'pimente', 'Quelle danse rapprochée te plaît ?'),
  ('pi-211', 'pimente', 'Quel geste de jalousie te rassure un peu ?'),
  ('pi-212', 'pimente', 'Qu''est-ce qui te rend tendre et coquin ?'),
  ('pi-213', 'pimente', 'Quelle façon de me complimenter te plaît ?'),
  ('pi-214', 'pimente', 'Quel moment de jeu te fait sourire ?'),
  ('pi-215', 'pimente', 'Qu''est-ce qui te fait te sentir irrésistible ?'),
  ('pi-216', 'pimente', 'Quelle attention sensuelle te détend ?'),
  ('pi-217', 'pimente', 'Quel rituel coquin aimerais-tu inventer ?'),
  ('pi-218', 'pimente', 'Qu''est-ce qui te fait te sentir désirable ?'),
  ('pi-219', 'pimente', 'Quelle manière de te regarder te plaît ?'),
  ('pi-220', 'pimente', 'Quel jeu de séduction aimerais-tu prolonger ?'),
  ('pi-221', 'pimente', 'Qu''est-ce qui te met de bonne humeur coquine ?'),
  ('pi-222', 'pimente', 'Quelle surprise tendre aimerais-tu ?'),
  ('pi-223', 'pimente', 'Quel geste discret te fait de l''effet ?'),
  ('pi-224', 'pimente', 'Qu''est-ce qui te rend plus affectueux ?'),
  ('pi-225', 'pimente', 'Quelle façon de danser te plaît à deux ?'),
  ('pi-226', 'pimente', 'Quel moment de complicité sensuelle aimes-tu ?'),
  ('pi-227', 'pimente', 'Qu''est-ce qui te fait te sentir voulu ?'),
  ('pi-228', 'pimente', 'Quelle caresse sur le dos préfères-tu ?'),
  ('pi-229', 'pimente', 'Quel jeu de mots coquin te plaît ?'),
  ('pi-230', 'pimente', 'Qu''est-ce qui te rend fou de désir avec élégance ?'),
  ('pi-231', 'pimente', 'Quelle ambiance de rendez-vous préfères-tu ?'),
  ('pi-232', 'pimente', 'Quel regard de braise aimerais-tu recevoir ?'),
  ('pi-233', 'pimente', 'Qu''est-ce qui te fait te sentir attirant ?'),
  ('pi-234', 'pimente', 'Quelle façon de t''inviter te plaît ?'),
  ('pi-235', 'pimente', 'Quel geste de tendresse sensuelle t''apaise ?'),
  ('pi-236', 'pimente', 'Qu''est-ce qui te met dans un état de douceur ?'),
  ('pi-237', 'pimente', 'Quel fantasme léger aimerais-tu réaliser ?'),
  ('pi-238', 'pimente', 'Qu''est-ce qui te fait te sentir plus hardi ?'),
  ('pi-239', 'pimente', 'Quelle façon de me complimenter te séduit ?'),
  ('pi-240', 'pimente', 'Quel moment de flirt te plaît ?'),
  ('pi-241', 'pimente', 'Qu''est-ce qui te fait rougir de plaisir ?'),
  ('pi-242', 'pimente', 'Quelle attention coquine te fait rire ?'),
  ('pi-243', 'pimente', 'Quel jeu de séduction aimerais-tu tester ?'),
  ('pi-244', 'pimente', 'Qu''est-ce qui te met dans l''ambiance en un mot ?'),
  ('pi-245', 'pimente', 'Quelle façon de me toucher te plaît ?'),
  ('pi-246', 'pimente', 'Quel regard complice te fait sourire ?'),
  ('pi-247', 'pimente', 'Qu''est-ce qui te rend plus joueur ?'),
  ('pi-248', 'pimente', 'Quelle tenue de soirée te plaît le plus ?'),
  ('pi-249', 'pimente', 'Qu''est-ce qui te fait te sentir choisi sensuellement ?'),
  ('pi-250', 'pimente', 'Quel geste de séduction aimerais-tu recevoir plus ?'),
  ('pi-251', 'pimente', 'Quelle ambiance éclairée préfères-tu ?'),
  ('pi-252', 'pimente', 'Qu''est-ce qui te rend tendrement entreprenant ?'),
  ('pi-253', 'pimente', 'Quel jeu de taquinerie te plaît ?'),
  ('pi-254', 'pimente', 'Qu''est-ce qui te fait te sentir irrésistiblement attiré ?'),
  ('pi-255', 'pimente', 'Quelle façon de m''attirer te plaît ?'),
  ('pi-256', 'pimente', 'Quel moment de tendresse intense aimes-tu ?'),
  ('pi-257', 'pimente', 'Qu''est-ce qui te met dans un état de désir tendre ?'),
  ('pi-258', 'pimente', 'Quelle confidence sensuelle aimerais-tu faire ?'),
  ('pi-259', 'pimente', 'Quel geste de complicité coquine te plaît ?'),
  ('pi-260', 'pimente', 'Qu''est-ce qui te fait te sentir désirable pour moi ?'),
  ('pi-261', 'pimente', 'Quelle façon de me surprendre te plaît ?'),
  ('pi-262', 'pimente', 'Quel jeu de nuque et d''oreille te fait frissonner ?'),
  ('pi-263', 'pimente', 'Qu''est-ce qui te met de bonne humeur sensuelle ?'),
  ('pi-264', 'pimente', 'Quelle ambiance électronique te plaît ?'),
  ('pi-265', 'pimente', 'Qu''est-ce qui te fait te sentir proche de moi ?'),
  ('pi-266', 'pimente', 'Quel moment de rapprochement préfères-tu ?'),
  ('pi-267', 'pimente', 'Quelle façon de me chuchoter te plaît ?'),
  ('pi-268', 'pimente', 'Quel geste discret te fait de l''effet en public ?'),
  ('pi-269', 'pimente', 'Qu''est-ce qui te rend tendre instantanément ?'),
  ('pi-270', 'pimente', 'Quelle manière de me prendre la main te plaît ?'),
  ('pi-271', 'pimente', 'Quel jeu de taquinerie sensuelle aimes-tu ?'),
  ('pi-272', 'pimente', 'Qu''est-ce qui te fait te sentir convoité ?'),
  ('pi-273', 'pimente', 'Quelle façon de t''embrasser le matin préfères-tu ?'),
  ('pi-274', 'pimente', 'Quel moment de douceur coquine aimes-tu ?'),
  ('pi-275', 'pimente', 'Qu''est-ce qui te met dans un état de bien-être sensuel ?'),
  ('pi-276', 'pimente', 'Quelle attention discrète te fait de l''effet ?'),
  ('pi-277', 'pimente', 'Quel regard en coin te plaît ?'),
  ('pi-278', 'pimente', 'Qu''est-ce qui te rend plus câlin ?'),
  ('pi-279', 'pimente', 'Quelle façon de me dire les choses te plaît ?'),
  ('pi-280', 'pimente', 'Quel geste de tendresse coquine préfères-tu ?'),
  ('pi-281', 'pimente', 'Qu''est-ce qui te fait te sentir séduisant au quotidien ?'),
  ('pi-282', 'pimente', 'Quelle ambiance sensorielle préfères-tu ?'),
  ('pi-283', 'pimente', 'Quel jeu de séduction aimerais-tu essayer ?'),
  ('pi-284', 'pimente', 'Qu''est-ce qui te met dans une humeur joueuse ?'),
  ('pi-285', 'pimente', 'Quelle façon de m''approcher te plaît ?'),
  ('pi-286', 'pimente', 'Quel moment de rapprochement te fait vibrer ?'),
  ('pi-287', 'pimente', 'Qu''est-ce qui te fait te sentir désiré comme jamais ?'),
  ('pi-288', 'pimente', 'Quelle attention douce te détend ?'),
  ('pi-289', 'pimente', 'Quel compliment sensuel te touche ?'),
  ('pi-290', 'pimente', 'Qu''est-ce qui te rend plus ardent ?'),
  ('pi-291', 'pimente', 'Quelle façon de me regarder te plaît ?'),
  ('pi-292', 'pimente', 'Quel jeu de mains te plaît ?'),
  ('pi-293', 'pimente', 'Qu''est-ce qui te met dans un état de grâce sensuelle ?'),
  ('pi-294', 'pimente', 'Quelle manière de me taquiner te fait sourire ?'),
  ('pi-295', 'pimente', 'Quel moment de complicité charnelle aimes-tu ?'),
  ('pi-296', 'pimente', 'Qu''est-ce qui te fait te sentir irrésistible ?'),
  ('pi-297', 'pimente', 'Quelle façon de me complimenter me fait fondre ?'),
  ('pi-298', 'pimente', 'Quel geste de séduction discret préfères-tu ?'),
  ('pi-299', 'pimente', 'Qu''est-ce qui te rend tendre et joueur ?'),
  ('pi-300', 'pimente', 'Quelle ambiance de soirée te plaît ?'),
  ('pi-301', 'pimente', 'Quel jeu d''approche te plaît ?'),
  ('pi-302', 'pimente', 'Qu''est-ce qui te fait te sentir voulue et désirée ?'),
  ('pi-303', 'pimente', 'Quelle façon de me dire bonsoir te plaît ?'),
  ('pi-304', 'pimente', 'Quel moment de tendresse passionnée aimes-tu ?'),
  ('pi-305', 'pimente', 'Qu''est-ce qui te met dans un état de douceur intense ?'),
  ('pi-306', 'pimente', 'Quelle attention sensuelle te fait te sentir vivant ?'),
  ('pi-307', 'pimente', 'Quel jeu de souffle et de peau te plaît ?'),
  ('pi-308', 'pimente', 'Qu''est-ce qui te fait te sentir séduisant sans mots ?'),
  ('pi-309', 'pimente', 'Quelle façon de m''attirer vers toi te plaît ?'),
  ('pi-310', 'pimente', 'Quel moment de complicité sensuelle préfères-tu ?'),
  ('pi-311', 'pimente', 'Qu''est-ce qui te rend plus entreprenant avec douceur ?'),
  ('pi-312', 'pimente', 'Quelle façon de me caresser la main te plaît ?'),
  ('pi-313', 'pimente', 'Quel jeu de regard et de sourire te plaît ?'),
  ('pi-314', 'pimente', 'Qu''est-ce qui te met dans un état d''envie tendre ?'),
  ('pi-315', 'pimente', 'Quelle attention coquine te fait te sentir aimé ?'),
  ('pi-316', 'pimente', 'Quel geste de séduction te met en confiance ?'),
  ('pi-317', 'pimente', 'Qu''est-ce qui te rend plus sensuel ?'),
  ('pi-318', 'pimente', 'Quelle ambiance de lumière préfères-tu ?'),
  ('pi-319', 'pimente', 'Quel jeu de mots doux te plaît ?'),
  ('pi-320', 'pimente', 'Qu''est-ce qui te fait te sentir irrésistible pour moi ?'),
  ('pi-321', 'pimente', 'Quelle façon de me prendre dans tes bras te plaît ?'),
  ('pi-322', 'pimente', 'Quel moment de tendresse physique aimes-tu ?'),
  ('pi-323', 'pimente', 'Qu''est-ce qui te met dans un état de désir doux ?'),
  ('pi-324', 'pimente', 'Quelle confidence légère aimerais-tu faire ?'),
  ('pi-325', 'pimente', 'Quel geste de complicité physique préfères-tu ?'),
  ('pi-326', 'pimente', 'Qu''est-ce qui te fait te sentir désirable et aimé ?'),
  ('pi-327', 'pimente', 'Quelle façon de me complimenter te plaît en public ?'),
  ('pi-328', 'pimente', 'Quel jeu de séduction douce aimerais-tu ?'),
  ('pi-329', 'pimente', 'Qu''est-ce qui te met dans une humeur tendre ?'),
  ('pi-330', 'pimente', 'Quelle manière de m''embrasser sur le front préfères-tu ?'),
  ('pi-331', 'pimente', 'Quel moment de douceur passionnée préfères-tu ?'),
  ('pi-332', 'pimente', 'Qu''est-ce qui te fait te sentir proche de moi instantanément ?'),
  ('pi-333', 'pimente', 'Quelle façon de me caresser les cheveux te plaît ?'),
  ('pi-334', 'pimente', 'Quel jeu de tendresse taquine aimes-tu ?'),
  ('pi-335', 'pimente', 'Qu''est-ce qui te rend plus affectueux sensuellement ?'),
  ('pi-336', 'pimente', 'Quelle attention sensuelle te fait te sentir à moi ?'),
  ('pi-337', 'pimente', 'Quel geste de séduction élégant préfères-tu ?'),
  ('pi-338', 'pimente', 'Qu''est-ce qui te fait te sentir attirant et désiré ?'),
  ('pi-339', 'pimente', 'Quelle façon de me dire les mots te plaît ?'),
  ('pi-340', 'pimente', 'Quel moment de rapprochement intime aimes-tu ?'),
  ('pi-341', 'pimente', 'Qu''est-ce qui te met dans un état de désir complice ?'),
  ('pi-342', 'pimente', 'Quelle attention coquine et respectueuse te plaît ?'),
  ('pi-343', 'pimente', 'Quel jeu de séduction physique aimes-tu ?'),
  ('pi-344', 'pimente', 'Qu''est-ce qui te fait te sentir irrésistiblement attirant ?'),
  ('pi-345', 'pimente', 'Quelle façon de me prendre la taille te plaît ?'),
  ('pi-346', 'pimente', 'Quel moment de tendresse sensuelle préfères-tu ?'),
  ('pi-347', 'pimente', 'Qu''est-ce qui te rend plus fou de douceur ?'),
  ('pi-348', 'pimente', 'Quelle ambiance douce préfères-tu ?'),
  ('pi-349', 'pimente', 'Quel jeu de mots doux et taquins te plaît ?'),
  ('pi-350', 'pimente', 'Qu''est-ce qui te fait te sentir désiré tendrement ?'),
  ('pi-351', 'pimente', 'Quelle façon de m''attirer dans tes bras te plaît ?'),
  ('pi-352', 'pimente', 'Quel moment de complicité passionnée préfères-tu ?'),
  ('pi-353', 'pimente', 'Qu''est-ce qui te met dans un état de tendresse intense ?'),
  ('pi-354', 'pimente', 'Quelle attention discrète te fait de l''effet au quotidien ?'),
  ('pi-355', 'pimente', 'Quel geste de séduction respectueux te plaît ?'),
  ('pi-356', 'pimente', 'Qu''est-ce qui te fait te sentir aimé et désiré ?'),
  ('pi-357', 'pimente', 'Quelle façon de me faire des avances te plaît ?'),
  ('pi-358', 'pimente', 'Quel moment de rapprochement doux aimes-tu ?'),
  ('pi-359', 'pimente', 'Qu''est-ce qui te met dans une humeur câline ?'),
  ('pi-360', 'pimente', 'Quelle façon de me taquiner tendrement te plaît ?'),
  ('pi-361', 'pimente', 'Quel jeu de séduction respectueuse te plaît ?'),
  ('pi-362', 'pimente', 'Qu''est-ce qui te fait te sentir conquérant ?'),
  ('pi-363', 'pimente', 'Quelle attention sensuelle respectueuse te plaît ?'),
  ('pi-364', 'pimente', 'Quel moment de douceur complice aimes-tu ?'),
  ('pi-365', 'pimente', 'Qu''est-ce qui te rend plus tendre ?'),
  ('pi-366', 'pimente', 'Quelle façon de me complimenter physiquement te plaît ?'),
  ('pi-367', 'pimente', 'Quel jeu d''approche tendre te plaît ?'),
  ('pi-368', 'pimente', 'Qu''est-ce qui te fait te sentir désirable et respecté ?'),
  ('pi-369', 'pimente', 'Quelle façon de me charmer te plaît ?'),
  ('pi-370', 'pimente', 'Quel moment de tendresse coquine préfères-tu ?'),
  ('pi-371', 'pimente', 'Qu''est-ce qui te met dans un état de plaisir léger ?'),
  ('pi-372', 'pimente', 'Quelle attention complice te fait te sentir bien ?'),
  ('pi-373', 'pimente', 'Quel geste de séduction du quotidien préfères-tu ?'),
  ('pi-374', 'pimente', 'Qu''est-ce qui te fait te sentir irrésistiblement aimé ?'),
  ('pi-375', 'pimente', 'Quelle façon de me dire une douceur te plaît ?'),
  ('pi-376', 'pimente', 'Quel moment de complicité complice préfères-tu ?'),
  ('pi-377', 'pimente', 'Qu''est-ce qui te rend plus séducteur avec élégance ?'),
  ('pi-378', 'pimente', 'Quelle façon de me regarder tendrement te plaît ?'),
  ('pi-379', 'pimente', 'Quel jeu de séduction sans pression te plaît ?'),
  ('pi-380', 'pimente', 'Qu''est-ce qui te fait te sentir désiré sans effort ?'),
  ('pi-381', 'pimente', 'Quelle attention légère te met de bonne humeur ?'),
  ('pi-382', 'pimente', 'Quel geste de tendresse coquine aimerais-tu ?'),
  ('pi-383', 'pimente', 'Qu''est-ce qui te rend tendrement provocant ?'),
  ('pi-384', 'pimente', 'Quelle façon de me dire les choses te séduit ?'),
  ('pi-385', 'pimente', 'Quel moment de rapprochement sensuel préfères-tu ?'),
  ('pi-386', 'pimente', 'Qu''est-ce qui te met dans un état de désir respectueux ?'),
  ('pi-387', 'pimente', 'Quelle attention sensible te plaît ?'),
  ('pi-388', 'pimente', 'Quel jeu de séduction complice te plaît ?'),
  ('pi-389', 'pimente', 'Qu''est-ce qui te fait te sentir attirant sans filtre ?'),
  ('pi-390', 'pimente', 'Quelle façon de me chuchoter une douceur te plaît ?'),
  ('pi-391', 'pimente', 'Quel moment de tendresse sensuelle aimerais-tu ?'),
  ('pi-392', 'pimente', 'Qu''est-ce qui te rend plus tendre que d''habitude ?'),
  ('pi-393', 'pimente', 'Quelle façon de m''embrasser dans le cou te plaît ?'),
  ('pi-394', 'pimente', 'Quel jeu de séduction tendre préfères-tu ?'),
  ('pi-395', 'pimente', 'Qu''est-ce qui te fait te sentir désirable à mes yeux ?'),
  ('pi-396', 'pimente', 'Quelle attention coquine te met en confiance ?'),
  ('pi-397', 'pimente', 'Quel geste de séduction doux préfères-tu ?'),
  ('pi-398', 'pimente', 'Qu''est-ce qui te met dans un état de complicité sensuelle ?'),
  ('pi-399', 'pimente', 'Quelle façon de me surprendre tendrement te plaît ?'),
  ('pi-400', 'pimente', 'Quel moment de tendresse complice aimes-tu ?'),
  ('pi-401', 'pimente', 'Qu''est-ce qui te rend plus câlin que prévu ?'),
  ('pi-402', 'pimente', 'Quelle façon de me prendre par la main te plaît ?'),
  ('pi-403', 'pimente', 'Quel jeu de séduction léger te plaît ?'),
  ('pi-404', 'pimente', 'Qu''est-ce qui te fait te sentir désiré et respecté ?'),
  ('pi-405', 'pimente', 'Quelle attention discrète te fait te sentir aimé ?'),
  ('pi-406', 'pimente', 'Quel geste de tendresse taquine préfères-tu ?'),
  ('pi-407', 'pimente', 'Qu''est-ce qui te met dans une humeur douce et joueuse ?')
on conflict (code) do nothing;

-- Très intime — 18+ (consentement requis) (306 questions)
insert into public.questions (code, category, body) values
  ('ti-101', 'tres_intime', 'Qu''est-ce qui t''aide à te sentir désiré dans l''intimité ?'),
  ('ti-102', 'tres_intime', 'Comment aimes-tu qu''on aborde un désir nouveau ?'),
  ('ti-103', 'tres_intime', 'Quelle attention te met en confiance avant l''intimité ?'),
  ('ti-104', 'tres_intime', 'Comment aimes-tu qu''on se dise ce qui nous plaît ?'),
  ('ti-105', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté dans l''échange intime ?'),
  ('ti-106', 'tres_intime', 'Comment aimes-tu qu''on se décide ensemble ?'),
  ('ti-107', 'tres_intime', 'Quelle ambiance te met le plus à l''aise ?'),
  ('ti-108', 'tres_intime', 'Comment aimes-tu qu''on se dise nos préférences une fois au calme ?'),
  ('ti-109', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé après l''intimité ?'),
  ('ti-110', 'tres_intime', 'Comment aimes-tu qu''on prenne soin de l''autre ensuite ?'),
  ('ti-111', 'tres_intime', 'Quelle attention te fait te sentir choisi intimement ?'),
  ('ti-112', 'tres_intime', 'Comment aimes-tu qu''on dise nos envies sans pression ?'),
  ('ti-113', 'tres_intime', 'Qu''est-ce qui te fait te sentir en sécurité pour refuser ?'),
  ('ti-114', 'tres_intime', 'Comment aimes-tu qu''on respecte un non ?'),
  ('ti-115', 'tres_intime', 'Quelle façon de discuter de nos envies préfères-tu ?'),
  ('ti-116', 'tres_intime', 'Comment aimes-tu qu''on se dise nos limites avec douceur ?'),
  ('ti-117', 'tres_intime', 'Qu''est-ce qui te fait te sentir écouté sur ce sujet ?'),
  ('ti-118', 'tres_intime', 'Comment aimes-tu qu''on garde notre intimité privée ?'),
  ('ti-119', 'tres_intime', 'Quelle attention te fait te sentir prioritaire intimement ?'),
  ('ti-120', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-121', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé tendrement ?'),
  ('ti-122', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de découverte ?'),
  ('ti-123', 'tres_intime', 'Quelle façon de communiquer préfères-tu dans ce domaine ?'),
  ('ti-124', 'tres_intime', 'Comment aimes-tu qu''on aborde nos différences de rythme ?'),
  ('ti-125', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté dans tes préférences ?'),
  ('ti-126', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de nouveauté ?'),
  ('ti-127', 'tres_intime', 'Quelle attention te fait te sentir aimé sans jugement ?'),
  ('ti-128', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-129', 'tres_intime', 'Qu''est-ce qui te fait te sentir désiré au quotidien ?'),
  ('ti-130', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-131', 'tres_intime', 'Quelle façon de te rassurer préfères-tu ?'),
  ('ti-132', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-133', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé dans la durée ?'),
  ('ti-134', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-135', 'tres_intime', 'Quelle attention te fait te sentir choisi chaque fois ?'),
  ('ti-136', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''écoute ?'),
  ('ti-137', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien à deux ?'),
  ('ti-138', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-139', 'tres_intime', 'Quelle façon de montrer ton désir préfères-tu ?'),
  ('ti-140', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-141', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé profondément ?'),
  ('ti-142', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-143', 'tres_intime', 'Quelle attention te fait te sentir à l''aise ?'),
  ('ti-144', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de nouveauté ?'),
  ('ti-145', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté et compris ?'),
  ('ti-146', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-147', 'tres_intime', 'Quelle façon de te complimenter préfères-tu dans l''intimité ?'),
  ('ti-148', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-149', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé sans condition ?'),
  ('ti-150', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-151', 'tres_intime', 'Quelle attention te fait te sentir prioritaire ?'),
  ('ti-152', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-153', 'tres_intime', 'Qu''est-ce qui te fait te sentir libre dans l''intimité ?'),
  ('ti-154', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-155', 'tres_intime', 'Quelle façon de te faire sentir désiré préfères-tu ?'),
  ('ti-156', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''attention ?'),
  ('ti-157', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé et désiré ?'),
  ('ti-158', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-159', 'tres_intime', 'Quelle attention te fait te sentir en confiance ?'),
  ('ti-160', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-161', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien dans ton corps ?'),
  ('ti-162', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de nouveauté ?'),
  ('ti-163', 'tres_intime', 'Quelle façon de te toucher préfères-tu ?'),
  ('ti-164', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-165', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé tendrement ?'),
  ('ti-166', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-167', 'tres_intime', 'Quelle attention te fait te sentir écouté ?'),
  ('ti-168', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-169', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé sans pression ?'),
  ('ti-170', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-171', 'tres_intime', 'Quelle façon de te rassurer préfères-tu après ?'),
  ('ti-172', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-173', 'tres_intime', 'Qu''est-ce qui te fait te sentir comblé tendrement ?'),
  ('ti-174', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-175', 'tres_intime', 'Quelle attention te fait te sentir aimé chaque jour ?'),
  ('ti-176', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-177', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien et respecté ?'),
  ('ti-178', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-179', 'tres_intime', 'Qu''attends-tu pour te sentir en confiance dans l''intimité ?'),
  ('ti-180', 'tres_intime', 'Comment aimes-tu qu''on parle de nos envies intimes ?'),
  ('ti-181', 'tres_intime', 'Qu''est-ce qui te met à l''aise pour te laisser aller ?'),
  ('ti-182', 'tres_intime', 'Quelles limites aimerais-tu qu''on respecte toujours ?'),
  ('ti-183', 'tres_intime', 'Comment aimes-tu qu''on se dise nos désirs ?'),
  ('ti-184', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable dans l''intimité ?'),
  ('ti-185', 'tres_intime', 'Comment aimes-tu les préliminaires ?'),
  ('ti-186', 'tres_intime', 'Quel rythme te plaît le plus ?'),
  ('ti-187', 'tres_intime', 'Comment aimes-tu qu''on prenne soin de l''autre ?'),
  ('ti-188', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté intimement ?'),
  ('ti-189', 'tres_intime', 'Comment aimes-tu qu''on communique pendant l''intimité ?'),
  ('ti-190', 'tres_intime', 'Quelles attentions te mettent dans l''ambiance ?'),
  ('ti-191', 'tres_intime', 'Qu''est-ce qui te détend pour te laisser aller ?'),
  ('ti-192', 'tres_intime', 'Comment aimes-tu qu''on se retrouve après une longue journée ?'),
  ('ti-193', 'tres_intime', 'Quel moment te paraît le plus propice à l''intimité ?'),
  ('ti-194', 'tres_intime', 'Comment aimes-tu qu''on se dise nos besoins ?'),
  ('ti-195', 'tres_intime', 'Qu''est-ce qui te fait te sentir désiré dans l''intimité ?'),
  ('ti-196', 'tres_intime', 'Comment aimes-tu qu''on explore doucement ?'),
  ('ti-197', 'tres_intime', 'Quelles caresses préfères-tu ?'),
  ('ti-198', 'tres_intime', 'Comment aimes-tu qu''on se respecte dans le plaisir ?'),
  ('ti-199', 'tres_intime', 'Qu''est-ce qui te fait te sentir en sécurité intime ?'),
  ('ti-200', 'tres_intime', 'Comment aimes-tu qu''on se dise nos limites ?'),
  ('ti-201', 'tres_intime', 'Quelles ambiances te plaisent le plus ?'),
  ('ti-202', 'tres_intime', 'Comment aimes-tu qu''on se taquine dans l''intimité ?'),
  ('ti-203', 'tres_intime', 'Qu''est-ce qui te fait te sentir libre dans l''intimité ?'),
  ('ti-204', 'tres_intime', 'Quel équilibre donnes-tu et reçois-tu ?'),
  ('ti-205', 'tres_intime', 'Comment aimes-tu qu''on se dise nos préférences ?'),
  ('ti-206', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable et respecté ?'),
  ('ti-207', 'tres_intime', 'Comment aimes-tu qu''on prenne notre temps ?'),
  ('ti-208', 'tres_intime', 'Quels préliminaires aimes-tu le plus ?'),
  ('ti-209', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies secrètes ?'),
  ('ti-210', 'tres_intime', 'Qu''est-ce qui te fait te sentir proche intimement ?'),
  ('ti-211', 'tres_intime', 'Comment aimes-tu qu''on se laisse aller ?'),
  ('ti-212', 'tres_intime', 'Quelles attentions intimes te touchent le plus ?'),
  ('ti-213', 'tres_intime', 'Comment aimes-tu qu''on se dise stop quand il faut ?'),
  ('ti-214', 'tres_intime', 'Qu''est-ce qui te fait te sentir écouté intimenement ?'),
  ('ti-215', 'tres_intime', 'Comment aimes-tu qu''on se découvre ?'),
  ('ti-216', 'tres_intime', 'Quelles caresses te font frissonner ?'),
  ('ti-217', 'tres_intime', 'Comment aimes-tu qu''on se respecte dans l''échange ?'),
  ('ti-218', 'tres_intime', 'Qu''est-ce qui te met dans un état de désir intime ?'),
  ('ti-219', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies du moment ?'),
  ('ti-220', 'tres_intime', 'Quelles positions préfères-tu, si tu veux en parler ?'),
  ('ti-221', 'tres_intime', 'Comment aimes-tu qu''on se dise nos douceurs préférées ?'),
  ('ti-222', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé intimement ?'),
  ('ti-223', 'tres_intime', 'Comment aimes-tu qu''on se taquine tendrement ?'),
  ('ti-224', 'tres_intime', 'Quelles zones aimes-tu qu''on caresse ?'),
  ('ti-225', 'tres_intime', 'Comment aimes-tu qu''on se dise nos fantaisies ?'),
  ('ti-226', 'tres_intime', 'Qu''est-ce qui te fait te sentir en confiance pour oser ?'),
  ('ti-227', 'tres_intime', 'Comment aimes-tu qu''on se dise nos pudeurs ?'),
  ('ti-228', 'tres_intime', 'Quels jeux intimes aimerais-tu ?'),
  ('ti-229', 'tres_intime', 'Comment aimes-tu qu''on se dise nos limites physiques ?'),
  ('ti-230', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable sans pression ?'),
  ('ti-231', 'tres_intime', 'Comment aimes-tu qu''on se dise nos rythmes ?'),
  ('ti-232', 'tres_intime', 'Quelles attentions aimes-tu après l''intimité ?'),
  ('ti-233', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''essayer ?'),
  ('ti-234', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé après ?'),
  ('ti-235', 'tres_intime', 'Comment aimes-tu qu''on se dise nos moments préférés ?'),
  ('ti-236', 'tres_intime', 'Quels préliminaires aimerais-tu prolonger ?'),
  ('ti-237', 'tres_intime', 'Comment aimes-tu qu''on se dise nos douceurs ?'),
  ('ti-238', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté dans tes envies ?'),
  ('ti-239', 'tres_intime', 'Comment aimes-tu qu''on se dise nos consentements ?'),
  ('ti-240', 'tres_intime', 'Quelles caresses aimerais-tu recevoir plus ?'),
  ('ti-241', 'tres_intime', 'Comment aimes-tu qu''on se dise nos découvertes ?'),
  ('ti-242', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien après l''amour ?'),
  ('ti-243', 'tres_intime', 'Comment aimes-tu qu''on se dise nos attentions préférées ?'),
  ('ti-244', 'tres_intime', 'Quelles ambiances de lumière aimes-tu ?'),
  ('ti-245', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-246', 'tres_intime', 'Qu''est-ce qui te fait te sentir unique intimement ?'),
  ('ti-247', 'tres_intime', 'Comment aimes-tu qu''on se dise nos besoins de lenteur ?'),
  ('ti-248', 'tres_intime', 'Quels gestes aimes-tu dans l''intimité ?'),
  ('ti-249', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-250', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable et aimé ?'),
  ('ti-251', 'tres_intime', 'Comment aimes-tu qu''on se dise nos préférences de rythme ?'),
  ('ti-252', 'tres_intime', 'Quelles attentions aimes-tu avant l''intimité ?'),
  ('ti-253', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-254', 'tres_intime', 'Qu''est-ce qui te fait te sentir en phase intimement ?'),
  ('ti-255', 'tres_intime', 'Comment aimes-tu qu''on se dise nos besoins d''attention ?'),
  ('ti-256', 'tres_intime', 'Quels jeux de regard aimes-tu dans l''intimité ?'),
  ('ti-257', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-258', 'tres_intime', 'Qu''est-ce qui te fait te sentir comblé intimement ?'),
  ('ti-259', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''explorer ?'),
  ('ti-260', 'tres_intime', 'Quelles caresses aimerais-tu découvrir ?'),
  ('ti-261', 'tres_intime', 'Comment aimes-tu qu''on se dise nos limites de confort ?'),
  ('ti-262', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté et désiré ?'),
  ('ti-263', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-264', 'tres_intime', 'Quels préliminaires aimes-tu inventer ?'),
  ('ti-265', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-266', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé sans jugement ?'),
  ('ti-267', 'tres_intime', 'Comment aimes-tu qu''on se dise nos découvertes récentes ?'),
  ('ti-268', 'tres_intime', 'Quelles attentions te font te sentir choisi ?'),
  ('ti-269', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-270', 'tres_intime', 'Qu''est-ce qui te fait te sentir à l''aise pour parler ?'),
  ('ti-271', 'tres_intime', 'Comment aimes-tu qu''on se dise nos besoins de tendresse ?'),
  ('ti-272', 'tres_intime', 'Quels gestes aimes-tu après l''intimité ?'),
  ('ti-273', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-274', 'tres_intime', 'Qu''est-ce qui te fait te sentir en sécurité pour explorer ?'),
  ('ti-275', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de nouveauté ?'),
  ('ti-276', 'tres_intime', 'Quelles caresses aimes-tu recevoir avec tendresse ?'),
  ('ti-277', 'tres_intime', 'Comment aimes-tu qu''on se dise nos préférences sensorielles ?'),
  ('ti-278', 'tres_intime', 'Qu''est-ce qui te fait te sentir désiré avec respect ?'),
  ('ti-279', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-280', 'tres_intime', 'Quels mots aimes-tu entendre dans l''intimité ?'),
  ('ti-281', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-282', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé dans l''intimité ?'),
  ('ti-283', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de rapprochement ?'),
  ('ti-284', 'tres_intime', 'Quelles attentions aimes-tu de part et d''autre ?'),
  ('ti-285', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-286', 'tres_intime', 'Qu''est-ce qui te fait te sentir en confiance pour demander ?'),
  ('ti-287', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''écoute ?'),
  ('ti-288', 'tres_intime', 'Quels gestes aimes-tu quand on se retrouve ?'),
  ('ti-289', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de patience ?'),
  ('ti-290', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable et écouté ?'),
  ('ti-291', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''attention ?'),
  ('ti-292', 'tres_intime', 'Quelles attentions sensuelles aimes-tu ?'),
  ('ti-293', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-294', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien dans ton corps ?'),
  ('ti-295', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-296', 'tres_intime', 'Quels jeux aimes-tu sans pression ?'),
  ('ti-297', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-298', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé tel que tu es ?'),
  ('ti-299', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-300', 'tres_intime', 'Quelles caresses aimes-tu le matin ?'),
  ('ti-301', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-302', 'tres_intime', 'Qu''est-ce qui te fait te sentir désiré et aimé ?'),
  ('ti-303', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-304', 'tres_intime', 'Quels moments aimes-tu partager intimement ?'),
  ('ti-305', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-306', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté dans l''intimité ?'),
  ('ti-307', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de nouveauté ?'),
  ('ti-308', 'tres_intime', 'Quelles attentions aimes-tu dans les préliminaires ?'),
  ('ti-309', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-310', 'tres_intime', 'Qu''est-ce qui te fait te sentir comblé et respecté ?'),
  ('ti-311', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''exploration ?'),
  ('ti-312', 'tres_intime', 'Quels gestes aimes-tu quand on est complices ?'),
  ('ti-313', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''écoute ?'),
  ('ti-314', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé et désiré ?'),
  ('ti-315', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-316', 'tres_intime', 'Quelles attentions aimes-tu avant de dormir ?'),
  ('ti-317', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de calme ?'),
  ('ti-318', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien après l''intimité ?'),
  ('ti-319', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de câlin ?'),
  ('ti-320', 'tres_intime', 'Quels moments aimes-tu après l''amour ?'),
  ('ti-321', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-322', 'tres_intime', 'Qu''est-ce qui te fait te sentir respecté et aimé ?'),
  ('ti-323', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-324', 'tres_intime', 'Quelles attentions aimes-tu au réveil ?'),
  ('ti-325', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-326', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable au quotidien ?'),
  ('ti-327', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-328', 'tres_intime', 'Quels gestes aimes-tu dans l''intimité tendre ?'),
  ('ti-329', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-330', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé sans condition ?'),
  ('ti-331', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-332', 'tres_intime', 'Quelles attentions aimes-tu pendant l''intimité ?'),
  ('ti-333', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-334', 'tres_intime', 'Qu''est-ce qui te fait te sentir en confiance pour oser ?'),
  ('ti-335', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de nouveauté ?'),
  ('ti-336', 'tres_intime', 'Quels jeux aimes-tu proposer ?'),
  ('ti-337', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-338', 'tres_intime', 'Qu''est-ce qui te fait te sentir désiré et écouté ?'),
  ('ti-339', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-340', 'tres_intime', 'Quelles caresses aimes-tu redécouvrir ?'),
  ('ti-341', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-342', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé profondément ?'),
  ('ti-343', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-344', 'tres_intime', 'Quels moments aimes-tu partager au lit ?'),
  ('ti-345', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-346', 'tres_intime', 'Qu''est-ce qui te fait te sentir comblé intimement ?'),
  ('ti-347', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''attention ?'),
  ('ti-348', 'tres_intime', 'Quelles attentions aimes-tu recevoir avec respect ?'),
  ('ti-349', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-350', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable et aimé ?'),
  ('ti-351', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-352', 'tres_intime', 'Quels gestes aimes-tu dans les moments tendres ?'),
  ('ti-353', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''écoute ?'),
  ('ti-354', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien dans l''intimité ?'),
  ('ti-355', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de nouveauté ?'),
  ('ti-356', 'tres_intime', 'Quelles attentions aimes-tu partager ?'),
  ('ti-357', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-358', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé et respecté ?'),
  ('ti-359', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-360', 'tres_intime', 'Quels moments aimes-tu de complicité ?'),
  ('ti-361', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-362', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable sans jugement ?'),
  ('ti-363', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-364', 'tres_intime', 'Quelles attentions aimes-tu découvrir ?'),
  ('ti-365', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-366', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé tel que tu es ?'),
  ('ti-367', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-368', 'tres_intime', 'Quels gestes aimes-tu dans la tendresse ?'),
  ('ti-369', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-370', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien à deux ?'),
  ('ti-371', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''attention ?'),
  ('ti-372', 'tres_intime', 'Quelles attentions aimes-tu au quotidien ?'),
  ('ti-373', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-374', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé et désiré ?'),
  ('ti-375', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-376', 'tres_intime', 'Quels moments aimes-tu privilégier ?'),
  ('ti-377', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-378', 'tres_intime', 'Qu''est-ce qui te fait te sentir comblé affectivement ?'),
  ('ti-379', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-380', 'tres_intime', 'Quelles attentions aimes-tu partager encore ?'),
  ('ti-381', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-382', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé profondément et libre ?'),
  ('ti-383', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de nouveauté ?'),
  ('ti-384', 'tres_intime', 'Quels gestes aimes-tu dans l''intimité complice ?'),
  ('ti-385', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-386', 'tres_intime', 'Qu''est-ce qui te fait te sentir désirable et respecté ?'),
  ('ti-387', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-388', 'tres_intime', 'Quelles attentions aimes-tu et apprécies-tu ?'),
  ('ti-389', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-390', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé et écouté ?'),
  ('ti-391', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-392', 'tres_intime', 'Quels moments aimes-tu cultiver ?'),
  ('ti-393', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de douceur ?'),
  ('ti-394', 'tres_intime', 'Qu''est-ce qui te fait te sentir bien et respecté ?'),
  ('ti-395', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de proximité ?'),
  ('ti-396', 'tres_intime', 'Quelles attentions aimes-tu offrir ?'),
  ('ti-397', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de respect ?'),
  ('ti-398', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé et aimant ?'),
  ('ti-399', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de complicité ?'),
  ('ti-400', 'tres_intime', 'Quels moments aimes-tu garder précieusement ?'),
  ('ti-401', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de tendresse ?'),
  ('ti-402', 'tres_intime', 'Qu''est-ce qui te fait te sentir heureux à deux ?'),
  ('ti-403', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies de lenteur ?'),
  ('ti-404', 'tres_intime', 'Quelles attentions aimes-tu voir durer ?'),
  ('ti-405', 'tres_intime', 'Comment aimes-tu qu''on se dise nos envies d''intimité ?'),
  ('ti-406', 'tres_intime', 'Qu''est-ce qui te fait te sentir aimé pour toujours ?')
on conflict (code) do nothing;

-- Avenir et relations (311 questions)
insert into public.questions (code, category, body) values
  ('av-101', 'avenir', 'Quel projet aimerais-tu qu''on planifie ce trimestre ?'),
  ('av-102', 'avenir', 'Comment aimerais-tu qu''on se projette dans un déménagement ?'),
  ('av-103', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne avant la fin de l''année ?'),
  ('av-104', 'avenir', 'Comment aimerais-tu qu''on gère nos économies à long terme ?'),
  ('av-105', 'avenir', 'Quel rêve aimerais-tu qu''on protège des contraintes ?'),
  ('av-106', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de racines ?'),
  ('av-107', 'avenir', 'Quel projet aimerais-tu qu''on teste rapidement ?'),
  ('av-108', 'avenir', 'Comment aimerais-tu qu''on se projette dans un grand voyage ?'),
  ('av-109', 'avenir', 'Quel objectif aimerais-tu qu''on partage pour notre forme ?'),
  ('av-110', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de stabilité ?'),
  ('av-111', 'avenir', 'Quel projet aimerais-tu qu''on mène cet été ?'),
  ('av-112', 'avenir', 'Comment aimerais-tu qu''on se projette dans un engagement ?'),
  ('av-113', 'avenir', 'Quel objectif aimerais-tu qu''on se fixe à deux ?'),
  ('av-114', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves de carrière ?'),
  ('av-115', 'avenir', 'Quel projet aimerais-tu qu''on prépare tranquillement ?'),
  ('av-116', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de famille ?'),
  ('av-117', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne ensemble ?'),
  ('av-118', 'avenir', 'Comment aimerais-tu qu''on se projette dans la confiance ?'),
  ('av-119', 'avenir', 'Quel projet aimerais-tu qu''on réalise à deux ?'),
  ('av-120', 'avenir', 'Comment aimerais-tu qu''on gère nos projets de voyage ?'),
  ('av-121', 'avenir', 'Quel objectif aimerais-tu qu''on partage pour notre nid ?'),
  ('av-122', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies d''ailleurs ?'),
  ('av-123', 'avenir', 'Quel projet aimerais-tu qu''on construise cette saison ?'),
  ('av-124', 'avenir', 'Comment aimerais-tu qu''on se projette dans la simplicité ?'),
  ('av-125', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne sans pression ?'),
  ('av-126', 'avenir', 'Comment aimerais-tu qu''on gère nos ambitions communes ?'),
  ('av-127', 'avenir', 'Quel projet aimerais-tu qu''on ose enfin ?'),
  ('av-128', 'avenir', 'Comment aimerais-tu qu''on se dise nos besoins d''espace ?'),
  ('av-129', 'avenir', 'Quel objectif aimerais-tu qu''on garde pour nous ?'),
  ('av-130', 'avenir', 'Comment aimerais-tu qu''on se projette dans un jardin ou une maison ?'),
  ('av-131', 'avenir', 'Quel projet aimerais-tu qu''on partage avec nos proches ?'),
  ('av-132', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves de changement ?'),
  ('av-133', 'avenir', 'Quel objectif aimerais-tu qu''on se donne cet automne ?'),
  ('av-134', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de découverte ?'),
  ('av-135', 'avenir', 'Quel projet aimerais-tu qu''on mène à bien ensemble ?'),
  ('av-136', 'avenir', 'Comment aimerais-tu qu''on se projette dans la bienveillance ?'),
  ('av-137', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne pour nous ?'),
  ('av-138', 'avenir', 'Comment aimerais-tu qu''on gère nos envies de fonder ?'),
  ('av-139', 'avenir', 'Quel projet aimerais-tu qu''on imagine à deux ?'),
  ('av-140', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de retour aux sources ?'),
  ('av-141', 'avenir', 'Quel objectif aimerais-tu qu''on vise ensemble ?'),
  ('av-142', 'avenir', 'Comment aimerais-tu qu''on se projette dans la complicité ?'),
  ('av-143', 'avenir', 'Quel projet aimerais-tu qu''on développe sereinement ?'),
  ('av-144', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves de reconversion ?'),
  ('av-145', 'avenir', 'Quel objectif aimerais-tu qu''on partage pour notre couple ?'),
  ('av-146', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies d''aventure ?'),
  ('av-147', 'avenir', 'Quel projet aimerais-tu qu''on réalise en équipe ?'),
  ('av-148', 'avenir', 'Comment aimerais-tu qu''on se projette dans la joie ?'),
  ('av-149', 'avenir', 'Quel objectif aimerais-tu qu''on se fixe pour nous deux ?'),
  ('av-150', 'avenir', 'Comment aimerais-tu qu''on gérer nos projets de famille ?'),
  ('av-151', 'avenir', 'Quel projet aimerais-tu qu''on ancre ensemble ?'),
  ('av-152', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de toujours ?'),
  ('av-153', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne main dans la main ?'),
  ('av-154', 'avenir', 'Comment aimerais-tu qu''on se projette dans la sérénité ?'),
  ('av-155', 'avenir', 'Quel projet aimerais-tu qu''on écrive à deux ?'),
  ('av-156', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves d''horizon ?'),
  ('av-157', 'avenir', 'Quel objectif aimerais-tu qu''on garde en tête ?'),
  ('av-158', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de construire ?'),
  ('av-159', 'avenir', 'Quel projet aimerais-tu qu''on partage bientôt ?'),
  ('av-160', 'avenir', 'Comment aimerais-tu qu''on se projette dans un long terme ?'),
  ('av-161', 'avenir', 'Quel objectif aimerais-tu qu''on célèbre ensemble ?'),
  ('av-162', 'avenir', 'Comment aimerais-tu qu''on gère nos grands projets ?'),
  ('av-163', 'avenir', 'Quel projet aimerais-tu qu''on réalise pas à pas ?'),
  ('av-164', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de racines communes ?'),
  ('av-165', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne avec cœur ?'),
  ('av-166', 'avenir', 'Comment aimerais-tu qu''on se projette dans la douceur ?'),
  ('av-167', 'avenir', 'Quel projet aimerais-tu qu''on porte à deux ?'),
  ('av-168', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves partagés ?'),
  ('av-169', 'avenir', 'Quel objectif aimerais-tu qu''on se donne pour la suite ?'),
  ('av-170', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de futur ?'),
  ('av-171', 'avenir', 'Quel projet aimerais-tu qu''on mène jusqu''au bout ?'),
  ('av-172', 'avenir', 'Comment aimerais-tu qu''on se projette dans l''équilibre ?'),
  ('av-173', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne pour nous deux ?'),
  ('av-174', 'avenir', 'Comment aimerais-tu qu''on gérer nos ambitions d''avenir ?'),
  ('av-175', 'avenir', 'Quel projet aimerais-tu qu''on réalise avec fierté ?'),
  ('av-176', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de grandir ?'),
  ('av-177', 'avenir', 'Quel objectif aimerais-tu qu''on partage toujours ?'),
  ('av-178', 'avenir', 'Comment aimerais-tu qu''on se projette dans l''amour ?'),
  ('av-179', 'avenir', 'Quel projet aimerais-tu qu''on écrive ensemble ?'),
  ('av-180', 'avenir', 'Comment aimerais-tu qu''on gérer nos rêves communs ?'),
  ('av-181', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne ensemble ?'),
  ('av-182', 'avenir', 'Comment aimerais-tu qu''on se projette dans la vie à deux, aujourd''hui ?'),
  ('av-183', 'avenir', 'Où aimerais-tu que nous soyons dans un an ?'),
  ('av-184', 'avenir', 'Quel projet aimerais-tu qu''on lance ensemble ?'),
  ('av-185', 'avenir', 'Quelle habitude aimerais-tu qu''on construise à deux ?'),
  ('av-186', 'avenir', 'Comment imagines-tu une semaine idéale ensemble ?'),
  ('av-187', 'avenir', 'Quel voyage rêves-tu qu''on fasse ?'),
  ('av-188', 'avenir', 'Quelle décision aimerais-tu qu''on prenne ensemble ?'),
  ('av-189', 'avenir', 'Qu''aimerais-tu qu''on améliore dans notre quotidien ?'),
  ('av-190', 'avenir', 'Quel objectif commun te tiendrait à cœur ?'),
  ('av-191', 'avenir', 'Comment vois-tu notre équilibre vie pro / vie perso ?'),
  ('av-192', 'avenir', 'Quelle promesse aimerais-tu qu''on se tienne ?'),
  ('av-193', 'avenir', 'Quel espace aimerais-tu qu''on s''aménage à deux ?'),
  ('av-194', 'avenir', 'Comment aimerais-tu qu''on gère l''argent ensemble ?'),
  ('av-195', 'avenir', 'Quelle tradition aimerais-tu créer avec moi ?'),
  ('av-196', 'avenir', 'Quel rêve commun aimerais-tu réaliser ?'),
  ('av-197', 'avenir', 'Comment veux-tu qu''on grandisse ensemble ?'),
  ('av-198', 'avenir', 'Quelle valeur aimerais-tu transmettre à deux ?'),
  ('av-199', 'avenir', 'Quel défi aimerais-tu qu''on relève ?'),
  ('av-200', 'avenir', 'Comment aimerais-tu qu''on se soutienne dans nos carrières ?'),
  ('av-201', 'avenir', 'Quelle maison ou lieu de vie te ferait rêver ?'),
  ('av-202', 'avenir', 'Quelle famille ou entourage aimerais-tu qu''on cultive ?'),
  ('av-203', 'avenir', 'Quel rythme de vie aimerais-tu à deux ?'),
  ('av-204', 'avenir', 'Comment aimerais-tu qu''on prenne les grandes décisions ?'),
  ('av-205', 'avenir', 'Quel objectif financier aimerais-tu atteindre ?'),
  ('av-206', 'avenir', 'Quelle aventure aimerais-tu qu''on tente ?'),
  ('av-207', 'avenir', 'Comment vois-tu notre couple dans dix ans ?'),
  ('av-208', 'avenir', 'Quelle qualité aimerais-tu qu''on renforce ensemble ?'),
  ('av-209', 'avenir', 'Quel projet de vie te motive le plus ?'),
  ('av-210', 'avenir', 'Comment aimerais-tu qu''on gère les imprévus ?'),
  ('av-211', 'avenir', 'Quelle cause aimerais-tu qu''on soutienne ?'),
  ('av-212', 'avenir', 'Quel apprentissage aimerais-tu qu''on fasse ensemble ?'),
  ('av-213', 'avenir', 'Comment aimerais-tu qu''on se projette dans le travail ?'),
  ('av-214', 'avenir', 'Quel lieu aimerais-tu qu''on découvre ensemble ?'),
  ('av-215', 'avenir', 'Quelle étape aimerais-tu qu''on franchisse ?'),
  ('av-216', 'avenir', 'Comment aimerais-tu qu''on gère les désaccords d''avenir ?'),
  ('av-217', 'avenir', 'Quel rêve d''enfance aimerais-tu réaliser adulte ?'),
  ('av-218', 'avenir', 'Comment aimerais-tu qu''on partage nos ambitions ?'),
  ('av-219', 'avenir', 'Quelle sécurité aimerais-tu bâtir à deux ?'),
  ('av-220', 'avenir', 'Quel projet créatif aimerais-tu qu''on lance ?'),
  ('av-221', 'avenir', 'Comment aimerais-tu qu''on vieillisse ensemble ?'),
  ('av-222', 'avenir', 'Quelle priorité aimerais-tu pour notre couple ?'),
  ('av-223', 'avenir', 'Quel challenge sportif aimerais-tu qu''on relève ?'),
  ('av-224', 'avenir', 'Comment aimerais-tu qu''on se répartisse les tâches ?'),
  ('av-225', 'avenir', 'Quel voyage à deux te ferait vibrer ?'),
  ('av-226', 'avenir', 'Comment aimerais-tu qu''on cultive notre complicité ?'),
  ('av-227', 'avenir', 'Quel projet immobilier aimerais-tu ?'),
  ('av-228', 'avenir', 'Comment aimerais-tu qu''on gère nos familles ?'),
  ('av-229', 'avenir', 'Quelle habitude de couple aimerais-tu instaurer ?'),
  ('av-230', 'avenir', 'Comment aimerais-tu qu''on célèbre nos réussites ?'),
  ('av-231', 'avenir', 'Quel objectif de santé aimerais-tu qu''on partage ?'),
  ('av-232', 'avenir', 'Comment aimerais-tu qu''on se motive mutuellement ?'),
  ('av-233', 'avenir', 'Quel rêve professionnel aimerais-tu poursuivre ?'),
  ('av-234', 'avenir', 'Comment aimerais-tu qu''on gère nos amitiés ?'),
  ('av-235', 'avenir', 'Quelle tradition de vacances aimerais-tu créer ?'),
  ('av-236', 'avenir', 'Comment aimerais-tu qu''on se soutienne dans l''échec ?'),
  ('av-237', 'avenir', 'Quel projet commun te ferait le plus plaisir ?'),
  ('av-238', 'avenir', 'Comment aimerais-tu qu''on planifie notre retraite ?'),
  ('av-239', 'avenir', 'Quelle valeur aimerais-tu qu''on défende ensemble ?'),
  ('av-240', 'avenir', 'Quel engagement aimerais-tu qu''on prenne ?'),
  ('av-241', 'avenir', 'Comment aimerais-tu qu''on se fasse confiance sur l''avenir ?'),
  ('av-242', 'avenir', 'Quel rêve aimerais-tu qu''on écrive à deux ?'),
  ('av-243', 'avenir', 'Comment aimerais-tu qu''on partage les responsabilités ?'),
  ('av-244', 'avenir', 'Quelle expérience aimerais-tu qu''on vive ensemble ?'),
  ('av-245', 'avenir', 'Comment aimerais-tu qu''on prépare le futur ?'),
  ('av-246', 'avenir', 'Quel objectif commun aimerais-tu fixer cette année ?'),
  ('av-247', 'avenir', 'Comment aimerais-tu qu''on gère nos différences ?'),
  ('av-248', 'avenir', 'Quel projet d''épargne aimerais-tu qu''on ouvre ?'),
  ('av-249', 'avenir', 'Comment aimerais-tu qu''on se projette en famille ?'),
  ('av-250', 'avenir', 'Quelle activité aimerais-tu qu''on fasse régulièrement ?'),
  ('av-251', 'avenir', 'Comment aimerais-tu qu''on se réinvente ?'),
  ('av-252', 'avenir', 'Quel lieu aimerais-tu qu''on appelle « chez nous » ?'),
  ('av-253', 'avenir', 'Comment aimerais-tu qu''on se dise nos rêves d''avenir ?'),
  ('av-254', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne ensemble ?'),
  ('av-255', 'avenir', 'Comment aimerais-tu qu''on gère les grandes étapes ?'),
  ('av-256', 'avenir', 'Quel rêve d''aventure aimerais-tu partager ?'),
  ('av-257', 'avenir', 'Comment aimerais-tu qu''on se soutienne au quotidien ?'),
  ('av-258', 'avenir', 'Quelle habitude financière aimerais-tu qu''on adopte ?'),
  ('av-259', 'avenir', 'Comment aimerais-tu qu''on se projette dans le travail à deux ?'),
  ('av-260', 'avenir', 'Quel projet de voyage lointain aimerais-tu ?'),
  ('av-261', 'avenir', 'Comment aimerais-tu qu''on gère nos rythmes différents ?'),
  ('av-262', 'avenir', 'Quel objectif sportif aimerais-tu qu''on poursuive ?'),
  ('av-263', 'avenir', 'Comment aimerais-tu qu''on se dise nos peurs d''avenir ?'),
  ('av-264', 'avenir', 'Quelle priorité aimerais-tu qu''on garde toujours ?'),
  ('av-265', 'avenir', 'Quel projet artistique aimerais-tu qu''on crée ?'),
  ('av-266', 'avenir', 'Comment aimerais-tu qu''on bâtisse notre nid ?'),
  ('av-267', 'avenir', 'Quel engagement aimerais-tu qu''on renouvelle ?'),
  ('av-268', 'avenir', 'Comment aimerais-tu qu''on se projette dans la parentalité, si tu le souhaites ?'),
  ('av-269', 'avenir', 'Quel rêve aimerais-tu qu''on ose enfin ?'),
  ('av-270', 'avenir', 'Comment aimerais-tu qu''on se dise nos ambitions pro ?'),
  ('av-271', 'avenir', 'Quel projet aimerais-tu qu''on réussisse à deux ?'),
  ('av-272', 'avenir', 'Comment aimerais-tu qu''on gère le temps pour nous ?'),
  ('av-273', 'avenir', 'Quel objectif aimerais-tu qu''on partage pour notre santé ?'),
  ('av-274', 'avenir', 'Comment aimerais-tu qu''on se projette dans les voyages ?'),
  ('av-275', 'avenir', 'Quel rêve aimerais-tu qu''on poursuive sans peur ?'),
  ('av-276', 'avenir', 'Comment aimerais-tu qu''on se soutienne dans les projets ?'),
  ('av-277', 'avenir', 'Quel projet aimerais-tu qu''on planifie à long terme ?'),
  ('av-278', 'avenir', 'Comment aimerais-tu qu''on gère nos priorités ?'),
  ('av-279', 'avenir', 'Quel objectif aimerais-tu qu''on célèbre ensemble ?'),
  ('av-280', 'avenir', 'Comment aimerais-tu qu''on se dise nos espoirs ?'),
  ('av-281', 'avenir', 'Quel projet aimerais-tu qu''on démarre bientôt ?'),
  ('av-282', 'avenir', 'Comment aimerais-tu qu''on se projette dans l''avenir à deux ?'),
  ('av-283', 'avenir', 'Quel engagement aimerais-tu qu''on prenne l''un envers l''autre ?'),
  ('av-284', 'avenir', 'Comment aimerais-tu qu''on se dise nos rêves fous ?'),
  ('av-285', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne dans cinq ans ?'),
  ('av-286', 'avenir', 'Comment aimerais-tu qu''on gère nos finances communes ?'),
  ('av-287', 'avenir', 'Quel projet aimerais-tu qu''on réalise en premier ?'),
  ('av-288', 'avenir', 'Comment aimerais-tu qu''on se projette dans notre carrière ?'),
  ('av-289', 'avenir', 'Quel rêve aimerais-tu qu''on partage avec nos proches ?'),
  ('av-290', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de vie ?'),
  ('av-291', 'avenir', 'Quel projet aimerais-tu qu''on construise pas à pas ?'),
  ('av-292', 'avenir', 'Comment aimerais-tu qu''on gère les grandes transitions ?'),
  ('av-293', 'avenir', 'Quel objectif aimerais-tu qu''on se donne pour nous ?'),
  ('av-294', 'avenir', 'Comment aimerais-tu qu''on se projette dans la simplicité ?'),
  ('av-295', 'avenir', 'Quel rêve aimerais-tu qu''on vive ensemble ?'),
  ('av-296', 'avenir', 'Comment aimerais-tu qu''on se dise nos besoins d''avenir ?'),
  ('av-297', 'avenir', 'Quel projet aimerais-tu qu''on mène à bien ?'),
  ('av-298', 'avenir', 'Comment aimerais-tu qu''on gère nos engagements ?'),
  ('av-299', 'avenir', 'Quel objectif aimerais-tu qu''on partage avec joie ?'),
  ('av-300', 'avenir', 'Comment aimerais-tu qu''on se projette dans la stabilité ?'),
  ('av-301', 'avenir', 'Quel rêve aimerais-tu qu''on réalise adultes ?'),
  ('av-302', 'avenir', 'Comment aimerais-tu qu''on se dise nos projets à deux ?'),
  ('av-303', 'avenir', 'Quel projet aimerais-tu qu''on écrive ensemble ?'),
  ('av-304', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves communs ?'),
  ('av-305', 'avenir', 'Quel objectif aimerais-tu qu''on garde en vue ?'),
  ('av-306', 'avenir', 'Comment aimerais-tu qu''on se projette dans la tendresse ?'),
  ('av-307', 'avenir', 'Quel rêve aimerais-tu qu''on tente bientôt ?'),
  ('av-308', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de changement ?'),
  ('av-309', 'avenir', 'Quel projet aimerais-tu qu''on développe ?'),
  ('av-310', 'avenir', 'Comment aimerais-tu qu''on gère nos ambitions ?'),
  ('av-311', 'avenir', 'Quel objectif aimerais-tu qu''on se fixe pour l''été ?'),
  ('av-312', 'avenir', 'Comment aimerais-tu qu''on se projette dans les fêtes ?'),
  ('av-313', 'avenir', 'Quel rêve aimerais-tu qu''on partage en famille ?'),
  ('av-314', 'avenir', 'Comment aimerais-tu qu''on se dise nos projets de voyage ?'),
  ('av-315', 'avenir', 'Quel projet aimerais-tu qu''on concrétise cette année ?'),
  ('av-316', 'avenir', 'Comment aimerais-tu qu''on gère nos envies d''ailleurs ?'),
  ('av-317', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne à deux ?'),
  ('av-318', 'avenir', 'Comment aimerais-tu qu''on se projette dans la santé ?'),
  ('av-319', 'avenir', 'Quel rêve aimerais-tu qu''on poursuive ensemble ?'),
  ('av-320', 'avenir', 'Comment aimerais-tu qu''on se dise nos besoins d''épanouissement ?'),
  ('av-321', 'avenir', 'Quel projet aimerais-tu qu''on réalise avec fierté ?'),
  ('av-322', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves au quotidien ?'),
  ('av-323', 'avenir', 'Quel objectif aimerais-tu qu''on partage pour nos proches ?'),
  ('av-324', 'avenir', 'Comment aimerais-tu qu''on se projette dans la générosité ?'),
  ('av-325', 'avenir', 'Quel rêve aimerais-tu qu''on ose enfin vivre ?'),
  ('av-326', 'avenir', 'Comment aimerais-tu qu''on se dise nos ambitions d''avenir ?'),
  ('av-327', 'avenir', 'Quel projet aimerais-tu qu''on mène en équipe ?'),
  ('av-328', 'avenir', 'Comment aimerais-tu qu''on gère le temps qui passe à deux ?'),
  ('av-329', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne sans stress ?'),
  ('av-330', 'avenir', 'Comment aimerais-tu qu''on se projette dans la confiance ?'),
  ('av-331', 'avenir', 'Quel rêve aimerais-tu qu''on écrive à deux mains ?'),
  ('av-332', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies profondes ?'),
  ('av-333', 'avenir', 'Quel projet aimerais-tu qu''on réalise en duo ?'),
  ('av-334', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves de carrière ?'),
  ('av-335', 'avenir', 'Quel objectif aimerais-tu qu''on fixe pour notre couple ?'),
  ('av-336', 'avenir', 'Comment aimerais-tu qu''on se projette dans l''aventure ?'),
  ('av-337', 'avenir', 'Quel rêve aimerais-tu qu''on poursuive malgré les obstacles ?'),
  ('av-338', 'avenir', 'Comment aimerais-tu qu''on se dise nos espoirs de vie ?'),
  ('av-339', 'avenir', 'Quel projet aimerais-tu qu''on bâtisse ensemble ?'),
  ('av-340', 'avenir', 'Comment aimerais-tu qu''on gère nos envies de fonder ?'),
  ('av-341', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne avec bonheur ?'),
  ('av-342', 'avenir', 'Comment aimerais-tu qu''on se projette dans l''amour durable ?'),
  ('av-343', 'avenir', 'Quel rêve aimerais-tu qu''on protège à deux ?'),
  ('av-344', 'avenir', 'Comment aimerais-tu qu''on se dise nos ambitions longues ?'),
  ('av-345', 'avenir', 'Quel projet aimerais-tu qu''on prépare sereinement ?'),
  ('av-346', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves partagés ?'),
  ('av-347', 'avenir', 'Quel objectif aimerais-tu qu''on célèbre bientôt ?'),
  ('av-348', 'avenir', 'Comment aimerais-tu qu''on se projette dans la parentalité, si tu le veux ?'),
  ('av-349', 'avenir', 'Quel rêve aimerais-tu qu''on réalise avant tout ?'),
  ('av-350', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de racines ?'),
  ('av-351', 'avenir', 'Quel projet aimerais-tu qu''on ancre dans le réel ?'),
  ('av-352', 'avenir', 'Comment aimerais-tu qu''on gère nos envies d''ailleurs ?'),
  ('av-353', 'avenir', 'Quel objectif aimerais-tu qu''on partage avec nos amis ?'),
  ('av-354', 'avenir', 'Comment aimerais-tu qu''on se projette dans la solidité ?'),
  ('av-355', 'avenir', 'Quel rêve aimerais-tu qu''on poursuive à deux ?'),
  ('av-356', 'avenir', 'Comment aimerais-tu qu''on se dise nos besoins de liberté ?'),
  ('av-357', 'avenir', 'Quel projet aimerais-tu qu''on réalise en harmonie ?'),
  ('av-358', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves de maison ?'),
  ('av-359', 'avenir', 'Quel objectif aimerais-tu qu''on fixe pour notre bien-être ?'),
  ('av-360', 'avenir', 'Comment aimerais-tu qu''on se projette dans la complicité future ?'),
  ('av-361', 'avenir', 'Quel rêve aimerais-tu qu''on vive sans regret ?'),
  ('av-362', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de toujours ?'),
  ('av-363', 'avenir', 'Quel projet aimerais-tu qu''on construise durablement ?'),
  ('av-364', 'avenir', 'Comment aimerais-tu qu''on gère nos projets de famille ?'),
  ('av-365', 'avenir', 'Quel objectif aimerais-tu qu''on partage à long terme ?'),
  ('av-366', 'avenir', 'Comment aimerais-tu qu''on se projette dans la joie ?'),
  ('av-367', 'avenir', 'Quel rêve aimerais-tu qu''on écrive ensemble ?'),
  ('av-368', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de voyage ?'),
  ('av-369', 'avenir', 'Quel projet aimerais-tu qu''on développe à deux ?'),
  ('av-370', 'avenir', 'Comment aimerais-tu qu''on gère nos ambitions communes ?'),
  ('av-371', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne en équipe ?'),
  ('av-372', 'avenir', 'Comment aimerais-tu qu''on se projette dans la sérénité ?'),
  ('av-373', 'avenir', 'Quel rêve aimerais-tu qu''on protège ensemble ?'),
  ('av-374', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de créer ?'),
  ('av-375', 'avenir', 'Quel projet aimerais-tu qu''on réalise avec cœur ?'),
  ('av-376', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves de demain ?'),
  ('av-377', 'avenir', 'Quel objectif aimerais-tu qu''on garde toujours ?'),
  ('av-378', 'avenir', 'Comment aimerais-tu qu''on se projette dans la bienveillance ?'),
  ('av-379', 'avenir', 'Quel rêve aimerais-tu qu''on ose à deux ?'),
  ('av-380', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de futur ?'),
  ('av-381', 'avenir', 'Quel projet aimerais-tu qu''on mène ensemble ?'),
  ('av-382', 'avenir', 'Comment aimerais-tu qu''on gère nos engagements de vie ?'),
  ('av-383', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne en duo ?'),
  ('av-384', 'avenir', 'Comment aimerais-tu qu''on se projette dans l''équilibre ?'),
  ('av-385', 'avenir', 'Quel rêve aimerais-tu qu''on réalise main dans la main ?'),
  ('av-386', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de grandir ?'),
  ('av-387', 'avenir', 'Quel projet aimerais-tu qu''on bâtisse avec soin ?'),
  ('av-388', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves de couple ?'),
  ('av-389', 'avenir', 'Quel objectif aimerais-tu qu''on partage avec bonheur ?'),
  ('av-390', 'avenir', 'Comment aimerais-tu qu''on se projette dans la durée ?'),
  ('av-391', 'avenir', 'Quel rêve aimerais-tu qu''on écrive à deux ?'),
  ('av-392', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de toujours ?'),
  ('av-393', 'avenir', 'Quel projet aimerais-tu qu''on réalise ensemble ?'),
  ('av-394', 'avenir', 'Comment aimerais-tu qu''on gère nos ambitions de vie ?'),
  ('av-395', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne pour nous ?'),
  ('av-396', 'avenir', 'Comment aimerais-tu qu''on se projette dans l''avenir ?'),
  ('av-397', 'avenir', 'Quel rêve aimerais-tu qu''on garde vivant ?'),
  ('av-398', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de demain ?'),
  ('av-399', 'avenir', 'Quel projet aimerais-tu qu''on mène à deux ?'),
  ('av-400', 'avenir', 'Comment aimerais-tu qu''on gère nos rêves communs ?'),
  ('av-401', 'avenir', 'Quel objectif aimerais-tu qu''on partage toujours ?'),
  ('av-402', 'avenir', 'Comment aimerais-tu qu''on se projette dans l''amour ?'),
  ('av-403', 'avenir', 'Quel rêve aimerais-tu qu''on réalise enfin ?'),
  ('av-404', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de construire ?'),
  ('av-405', 'avenir', 'Quel projet aimerais-tu qu''on crée ensemble ?'),
  ('av-406', 'avenir', 'Comment aimerais-tu qu''on gère nos projets d''avenir ?'),
  ('av-407', 'avenir', 'Quel objectif aimerais-tu qu''on atteigne avec amour ?'),
  ('av-408', 'avenir', 'Comment aimerais-tu qu''on se projette dans la vie à deux ?'),
  ('av-409', 'avenir', 'Quel rêve aimerais-tu qu''on ose écrire ?'),
  ('av-410', 'avenir', 'Comment aimerais-tu qu''on se dise nos envies de toujours ?'),
  ('av-411', 'avenir', 'Quel projet aimerais-tu qu''on réalise ensemble, aujourd''hui ?')
on conflict (code) do nothing;

-- ############################################################################
-- ##  migrations/0005_realtime.sql
-- ############################################################################

-- =============================================================================
-- Entre Nous — 0005_realtime.sql
-- Active la diffusion temps réel (§11, §17.3) sur les tables nécessaires, et
-- durcit les droits des fonctions purement internes.
-- =============================================================================

-- Garde-fou d'ordre : 0005 s'appuie sur les fonctions RPC créées par 0003.
do $$
begin
  if to_regprocedure('public.create_duo(text,text)') is null then
    raise exception 'MIGRATION_ORDER: applique d''abord 0003_rpc.sql avant 0005_realtime.sql (les fonctions RPC sont absentes).';
  end if;
end;
$$;

-- Supabase Realtime ne diffuse que les tables inscrites dans la publication
-- « supabase_realtime ». On l'active si elle existe (projet Supabase managé).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    -- Chat privé
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
    ) then
      alter publication supabase_realtime add table public.messages;
    end if;

    -- État du jeu (synchronisation des deux appareils)
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sessions'
    ) then
      alter publication supabase_realtime add table public.sessions;
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'session_participants'
    ) then
      alter publication supabase_realtime add table public.session_participants;
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'session_question_instances'
    ) then
      alter publication supabase_realtime add table public.session_question_instances;
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'question_turns'
    ) then
      alter publication supabase_realtime add table public.question_turns;
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'question_answers'
    ) then
      alter publication supabase_realtime add table public.question_answers;
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'session_consents'
    ) then
      alter publication supabase_realtime add table public.session_consents;
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'duo_members'
    ) then
      alter publication supabase_realtime add table public.duo_members;
    end if;
  end if;
end;
$$;

-- REPLICA IDENTITY FULL : permet aux filtres et aux mises à jour d'être
-- correctement transmis (utile pour synchroniser l'état du jeu).
alter table public.sessions          replica identity full;
alter table public.question_turns    replica identity full;
alter table public.session_participants replica identity full;
alter table public.session_consents  replica identity full;
alter table public.duo_members       replica identity full;

-- =============================================================================
-- Durcissement : les helpers internes ne doivent pas être appelables par le
-- rôle anonyme.
-- =============================================================================
revoke all on function public.generate_invite_code() from public, anon;
revoke all on function public.category_weight(public.question_category) from public, anon;
revoke all on function public.assert_duo_member(uuid) from public, anon;
revoke all on function public.assert_session_member(uuid) from public, anon;
