# stillwiki — a self-hostable markdown knowledge base

[![CI](https://github.com/nomadical/stillwiki/actions/workflows/ci.yml/badge.svg)](https://github.com/nomadical/stillwiki/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

An open-source, plug-and-play knowledge base built on **Supabase + Vite/React +
a thin Express API**. Public visitors read published articles; signed-in staff
write them in an Obsidian-style split editor with live preview. Formerly md-kb.

**[Try the demo →](https://nomadical.github.io/stillwiki/)** It runs entirely in
your browser (signed in as an admin, nothing saved past the tab), built from
this repo with `VITE_DEMO=true` — see `src/demo/`.

- **Per-user private drafts** — your edits are private until reviewed & published.
- **Review-gated publishing** — submit → review → publish (configurable).
- **Published-only version history**, trash/restore, audit log.
- **Roles** — admin / editor / reviewer / viewer, plus optional per-article
  access-role tags for gated content.
- **Admin Settings** — branding, languages, publishing policy, feature flags —
  all configurable in-app, no redeploy.
- **Search** — Postgres full-text + fuzzy matching, with matched terms
  highlighted; readers can bookmark articles for a personal "Saved" list.
- **Bulk import/export** — round-trip your content as frontmatter Markdown (zip).
- **SEO** — `robots.txt`, `sitemap.xml`, and server-rendered per-article
  OpenGraph/Twitter tags for link previews.
- **Optional AI ("Ask the KB")** — pgvector RAG against any OpenAI-compatible
  endpoint (off by default).

> This is the community edition. It ships with **no proprietary data, branding,
> or identity provider** — bring your own Supabase project and configure the
> rest from the admin Settings page.

## Quickstart

Prerequisites: **Node 22+**, **Docker**, and the **[Supabase CLI](https://supabase.com/docs/guides/cli)**.

```bash
npm install
npm run setup          # starts local Supabase, wires .env.local, migrates + seeds
npm run dev            # SPA  → http://localhost:5173
npm run server:dev     # API  (separate terminal)
```

Open the app and **sign up** — the first account becomes the **admin**. From
**Admin → Settings** you can set the site name, theme, enabled languages, and
publishing policy.

### Hosted Supabase (instead of local)

Skip `npm run setup`; instead copy `.env.example` to `.env.local`, fill in your
project's URL + keys, then:

```bash
npm run db:migrate     # applies supabase/migrations.sql
npm run db:seed        # optional demo content
```

### Run with Docker

To run the app container (SPA + API in one image) against any Supabase, copy
`.env.example` to `.env`, fill it in, then:

```bash
docker compose up --build   # → http://localhost:8787
```

Bring your own Supabase (Cloud, or a local `supabase start`); apply
`supabase/migrations.sql` to it once. See [docs/DEPLOY.md](docs/DEPLOY.md) for a
hosted end-to-end walkthrough.

## Auth

Email + password and magic-link work out of the box (configure SMTP in Supabase
for magic-link delivery). To add OAuth, enable the provider in your Supabase
dashboard and list it in `VITE_OAUTH_PROVIDERS` (e.g. `github,google`).

## Tech

Vite + React + TypeScript SPA · Express API · Supabase (Postgres + Auth + RLS +
Storage) · Tailwind. Row-Level Security is the real authorization boundary; the
API adds server-side audit logging.

## License

MIT — see [LICENSE](./LICENSE).