-- Friend request database layer for LA Jewish Tonight / LiveFeed.
-- Matches the existing static frontend assumptions without changing frontend field names.

create extension if not exists pgcrypto;

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  from_profile_id uuid not null references public.profiles(id) on delete cascade,
  to_profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint friend_requests_no_self check (from_profile_id <> to_profile_id),
  constraint friend_requests_status_check check (status in ('pending', 'accepted', 'declined', 'canceled'))
);

create index if not exists friend_requests_from_profile_id_idx on public.friend_requests(from_profile_id);
create index if not exists friend_requests_to_profile_id_idx on public.friend_requests(to_profile_id);
create index if not exists friend_requests_status_idx on public.friend_requests(status);
create index if not exists friend_requests_created_at_idx on public.friend_requests(created_at);

-- Only one pending request may exist between two profiles, regardless of direction.
create unique index if not exists friend_requests_one_pending_pair_idx
  on public.friend_requests (
    least(from_profile_id, to_profile_id),
    greatest(from_profile_id, to_profile_id)
  )
  where status = 'pending';

create table if not exists public.accepted_friendships (
  user_a uuid not null references public.profiles(id) on delete cascade,
  user_b uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint accepted_friendships_no_self check (user_a <> user_b),
  constraint accepted_friendships_canonical_order check (user_a < user_b),
  primary key (user_a, user_b)
);

create index if not exists accepted_friendships_user_a_idx on public.accepted_friendships(user_a);
create index if not exists accepted_friendships_user_b_idx on public.accepted_friendships(user_b);

create or replace function public.set_friend_request_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_friend_requests_updated_at on public.friend_requests;
create trigger set_friend_requests_updated_at
before update on public.friend_requests
for each row
execute function public.set_friend_request_updated_at();

create or replace view public.profile_friend_counts as
select profile_id, count(*) as friend_count
from (
  select user_a as profile_id from public.accepted_friendships
  union all
  select user_b as profile_id from public.accepted_friendships
) friendships
 group by profile_id;

