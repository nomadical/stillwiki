-- Idempotent migrations applied to an already-initialised database (the
-- init-time schema.sql only runs on first boot). Safe to re-run.
-- Apply to a local DB with `npm run db:migrate`; CI runs the `db-migrate`
-- workflow against the live DB.

-- ----------------------------------------------------------------------------
-- App-wide page analytics (visits / recurring visitors / dwell time).
--   Anonymous: visitor_id is a random id kept in the browser's localStorage;
--   no PII. Anyone may INSERT (via /api/track); only staff may read.
-- ----------------------------------------------------------------------------
create table if not exists public.page_views (
  id          uuid primary key default gen_random_uuid(),
  path        text not null,
  visitor_id  text,
  session_id  text,
  dwell_ms    int,
  created_at  timestamptz not null default now()
);

create index if not exists page_views_created_idx on public.page_views (created_at desc);
create index if not exists page_views_visitor_idx on public.page_views (visitor_id);

alter table public.page_views enable row level security;

drop policy if exists "anyone inserts" on public.page_views;
create policy "anyone inserts" on public.page_views
  for insert to anon, authenticated with check (true);

drop policy if exists "staff reads" on public.page_views;
create policy "staff reads" on public.page_views
  for select to authenticated
  using (public.current_user_role() in ('admin', 'editor'));

-- ----------------------------------------------------------------------------
-- Allow short video clips in the kb-images bucket (GIFs are already images).
-- ----------------------------------------------------------------------------
update storage.buckets
  set allowed_mime_types = array[
    'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/svg+xml',
    'video/mp4', 'video/webm'
  ]
  where id = 'kb-images';

-- ----------------------------------------------------------------------------
-- Editorial roles + mandatory-review publishing gate + search-click analytics.
-- Mirrors schema.sql; idempotent so it applies cleanly to a running database.
-- ----------------------------------------------------------------------------

-- profiles: add the reviewer tier + role provenance (role_source). Manually
-- assigned roles ('manual') are not overwritten by the Keycloak login re-sync.
alter table public.profiles add column if not exists role_source text not null default 'auto';
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('admin', 'editor', 'reviewer', 'viewer'));
alter table public.profiles drop constraint if exists profiles_role_source_check;
alter table public.profiles add constraint profiles_role_source_check
  check (role_source in ('auto', 'manual'));

-- articles: lifecycle status + review metadata. `published` is derived from
-- `status` by the trigger below; backfill it from the legacy boolean.
alter table public.articles add column if not exists status text not null default 'draft';
alter table public.articles add column if not exists submitted_by uuid;
alter table public.articles add column if not exists submitted_at timestamptz;
alter table public.articles add column if not exists reviewed_by  uuid references public.profiles (id) on delete set null;
alter table public.articles add column if not exists reviewed_at  timestamptz;
alter table public.articles add column if not exists review_note  text;
alter table public.articles drop constraint if exists articles_status_check;
alter table public.articles add constraint articles_status_check
  check (status in ('draft', 'in_review', 'published'));
update public.articles set status = 'published' where published and status = 'draft';
create index if not exists articles_status_idx on public.articles (status);

-- Contextual related-articles: stable host-screen identifiers (e.g.
-- 'intervention.shipment-detail') an article is relevant to. Embeds match by
-- array overlap (kb-react KbRelated / client.relatedArticles). No RLS change —
-- it's another column on articles, covered by the existing read policies.
alter table public.articles add column if not exists context_keys text[] not null default '{}';
create index if not exists articles_context_gin_idx on public.articles using gin (context_keys);

-- Publishing gate: status is the source of truth; `published` is derived here
-- so they never diverge, and only admin/reviewer may move an article into
-- 'published' (editors are rejected at the DB layer). NULL role (service role /
-- superuser, e.g. this migration) bypasses, matching seed/admin-client writes.
create or replace function public.enforce_publish_gate()
returns trigger language plpgsql security definer set search_path = public as $$
declare becoming_published boolean;
begin
  becoming_published := new.status = 'published'
    and (tg_op = 'INSERT' or old.status is distinct from 'published');
  if becoming_published and public.current_user_role() not in ('admin', 'reviewer') then
    raise exception 'Only a reviewer or admin can publish an article'
      using errcode = 'check_violation';
  end if;
  if becoming_published then
    new.reviewed_by := auth.uid();
    new.reviewed_at := now();
  end if;
  new.published := new.status = 'published';
  return new;
end;
$$;

drop trigger if exists articles_enforce_publish_gate on public.articles;
create trigger articles_enforce_publish_gate
  before insert or update on public.articles
  for each row execute function public.enforce_publish_gate();

-- RLS: reviewers join editorial staff (read drafts; may write status/notes).
drop policy if exists "staff read all" on public.articles;
create policy "staff read all"
  on public.articles for select to authenticated
  using (public.current_user_role() in ('admin', 'editor', 'reviewer'));

drop policy if exists "editors update" on public.articles;
create policy "editors update"
  on public.articles for update to authenticated
  using (public.current_user_role() in ('admin', 'editor', 'reviewer'))
  with check (public.current_user_role() in ('admin', 'editor', 'reviewer'));

drop policy if exists "staff read chunks" on public.article_chunks;
create policy "staff read chunks"
  on public.article_chunks for select to authenticated
  using (public.current_user_role() in ('admin', 'editor', 'reviewer'));

-- Search result click-throughs (feeds the "most opened from search" panel).
create table if not exists public.search_result_clicks (
  id          uuid primary key default gen_random_uuid(),
  query       text,
  article_id  uuid references public.articles (id) on delete cascade,
  created_at  timestamptz not null default now()
);
create index if not exists search_clicks_article_idx on public.search_result_clicks (article_id);
create index if not exists search_clicks_created_idx on public.search_result_clicks (created_at desc);
alter table public.search_result_clicks enable row level security;
drop policy if exists "anyone inserts" on public.search_result_clicks;
create policy "anyone inserts" on public.search_result_clicks
  for insert to anon, authenticated with check (true);
