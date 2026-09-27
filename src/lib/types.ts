// Shared, framework-agnostic article model lives in @stillwiki/core (single
// source of truth, also bundled into @stillwiki/react). The full editorial
// `Article` (status/trash/audit fields) stays here. Import-and-re-export so the
// names are also bound locally (used by canWriteArticle below).
import {
  ARTICLE_LIST_COLUMNS,
  isPublicArticle,
  LANGUAGES,
  LANGUAGE_CODES,
  SOURCE_LANGUAGE,
  isSourceLanguage,
  normalizeLanguage,
  languageLabel,
  type ArticleMeta,
  type Language,
} from "@stillwiki/core";

export {
  ARTICLE_LIST_COLUMNS,
  isPublicArticle,
  LANGUAGES,
  LANGUAGE_CODES,
  SOURCE_LANGUAGE,
  isSourceLanguage,
  normalizeLanguage,
  languageLabel,
  type ArticleMeta,
  type Language,
};

export type Role = "admin" | "editor" | "reviewer" | "viewer";

export const ROLES: Role[] = ["admin", "editor", "reviewer", "viewer"];

/** What each role is allowed to do (used for UI gating; RLS enforces the DB). */
export const can = {
  edit: (role: Role | null) => role === "admin" || role === "editor",
  delete: (role: Role | null) => role === "admin",
  manageUsers: (role: Role | null) => role === "admin",
  /** Approve / reject articles submitted for review (admins bypass the queue). */
  review: (role: Role | null) => role === "admin" || role === "reviewer",
  /** View the audit log and the trash bin (admin-only). */
  audit: (role: Role | null) => role === "admin",
};

/** Access-role tags that gate article visibility, offered by the article
 *  access-role picker. BASIC_ACCESS is treated as "public". Customize this list
 *  for your deployment (an empty access_roles set also means public). */
export const ENTITLEMENT_ROLES = [
  "BASIC_ACCESS",
  "INTERNAL",
  "STAFF",
] as const;

export type Profile = {
  id: string;
  email: string | null;
  role: Role;
  /** 'auto' = derived from Keycloak groups on login; 'manual' = pinned by an
   *  admin (and therefore not overwritten on the next login). */
  role_source: "auto" | "manual";
  access_roles: string[];
  /** Admin-granted entitlements (survive the Keycloak login re-sync). */
  manual_access_roles: string[];
  created_at: string;
};

/** Editorial lifecycle of an article. `published` is derived from this. */
export type ArticleStatus = "draft" | "in_review" | "published";

export type Article = {
  id: string;
  slug: string;
  title: string;
  folder: string;
  content: string;
  tags: string[];
  /** Entitlement roles required to read this article (ANY-of). Empty or
   *  containing BASIC_ACCESS => public. */
  access_roles: string[];
  /** Stable host-screen keys this article is relevant to (contextual related-
   *  articles in embeds, e.g. "intervention.shipment-detail"). */
  context_keys: string[];
  status: ArticleStatus;
  /** Kept in sync from `status` by the DB (status === 'published'). */
  published: boolean;
  submitted_by: string | null;
  submitted_at: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  review_note: string | null;
  /** Trash bin: null = live; set = soft-deleted (restorable until purged). */
  deleted_at: string | null;
  deleted_by: string | null;
  created_at: string;
  updated_at: string;
};

/** A per-language version of an article (WordPress-style). Holds only the
 *  translatable fields + its own editorial lifecycle; article-level metadata
 *  (slug/folder/tags/access_roles/context_keys) lives on the parent article. */
export type ArticleTranslation = {
  id: string;
  article_id: string;
  language: string;
  title: string;
  content: string;
  status: ArticleStatus;
  published: boolean;
  submitted_by: string | null;
  submitted_at: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  review_note: string | null;
  created_at: string;
  updated_at: string;
};

/** A user's PRIVATE working copy of an article (source language). Edits live
 *  here, invisible to others, until published; reviewers see it once in_review. */
export type ArticleDraft = {
  id: string;
  article_id: string;
  author_id: string;
  language: string;
  title: string;
  slug: string;
  folder: string;
  content: string;
  tags: string[];
  access_roles: string[];
  context_keys: string[];
  status: "draft" | "in_review";
  review_note: string | null;
  base_revision: number | null;
  submitted_at: string | null;
  created_at: string;
  updated_at: string;
};

/** Per-language status for the editor's language switcher (source excluded). */
export type TranslationSummary = {
  language: string;
  status: ArticleStatus;
  updated_at: string;
};

/** One immutable snapshot of an article, captured on each content/status change. */
export type ArticleRevision = {
  id: string;
  article_id: string;
  revision: number;
  title: string;
  slug: string;
  folder: string;
  content: string;
  tags: string[];
  access_roles: string[];
  status: ArticleStatus;
  edited_by: string | null;
  created_at: string;
};

/** One entry in the editorial audit trail. */
export type AuditEntry = {
  id: string;
  actor_id: string | null;
  actor_email: string | null;
  action: string;
  target_type: "article" | "user";
  target_id: string | null;
  summary: string | null;
  metadata: Record<string, unknown> | null;
  created_at: string;
};

// `ArticleMeta`, `ARTICLE_LIST_COLUMNS`, and `isPublicArticle` now come from
// @stillwiki/core (re-exported at the top of this file).

/** UI mirror of the DB `can_write_article`: admins/reviewers may edit anything;
 *  an editor may edit an article only if it's public or they hold ALL of its
 *  entitlement roles. RLS is the real boundary; this just gates the UI. */
export function canWriteArticle(
  articleRoles: string[],
  userRoles: string[],
  role: Role | null,
): boolean {
  if (role === "admin" || role === "reviewer") return true;
  if (role !== "editor") return false;
  return (
    isPublicArticle(articleRoles) ||
    articleRoles.every((r) => userRoles.includes(r))
  );
}

// ----------------------------------------------------------------------------
// App-wide settings (admin-configurable, persisted in public.app_settings).
// Stored as a JSONB blob; the client merges it over DEFAULT_SETTINGS so missing
// keys fall back. Some are wired to behaviour today; the rest are persisted and
// wired incrementally.
// ----------------------------------------------------------------------------
export type AppSettings = {
  // Branding & appearance
  siteName: string;
  tagline: string;
  accentColor: string;
  defaultTheme: "light" | "dark" | "system";
  // Publishing & review
  requireReview: boolean;
  allowAdminSelfReview: boolean;
  // Languages & access
  enabledLanguages: string[];
  defaultLanguage: string;
  fallbackToSource: boolean;
  requireLoginToRead: boolean;
  defaultUserRole: Role;
  // Editor, AI & analytics
  defaultEditorView: "edit" | "live" | "preview";
  tagsEnabled: boolean;
  askAiEnabled: boolean;
  feedbackWidget: boolean;
  /** Reader "suggest an edit / report a mistake" control on articles. */
  suggestEdits: boolean;
  viewTracking: boolean;
  searchLogging: boolean;
};

export const DEFAULT_SETTINGS: AppSettings = {
  siteName: "stillwiki",
  tagline: "",
  accentColor: "#0369a1",
  defaultTheme: "system",
  requireReview: true,
  allowAdminSelfReview: true,
  enabledLanguages: ["en", "de"],
  defaultLanguage: "en",
  fallbackToSource: true,
  requireLoginToRead: false,
  defaultUserRole: "viewer",
  defaultEditorView: "live",
  tagsEnabled: true,
  askAiEnabled: true,
  feedbackWidget: true,
  suggestEdits: true,
  viewTracking: true,
  searchLogging: true,
};
