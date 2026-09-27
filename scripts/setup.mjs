#!/usr/bin/env node
// One-command local setup: start Supabase, wire .env.local, migrate + seed.
//   npm run setup   (after `npm install`)
import { execSync } from "node:child_process";
import { existsSync, copyFileSync, readFileSync, writeFileSync } from "node:fs";

const run = (cmd, opts = {}) =>
  execSync(cmd, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...opts });
const has = (bin) => {
  try {
    run(`command -v ${bin}`);
    return true;
  } catch {
    return false;
  }
};
const log = (m) => console.log(m);

log("\n▶  stillwiki setup\n");

// 1. .env.local
if (!existsSync(".env.local")) {
  copyFileSync(".env.example", ".env.local");
  log("•  created .env.local from .env.example");
}

// 2. Supabase CLI + local stack
if (!has("supabase")) {
  log("✗  Supabase CLI not found.");
  log("   Install it → https://supabase.com/docs/guides/cli  then re-run `npm run setup`.");
  log("   (Or point .env.local at a hosted Supabase project and run `npm run db:migrate && npm run db:seed`.)\n");
  process.exit(1);
}

let status = "";
try {
  status = run("supabase status -o env 2>/dev/null");
} catch {
  /* not started yet */
}
if (!/API_URL=/.test(status)) {
  log("•  starting local Supabase (first run pulls Docker images — may take a minute)…");
  run("supabase start", { stdio: "inherit" });
  status = run("supabase status -o env");
}

const env = Object.fromEntries(
  status
    .split("\n")
    .filter((l) => l.includes("="))
    .map((l) => {
      const i = l.indexOf("=");
      return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^"|"$/g, "")];
    }),
);
const { API_URL, ANON_KEY, SERVICE_ROLE_KEY, DB_URL } = env;
if (!API_URL || !ANON_KEY) {
  log("✗  Could not read Supabase status. Run `supabase start` manually, then re-run setup.");
  process.exit(1);
}

// 3. Write the keys into .env.local
function setEnv(key, val) {
  let txt = readFileSync(".env.local", "utf8");
  const re = new RegExp(`^${key}=.*$`, "m");
  txt = re.test(txt) ? txt.replace(re, `${key}=${val}`) : `${txt.replace(/\n*$/, "")}\n${key}=${val}\n`;
  writeFileSync(".env.local", txt);
}
setEnv("VITE_SUPABASE_URL", API_URL);
setEnv("VITE_SUPABASE_ANON_KEY", ANON_KEY);
if (SERVICE_ROLE_KEY) setEnv("SUPABASE_SERVICE_ROLE_KEY", SERVICE_ROLE_KEY);
log("•  wrote Supabase URL + keys to .env.local");

// 4. Migrate + seed
const dbEnv = DB_URL ? { ...process.env, DATABASE_URL: DB_URL } : process.env;
log("•  applying migrations + demo content…");
run("npm run db:migrate", { stdio: "inherit", env: dbEnv });
run("npm run db:seed", { stdio: "inherit", env: dbEnv });

log("\n✓  Setup complete. Start the app:\n");
log("     npm run dev          # SPA  (http://localhost:5173)");
log("     npm run server:dev   # API  (separate terminal)\n");
log("   Then open the app and sign up — the first account becomes the admin.\n");