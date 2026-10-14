-- =============================================================================
-- 0007_admin.sql — Page Admin + Import de questions depuis TXT
-- =============================================================================

alter table public.players
  add column if not exists is_admin boolean not null default false;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_admin from public.players where id = auth.uid()),
    false
  );
$$;

create or replace function public._admin_next_code(p_category public.question_category)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pref text;
  v_max  int;
begin
  v_pref := case p_category
    when 'brise_glace'   then 'bg'
    when 'personnalite'  then 'ph'
    when 'amour'         then 'as'
    when 'secrets'       then 'sc'
    when 'pimente'       then 'pi'
    when 'tres_intime'   then 'ti'
    when 'avenir'        then 'av'
    else null
  end;
  if v_pref is null then
    raise exception 'CATEGORIE_INVALIDE';
  end if;
  select coalesce(max(substring(code from length(v_pref)+2)::int), 100)
    into v_max
  from public.questions
  where category = p_category
    and code ~ ('^' || v_pref || '-[0-9]+$');
  return v_pref || '-' || (v_max + 1);
end;
$$;

create or replace function public.admin_import_questions(
  p_category public.question_category,
  p_questions text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_q   text;
  v_code text;
  v_ins int := 0;
  v_dup int := 0;
  v_skip int := 0;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public.is_admin() then
    raise exception 'NOT_ADMIN';
  end if;
  if p_questions is null then
    return jsonb_build_object('inserted', 0, 'duplicates', 0, 'skipped', 0);
  end if;
  foreach v_q in array p_questions loop
    v_q := trim(v_q);
    if v_q = '' then
      v_skip := v_skip + 1;
      continue;
    end if;
    if left(v_q, 1) = '#' then
      v_skip := v_skip + 1;
      continue;
    end if;
    if exists (
      select 1 from public.questions q
      where q.category = p_category
        and lower(regexp_replace(q.body, '\s+', ' ', 'g')) =
            lower(regexp_replace(v_q,  '\s+', ' ', 'g'))
    ) then
      v_dup := v_dup + 1;
      continue;
    end if;
    v_code := public._admin_next_code(p_category);
    insert into public.questions (code, category, body, is_active)
    values (v_code, p_category, v_q, true)
    on conflict (code) do nothing;
    v_ins := v_ins + 1;
  end loop;
  return jsonb_build_object('inserted',v_ins,'duplicates',v_dup,'skipped',v_skip,'total',array_length(p_questions,1));
end;
$$;

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
revoke all on function public._admin_next_code(public.question_category) from public, anon;
grant execute on function public._admin_next_code(public.question_category) to authenticated;
revoke all on function public.admin_import_questions(public.question_category, text[]) from public, anon;
grant execute on function public.admin_import_questions(public.question_category, text[]) to authenticated;
