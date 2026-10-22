-- BASTILLE — schéma Supabase (v2)
-- À coller dans Supabase : SQL Editor → New query → Run. Peut être relancé sans risque.
-- Remplacez l'adresse de la ligne « insert into public.admins » par l'e-mail administrateur si besoin.

create extension if not exists pgcrypto;

-- ============ Administrateurs ============
create table if not exists public.admins (email text primary key);
insert into public.admins (email) values ('mathieu.chaplain@facildata.com') on conflict do nothing;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins a where lower(a.email) = lower(auth.jwt() ->> 'email'));
$$;

-- ============ Profils joueurs (créés à la première connexion par code) ============
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  news_consent boolean not null default false,
  ref_code text unique not null default substr(replace(gen_random_uuid()::text,'-',''),1,8),
  referred_by uuid references public.profiles(id) on delete set null,
  credits_bonus int not null default 0,
  created_at timestamptz not null default now()
);

create or replace function public.on_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.on_new_user();

-- Consentement newsletter (le joueur ne peut modifier que le sien)
create or replace function public.set_news_consent(ok boolean) returns void
language sql security definer set search_path = public as $$
  update public.profiles set news_consent = ok where id = auth.uid();
$$;

-- Parrainage : une seule fois, dans les 24 h après l'inscription, pas soi-même.
-- Parrain +200 crédits, filleul +100 crédits de bienvenue.
create or replace function public.claim_referral(code text) returns int
language plpgsql security definer set search_path = public as $$
declare me public.profiles; ref public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or me.referred_by is not null or me.created_at < now() - interval '1 day' then return 0; end if;
  select * into ref from public.profiles where ref_code = code;
  if ref.id is null or ref.id = me.id then return 0; end if;
  update public.profiles set referred_by = ref.id, credits_bonus = credits_bonus + 100 where id = me.id;
  update public.profiles set credits_bonus = credits_bonus + 200 where id = ref.id;
  return 100;
end $$;

-- ============ Parties ============
create table if not exists public.games (
  id bigint generated always as identity primary key,
  visitor text not null check (length(visitor) <= 64),
  side text not null check (side in ('bloc','police')),
  score bigint not null default 0 check (score >= 0 and score < 1000000000000),
  stage int not null default 1 check (stage between 1 and 999),
  bosses int not null default 0 check (bosses between 0 and 999),
  duration_s int not null default 0 check (duration_s between 0 and 86400),
  device text check (length(device) <= 20),
  created_at timestamptz not null default now()
);
alter table public.games add column if not exists user_id uuid default auth.uid() references auth.users(id) on delete set null;
alter table public.games add column if not exists tenue text check (length(tenue) <= 40);
alter table public.games add column if not exists arme text check (length(arme) <= 40);
alter table public.games add column if not exists exo text check (length(exo) <= 40);
alter table public.games add column if not exists picked text check (length(picked) <= 300);
alter table public.games add column if not exists perks text check (length(perks) <= 100);
alter table public.games add column if not exists clip text check (length(clip) <= 200);
alter table public.games add column if not exists mailed_at timestamptz;
alter table public.games add column if not exists gkey uuid unique;

-- Le joueur qui se connecte juste après sa partie la rattache à son compte (dans l'heure, si elle n'a pas de propriétaire)
create or replace function public.claim_game(k uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update public.games set user_id = auth.uid()
  where gkey = k and user_id is null and created_at > now() - interval '1 hour';
  return exists (select 1 from public.games where gkey = k and user_id = auth.uid());
end $$;

-- Le joueur rattache la vidéo à SA partie (fichier rangé dans son propre dossier)
create or replace function public.set_game_clip(k uuid, path text) returns void
language sql security definer set search_path = public as $$
  update public.games set clip = path
  where gkey = k and user_id = auth.uid() and clip is null and path like auth.uid()::text || '/%';
$$;

-- ============ Visites ============
create table if not exists public.visits (
  id bigint generated always as identity primary key,
  visitor text not null check (length(visitor) <= 64),
  referrer text check (length(referrer) <= 300),
  device text check (length(device) <= 20),
  created_at timestamptz not null default now()
);
alter table public.visits add column if not exists ref text check (length(ref) <= 16);

-- ============ Sécurité (Row Level Security) ============
alter table public.admins   enable row level security;
alter table public.profiles enable row level security;
alter table public.games    enable row level security;
alter table public.visits   enable row level security;

drop policy if exists "admin self" on public.admins;
drop policy if exists "own profile" on public.profiles;
drop policy if exists "admin profiles" on public.profiles;
drop policy if exists "insert game" on public.games;
drop policy if exists "own games" on public.games;
drop policy if exists "admin games" on public.games;
drop policy if exists "insert visit" on public.visits;
drop policy if exists "admin visits" on public.visits;

create policy "admin self"     on public.admins   for select to authenticated using (public.is_admin());
create policy "own profile"    on public.profiles for select to authenticated using (id = auth.uid());
create policy "admin profiles" on public.profiles for select to authenticated using (public.is_admin());
create policy "insert game"    on public.games    for insert to anon, authenticated with check (user_id is null or user_id = auth.uid());
create policy "own games"      on public.games    for select to authenticated using (user_id = auth.uid());
create policy "admin games"    on public.games    for select to authenticated using (public.is_admin());
create policy "insert visit"   on public.visits   for insert to anon, authenticated with check (true);
create policy "admin visits"   on public.visits   for select to authenticated using (public.is_admin());

grant insert on public.games, public.visits to anon, authenticated;
grant select on public.games, public.visits, public.profiles, public.admins to authenticated;
grant execute on function public.set_news_consent(boolean), public.claim_referral(text), public.claim_game(uuid), public.set_game_clip(uuid,text) to authenticated;

-- ============ Vidéos (stockage public en lecture, dépôt par le joueur connecté dans son dossier) ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('clips', 'clips', true, 15728640, array['video/mp4','video/webm'])
on conflict (id) do update set public = true, file_size_limit = 15728640, allowed_mime_types = array['video/mp4','video/webm'];

drop policy if exists "clip upload" on storage.objects;
create policy "clip upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'clips' and (storage.foldername(name))[1] = auth.uid()::text);

-- Ancienne table de la v1 (inscriptions sans compte) : conservée si elle existe
-- (les nouveaux e-mails sont dans profiles)
