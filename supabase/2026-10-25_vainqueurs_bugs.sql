-- BASTILLE — migration du 25/10/2026 (2) : mur des joueurs, messages des vainqueurs, signalement de bugs
-- Idempotente : peut être rejouée sans risque.

-- ============ Mur des joueurs (commentaires) ============
create table if not exists public.comments (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 2 and 280),
  side text check (side in ('bloc','police')),
  hidden boolean not null default false,
  reports int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.comments alter column user_id drop not null;
alter table public.comments add column if not exists won boolean not null default false;
alter table public.comments add column if not exists era text check (era is null or length(era) <= 12);
alter table public.comments add column if not exists time_s int;
alter table public.comments add column if not exists anon_name text check (anon_name is null or char_length(anon_name) between 2 and 24);
alter table public.comments add column if not exists gkey uuid unique;
alter table public.comments add column if not exists visitor text;

create index if not exists comments_recent on public.comments (created_at desc) where not hidden;
create table if not exists public.comment_reports (
  comment_id bigint references public.comments(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
alter table public.comments enable row level security;
alter table public.comment_reports enable row level security;
revoke all on public.comments, public.comment_reports from anon, authenticated;
drop policy if exists "admin comments" on public.comments;
create policy "admin comments" on public.comments for select to authenticated using (public.is_admin());
grant select on public.comments to authenticated;

-- Normalisation pour le filtre : minuscules, sans accents, lettres répétées réduites, chiffres « leet » remplacés
create or replace function public.norm_text(t text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(
           translate(lower(t), 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ013457@$', 'aaaaaaceeeeiiiinooooouuuuyyoaoieastas'),
           '(.)\1+', '\1', 'g');
$$;

-- Liste de termes refusés (insultes, propos haineux, appels à la violence). Complétable par l'administrateur.
create table if not exists public.banned_terms (term text primary key);
alter table public.banned_terms enable row level security;
revoke all on public.banned_terms from anon, authenticated;
delete from public.banned_terms where term in ('viol','suicide');
insert into public.banned_terms (term) values
 ('connard'),('connasse'),('salope'),('pute'),('putain de'),('encule'),('enfoire'),('batard'),('nique'),('niquer'),('ntm'),('fdp'),('fils de p'),
 ('pd'),('pede'),('tapette'),('gouine'),('negre'),('negro'),('bougnoul'),('bicot'),('raton'),('youpin'),('feuj'),('chinetoque'),('bamboula'),
 ('sale arabe'),('sale noir'),('sale juif'),('sale blanc'),('sale flic'),('nazi'),('hitler'),('heil'),('sieg'),
 ('tuer les'),('tuez'),('buter les'),('butez'),('egorger'),('mort aux'),('crever les'),('a mort'),('acab'),('1312'),
 ('violer'),('violez'),('pedo'),('pedophile'),('jihad'),('attentat')
on conflict do nothing;

create or replace function public.has_banned(t text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.banned_terms b
    where (' ' || regexp_replace(public.norm_text(t), '[^a-z0-9]+', ' ', 'g') || ' ')
          like ('% ' || btrim(regexp_replace(public.norm_text(b.term), '[^a-z0-9]+', ' ', 'g')) || ' %')
  );
$$;

-- Publier : joueur vérifié non exclu, sans lien, sans terme refusé, 30 s entre deux messages, 20 par jour
create or replace function public.post_comment(p_body text, p_side text) returns bigint
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); b text; nid bigint;
begin
  if uid is null then raise exception 'auth'; end if;
  if exists (select 1 from public.profiles where id = uid and banned) then raise exception 'banned'; end if;
  b := btrim(regexp_replace(regexp_replace(coalesce(p_body,''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g'));
  if char_length(b) < 2 or char_length(b) > 280 then raise exception 'length'; end if;
  if b ~* '(https?://|www\.|[a-z0-9-]+\.(com|fr|net|org|io|ly|gg|me|tv|co|xyz|info|biz|ru|be|ch)\b|@[a-z0-9_]{3,})' then raise exception 'link'; end if;
  if public.has_banned(b) then raise exception 'banned_term'; end if;
  if exists (select 1 from public.comments where user_id = uid and created_at > now() - interval '30 seconds') then raise exception 'rate_limited'; end if;
  if (select count(*) from public.comments where user_id = uid and created_at > now() - interval '1 day') >= 20 then raise exception 'rate_limited'; end if;
  insert into public.comments (user_id, body, side) values (uid, b, case when p_side in ('bloc','police') then p_side end) returning id into nid;
  return nid;
end $$;

-- Lire le mur : messages visibles, auteurs non exclus, pseudo et meilleur score (jamais l'e-mail)
drop function if exists public.wall(timestamptz,int);
create or replace function public.wall(p_before timestamptz default null, p_limit int default 30)
returns table (id bigint, pseudo text, body text, side text, best bigint, created_at timestamptz, mine boolean, won boolean, era text, time_s int)
language sql stable security definer set search_path = public as $$
  select c.id, coalesce(p.pseudo, c.anon_name, 'Joueur'), c.body, c.side,
         case when c.user_id is null then null else (select max(g.score) from public.games g where g.user_id = c.user_id and g.side = coalesce(c.side, g.side)) end,
         c.created_at, c.user_id is not null and c.user_id = auth.uid(), c.won, c.era, c.time_s
  from public.comments c left join public.profiles p on p.id = c.user_id
  where not c.hidden and (c.user_id is null or not coalesce(p.banned,false)) and (p_before is null or c.created_at < p_before)
  order by c.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 50);
$$;

-- Signaler : une fois par joueur et par message ; masqué automatiquement à 3 signalements
create or replace function public.report_comment(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'auth'; end if;
  insert into public.comment_reports (comment_id, user_id) values (p_id, uid) on conflict do nothing;
  if found then
    update public.comments set reports = reports + 1, hidden = hidden or reports + 1 >= 3 where id = p_id;
  end if;
end $$;

-- Supprimer son propre message
create or replace function public.delete_my_comment(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from public.comments where id = p_id and user_id = auth.uid();
$$;

-- Modération (administrateur)
create or replace function public.admin_moderate_comment(p_id bigint, p_action text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_action = 'hide' then update public.comments set hidden = true where id = p_id;
  elsif p_action = 'show' then update public.comments set hidden = false, reports = 0 where id = p_id; delete from public.comment_reports where comment_id = p_id;
  elsif p_action = 'delete' then delete from public.comments where id = p_id;
  else raise exception 'action'; end if;
end $$;

create or replace function public.admin_add_banned_term(p_term text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  insert into public.banned_terms (term) values (lower(btrim(p_term))) on conflict do nothing;
end $$;

revoke execute on function public.norm_text(text), public.has_banned(text) from public, anon, authenticated;
revoke execute on function public.post_comment(text,text), public.report_comment(bigint), public.delete_my_comment(bigint),
  public.admin_moderate_comment(bigint,text), public.admin_add_banned_term(text) from public, anon;
grant execute on function public.post_comment(text,text), public.report_comment(bigint), public.delete_my_comment(bigint),
  public.admin_moderate_comment(bigint,text), public.admin_add_banned_term(text) to authenticated;
revoke execute on function public.wall(timestamptz,int) from public;
grant execute on function public.wall(timestamptz,int) to anon, authenticated;


-- ============ Messages des vainqueurs (prise de la Bastille) ============
-- Un message par victoire : la partie (gkey) doit être gagnée, récente (2 h) et venir du même navigateur (visitor) ou du même compte
create or replace function public.post_win_comment(p_gkey uuid, p_visitor text, p_name text, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); g record; b text; n text; nid bigint;
begin
  select * into g from public.games where gkey = p_gkey and won and created_at > now() - interval '2 hours'
    and (visitor = p_visitor or (uid is not null and user_id = uid)) limit 1;
  if not found then raise exception 'not_winner'; end if;
  if exists (select 1 from public.comments where gkey = p_gkey) then raise exception 'already'; end if;
  if uid is not null and exists (select 1 from public.profiles where id = uid and banned) then raise exception 'banned'; end if;
  b := btrim(regexp_replace(regexp_replace(coalesce(p_body,''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g'));
  n := btrim(regexp_replace(regexp_replace(coalesce(p_name,''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g'));
  if char_length(b) < 2 or char_length(b) > 280 then raise exception 'length'; end if;
  if uid is null and (char_length(n) < 2 or char_length(n) > 24) then raise exception 'name'; end if;
  if (b || ' ' || n) ~* '(https?://|www\.|[a-z0-9-]+\.(com|fr|net|org|io|ly|gg|me|tv|co|xyz|info|biz|ru|be|ch)\b|@[a-z0-9_]{3,})' then raise exception 'link'; end if;
  if public.has_banned(b) or public.has_banned(n) then raise exception 'banned_term'; end if;
  if (select count(*) from public.comments where visitor = p_visitor and created_at > now() - interval '1 day') >= 10 then raise exception 'rate_limited'; end if;
  insert into public.comments (user_id, body, side, won, era, time_s, anon_name, gkey, visitor)
  values (uid, b, g.side, true, g.era, g.time_s, case when uid is null then n end, p_gkey, left(p_visitor, 64)) returning id into nid;
  return nid;
end $$;
revoke execute on function public.post_win_comment(uuid,text,text,text) from public;
grant execute on function public.post_win_comment(uuid,text,text,text) to anon, authenticated;

-- ============ Signalement de bugs ============
create table if not exists public.bug_reports (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid references auth.users(id) on delete set null,
  visitor text,
  body text not null check (char_length(body) between 5 and 1000),
  ctx jsonb,
  status text not null default 'nouveau' check (status in ('nouveau','vu','corrigé','ignoré'))
);
alter table public.bug_reports enable row level security;
revoke all on public.bug_reports from anon, authenticated;
drop policy if exists "admin bugs" on public.bug_reports;
create policy "admin bugs" on public.bug_reports for select to authenticated using (public.is_admin());
grant select on public.bug_reports to authenticated;

create or replace function public.report_bug(p_visitor text, p_body text, p_ctx jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare b text; nid bigint;
begin
  b := btrim(regexp_replace(coalesce(p_body,''), '[[:cntrl:]]', ' ', 'g'));
  if char_length(b) < 5 or char_length(b) > 1000 then raise exception 'length'; end if;
  if exists (select 1 from public.bug_reports where visitor = p_visitor and created_at > now() - interval '30 seconds') then raise exception 'rate_limited'; end if;
  if (select count(*) from public.bug_reports where visitor = p_visitor and created_at > now() - interval '1 day') >= 15 then raise exception 'rate_limited'; end if;
  insert into public.bug_reports (user_id, visitor, body, ctx) values (auth.uid(), left(p_visitor,64), b, case when octet_length(coalesce(p_ctx::text,'')) <= 2000 then p_ctx end) returning id into nid;
  return nid;
end $$;
create or replace function public.admin_set_bug(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.bug_reports set status = p_status where id = p_id;
end $$;
revoke execute on function public.report_bug(text,text,jsonb), public.admin_set_bug(bigint,text) from public;
grant execute on function public.report_bug(text,text,jsonb) to anon, authenticated;
grant execute on function public.admin_set_bug(bigint,text) to authenticated;
