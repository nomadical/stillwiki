# ADR 0001 — Build on Supabase (Postgres + PostgREST + GoTrue + RLS)

- Status: Accepted

## Context

stillwiki's defining feature is **role-based article visibility**: some content is
public, some is gated to users holding specific entitlement roles. Getting that
right is a security problem, not just a UI one — the boundary has to hold even
when the application has a bug.

The question was which architecture enforces that safely with the least
hand-rolled code.

What the app relies on:

- **RLS is the security boundary.** Visibility is enforced in the database, so it
  holds regardless of an application bug. The browser can only ever read rows the
  policies allow.
- **PostgREST is an unwritten backend.** The browser issues RLS-filtered queries
  directly (search, view/feedback inserts, user admin), with no bespoke API layer
  to keep in sync with the policies.
- **GoTrue** provides email/password + magic-link auth (and optional OAuth)
  without reimplementing sessions, password reset, or token refresh.

## Decision

**Build on the Supabase stack** (Postgres + PostgREST + GoTrue + Storage), with
RLS in the database as the authorization boundary. The stack is standard open
source, so it runs either on Supabase Cloud or fully self-hosted; the application
code is identical — only the `VITE_*` / service-role env differ.

## Alternatives considered

- **Plain Postgres + a hand-rolled API and auth** — rejected: moves the security
  boundary into application code and requires reimplementing OIDC/sessions and a
  PostgREST-equivalent API. High risk for gated content, and more code to own.
- **A document store / search-only backend** — rejected: role-based row
  visibility is exactly what RLS over a relational store does well.

## Consequences

- The security boundary lives in Postgres RLS — auditable and app-independent.
- Self-hosting is a deployment choice, not a code change: point the env at a
  self-hosted Supabase or Supabase Cloud (see [docs/DEPLOY.md](../DEPLOY.md)).
- Schema and policies are versioned as code (`supabase/schema.sql` +
  `supabase/migrations.sql`).

## Reversal trigger

If RLS proves too restrictive for a future requirement, keep visibility in
Postgres (e.g. a per-request role GUC) rather than moving the boundary into
application code.
