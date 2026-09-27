import { createClient } from "@/lib/supabase/client";
import {
  SOURCE_LANGUAGE,
  type AppSettings,
  type ArticleDraft,
  type Role,
} from "@/lib/types";

// SPA writes module (stage 4): typed client for the editorial mutations that
// were Next server actions (src/app/admin/actions.ts). Each call POSTs to the
// thin Express backend (stage 5) under `${BASE_PATH}/api/admin/<name>` with the
// user's Supabase access token, so the backend performs the write under the
// user's RLS *and* records the audit_log entry server-side (service role) —
// preserving audit integrity, which a direct client→Supabase write can't.

export type SaveResult = { ok: true } | { ok: false; error: string };
export type RoleResult = SaveResult;

export type SaveInput = {
  id: string;
  title: string;
  slug: string;
  folder: string;
  content: string;
  tags: string[];
  access_roles: string[];
  context_keys: string[];
};

export type SaveTranslationInput = {
  articleId: string;
  language: string;
  title: string;
  content: string;
};

export type TemplateInput = {
  id?: string;
  name: string;
  description: string;
  content: string;
  folder: string;
  tags: string[];
};

// import.meta.env.BASE_URL is the vite `base` (default "/"; e.g. "/kb/").
const API_BASE = `${import.meta.env.BASE_URL.replace(/\/$/, "")}/api/admin`;

async function authHeaders(): Promise<Record<string, string>> {
  const { data } = await createClient().auth.getSession();
  const token = data.session?.access_token;
  return {
    "content-type": "application/json",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
}

async function post(name: string, body: unknown): Promise<Response> {
  return fetch(`${API_BASE}/${name}`, {
    method: "POST",
    headers: await authHeaders(),
    body: JSON.stringify(body ?? {}),
  });
}

/** Call returning a SaveResult/RoleResult — never throws (mirrors the actions). */
async function callResult(name: string, body: unknown): Promise<SaveResult> {
  try {
    const res = await post(name, body);
    if (res.ok) return (await res.json()) as SaveResult;
    const msg = await res
      .json()
      .then((j: { error?: string }) => j?.error)
      .catch(() => null);
    return { ok: false, error: msg ?? `Request failed (${res.status})` };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

/** Call that returns data or throws (mirrors the create actions' redirect path). */
async function callOrThrow<T>(name: string, body: unknown): Promise<T> {
  const res = await post(name, body);
  if (!res.ok) {
    const msg = await res
      .json()
      .then((j: { error?: string }) => j?.error)
      .catch(() => null);
    throw new Error(msg ?? `Request failed (${res.status})`);
  }
  return (await res.json()) as T;
}

// ---- article content + lifecycle ----
// The lifecycle calls take an optional `language`: the source language acts on
// the article (unchanged), any other language acts on that article's row in
// article_translations (independent status per language).
export const saveArticle = (input: SaveInput) => callResult("saveArticle", input);
export const saveTranslation = (input: SaveTranslationInput) =>
  callResult("saveTranslation", input);

// ---- source-language private drafts ----
// Get-or-create the caller's private draft for an article (fork-on-edit).
export async function getDraft(articleId: string): Promise<ArticleDraft> {
  const res = await callOrThrow<{ ok: boolean; draft?: ArticleDraft; error?: string }>(
    "getDraft",
    { id: articleId },
  );
  if (!res.ok || !res.draft) throw new Error(res.error ?? "Could not load draft.");
  return res.draft;
}
// Lifecycle on a specific draft id (source language). Submit/withdraw act on the
// author's own draft; publish/requestChanges are reviewer/admin actions.
export const submitDraft = (draftId: string) =>
  callResult("submitForReview", { draftId });
export const withdrawDraft = (draftId: string) =>
  callResult("withdrawReview", { draftId });
export const publishDraft = (draftId: string) =>
  callResult("approveArticle", { draftId });
export const requestDraftChanges = (draftId: string, note: string) =>
  callResult("requestChanges", { draftId, note });
export const submitForReview = (id: string, language: string = SOURCE_LANGUAGE) =>
  callResult("submitForReview", { id, language });
export const approveArticle = (id: string, language: string = SOURCE_LANGUAGE) =>
  callResult("approveArticle", { id, language });
export const requestChanges = (
  id: string,
  note: string,
  language: string = SOURCE_LANGUAGE,
) => callResult("requestChanges", { id, note, language });
export const unpublishArticle = (id: string, language: string = SOURCE_LANGUAGE) =>
  callResult("unpublishArticle", { id, language });
export const withdrawReview = (id: string, language: string = SOURCE_LANGUAGE) =>
  callResult("withdrawReview", { id, language });

// ---- create (was a server redirect; caller navigates with the returned id) ----
export const createArticle = () => callOrThrow<{ id: string }>("createArticle", {});
export const createArticleFromTemplate = (templateId: string) =>
  callOrThrow<{ id: string }>("createArticleFromTemplate", { templateId });

// ---- trash / revisions ----
export const deleteArticle = (id: string) => callResult("deleteArticle", { id });
export const restoreArticle = (id: string) => callResult("restoreArticle", { id });
export const purgeArticle = (id: string) => callResult("purgeArticle", { id });
export const restoreRevision = (articleId: string, revisionId: string) =>
  callResult("restoreRevision", { articleId, revisionId });
export const restoreTranslationRevision = (revisionId: string) =>
  callResult("restoreTranslationRevision", { revisionId });

// ---- templates ----
export const saveTemplate = (input: TemplateInput) => callResult("saveTemplate", input);
export const deleteTemplate = (id: string) => callResult("deleteTemplate", { id });

// ---- settings ----
export const updateSettings = (settings: AppSettings) =>
  callResult("updateSettings", { settings });

// ---- bulk import / export ----
async function authToken(): Promise<string | undefined> {
  const { data } = await createClient().auth.getSession();
  return data.session?.access_token;
}

/** Download every live article as a zip of frontmatter markdown files. */
export async function exportArticles(): Promise<void> {
  const token = await authToken();
  const res = await fetch(`${API_BASE}/export`, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  if (!res.ok) throw new Error(`Export failed (${res.status})`);
  const blob = await res.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "stillwiki-export.zip";
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export type ImportResult = {
  imported: number;
  total: number;
  errors: { path: string; error: string }[];
};

/** Upload .md files and/or .zip archives; each doc becomes a private draft. */
export async function importArticles(files: File[]): Promise<ImportResult> {
  const token = await authToken();
  const form = new FormData();
  for (const f of files) form.append("files", f);
  const res = await fetch(`${API_BASE}/import`, {
    method: "POST",
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    body: form,
  });
  if (!res.ok) {
    const msg = await res
      .json()
      .then((j: { error?: string }) => j?.error)
      .catch(() => null);
    throw new Error(msg ?? `Import failed (${res.status})`);
  }
  return (await res.json()) as ImportResult;
}

// ---- users ----
export const setUserRole = (userId: string, role: Role) =>
  callResult("setUserRole", { userId, role });
export const setUserAccessRoles = (userId: string, roles: string[]) =>
  callResult("setUserAccessRoles", { userId, roles });