create or replace function public.send_friend_request(
  p_from_profile_id uuid,
  p_to_profile_id uuid
)
returns table (
  request_id uuid,
  state text,
  from_profile_id uuid,
  to_profile_id uuid,
  status text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.friend_requests%rowtype;
  v_user_a uuid;
  v_user_b uuid;
begin
  if p_from_profile_id is null or p_to_profile_id is null then
    raise exception 'profile ids are required' using errcode = '22004';
  end if;

  if p_from_profile_id = p_to_profile_id then
    raise exception 'cannot send a friend request to yourself' using errcode = '23514';
  end if;

  perform 1 from public.profiles p where p.id = p_from_profile_id;
  if not found then
    raise exception 'from_profile_id does not exist' using errcode = '23503';
  end if;

  perform 1 from public.profiles p where p.id = p_to_profile_id;
  if not found then
    raise exception 'to_profile_id does not exist' using errcode = '23503';
  end if;

  v_user_a := least(p_from_profile_id, p_to_profile_id);
  v_user_b := greatest(p_from_profile_id, p_to_profile_id);

  if exists (
    select 1
    from public.accepted_friendships af
    where af.user_a = v_user_a and af.user_b = v_user_b
  ) then
    return query select null::uuid, 'friends'::text, p_from_profile_id, p_to_profile_id, 'accepted'::text;
    return;
  end if;

  select fr.* into v_request
  from public.friend_requests fr
  where fr.from_profile_id = p_from_profile_id
    and fr.to_profile_id = p_to_profile_id
    and fr.status = 'pending'
  order by fr.created_at desc
  limit 1;

  if found then
    return query select v_request.id, 'outgoing_pending'::text, v_request.from_profile_id, v_request.to_profile_id, v_request.status;
    return;
  end if;

  select fr.* into v_request
  from public.friend_requests fr
  where fr.from_profile_id = p_to_profile_id
    and fr.to_profile_id = p_from_profile_id
    and fr.status = 'pending'
  order by fr.created_at desc
  limit 1
  for update;

  if found then
    update public.friend_requests fr
       set status = 'accepted'
     where fr.id = v_request.id
     returning fr.* into v_request;

    insert into public.accepted_friendships(user_a, user_b)
    values (v_user_a, v_user_b)
    on conflict (user_a, user_b) do nothing;

    return query select v_request.id, 'accepted_incoming'::text, v_request.from_profile_id, v_request.to_profile_id, v_request.status;
    return;
  end if;

  begin
    insert into public.friend_requests(from_profile_id, to_profile_id, status)
    values (p_from_profile_id, p_to_profile_id, 'pending')
    returning * into v_request;
  exception when unique_violation then
    select fr.* into v_request
    from public.friend_requests fr
    where least(fr.from_profile_id, fr.to_profile_id) = v_user_a
      and greatest(fr.from_profile_id, fr.to_profile_id) = v_user_b
      and fr.status = 'pending'
    order by fr.created_at desc
    limit 1;

    if v_request.from_profile_id = p_from_profile_id then
      return query select v_request.id, 'outgoing_pending'::text, v_request.from_profile_id, v_request.to_profile_id, v_request.status;
    else
      return query select v_request.id, 'incoming_pending'::text, v_request.from_profile_id, v_request.to_profile_id, v_request.status;
    end if;
    return;
  end;

  return query select v_request.id, 'created'::text, v_request.from_profile_id, v_request.to_profile_id, v_request.status;
end;
$$;

create or replace function public.accept_friend_request(p_request_id uuid)
returns table (
  success boolean,
  request_id uuid,
  user_a uuid,
  user_b uuid,
  state text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.friend_requests%rowtype;
  v_user_a uuid;
  v_user_b uuid;
begin
  if p_request_id is null then
    raise exception 'request id is required' using errcode = '22004';
  end if;

  select fr.* into v_request
  from public.friend_requests fr
  where fr.id = p_request_id
    and fr.status = 'pending'
  for update;

  if not found then
    return query select false, p_request_id, null::uuid, null::uuid, 'not_pending_or_missing'::text;
    return;
  end if;

  v_user_a := least(v_request.from_profile_id, v_request.to_profile_id);
  v_user_b := greatest(v_request.from_profile_id, v_request.to_profile_id);

  update public.friend_requests fr
     set status = 'accepted'
   where fr.id = v_request.id;

  insert into public.accepted_friendships(user_a, user_b)
  values (v_user_a, v_user_b)
  on conflict (user_a, user_b) do nothing;

  return query select true, v_request.id, v_user_a, v_user_b, 'accepted'::text;
end;
$$;

create or replace function public.set_friend_request_status(
  p_request_id uuid,
  p_status text
)
returns table (
  success boolean,
  request_id uuid,
  state text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request public.friend_requests%rowtype;
begin
  if p_request_id is null then
    raise exception 'request id is required' using errcode = '22004';
  end if;

  if p_status not in ('declined', 'canceled') then
    raise exception 'unsupported friend request status' using errcode = '23514';
  end if;

  select fr.* into v_request
  from public.friend_requests fr
  where fr.id = p_request_id
    and fr.status = 'pending'
  for update;

  if not found then
    return query select false, p_request_id, 'not_pending_or_missing'::text;
    return;
  end if;

  update public.friend_requests fr
     set status = p_status
   where fr.id = v_request.id;

  return query select true, v_request.id, p_status;
end;
$$;

create or replace function public.decline_friend_request(p_request_id uuid)
returns table (
  success boolean,
  request_id uuid,
  state text
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select * from public.set_friend_request_status(p_request_id, 'declined');
$$;

create or replace function public.cancel_friend_request(p_request_id uuid)
returns table (
  success boolean,
  request_id uuid,
  state text
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select * from public.set_friend_request_status(p_request_id, 'canceled');
$$;

-- Isolated invite support for existing frontend RPC references.
create table if not exists public.friend_invites (
  invite_code text primary key default substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  inviter_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

create index if not exists friend_invites_inviter_profile_id_idx on public.friend_invites(inviter_profile_id);

create or replace function public.create_invite_link(p_inviter_profile_id uuid)
returns table (
  invite_code text,
  inviter_profile_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invite public.friend_invites%rowtype;
begin
  if p_inviter_profile_id is null then
    raise exception 'inviter profile id is required' using errcode = '22004';
  end if;

  perform 1 from public.profiles p where p.id = p_inviter_profile_id;
  if not found then
    raise exception 'inviter profile does not exist' using errcode = '23503';
  end if;

  insert into public.friend_invites(inviter_profile_id)
  values (p_inviter_profile_id)
  returning * into v_invite;

  return query select v_invite.invite_code, v_invite.inviter_profile_id;
end;
$$;

create or replace function public.resolve_invite_link(p_invite_code text)
returns table (
  invite_code text,
  inviter_profile_id uuid,
  profile_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code text;
  v_invite public.friend_invites%rowtype;
begin
  v_code := lower(regexp_replace(coalesce(p_invite_code, ''), '[^a-zA-Z0-9_-]', '', 'g'));

  if v_code = '' then
    return;
  end if;

  select fi.* into v_invite
  from public.friend_invites fi
  where fi.invite_code = v_code
  limit 1;

  if not found then
    return;
  end if;

  update public.friend_invites fi
     set last_used_at = now()
   where fi.invite_code = v_invite.invite_code;

  return query select v_invite.invite_code, v_invite.inviter_profile_id, v_invite.inviter_profile_id;
end;
$$;

alter table public.friend_requests enable row level security;
alter table public.accepted_friendships enable row level security;
alter table public.friend_invites enable row level security;

-- Reset only policies owned by this migration so the file remains re-runnable.
drop policy if exists friend_requests_select_authenticated_involved on public.friend_requests;
drop policy if exists friend_requests_select_anon_compat on public.friend_requests;
drop policy if exists accepted_friendships_select_authenticated_involved on public.accepted_friendships;
drop policy if exists accepted_friendships_select_anon_compat on public.accepted_friendships;
drop policy if exists friend_invites_select_authenticated_owner on public.friend_invites;

create policy friend_requests_select_authenticated_involved
on public.friend_requests
for select
to authenticated
using (auth.uid() = from_profile_id or auth.uid() = to_profile_id);

create policy accepted_friendships_select_authenticated_involved
on public.accepted_friendships
for select
to authenticated
using (auth.uid() = user_a or auth.uid() = user_b);

-- Compatibility read policies for the current static frontend. The app stores local
-- profile ids that may not equal auth.uid(), so direct browser reads cannot be
-- safely scoped to the caller until the frontend sends a real authenticated user.
-- Mutations remain restricted to SECURITY DEFINER RPCs below; no broad table writes
-- are granted or allowed by RLS policies.
create policy friend_requests_select_anon_compat
on public.friend_requests
for select
to anon
using (true);

create policy accepted_friendships_select_anon_compat
on public.accepted_friendships
for select
to anon
using (true);

create policy friend_invites_select_authenticated_owner
on public.friend_invites
for select
to authenticated
using (auth.uid() = inviter_profile_id);

revoke all on public.friend_requests from anon, authenticated;
revoke all on public.accepted_friendships from anon, authenticated;
revoke all on public.friend_invites from anon, authenticated;

revoke all on function public.send_friend_request(uuid, uuid) from public;
revoke all on function public.accept_friend_request(uuid) from public;
revoke all on function public.set_friend_request_status(uuid, text) from public;
revoke all on function public.decline_friend_request(uuid) from public;
revoke all on function public.cancel_friend_request(uuid) from public;
revoke all on function public.create_invite_link(uuid) from public;
revoke all on function public.resolve_invite_link(text) from public;

grant select on public.friend_requests to anon, authenticated;
grant select on public.accepted_friendships to anon, authenticated;
grant select on public.profile_friend_counts to anon, authenticated;

grant execute on function public.send_friend_request(uuid, uuid) to anon, authenticated;
grant execute on function public.accept_friend_request(uuid) to anon, authenticated;
grant execute on function public.decline_friend_request(uuid) to anon, authenticated;
grant execute on function public.cancel_friend_request(uuid) to anon, authenticated;
grant execute on function public.create_invite_link(uuid) to anon, authenticated;
grant execute on function public.resolve_invite_link(text) to anon, authenticated;
