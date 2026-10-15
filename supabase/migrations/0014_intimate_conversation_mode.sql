-- =============================================================================
-- Entre Nous — 0014_intimate_conversation_mode.sql
-- Salon de conversation intime, avec accord mutuel et contrôle d'accès serveur.
-- =============================================================================

do $$
begin
  if to_regclass('public.messages') is null
     or to_regclass('public.session_consents') is null
     or to_regprocedure('public.assert_duo_member(uuid)') is null
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'sessions'
         and column_name = 'question_category'
     ) then
    raise exception 'MIGRATION_ORDER: applique les migrations 0001 à 0010 avant 0014.';
  end if;
end;
$$;

create table if not exists public.intimate_mode_rooms (
  id uuid primary key default gen_random_uuid(),
  duo_id uuid not null references public.duos (id) on delete cascade,
  created_by uuid not null references public.players (id) on delete cascade,
  state text not null default 'consent'
    check (state in ('consent', 'active', 'fallback', 'ended')),
  fallback_session_id uuid references public.sessions (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  ended_at timestamptz
);

create unique index if not exists intimate_mode_one_open_room_per_duo
  on public.intimate_mode_rooms (duo_id)
  where state in ('consent', 'active');

create table if not exists public.intimate_mode_participants (
  room_id uuid not null references public.intimate_mode_rooms (id) on delete cascade,
  player_id uuid not null references public.players (id) on delete cascade,
  is_adult boolean not null,
  accepts_mode boolean not null,
  accepts_privacy_pledge boolean not null,
  created_at timestamptz not null default now(),
  primary key (room_id, player_id)
);

create table if not exists public.intimate_mode_readiness (
  room_id uuid not null references public.intimate_mode_rooms (id) on delete cascade,
  player_id uuid not null references public.players (id) on delete cascade,
  excitement smallint not null check (excitement between 0 and 100),
  created_at timestamptz not null default now(),
  primary key (room_id, player_id)
);

alter table public.intimate_mode_rooms enable row level security;
alter table public.intimate_mode_participants enable row level security;
alter table public.intimate_mode_readiness enable row level security;

drop policy if exists intimate_mode_rooms_select_member on public.intimate_mode_rooms;
create policy intimate_mode_rooms_select_member
  on public.intimate_mode_rooms for select
  to authenticated
  using (public.is_duo_member(duo_id));

drop policy if exists intimate_mode_participants_select_self on public.intimate_mode_participants;
create policy intimate_mode_participants_select_self
  on public.intimate_mode_participants for select
  to authenticated
  using (player_id = auth.uid());

revoke all on public.intimate_mode_rooms from anon, authenticated;
grant select on public.intimate_mode_rooms to authenticated;
revoke all on public.intimate_mode_participants from anon, authenticated;
revoke all on public.intimate_mode_readiness from anon, authenticated;

alter table public.messages
  add column if not exists intimate_mode_id uuid
  references public.intimate_mode_rooms (id) on delete set null;

create index if not exists messages_intimate_mode_idx
  on public.messages (intimate_mode_id, created_at)
  where intimate_mode_id is not null;

create or replace function public.get_intimate_mode_snapshot(p_room uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_room public.intimate_mode_rooms;
begin
  select * into v_room
  from public.intimate_mode_rooms
  where id = p_room;
  if v_room.id is null then
    raise exception 'INTIMATE_MODE_NOT_FOUND';
  end if;
  perform public.assert_duo_member(v_room.duo_id);

  return jsonb_build_object(
    'id', v_room.id,
    'duo_id', v_room.duo_id,
    'state', v_room.state,
    'fallback_session_id', v_room.fallback_session_id,
    'has_submitted', exists (
      select 1 from public.intimate_mode_participants
      where room_id = v_room.id and player_id = auth.uid()
    )
  );
end;
$$;

create or replace function public.get_open_intimate_mode(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room uuid;
begin
  perform public.assert_duo_member(p_duo);
  perform 1 from public.duos where id = p_duo for update;
  update public.intimate_mode_rooms
  set state = 'ended', ended_at = now()
  where duo_id = p_duo and state = 'consent' and expires_at <= now();
  delete from public.intimate_mode_readiness
  where room_id in (
    select id from public.intimate_mode_rooms
    where duo_id = p_duo and state = 'ended' and expires_at <= now()
  );
  delete from public.intimate_mode_participants
  where room_id in (
    select id from public.intimate_mode_rooms
    where duo_id = p_duo and state = 'ended' and expires_at <= now()
  );

  select id into v_room
  from public.intimate_mode_rooms
  where duo_id = p_duo and state in ('consent', 'active')
  order by created_at desc
  limit 1;
  if v_room is null then
    return null;
  end if;
  return public.get_intimate_mode_snapshot(v_room);
end;
$$;

create or replace function public.create_intimate_mode(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_room uuid;
begin
  perform public.assert_duo_member(p_duo);
  if (select count(*) from public.duo_members where duo_id = p_duo) <> 2 then
    raise exception 'NEED_TWO_PLAYERS';
  end if;
  perform 1 from public.duos where id = p_duo for update;
  update public.intimate_mode_rooms
  set state = 'ended', ended_at = now()
  where duo_id = p_duo and state = 'consent' and expires_at <= now();
  delete from public.intimate_mode_readiness
  where room_id in (
    select id from public.intimate_mode_rooms
    where duo_id = p_duo and state = 'ended' and expires_at <= now()
  );
  delete from public.intimate_mode_participants
  where room_id in (
    select id from public.intimate_mode_rooms
    where duo_id = p_duo and state = 'ended' and expires_at <= now()
  );

  select id into v_room
  from public.intimate_mode_rooms
  where duo_id = p_duo and state in ('consent', 'active')
  order by created_at desc
  limit 1
  for update;

  if v_room is null then
    insert into public.intimate_mode_rooms (duo_id, created_by)
    values (p_duo, v_uid)
    returning id into v_room;
  end if;

  return public.get_intimate_mode_snapshot(v_room);
end;
$$;

create or replace function public.submit_intimate_mode_checkin(
  p_room uuid,
  p_is_adult boolean,
  p_accepts_mode boolean,
  p_accepts_privacy_pledge boolean,
  p_excitement smallint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_duo uuid;
  v_state text;
  v_expires_at timestamptz;
  v_participants int;
  v_ready int;
  v_min_excitement int;
  v_fallback_session uuid;
begin
  select duo_id, state, expires_at into v_duo, v_state, v_expires_at
  from public.intimate_mode_rooms
  where id = p_room
  for update;
  if v_duo is null then
    raise exception 'INTIMATE_MODE_NOT_FOUND';
  end if;
  perform public.assert_duo_member(v_duo);
  if v_state <> 'consent' then
    return public.get_intimate_mode_snapshot(p_room);
  end if;
  if v_expires_at <= now() then
    update public.intimate_mode_rooms
    set state = 'ended', ended_at = now()
    where id = p_room;
    delete from public.intimate_mode_readiness where room_id = p_room;
    delete from public.intimate_mode_participants where room_id = p_room;
    return public.get_intimate_mode_snapshot(p_room);
  end if;
  if p_excitement is null or p_excitement < 0 or p_excitement > 100 then
    raise exception 'INVALID_READINESS_LEVEL';
  end if;

  if not p_is_adult or not p_accepts_mode or not p_accepts_privacy_pledge then
    update public.intimate_mode_rooms
    set state = 'fallback', ended_at = now()
    where id = p_room;
    delete from public.intimate_mode_readiness where room_id = p_room;
    delete from public.intimate_mode_participants where room_id = p_room;
    return public.get_intimate_mode_snapshot(p_room);
  end if;

  insert into public.intimate_mode_participants
    (room_id, player_id, is_adult, accepts_mode, accepts_privacy_pledge)
  values (p_room, v_uid, true, true, true)
  on conflict (room_id, player_id) do update
    set is_adult = excluded.is_adult,
        accepts_mode = excluded.accepts_mode,
        accepts_privacy_pledge = excluded.accepts_privacy_pledge,
        created_at = now();

  insert into public.intimate_mode_readiness (room_id, player_id, excitement)
  values (p_room, v_uid, p_excitement)
  on conflict (room_id, player_id) do update
    set excitement = excluded.excitement, created_at = now();

  select count(*) into v_participants
  from public.intimate_mode_participants
  where room_id = p_room and is_adult and accepts_mode and accepts_privacy_pledge;
  select count(*), min(excitement) into v_ready, v_min_excitement
  from public.intimate_mode_readiness
  where room_id = p_room;

  if v_participants = 2 and v_ready = 2 then
    if v_min_excitement >= 50 then
      update public.intimate_mode_rooms set state = 'active' where id = p_room;
      delete from public.intimate_mode_readiness where room_id = p_room;
    else
      if exists (
        select 1
        from public.questions q
        join public.intimate_mode_rooms r on r.duo_id = v_duo
        where q.category = 'tres_intime'
          and q.is_active
          and not exists (
            select 1 from public.duo_used_questions used
            where used.duo_id = r.duo_id and used.question_id = q.id
          )
      ) then
        insert into public.sessions
          (duo_id, state, created_by, expires_at, question_category)
        select v_duo, 'ready', created_by, now() + interval '24 hours', 'tres_intime'
        from public.intimate_mode_rooms
        where id = p_room
        returning id into v_fallback_session;

        insert into public.session_participants (session_id, player_id)
        select v_fallback_session, player_id
        from public.duo_members
        where duo_id = v_duo;

        insert into public.session_consents
          (session_id, player_id, is_adult, allow_intimate)
        select v_fallback_session, player_id, true, true
        from public.duo_members
        where duo_id = v_duo
        on conflict (session_id, player_id) do update
          set is_adult = true, allow_intimate = true, updated_at = now();
      end if;

      update public.intimate_mode_rooms
      set state = 'fallback', fallback_session_id = v_fallback_session, ended_at = now()
      where id = p_room;
      delete from public.intimate_mode_readiness where room_id = p_room;
      delete from public.intimate_mode_participants where room_id = p_room;
    end if;
  end if;

  return public.get_intimate_mode_snapshot(p_room);
end;
$$;

create or replace function public.send_intimate_mode_message(
  p_room uuid,
  p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_duo uuid;
  v_state text;
  v_body text := btrim(coalesce(p_body, ''));
  v_recent int;
  v_msg public.messages;
begin
  select duo_id, state into v_duo, v_state
  from public.intimate_mode_rooms
  where id = p_room
  for update;
  if v_duo is null then
    raise exception 'INTIMATE_MODE_NOT_FOUND';
  end if;
  perform public.assert_duo_member(v_duo);
  if v_state <> 'active' or not exists (
    select 1 from public.intimate_mode_participants
    where room_id = p_room and player_id = v_uid
      and is_adult and accepts_mode and accepts_privacy_pledge
  ) then
    raise exception 'INTIMATE_MODE_NOT_ACTIVE';
  end if;
  if v_body = '' then raise exception 'EMPTY_MESSAGE'; end if;
  if char_length(v_body) > 2000 then raise exception 'MESSAGE_TOO_LONG'; end if;

  select count(*) into v_recent
  from public.messages
  where sender_id = v_uid and created_at > now() - interval '1 minute';
  if v_recent >= 30 then raise exception 'RATE_LIMITED'; end if;

  insert into public.messages (duo_id, sender_id, body, intimate_mode_id)
  values (v_duo, v_uid, v_body, p_room)
  returning * into v_msg;
  return to_jsonb(v_msg);
end;
$$;

create or replace function public.end_intimate_mode(p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duo uuid;
begin
  select duo_id into v_duo
  from public.intimate_mode_rooms
  where id = p_room
  for update;
  if v_duo is null then
    raise exception 'INTIMATE_MODE_NOT_FOUND';
  end if;
  perform public.assert_duo_member(v_duo);
  update public.intimate_mode_rooms
  set state = 'ended', ended_at = now()
  where id = p_room and state in ('consent', 'active');
  delete from public.intimate_mode_participants where room_id = p_room;
  delete from public.intimate_mode_readiness where room_id = p_room;
  return public.get_intimate_mode_snapshot(p_room);
end;
$$;

revoke all on function public.get_intimate_mode_snapshot(uuid) from public, anon;
revoke all on function public.get_open_intimate_mode(uuid) from public, anon;
revoke all on function public.create_intimate_mode(uuid) from public, anon;
revoke all on function public.submit_intimate_mode_checkin(uuid, boolean, boolean, boolean, smallint) from public, anon;
revoke all on function public.send_intimate_mode_message(uuid, text) from public, anon;
revoke all on function public.end_intimate_mode(uuid) from public, anon;
grant execute on function public.get_intimate_mode_snapshot(uuid) to authenticated;
grant execute on function public.get_open_intimate_mode(uuid) to authenticated;
grant execute on function public.create_intimate_mode(uuid) to authenticated;
grant execute on function public.submit_intimate_mode_checkin(uuid, boolean, boolean, boolean, smallint) to authenticated;
grant execute on function public.send_intimate_mode_message(uuid, text) to authenticated;
grant execute on function public.end_intimate_mode(uuid) to authenticated;

alter table public.intimate_mode_rooms replica identity full;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'intimate_mode_rooms'
     ) then
    alter publication supabase_realtime add table public.intimate_mode_rooms;
  end if;
end;
$$;
