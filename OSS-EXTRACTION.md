# OSS extraction checklist

Genericizing the SkyCell knowledge base into a plug-and-play open-source app.
Decisions: standalone public repo · email/password + magic-link auth (OAuth
optional).

## Milestone 1 — clean scaffold ✅
- [x] Clean copy (no `.git` history, secrets, `node_modules`, build artifacts).
- [x] Remove SkyCell deploy infra; keep generic lint CI.
- [x] MIT `LICENSE`, generic `README.md`, generic `.env.example`, fresh git.

## Milestone 2 — auth ✅
- [x] Default login = email/password + magic-link via a shared `AuthPanel`
      (used by `/login` and the sign-in modal). OAuth buttons only when
      `VITE_OAUTH_PROVIDERS` is set.
- [x] Deleted `src/lib/keycloak.ts`, `server/routes/authSync.ts` (+ unmounted);
      `AuthCallback` no longer posts a provider token; `signOut` no longer does
      Keycloak RP-logout.
- [x] Editorial role still from `profiles.role`; access-role tags admin-managed.

## Milestone 3 — config / branding / i18n ✅
- [x] `VITE_BASE_PATH` (default `/`) across vite config, server env, config.ts.
- [x] Neutral branding: footer/login/title use the configurable site name;
      dropped SkyCell footer links; neutralized hero/footer/AI-prompt copy.
- [x] Dropped the hardcoded `de` translation-language DB constraint.
- [x] Generic access-role list (`BASIC_ACCESS`, `INTERNAL`, `STAFF`).

## Milestone 4 — content / data ✅
- [x] `npm run db:seed` → `supabase/seed.sql` (generic welcome/cheatsheet demo).
- [x] Removed SkyCell import/seed scripts; neutralized MCP server name.
- [x] No `skycell`/`skymind` strings remain in `src/`, `server/`, `scripts/`
      (verified) — except the package scope below.

**Verified:** typecheck ✅ · lint ✅ · tests 15/15 ✅ · prod build (Vite 8) ✅.
**Plug-and-play:** clone → `.env.local` → `db:migrate` + `db:seed` → run. First
sign-up becomes admin; configure the rest in Admin → Settings.

## Milestone 6 — scope rename ✅
- [x] `@skycell-ag/kb-core` → `@stillwiki/core` (package, imports, build scripts).
- [x] Removed the `kb-react` embed package (unused by the app; pulled a private
      `@skycell-ag/scd-lib`) and its Dockerfile/CI references.

## Deferred (polish, not blockers)
- [x] Purged residual SkyCell/Keycloak config + branding: disabled the
      azure/keycloak external-auth providers and genericized their comments in
      `supabase/config.toml`; deleted `supabase/AUTH-kb-embed.md` and the
      `@SkyCell-AG` `.github/CODEOWNERS`; renamed `KB_BRANDS.skycell` →
      `KB_BRANDS.default` (dropped the validaide palette); dropped the dead
      `VITE_KEYCLOAK_*` env types; neutralized the SSO footnote + theme comments.
- [ ] `docs/` still contains the SkyCell-internal architecture notes, ADRs, and
      ops/parity docs (SkyMind infra, Keycloak, Azure). Decide per-file:
      genericize the design docs worth keeping, drop the internal ops ones.

## Milestone 5 — improvements (per request: OSS hardening + UX + features + code quality)
- Scoped as follow-up PRs once the repo is published.