-- Keep historical catalog instances when their question is removed. The
-- question_id foreign key uses ON DELETE SET NULL, so the check must allow that
-- null reference for catalog instances; new catalog instances still get a
-- question_id from draw_question().
alter table public.session_question_instances
  drop constraint if exists session_question_instances_check;

alter table public.session_question_instances
  add constraint session_question_instances_check check (
    (kind = 'catalog' and custom_question_id is null)
    or
    (kind = 'custom' and custom_question_id is not null and question_id is null)
  );

delete from public.questions;