drop policy if exists "staff reads" on public.search_result_clicks;
create policy "staff reads" on public.search_result_clicks
  for select to authenticated using (public.current_user_role() in ('admin', 'editor'));

-- ----------------------------------------------------------------------------
-- Version history + trash bin (soft delete) + audit trail.
-- Mirrors schema.sql; idempotent so it applies cleanly to a running database.
-- ----------------------------------------------------------------------------

-- Trash: soft-delete columns + slug uniqueness scoped to live rows only.
alter table public.articles add column if not exists deleted_at timestamptz;
alter table public.articles add column if not exists deleted_by uuid references public.profiles (id) on delete set null;
alter table public.articles drop constraint if exists articles_slug_key;
create unique index if not exists articles_slug_active_idx
  on public.articles (slug) where deleted_at is null;
create index if not exists articles_deleted_idx on public.articles (deleted_at);

-- Trash never shows on public surfaces: add `deleted_at is null` to the
-- public/entitled read policies (staff still read every row; the app filters).
drop policy if exists "read public articles" on public.articles;
create policy "read public articles"
  on public.articles for select
  using (deleted_at is null and published and public.article_is_public(access_roles));
drop policy if exists "read entitled articles" on public.articles;
create policy "read entitled articles"
  on public.articles for select to authenticated
  using (deleted_at is null and published and access_roles && public.current_user_access_roles());

-- Version history: immutable snapshots, written only by the trigger; staff read.
create table if not exists public.article_revisions (
  id           uuid primary key default gen_random_uuid(),
  article_id   uuid not null references public.articles (id) on delete cascade,
  revision     int not null,
  title        text,
  slug         text,
  folder       text,
  content      text,
  tags         text[] not null default '{}',
  access_roles text[] not null default '{}',
  status       text,
  edited_by    uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (article_id, revision)
);
create index if not exists article_revisions_article_idx
  on public.article_revisions (article_id, created_at desc);

create or replace function public.snapshot_article_revision()
returns trigger language plpgsql security definer set search_path = public as $$
declare next_rev int;
begin
  if tg_op = 'UPDATE' and not (
       new.title is distinct from old.title or
       new.content is distinct from old.content or
       new.folder is distinct from old.folder or
       new.tags is distinct from old.tags or
       new.access_roles is distinct from old.access_roles or
       new.status is distinct from old.status
     ) then
    return null;
  end if;
  select coalesce(max(revision), 0) + 1 into next_rev
    from public.article_revisions where article_id = new.id;
  insert into public.article_revisions
    (article_id, revision, title, slug, folder, content, tags, access_roles, status, edited_by)
  values
    (new.id, next_rev, new.title, new.slug, new.folder, new.content, new.tags,
     new.access_roles, new.status, auth.uid());
  return null;
end;
$$;
drop trigger if exists articles_snapshot_revision on public.articles;
create trigger articles_snapshot_revision
  after insert or update on public.articles
  for each row execute function public.snapshot_article_revision();

alter table public.article_revisions enable row level security;
drop policy if exists "staff read revisions" on public.article_revisions;
create policy "staff read revisions"
  on public.article_revisions for select to authenticated
  using (public.current_user_role() in ('admin', 'editor', 'reviewer'));

