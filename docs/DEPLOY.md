# Deploy stillwiki (Fly.io + Supabase Cloud)

The app is one Docker image (the Express server serves the built SPA **and** the
`/api/*` endpoints). State lives in a Supabase project. This guide deploys a
public **demo** to Fly.io with a curated admin + sign-ups disabled.

## 1. Supabase project

1. Create a project at <https://supabase.com/dashboard>.
2. **Project Settings → API**: copy the **Project URL**, the **anon/publishable
   key** (public), and the **service-role/secret key** (server-only).
3. Apply the schema. Easiest from your machine, pointed at the project DB:
   ```bash
   DATABASE_URL="postgresql://postgres:[PASSWORD]@db.[REF].supabase.co:5432/postgres" npm run db:migrate
   DATABASE_URL="...same..." npm run db:seed     # optional demo content
   ```
   (DB connection string: Project Settings → Database.)

## 2. Deploy to Fly

```bash
fly auth login
fly launch --no-deploy            # edit app name/region in fly.toml, or accept

# build-time (baked into the SPA; the anon key is public)
fly deploy \
  --build-arg VITE_SUPABASE_URL=https://[REF].supabase.co \
  --build-arg VITE_SUPABASE_ANON_KEY=[ANON_KEY] \
  --build-arg VITE_SITE_URL=https://[APP].fly.dev \
  --build-arg VITE_ALLOW_SIGNUP=true       # keep true for the first sign-up

# runtime secret (server only)
fly secrets set SUPABASE_SERVICE_ROLE_KEY=[SERVICE_ROLE_KEY]
```

In Supabase **Authentication → URL Configuration**, add `https://[APP].fly.dev`
to the **Site URL** + **Redirect URLs** (so magic-link/OAuth return correctly).

## 3. Demo mode (curated admin, no public sign-up)

1. Open `https://[APP].fly.dev`, **sign up once** — the first account becomes the
   **admin**. Use the credentials you want to share.
2. Lock it down in Supabase **Authentication → Providers → Email**: turn **off**
   "Allow new users to sign up". (This is the real boundary.)
3. Optional: hide the sign-up UI by redeploying with
   `--build-arg VITE_ALLOW_SIGNUP=false`.
4. Curate from **Admin → Settings** (site name, theme, languages) and publish a
   few articles.

## Optional: AI ("Ask the KB")

Off by default. To enable, set runtime secrets pointing at any
OpenAI-compatible endpoint and turn it on in Admin → Settings:

```bash
fly secrets set EMBEDDINGS_URL=... EMBEDDINGS_MODEL=... CHAT_URL=... CHAT_MODEL=... OPENAI_API_KEY=...
```

## Other hosts

The same image runs anywhere that takes a Dockerfile (Render, Railway, a VPS).
Pass the `VITE_*` build args at build time and `SUPABASE_SERVICE_ROLE_KEY` at
runtime; expose port `8787`.
