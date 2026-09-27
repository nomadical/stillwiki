// @stillwiki/core — framework-agnostic, dependency-free shared model for the
// knowledge base. Single source of truth for the read-only article shape and
// design tokens consumed by the app. No React, no MUI, no Supabase here.

/** Lightweight article shape for list/search views (omits the heavy `content`). */
export type ArticleMeta = {
  id: string;
  slug: string;
  title: string;
  folder: string;
  tags: string[];
  /** Entitlement roles required to read (ANY-of). Empty or BASIC_ACCESS => public. */
  access_roles: string[];
  published: boolean;
  updated_at: string;
};

/** Columns fetched for list/search views (no heavy `content`). */
export const ARTICLE_LIST_COLUMNS =
  "id,slug,title,folder,tags,access_roles,published,updated_at";

/** An article is public (readable without entitlement) when it has no roles or
 *  explicitly grants BASIC_ACCESS. */
export function isPublicArticle(accessRoles: string[]): boolean {
  return accessRoles.length === 0 || accessRoles.includes("BASIC_ACCESS");
}

// ---- Languages -----------------------------------------------------------
// Single source of truth for the supported languages, shared by the SPA (UI
// i18n + article-translation switcher), the Express backend (validation), and
// any embed. The first entry is the SOURCE language: its content lives on the
// `articles` row itself; every other language is an `article_translations` row.

export type Language = {
  /** BCP-47-ish short code, also the DB `language` value (e.g. "en", "de"). */
  code: string;
  /** English name, for menus shown in an English context. */
  label: string;
  /** Endonym, shown in the language switcher (e.g. "Deutsch"). */
  nativeLabel: string;
};

/** Supported languages. `LANGUAGES[0]` is the source language. */
export const LANGUAGES: Language[] = [
  { code: "en", label: "English", nativeLabel: "English" },
  { code: "de", label: "German", nativeLabel: "Deutsch" },
];

/** The source language code — its content is stored on the `articles` row. */
export const SOURCE_LANGUAGE = "en";

/** All supported language codes (handy for whitelists / DB CHECKs). */
export const LANGUAGE_CODES: string[] = LANGUAGES.map((l) => l.code);

/** True for the source language (article content), false for translations. */
export function isSourceLanguage(code: string): boolean {
  return code === SOURCE_LANGUAGE;
}

/** A supported code (falling back to the source language for unknown input). */
export function normalizeLanguage(code: string | null | undefined): string {
  return code && LANGUAGE_CODES.includes(code) ? code : SOURCE_LANGUAGE;
}

/** Endonym for a code, falling back to the code itself if unknown. */
export function languageLabel(code: string): string {
  return LANGUAGES.find((l) => l.code === code)?.nativeLabel ?? code;
}

// Shared design tokens (brand palette, radii, type).
export {
  KB_BRANDS,
  KB_NEUTRALS,
  KB_RADII,
  KB_FONT_STACK,
  type KbBrand,
} from "./tokens";
