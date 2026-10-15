-- =============================================================================
-- Entre Nous — 0015_admin_intimate_mode_lock.sql
-- Contrôle du mode intime exclusivement par les administrateurs.
-- =============================================================================

do $$
begin
  if to_regclass('public.intimate_mode_rooms') is null
     or to_regprocedure('public.is_admin()') is null then
    raise exception 'MIGRATION_ORDER: applique d''abord 0007_admin.sql et 0014_intimate_conversation_mode.sql.';
  end if;
end;
$$;

create table if not exists public.platform_features (
  id boolean primary key default true check (id),
  intimate_mode_enabled boolean not null default false,
  updated_by uuid references public.players (id) on delete set null,
  updated_at timestamptz not null default now()
);

do $$
declare
  v_inserted boolean := false;
begin
  insert into public.platform_features (id, intimate_mode_enabled)
  values (true, false)
  on conflict (id) do nothing
  returning true into v_inserted;

  if coalesce(v_inserted, false) then
    update public.intimate_mode_rooms
    set state = 'ended', ended_at = now()
    where state in ('consent', 'active');
    delete from public.intimate_mode_readiness;
    delete from public.intimate_mode_participants;
  end if;
end;
$$;

alter table public.platform_features enable row level security;
revoke all on public.platform_features from public, anon, authenticated;

create or replace function public.intimate_mode_is_enabled()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select intimate_mode_enabled from public.platform_features where id = true),
    false
  );
$$;

create or replace function public.get_intimate_mode_enabled()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  return public.intimate_mode_is_enabled();
end;
$$;

create or replace function public.assert_intimate_mode_enabled()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.intimate_mode_is_enabled() then
    raise exception 'INTIMATE_MODE_DISABLED';
  end if;
end;
$$;

create or replace function public.guard_intimate_mode_room()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.state in ('consent', 'active') then
    perform public.assert_intimate_mode_enabled();
  end if;
  return new;
end;
$$;

drop trigger if exists intimate_mode_room_feature_guard on public.intimate_mode_rooms;
create trigger intimate_mode_room_feature_guard
  before insert or update of state on public.intimate_mode_rooms
  for each row execute function public.guard_intimate_mode_room();

create or replace function public.guard_intimate_mode_data()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_intimate_mode_enabled();
  return new;
end;
$$;

drop trigger if exists intimate_mode_participant_feature_guard on public.intimate_mode_participants;
create trigger intimate_mode_participant_feature_guard
  before insert or update on public.intimate_mode_participants
  for each row execute function public.guard_intimate_mode_data();

drop trigger if exists intimate_mode_readiness_feature_guard on public.intimate_mode_readiness;
create trigger intimate_mode_readiness_feature_guard
  before insert or update on public.intimate_mode_readiness
  for each row execute function public.guard_intimate_mode_data();

create or replace function public.guard_intimate_mode_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.intimate_mode_id is not null then
    perform public.assert_intimate_mode_enabled();
    if not exists (
      select 1 from public.intimate_mode_rooms
      where id = new.intimate_mode_id and state = 'active' and duo_id = new.duo_id
    ) then
      raise exception 'INTIMATE_MODE_NOT_ACTIVE';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists intimate_mode_message_feature_guard on public.messages;
create trigger intimate_mode_message_feature_guard
  before insert or update of intimate_mode_id on public.messages
  for each row execute function public.guard_intimate_mode_message();

create or replace function public.admin_set_intimate_mode_enabled(p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public.is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  update public.platform_features
  set intimate_mode_enabled = p_enabled,
      updated_by = auth.uid(),
      updated_at = now()
  where id = true;

  if not p_enabled then
    update public.intimate_mode_rooms
    set state = 'ended', ended_at = now()
    where state in ('consent', 'active');
    delete from public.intimate_mode_readiness;
    delete from public.intimate_mode_participants;
  end if;
  return p_enabled;
end;
$$;

create or replace function public.prevent_client_admin_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_admin is distinct from old.is_admin
     and auth.role() is not null
     and auth.role() not in ('service_role', 'postgres', 'supabase_admin') then
    raise exception 'ADMIN_ASSIGNMENT_REQUIRED';
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_client_admin_escalation on public.players;
create trigger prevent_client_admin_escalation
  before update of is_admin on public.players
  for each row execute function public.prevent_client_admin_escalation();

create or replace function public.claim_admin(p_secret text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception 'ADMIN_ASSIGNMENT_REQUIRED';
end;
$$;

revoke all on function public.intimate_mode_is_enabled() from public, anon, authenticated;
revoke all on function public.assert_intimate_mode_enabled() from public, anon, authenticated;
revoke all on function public.guard_intimate_mode_room() from public, anon, authenticated;
revoke all on function public.guard_intimate_mode_data() from public, anon, authenticated;
revoke all on function public.guard_intimate_mode_message() from public, anon, authenticated;
revoke all on function public.prevent_client_admin_escalation() from public, anon, authenticated;
revoke all on function public.get_intimate_mode_enabled() from public, anon;
revoke all on function public.admin_set_intimate_mode_enabled(boolean) from public, anon;
revoke all on function public.claim_admin(text) from public, anon;
grant execute on function public.get_intimate_mode_enabled() to authenticated;
grant execute on function public.admin_set_intimate_mode_enabled(boolean) to authenticated;
grant execute on function public.claim_admin(text) to authenticated;
