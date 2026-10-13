-- =============================================================================
-- Entre Nous — run_all.sql
-- Fichier unique regroupant 0001 -> 0005, dans le bon ordre.
--
-- UTILISATION : colle tout ce fichier dans le SQL Editor Supabase et exécute-le.
-- Il est REJOUABLE : tu peux le relancer autant de fois que nécessaire sans
-- erreur (« already exists »), car chaque étape est idempotente.
--
-- (Pour un projet géré par la CLI Supabase, ce fichier n'est PAS une migration :
--  utilise plutôt `supabase db push`, qui applique supabase/migrations/ dans
--  l'ordre 0001 -> 0005.)
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
