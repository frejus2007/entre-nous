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