-- Audit trail: append-only; written via service role; admins read.
create table if not exists public.audit_log (
  id          uuid primary key default gen_random_uuid(),
  actor_id    uuid references public.profiles (id) on delete set null,
  actor_email text,
  action      text not null,
  target_type text not null,
  target_id   uuid,
  summary     text,
  metadata    jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists audit_log_created_idx on public.audit_log (created_at desc);
create index if not exists audit_log_target_idx  on public.audit_log (target_type, target_id);
alter table public.audit_log enable row level security;
drop policy if exists "admin reads audit" on public.audit_log;
create policy "admin reads audit"
  on public.audit_log for select to authenticated
  using (public.current_user_role() = 'admin');

-- ----------------------------------------------------------------------------
-- Article templates (editable starting points). Mirrors schema.sql; idempotent.
-- ----------------------------------------------------------------------------
create table if not exists public.article_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  description text,
  content     text not null default '',
  folder      text not null default '',
  tags        text[] not null default '{}',
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
drop trigger if exists article_templates_touch_updated_at on public.article_templates;
create trigger article_templates_touch_updated_at
  before update on public.article_templates
  for each row execute function public.touch_updated_at();
alter table public.article_templates enable row level security;
drop policy if exists "staff read templates" on public.article_templates;
create policy "staff read templates" on public.article_templates for select to authenticated
  using (public.current_user_role() in ('admin', 'editor', 'reviewer'));
drop policy if exists "editors write templates" on public.article_templates;
create policy "editors write templates" on public.article_templates for insert to authenticated
  with check (public.current_user_role() in ('admin', 'editor'));
drop policy if exists "editors update templates" on public.article_templates;
create policy "editors update templates" on public.article_templates for update to authenticated
  using (public.current_user_role() in ('admin', 'editor'))
  with check (public.current_user_role() in ('admin', 'editor'));
drop policy if exists "admins delete templates" on public.article_templates;
create policy "admins delete templates" on public.article_templates for delete to authenticated
  using (public.current_user_role() = 'admin');

-- Seed a few default templates (idempotent on name).
insert into public.article_templates (name, description, folder, tags, content) values
  ('How-to', 'Step-by-step guide', 'General', array['how-to'],
   $tpl$# {{title}}

_Last updated {{date}} by {{author}}._

## Overview

Briefly describe what this guide covers and who it's for.

## Steps

1. First step
2. Second step
3. Third step

## Related

- [Related article](/kb/intro)
$tpl$),
  ('FAQ', 'Question & answer list', 'General', array['faq'],
   $tpl$# {{title}}

## Frequently asked questions

### Question one?

Answer.

### Question two?

Answer.
$tpl$),
  ('Troubleshooting', 'Problem / cause / fix', 'General', array['troubleshooting'],
   $tpl$# {{title}}

## Symptom

What the user sees.

## Cause

Why it happens.

## Resolution

1. Do this
2. Then this

> If the issue persists, contact support.
$tpl$),
  ('Release note', 'What changed', 'General', array['release'],
   $tpl$# {{title}}

_Released {{date}}._

## New

- …

## Improved

- …

## Fixed

- …
$tpl$)
on conflict (name) do nothing;

-- ----------------------------------------------------------------------------
-- Entitlement-scoped editing. Mirrors schema.sql; idempotent.
--   manual_access_roles : admin-granted entitlements (survive login sync).
--   effective roles      : access_roles (synced) UNION manual_access_roles.
--   editors may write only public articles or ones whose roles they ALL hold;
--   admins + reviewers unrestricted.
-- ----------------------------------------------------------------------------
alter table public.profiles add column if not exists manual_access_roles text[] not null default '{}';

create or replace function public.current_user_access_roles()
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(access_roles, '{}') || coalesce(manual_access_roles, '{}')
  from public.profiles where id = auth.uid();
$$;

create or replace function public.can_write_article(roles text[])
returns boolean language sql stable security definer set search_path = public as $$
  select case public.current_user_role()
    when 'admin' then true
    when 'reviewer' then true
    when 'editor' then
      public.article_is_public(roles) or (roles <@ public.current_user_access_roles())
    else false
  end;
$$;

drop policy if exists "editors insert" on public.articles;
create policy "editors insert"
  on public.articles for insert to authenticated
  with check (
    public.current_user_role() in ('admin', 'editor')
    and public.can_write_article(access_roles)
  );
drop policy if exists "editors update" on public.articles;
create policy "editors update"
  on public.articles for update to authenticated
  using (public.can_write_article(access_roles))
  with check (public.can_write_article(access_roles));

-- ----------------------------------------------------------------------------
-- Sample article: formatting + media embeds (image/GIF, uploaded video,
-- YouTube). Idempotent on slug. Public (no access roles).
-- ----------------------------------------------------------------------------
insert into public.articles (slug, title, folder, content, access_roles, tags, status)
values (
  'media-and-formatting-demo',
  'Media & Formatting Demo',
  'General',
  $kb$This article shows the formatting and media you can embed in the knowledge base — copy any of it into your own articles.

## Text & structure

**Bold**, *italic*, ~~strikethrough~~, and `inline code`. Link to another article: [Intro](/kb/intro).

> Use blockquotes for tips, warnings, or callouts.

### Lists

- First point
- Second point
  - Nested detail

1. Step one
2. Step two

### Code

```ts
export function greet(name: string): string {
  return `Hello, ${name}!`;
}
```

### Table

| Media type | How to add it |
| --- | --- |
| Image / GIF | Toolbar media button, paste, or drag-drop |
| Video (file) | Same — pick an `.mp4` / `.webm` |
| Video (YouTube) | Paste an `<iframe>` embed |

## Images & GIFs

Images and animated GIFs use standard markdown:

![Animated demo](/kb-images/sample/demo.gif)

## Uploaded video

Short clips upload to storage and play inline:

<video src="/kb-images/sample/demo.mp4" controls width="640" style="max-width:100%"></video>

## Embedded video (YouTube)

For longer videos, embed instead of uploading:

<iframe width="640" height="360" src="https://www.youtube.com/embed/aqz-KE-bpKQ" title="Sample video" allowfullscreen style="max-width:100%;aspect-ratio:16/9;border:0"></iframe>
$kb$,
  '{}', array['demo'], 'published'
)
on conflict (slug) where deleted_at is null do update set
  title = excluded.title, folder = excluded.folder,
  content = excluded.content, tags = excluded.tags, status = 'published';

-- ----------------------------------------------------------------------------
-- Lexical search + retrieval (no embeddings model required). pg_trgm gives the
-- ⌘K palette typo tolerance; FTS powers Ask-the-KB retrieval when no embedding
-- model is configured. Invoker-rights functions, so RLS applies.
-- ----------------------------------------------------------------------------
create extension if not exists pg_trgm;
create index if not exists articles_title_trgm_idx on public.articles using gin (title gin_trgm_ops);

create or replace function public.search_articles(query_text text, match_count int default 8)
returns table (
  id uuid, slug text, title text, folder text, tags text[],
  access_roles text[], published boolean, updated_at timestamptz
)
language sql stable as $$
  select a.id, a.slug, a.title, a.folder, a.tags, a.access_roles, a.published, a.updated_at
  from public.articles a
  where a.published and a.deleted_at is null
    and (
      a.search_tsv @@ websearch_to_tsquery('english', query_text)
      or a.title % query_text
    )
  order by
    ts_rank(a.search_tsv, websearch_to_tsquery('english', query_text)) desc,
    similarity(a.title, query_text) desc
  limit match_count;
$$;

create or replace function public.match_articles_fts(query_text text, match_count int default 6)
returns table (article_id uuid, slug text, title text, content text, similarity real)
language sql stable as $$
  select a.id, a.slug, a.title, a.content,
         ts_rank(a.search_tsv, websearch_to_tsquery('english', query_text)) as similarity
  from public.articles a
  where a.published and a.deleted_at is null
    and a.search_tsv @@ websearch_to_tsquery('english', query_text)
  order by similarity desc
  limit match_count;
$$;

-- ============================================================================
-- Article translations (WordPress-style language versions).
--   The `articles` row holds the SOURCE-language content (English). Each
--   additional language is one row here, carrying only the translatable fields
--   (title + content) plus its OWN editorial lifecycle and revision history —
--   so German can be published while French is still a draft. Article-level
--   metadata (slug, folder, tags, access_roles, context_keys) is NOT duplicated;
--   it stays on the parent article and governs a translation's visibility too.
--   Keep `language` values in sync with LANGUAGE_CODES in @stillwiki/core.
-- ============================================================================
create table if not exists public.article_translations (
  id           uuid primary key default gen_random_uuid(),
  article_id   uuid not null references public.articles (id) on delete cascade,
  language     text not null,
  title        text not null default 'Untitled',
  content      text not null default '',
  -- Independent lifecycle, mirroring articles. `published` is derived from
  -- `status` by enforce_translation_publish_gate and is the read-gate for RLS.
  status       text not null default 'draft'
               check (status in ('draft', 'in_review', 'published')),
  published    boolean not null default false,
  submitted_by uuid,
  submitted_at timestamptz,
  reviewed_by  uuid references public.profiles (id) on delete set null,
  reviewed_at  timestamptz,
  review_note  text,
  search_tsv   tsvector,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- One row per (article, language); the source language never appears here.
  unique (article_id, language)
);

-- Translation language codes are free-form (governed by the enabledLanguages
-- setting + kb-core's LANGUAGES); no DB-level allowlist in the OSS edition.
alter table public.article_translations drop constraint if exists article_translations_language_check;

create index if not exists article_translations_article_idx on public.article_translations (article_id);
create index if not exists article_translations_lang_idx     on public.article_translations (language);
create index if not exists article_translations_status_idx    on public.article_translations (status);
create index if not exists article_translations_published_idx  on public.article_translations (published);
create index if not exists article_translations_search_idx on public.article_translations using gin (search_tsv);

-- updated_at touch (reuses the shared touch_updated_at()).
drop trigger if exists article_translations_touch_updated_at on public.article_translations;
create trigger article_translations_touch_updated_at
  before update on public.article_translations
  for each row execute function public.touch_updated_at();

-- Weighted FTS vector (title^A, content^B). Mirrors articles_search_tsv().
create or replace function public.article_translations_search_tsv()
returns trigger language plpgsql as $$
begin
  new.search_tsv :=
    setweight(to_tsvector('simple', coalesce(new.title, '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(new.content, '')), 'B');
  return new;
end;
$$;

drop trigger if exists article_translations_search_tsv_trg on public.article_translations;
create trigger article_translations_search_tsv_trg
  before insert or update of title, content on public.article_translations
  for each row execute function public.article_translations_search_tsv();

-- Publishing gate, mirroring articles.enforce_publish_gate: only admins/reviewers
-- may move a translation INTO 'published'; approving stamps the reviewer; the
-- `published` boolean is kept in lockstep with `status`.
create or replace function public.enforce_translation_publish_gate()
returns trigger language plpgsql security definer set search_path = public as $$
declare becoming_published boolean;
begin
  becoming_published := new.status = 'published'
    and (tg_op = 'INSERT' or old.status is distinct from 'published');

  if becoming_published and public.current_user_role() not in ('admin', 'reviewer') then
    raise exception 'Only a reviewer or admin can publish a translation'
      using errcode = 'check_violation';
  end if;

  if becoming_published then
    new.reviewed_by := auth.uid();
    new.reviewed_at := now();
  end if;

  new.published := new.status = 'published';
  return new;
end;
$$;

drop trigger if exists article_translations_enforce_publish_gate on public.article_translations;
create trigger article_translations_enforce_publish_gate
  before insert or update on public.article_translations
  for each row execute function public.enforce_translation_publish_gate();

-- ----------------------------------------------------------------------------
-- RLS — visibility/writability are governed by the PARENT article (its
-- access_roles + published + deleted state), so translations can never leak
-- content the reader couldn't see on the source article.
-- ----------------------------------------------------------------------------
alter table public.article_translations enable row level security;

drop policy if exists "read public translations" on public.article_translations;
create policy "read public translations"
  on public.article_translations for select
  using (
    published and exists (
      select 1 from public.articles a
      where a.id = article_id and a.deleted_at is null and a.published
        and public.article_is_public(a.access_roles)
    )
  );

drop policy if exists "read entitled translations" on public.article_translations;
create policy "read entitled translations"
  on public.article_translations for select to authenticated
  using (
    published and exists (
      select 1 from public.articles a
      where a.id = article_id and a.deleted_at is null and a.published
        and a.access_roles && public.current_user_access_roles()
    )
  );

drop policy if exists "staff read translations" on public.article_translations;
create policy "staff read translations"
  on public.article_translations for select to authenticated
  using (public.current_user_role() in ('admin', 'editor', 'reviewer'));

drop policy if exists "editors insert translations" on public.article_translations;
create policy "editors insert translations"
  on public.article_translations for insert to authenticated
  with check (
    public.current_user_role() in ('admin', 'editor')
    and exists (
      select 1 from public.articles a
      where a.id = article_id and public.can_write_article(a.access_roles)
    )
  );

drop policy if exists "editors update translations" on public.article_translations;
create policy "editors update translations"
  on public.article_translations for update to authenticated
  using (
    exists (
      select 1 from public.articles a
      where a.id = article_id and public.can_write_article(a.access_roles)
    )
  )
  with check (
    exists (
      select 1 from public.articles a
      where a.id = article_id and public.can_write_article(a.access_roles)
    )
  );

drop policy if exists "admins delete translations" on public.article_translations;
create policy "admins delete translations"
  on public.article_translations for delete to authenticated
  using (public.current_user_role() = 'admin');

-- ----------------------------------------------------------------------------
-- Per-language version history (mirrors article_revisions). One immutable
-- snapshot per content/status change, written only by the trigger. Staff read.
-- ----------------------------------------------------------------------------
create table if not exists public.article_translation_revisions (
  id             uuid primary key default gen_random_uuid(),
  translation_id uuid not null references public.article_translations (id) on delete cascade,
  article_id     uuid not null references public.articles (id) on delete cascade,
  language       text not null,
  revision       int not null,
  title          text,
  content        text,
  status         text,
  edited_by      uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  unique (translation_id, revision)
);
create index if not exists article_translation_revisions_idx
  on public.article_translation_revisions (translation_id, created_at desc);

create or replace function public.snapshot_article_translation_revision()
returns trigger language plpgsql security definer set search_path = public as $$
declare next_rev int;
begin
  if tg_op = 'UPDATE' and not (
       new.title is distinct from old.title or
       new.content is distinct from old.content or
       new.status is distinct from old.status
     ) then
    return null; -- nothing material changed; skip
  end if;

  select coalesce(max(revision), 0) + 1 into next_rev
    from public.article_translation_revisions where translation_id = new.id;

  insert into public.article_translation_revisions
    (translation_id, article_id, language, revision, title, content, status, edited_by)
  values
    (new.id, new.article_id, new.language, next_rev, new.title, new.content,
     new.status, auth.uid());
  return null; -- AFTER trigger
end;
$$;

drop trigger if exists article_translations_snapshot_revision on public.article_translations;
create trigger article_translations_snapshot_revision
  after insert or update on public.article_translations
  for each row execute function public.snapshot_article_translation_revision();

alter table public.article_translation_revisions enable row level security;
drop policy if exists "staff read translation revisions" on public.article_translation_revisions;
create policy "staff read translation revisions"
  on public.article_translation_revisions for select to authenticated
  using (public.current_user_role() in ('admin', 'editor', 'reviewer'));

-- ============================================================================
-- Translation-aware search + RAG.
--   FTS (search_articles, match_articles_fts) and pgvector retrieval
--   (match_article_chunks) gain a `lang` argument. lang='en' (the source) keeps
--   the exact previous behaviour; any other language also searches that
--   language's published translations and prefers them per article, falling
--   back to the English source. RLS still applies (invoker-rights functions).
-- ============================================================================

-- article_chunks: a language tag, so a single article can hold chunks per
-- language. The uniqueness key widens to include it.
alter table public.article_chunks add column if not exists language text not null default 'en';
alter table public.article_chunks drop constraint if exists article_chunks_article_id_chunk_index_key;
drop index if exists public.article_chunks_aid_lang_idx;
create unique index article_chunks_aid_lang_idx
  on public.article_chunks (article_id, language, chunk_index);
create index if not exists article_chunks_language_idx on public.article_chunks (language);

-- ⌘K typo-tolerant search. lang<>'en' also searches that language's published
-- translations (parent must be published + visible); the translated title is
-- shown, and the higher-ranked title per article wins.
drop function if exists public.search_articles(text, int);
create or replace function public.search_articles(
  query_text text, match_count int default 8, lang text default 'en'
)
returns table (
  id uuid, slug text, title text, folder text, tags text[],
  access_roles text[], published boolean, updated_at timestamptz
)
language sql stable as $$
  with src as (
    select a.id, a.slug, a.title, a.folder, a.tags, a.access_roles,
           a.published, a.updated_at,
           greatest(
             ts_rank(a.search_tsv, websearch_to_tsquery('english', query_text)),
             similarity(a.title, query_text)
           ) as rank
    from public.articles a
    where a.published and a.deleted_at is null
      and (a.search_tsv @@ websearch_to_tsquery('english', query_text)
           or a.title % query_text)
  ),
  tr as (
    select a.id, a.slug, t.title, a.folder, a.tags, a.access_roles,
           a.published, a.updated_at,
           greatest(
             ts_rank(t.search_tsv, websearch_to_tsquery('simple', query_text)),
             similarity(t.title, query_text)
           ) as rank
    from public.article_translations t
    join public.articles a on a.id = t.article_id
    where lang <> 'en' and t.language = lang and t.published
      and a.published and a.deleted_at is null
      and (t.search_tsv @@ websearch_to_tsquery('simple', query_text)
           or t.title % query_text)
  ),
  unioned as (select * from src union all select * from tr),
  ranked as (
    select distinct on (id)
           id, slug, title, folder, tags, access_roles, published, updated_at, rank
    from unioned
    order by id, rank desc
  )
  select id, slug, title, folder, tags, access_roles, published, updated_at
  from ranked
  order by rank desc
  limit match_count;
$$;

-- Ask-the-KB FTS retrieval (no embeddings model). Same language behaviour;
-- returns the translated body for grounding when a translation matched.
drop function if exists public.match_articles_fts(text, int);
create or replace function public.match_articles_fts(
  query_text text, match_count int default 6, lang text default 'en'
)
returns table (article_id uuid, slug text, title text, content text, similarity real)
language sql stable as $$
  with src as (
    select a.id as article_id, a.slug, a.title, a.content,
           ts_rank(a.search_tsv, websearch_to_tsquery('english', query_text)) as similarity
    from public.articles a
    where a.published and a.deleted_at is null
      and a.search_tsv @@ websearch_to_tsquery('english', query_text)
  ),
  tr as (
    select a.id as article_id, a.slug, t.title, t.content,
           ts_rank(t.search_tsv, websearch_to_tsquery('simple', query_text)) as similarity
    from public.article_translations t
    join public.articles a on a.id = t.article_id
    where lang <> 'en' and t.language = lang and t.published
      and a.published and a.deleted_at is null
      and t.search_tsv @@ websearch_to_tsquery('simple', query_text)
  ),
  unioned as (select * from src union all select * from tr),
  ranked as (
    select distinct on (article_id) article_id, slug, title, content, similarity
    from unioned
    order by article_id, similarity desc
  )
  select article_id, slug, title, content, similarity
  from ranked
  order by similarity desc
  limit match_count;
$$;

-- Cosine-similarity retrieval over chunks. lang selects which language's chunks
-- to prefer; an article with no chunk in `lang` falls back to its English
-- chunks. The source title is localized when a published translation exists.
drop function if exists public.match_article_chunks(vector, int);
create or replace function public.match_article_chunks(
  query_embedding vector(768), match_count int default 6, lang text default 'en'
)
returns table (article_id uuid, slug text, title text, content text, similarity float)
language sql stable as $$
  select a.id, a.slug,
         coalesce(tr.title, a.title) as title,
         c.content,
         1 - (c.embedding <=> query_embedding) as similarity
  from public.article_chunks c
  join public.articles a on a.id = c.article_id
  left join public.article_translations tr
    on tr.article_id = a.id and tr.language = lang and tr.published
  where c.embedding is not null
    and (
      c.language = lang
      or (c.language = 'en' and not exists (
            select 1 from public.article_chunks c2
            where c2.article_id = c.article_id and c2.language = lang
         ))
    )
  order by c.embedding <=> query_embedding
  limit match_count;
$$;


-- ============================================================================
-- Per-user private drafts + publish-gated content (added 2026-06-30)
-- ============================================================================
-- ============================================================================
-- Per-user private drafts + publish-gated content.
--   * Editors edit their OWN private draft (article_drafts). The articles row
--     holds only the PUBLISHED canonical content and changes only on publish.
--   * A draft is visible to its author; reviewers/admins see in_review drafts.
--   * Brand-new (never-published) articles are private to their author.
--   * article_revisions snapshots PUBLISHED versions only.
-- Idempotent: safe to re-run.
-- ============================================================================

-- ---- table -----------------------------------------------------------------
create table if not exists public.article_drafts (
  id            uuid primary key default gen_random_uuid(),
  article_id    uuid not null references public.articles (id) on delete cascade,
  author_id     uuid not null references public.profiles (id) on delete cascade,
  language      text not null default 'en',
  title         text not null default 'Untitled',
  slug          text not null default '',
  folder        text not null default '',
  content       text not null default '',
  tags          text[] not null default '{}',
  access_roles  text[] not null default '{}',
  context_keys  text[] not null default '{}',
  status        text not null default 'draft' check (status in ('draft', 'in_review')),
  review_note   text,
  base_revision int,
  submitted_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (article_id, author_id, language)
);

create index if not exists article_drafts_author_idx on public.article_drafts (author_id);
create index if not exists article_drafts_review_idx
  on public.article_drafts (status) where status = 'in_review';

create or replace function public.touch_article_draft()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;
drop trigger if exists article_drafts_touch on public.article_drafts;
create trigger article_drafts_touch before update on public.article_drafts
  for each row execute function public.touch_article_draft();

-- ---- RLS: drafts are private to their author; reviewers see in_review -------
alter table public.article_drafts enable row level security;

drop policy if exists "authors manage own drafts" on public.article_drafts;
create policy "authors manage own drafts" on public.article_drafts
  for all to authenticated
  using (author_id = auth.uid())
  with check (
    author_id = auth.uid()
    and public.current_user_role() in ('admin', 'editor', 'reviewer')
  );

drop policy if exists "reviewers read in-review drafts" on public.article_drafts;
create policy "reviewers read in-review drafts" on public.article_drafts
  for select to authenticated
  using (status = 'in_review' and public.current_user_role() in ('admin', 'reviewer'));

-- ---- articles SELECT: published-for-all-staff + own-draft + in_review ------
-- Replaces the old "staff read all" so private drafts (incl. never-published
-- new articles) are not visible to other staff.
drop policy if exists "staff read all" on public.articles;

drop policy if exists "staff read published" on public.articles;
create policy "staff read published" on public.articles
  for select to authenticated
  using (
    deleted_at is null and published
    and public.current_user_role() in ('admin', 'editor', 'reviewer')
  );

drop policy if exists "authors read draft articles" on public.articles;
create policy "authors read draft articles" on public.articles
  for select to authenticated
  using (
    exists (
      select 1 from public.article_drafts d
      where d.article_id = articles.id and d.author_id = auth.uid()
    )
  );

drop policy if exists "reviewers read in-review articles" on public.articles;
create policy "reviewers read in-review articles" on public.articles
  for select to authenticated
  using (
    public.current_user_role() in ('admin', 'reviewer')
    and exists (
      select 1 from public.article_drafts d
      where d.article_id = articles.id and d.status = 'in_review'
    )
  );

drop policy if exists "admins read trashed" on public.articles;
create policy "admins read trashed" on public.articles
  for select to authenticated
  using (deleted_at is not null and public.current_user_role() = 'admin');

-- ---- articles UPDATE: only admins/reviewers (publish / unpublish / trash).
-- Editors never mutate the published row directly — they edit their draft.
drop policy if exists "editors update" on public.articles;
drop policy if exists "staff update articles" on public.articles;
create policy "staff update articles" on public.articles
  for update to authenticated
  using (public.current_user_role() in ('admin', 'reviewer'))
  with check (public.current_user_role() in ('admin', 'reviewer'));

-- ---- version history = PUBLISHED versions only -----------------------------
create or replace function public.snapshot_article_revision()
returns trigger language plpgsql security definer set search_path = public as $$
declare next_rev int;
begin
  -- Only snapshot published states. Since the articles row now changes solely
  -- at publish time, this yields a published-version history (not every save).
  if new.status <> 'published' then
    return null;
  end if;
  if tg_op = 'UPDATE' and old.status = 'published' and not (
       new.title is distinct from old.title or
       new.content is distinct from old.content or
       new.folder is distinct from old.folder or
       new.tags is distinct from old.tags or
       new.access_roles is distinct from old.access_roles
     ) then
    return null; -- republished with no material change
  end if;

  select coalesce(max(revision), 0) + 1 into next_rev
    from public.article_revisions where article_id = new.id;
  insert into public.article_revisions
    (article_id, revision, title, slug, folder, content, tags, access_roles, status, edited_by)
  values
    (new.id, next_rev, new.title, new.slug, new.folder, new.content, new.tags,
     new.access_roles, new.status, auth.uid());
  return null;
end;
$$;

-- ---- fork_draft(): get-or-create the caller's private draft from the live ---
-- published article (so "edit" always works on a private working copy).
create or replace function public.fork_draft(p_article_id uuid)
returns public.article_drafts language plpgsql security definer set search_path = public as $$
declare d public.article_drafts; a public.articles; uid uuid := auth.uid(); rev int;
begin
  if public.current_user_role() not in ('admin', 'editor', 'reviewer') then
    raise exception 'Not allowed' using errcode = 'check_violation';
  end if;
  select * into d from public.article_drafts
    where article_id = p_article_id and author_id = uid and language = 'en';
  if found then return d; end if;

  select * into a from public.articles where id = p_article_id;
  if not found then raise exception 'Article not found' using errcode = 'no_data_found'; end if;
  select coalesce(max(revision), 0) into rev from public.article_revisions where article_id = p_article_id;

  insert into public.article_drafts
    (article_id, author_id, language, title, slug, folder, content, tags, access_roles, context_keys, base_revision)
  values
    (a.id, uid, 'en', a.title, a.slug, a.folder, a.content, a.tags, a.access_roles, a.context_keys, rev)
  returning * into d;
  return d;
end;
$$;

-- ---- publish_draft(): copy a draft onto the live article + snapshot + clear -
create or replace function public.publish_draft(p_draft_id uuid)
returns public.articles language plpgsql security definer set search_path = public as $$
declare d public.article_drafts; a public.articles;
begin
  if public.current_user_role() not in ('admin', 'reviewer') then
    raise exception 'Only a reviewer or admin can publish' using errcode = 'check_violation';
  end if;
  select * into d from public.article_drafts where id = p_draft_id;
  if not found then raise exception 'Draft not found' using errcode = 'no_data_found'; end if;

  -- Copy the draft onto the published row. enforce_publish_gate() stamps
  -- reviewed_by/at + published; snapshot_article_revision() records the version.
  update public.articles set
    title = d.title, slug = d.slug, folder = d.folder, content = d.content,
    tags = d.tags, access_roles = d.access_roles, context_keys = d.context_keys,
    status = 'published', review_note = null, updated_at = now()
  where id = d.article_id
  returning * into a;

  delete from public.article_drafts where id = d.id;
  return a;
end;
$$;

-- ---- create_article(): new article + the author's private draft, atomically.
-- Done as a definer RPC because a fresh private article is not SELECT-visible
-- to its author until its draft exists, so a plain INSERT ... RETURNING fails.
create or replace function public.create_article()
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); new_id uuid; stamp text;
begin
  if public.current_user_role() not in ('admin', 'editor') then
    raise exception 'Only an editor or admin can create articles' using errcode = 'check_violation';
  end if;
  -- Timestamp + short random suffix so rapid successive calls (e.g. a bulk
  -- import loop) never collide on the articles_slug_active_idx unique index.
  stamp := to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);
  insert into public.articles (title, slug, content)
    values ('Untitled', 'untitled-' || stamp, '# Untitled' || E'\n\n')
    returning id into new_id;
  insert into public.article_drafts (article_id, author_id, language, title, slug, content)
    values (new_id, uid, 'en', 'Untitled', 'untitled-' || stamp, '# Untitled' || E'\n\n');
  return new_id;
end;
$$;

grant execute on function public.fork_draft(uuid) to authenticated;
grant execute on function public.publish_draft(uuid) to authenticated;
grant execute on function public.create_article() to authenticated;
-- ---- addendum: reviewer request-changes RPC + unpublish-visibility fix ------

-- Staff can also see articles that have EVER been published (have a revision),
-- so unpublishing one doesn't strand it. Brand-new private articles have no
-- revision yet, so they stay private to their author.
drop policy if exists "staff read previously published" on public.articles;
create policy "staff read previously published" on public.articles
  for select to authenticated
  using (
    deleted_at is null
    and public.current_user_role() in ('admin', 'editor', 'reviewer')
    and exists (select 1 from public.article_revisions rv where rv.article_id = articles.id)
  );

-- Reviewer/admin sends a submitted draft back to its author with a note.
-- (RLS lets the author manage their draft and reviewers only read in_review,
--  so the status flip back to 'draft' needs a gated definer RPC.)
create or replace function public.request_changes_draft(p_draft_id uuid, p_note text)
returns public.article_drafts language plpgsql security definer set search_path = public as $$
declare d public.article_drafts;
begin
  if public.current_user_role() not in ('admin', 'reviewer') then
    raise exception 'Only a reviewer or admin can request changes' using errcode = 'check_violation';
  end if;
  update public.article_drafts
    set status = 'draft', review_note = nullif(btrim(p_note), '')
    where id = p_draft_id and status = 'in_review'
    returning * into d;
  if not found then raise exception 'Draft not in review' using errcode = 'no_data_found'; end if;
  return d;
end;
$$;
grant execute on function public.request_changes_draft(uuid, text) to authenticated;
-- App settings (admin-configurable)
-- ============================================================================
-- App-wide admin-configurable settings (single JSONB row). Anyone may read
-- (branding / feature flags drive the public surface); only admins may write.
-- ============================================================================
create table if not exists public.app_settings (
  id         smallint primary key default 1 check (id = 1),
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);
insert into public.app_settings (id, value) values (1, '{}'::jsonb)
  on conflict (id) do nothing;

alter table public.app_settings enable row level security;

drop policy if exists "anyone reads settings" on public.app_settings;
create policy "anyone reads settings" on public.app_settings
  for select using (true);

drop policy if exists "admins write settings" on public.app_settings;
create policy "admins write settings" on public.app_settings
  for all to authenticated
  using (public.current_user_role() = 'admin')
  with check (public.current_user_role() = 'admin');


-- Enforce Publishing & review settings in the publish path
-- ============================================================================
-- Enforce the admin "Publishing & review" settings in the publish path.
--   requireReview        : when false, an editor may publish their OWN draft
--                          directly (no reviewer needed).
--   allowAdminSelfReview : when false, a reviewer/admin may NOT publish their
--                          own draft (another reviewer must).
-- ============================================================================

-- The legacy publish gate now honours requireReview (so a definer publish by an
-- editor isn't blocked when review is disabled).
create or replace function public.enforce_publish_gate()
returns trigger language plpgsql security definer set search_path = public as $$
declare becoming_published boolean; require_review boolean;
begin
  becoming_published := new.status = 'published'
    and (tg_op = 'INSERT' or old.status is distinct from 'published');
  require_review := coalesce(
    (select (value->>'requireReview')::boolean from public.app_settings where id = 1), true);

  if becoming_published and require_review
     and public.current_user_role() not in ('admin', 'reviewer') then
    raise exception 'Only a reviewer or admin can publish an article'
      using errcode = 'check_violation';
  end if;

  if becoming_published then
    new.reviewed_by := auth.uid();
    new.reviewed_at := now();
  end if;
  new.published := new.status = 'published';
  return new;
end;
$$;

-- publish_draft authorizes per the settings, then copies draft -> article.
create or replace function public.publish_draft(p_draft_id uuid)
returns public.articles language plpgsql security definer set search_path = public as $$
declare d public.article_drafts; a public.articles; s jsonb;
        require_review boolean; allow_self boolean;
        uid uuid := auth.uid(); urole text := public.current_user_role();
begin
  select value into s from public.app_settings where id = 1;
  require_review := coalesce((s->>'requireReview')::boolean, true);
  allow_self := coalesce((s->>'allowAdminSelfReview')::boolean, true);

  select * into d from public.article_drafts where id = p_draft_id;
  if not found then raise exception 'Draft not found' using errcode = 'no_data_found'; end if;

  if urole in ('admin', 'reviewer') then
    if not allow_self and d.author_id = uid then
      raise exception 'Self-review is disabled — another reviewer must publish this'
        using errcode = 'check_violation';
    end if;
  elsif urole = 'editor' and not require_review and d.author_id = uid then
    null; -- review not required: an editor may publish their own draft
  else
    raise exception 'Only a reviewer or admin can publish' using errcode = 'check_violation';
  end if;

  update public.articles set
    title = d.title, slug = d.slug, folder = d.folder, content = d.content,
    tags = d.tags, access_roles = d.access_roles, context_keys = d.context_keys,
    status = 'published', review_note = null, updated_at = now()
  where id = d.article_id
  returning * into a;

  delete from public.article_drafts where id = d.id;
  return a;
end;
$$;


-- New users get settings.defaultUserRole (first user still admin)
-- New users get the admin-configured default role (settings.defaultUserRole);
-- the first user is still bootstrapped as admin.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare default_role text;
begin
  default_role := coalesce(
    (select value->>'defaultUserRole' from public.app_settings where id = 1), 'viewer');
  if default_role not in ('admin', 'editor', 'reviewer', 'viewer') then
    default_role := 'viewer';
  end if;
  insert into public.profiles (id, email, role)
  values (
    new.id, new.email,
    case when not exists (select 1 from public.profiles where role = 'admin')
         then 'admin' else default_role end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- Reader-submitted corrections ("suggest an edit / report a mistake"). Anyone
-- may INSERT (the reader picks text and describes a fix); only staff may read
-- and update the triage status. Powers /admin/suggestions.
-- ----------------------------------------------------------------------------
create table if not exists public.article_suggestions (
  id          uuid primary key default gen_random_uuid(),
  article_id  uuid references public.articles (id) on delete cascade,
  excerpt     text,
  suggestion  text not null,
  email       text,
  url         text,
  status      text not null default 'open'
              check (status in ('open', 'resolved', 'dismissed')),
  created_at  timestamptz not null default now()
);

create index if not exists suggestions_article_idx on public.article_suggestions (article_id);
create index if not exists suggestions_status_idx  on public.article_suggestions (status);
create index if not exists suggestions_created_idx on public.article_suggestions (created_at desc);

alter table public.article_suggestions enable row level security;

drop policy if exists "anyone inserts" on public.article_suggestions;
create policy "anyone inserts" on public.article_suggestions
  for insert to anon, authenticated with check (true);

drop policy if exists "staff reads" on public.article_suggestions;
create policy "staff reads" on public.article_suggestions
  for select to authenticated
  using (public.current_user_role() in ('admin', 'editor'));

drop policy if exists "staff updates suggestions" on public.article_suggestions;
create policy "staff updates suggestions" on public.article_suggestions
  for update to authenticated
  using (public.current_user_role() in ('admin', 'editor'))
  with check (public.current_user_role() in ('admin', 'editor'));
