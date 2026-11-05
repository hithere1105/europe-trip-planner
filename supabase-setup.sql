-- ============================================================
--  유럽 여행 플래너 · Supabase 설정 SQL
--  Supabase 대시보드 > SQL Editor > New query 에 이 파일 내용을
--  통째로 붙여넣고 [Run] 을 누르세요. (여러 번 실행해도 안전해요)
--
--  구조: 플랜은 plans 테이블에 저장되고, 브라우저(anon 키)는 테이블을
--  직접 읽거나 쓸 수 없어요. 아래 함수(plan_*)로만 접근하고, 코드(2자리)
--  확인과 닉네임 10개 제한은 모두 서버(DB)에서 처리해요.
--  코드를 5번 틀리면 해당 닉네임은 10분간 잠겨요.
-- ============================================================

create table if not exists public.plans (
  id           text primary key,                 -- 소문자로 바꾼 닉네임
  nick         text not null,                    -- 처음 입력한 닉네임(표시용)
  code         text not null,                    -- 숫자 2자리
  plan         jsonb not null,                   -- 일정 전체
  rev          integer not null default 1,       -- 저장 횟수(충돌 확인용)
  fails        integer not null default 0,       -- 코드 연속 실패 횟수
  locked_until timestamptz,                      -- 잠금 해제 시각
  updated_at   timestamptz not null default now()
);

alter table public.plans enable row level security;      -- 정책이 없으므로 직접 접근 전부 차단
revoke all on table public.plans from anon, authenticated;

-- 내부용: 코드 확인 (성공하면 null, 실패하면 오류 이름을 돌려줌)
create or replace function public._plan_check(p_id text, p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare r public.plans%rowtype;
begin
  select * into r from public.plans where id = p_id for update;
  if not found then return 'not_found'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if r.code is distinct from p_code then
    if r.fails + 1 >= 5 then
      update public.plans set fails = 0, locked_until = now() + interval '10 minutes' where id = p_id;
    else
      update public.plans set fails = r.fails + 1 where id = p_id;
    end if;
    return 'bad_code';
  end if;
  if r.fails <> 0 then
    update public.plans set fails = 0 where id = p_id;
  end if;
  return null;
end $$;
revoke all on function public._plan_check(text, text) from public, anon, authenticated;

-- 닉네임이 있는지 + 지금까지 만들어진 닉네임 수
create or replace function public.plan_status(p_nick text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare n integer; e boolean;
begin
  select count(*) into n from public.plans;
  select exists (select 1 from public.plans where id = lower(btrim(p_nick))) into e;
  return jsonb_build_object('ok', true, 'exists', e, 'count', n, 'max', 10);
end $$;

-- 플랜 불러오기 (닉네임 + 코드)
create or replace function public.plan_load(p_nick text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare pid text := lower(btrim(p_nick)); e text; r public.plans%rowtype;
begin
  e := public._plan_check(pid, p_code);
  if e is not null then return jsonb_build_object('ok', false, 'error', e); end if;
  select * into r from public.plans where id = pid;
  return jsonb_build_object('ok', true, 'nick', r.nick, 'rev', r.rev, 'plan', r.plan);
end $$;

-- 저장된 버전 번호만 확인 (다른 기기에서 바뀌었는지 확인용)
create or replace function public.plan_rev(p_nick text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare pid text := lower(btrim(p_nick)); e text; r public.plans%rowtype;
begin
  e := public._plan_check(pid, p_code);
  if e is not null then return jsonb_build_object('ok', false, 'error', e); end if;
  select * into r from public.plans where id = pid;
  return jsonb_build_object('ok', true, 'rev', r.rev);
end $$;

-- 새 닉네임 만들기 (최대 10개)
create or replace function public.plan_create(p_nick text, p_code text, p_plan jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare pid text := lower(btrim(p_nick)); n integer;
begin
  if char_length(btrim(p_nick)) < 1 or char_length(btrim(p_nick)) > 12 then
    return jsonb_build_object('ok', false, 'error', 'bad_nick');
  end if;
  if p_code is null or p_code !~ '^[0-9]{2}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_code_format');
  end if;
  perform pg_advisory_xact_lock(7001);              -- 동시에 만들어도 10개를 넘지 않게
  if exists (select 1 from public.plans where id = pid) then
    return jsonb_build_object('ok', false, 'error', 'exists');
  end if;
  select count(*) into n from public.plans;
  if n >= 10 then
    return jsonb_build_object('ok', false, 'error', 'full');
  end if;
  insert into public.plans (id, nick, code, plan) values (pid, btrim(p_nick), p_code, p_plan);
  return jsonb_build_object('ok', true, 'rev', 1);
end $$;

-- 저장하기 (p_base_rev 가 서버와 다르면 충돌, p_force 면 덮어쓰기)
create or replace function public.plan_save(
  p_nick text, p_code text, p_plan jsonb, p_base_rev integer, p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare pid text := lower(btrim(p_nick)); e text; r public.plans%rowtype; nrev integer;
begin
  e := public._plan_check(pid, p_code);
  if e is not null then return jsonb_build_object('ok', false, 'error', e); end if;
  select * into r from public.plans where id = pid;
  if r.rev <> p_base_rev and not coalesce(p_force, false) then
    return jsonb_build_object('ok', false, 'error', 'conflict', 'rev', r.rev);
  end if;
  nrev := r.rev + 1;
  update public.plans set plan = p_plan, rev = nrev, updated_at = now() where id = pid;
  return jsonb_build_object('ok', true, 'rev', nrev);
end $$;

-- 플랜 삭제 (닉네임 자리 반납)
create or replace function public.plan_delete(p_nick text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare pid text := lower(btrim(p_nick)); e text;
begin
  e := public._plan_check(pid, p_code);
  if e is not null then return jsonb_build_object('ok', false, 'error', e); end if;
  delete from public.plans where id = pid;
  return jsonb_build_object('ok', true);
end $$;

-- 브라우저(anon 키)가 부를 수 있는 함수만 열어 둠
revoke all on function public.plan_status(text) from public;
revoke all on function public.plan_load(text, text) from public;
revoke all on function public.plan_rev(text, text) from public;
revoke all on function public.plan_create(text, text, jsonb) from public;
revoke all on function public.plan_save(text, text, jsonb, integer, boolean) from public;
revoke all on function public.plan_delete(text, text) from public;
grant execute on function public.plan_status(text) to anon, authenticated;
grant execute on function public.plan_load(text, text) to anon, authenticated;
grant execute on function public.plan_rev(text, text) to anon, authenticated;
grant execute on function public.plan_create(text, text, jsonb) to anon, authenticated;
grant execute on function public.plan_save(text, text, jsonb, integer, boolean) to anon, authenticated;
grant execute on function public.plan_delete(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
