# Contributing to stillwiki

Thanks for helping out! 🙌

## Dev setup

```bash
npm install
npm run setup          # local Supabase + .env.local + migrate/seed
npm run dev            # SPA
npm run server:dev     # API (separate terminal)
```

(No Supabase CLI? Point `.env.local` at a hosted project and run
`npm run db:migrate && npm run db:seed` instead.)

## Before opening a PR

CI runs lint + typecheck + tests; run them locally first:

```bash
npm run lint
npm run typecheck
npm test
```

## Conventions

- **Conventional Commits** for messages (`feat:`, `fix:`, `chore:`, `docs:`…).
- **Pin exact dependency versions** — no `^`/`~` (`.npmrc` has `save-exact=true`).
- TypeScript everywhere; keep components small and match the surrounding style.
- Row-Level Security is the real authorization boundary — never rely on the UI
  or API alone to gate access; add/adjust RLS in `supabase/` and keep
  `schema.sql` (init) and `migrations.sql` (idempotent) in sync.

## Project layout

- `src/` — Vite/React SPA · `server/` — Express API · `packages/core` — shared
  model · `supabase/` — schema, migrations, seed.

By contributing you agree your work is licensed under the project's MIT license.
