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
