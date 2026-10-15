-- =============================================================================
-- Entre Nous — 0012_chat_reactions.sql
-- Réactions rapides et synchronisées sur les messages privés.
-- =============================================================================

do $$
begin
  if to_regclass('public.messages') is null
     or to_regprocedure('public.assert_duo_member(uuid)') is null then
    raise exception 'MIGRATION_ORDER: applique d''abord 0001_schema.sql, 0002_rls.sql et 0003_rpc.sql.';
  end if;
end;
$$;

create table if not exists public.message_reactions (
  message_id uuid not null references public.messages (id) on delete cascade,
  duo_id uuid not null references public.duos (id) on delete cascade,
  user_id uuid not null references public.players (id) on delete cascade,
  reaction text not null check (reaction in ('❤️', '😂', '🥰', '👏', '👍')),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create index if not exists message_reactions_duo_idx
  on public.message_reactions (duo_id, message_id);

alter table public.message_reactions enable row level security;

drop policy if exists message_reactions_select_member on public.message_reactions;
create policy message_reactions_select_member
  on public.message_reactions for select
  to authenticated
  using (public.is_duo_member(duo_id));

revoke all on public.message_reactions from anon, authenticated;
grant select on public.message_reactions to authenticated;

create or replace function public.toggle_message_reaction(
  p_message uuid,
  p_reaction text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_duo uuid;
  v_existing text;
  v_result text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if p_reaction is null or p_reaction not in ('❤️', '😂', '🥰', '👏', '👍') then
    raise exception 'INVALID_REACTION';
  end if;

  select duo_id into v_duo
  from public.messages
  where id = p_message
  for update;

  if v_duo is null then
    raise exception 'MESSAGE_NOT_FOUND';
  end if;
  perform public.assert_duo_member(v_duo);

  select reaction into v_existing
  from public.message_reactions
  where message_id = p_message and user_id = v_uid;

  if v_existing = p_reaction then
    delete from public.message_reactions
    where message_id = p_message and user_id = v_uid;
    v_result := null;
  else
    insert into public.message_reactions (message_id, duo_id, user_id, reaction)
    values (p_message, v_duo, v_uid, p_reaction)
    on conflict (message_id, user_id)
    do update set reaction = excluded.reaction, created_at = now();
    v_result := p_reaction;
  end if;

  return jsonb_build_object('message_id', p_message, 'reaction', v_result);
end;
$$;

revoke all on function public.toggle_message_reaction(uuid, text) from public, anon;
grant execute on function public.toggle_message_reaction(uuid, text) to authenticated;

alter table public.message_reactions replica identity full;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'message_reactions'
     ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end;
$$;
