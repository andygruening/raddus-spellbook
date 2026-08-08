import { AppError, isRecord } from "./http";

export type SpellInput = {
  uid: string | null;
  name: string;
  description: string;
  tags: string[];
  file: string;
  content: string;
};

export type SpellRow = {
  id: string;
  name: string;
  description: string;
  file: string;
  content: string;
  tags_json: string;
  owner_email: string;
  published: number;
  created_at: string;
  updated_at: string;
  published_at: string;
  star_count: number;
  starred_by_viewer: number;
};

export type SpellResponse = {
  uid: string;
  name: string;
  description: string;
  tags: string[];
  file: string;
  content: string;
  ownerEmail: string;
  publishedAt: string | null;
  starCount: number;
  starredByMe: boolean;
};

export function parseSpellInput(body: Record<string, unknown>): SpellInput {
  const name = requiredText(body.name, "Name is required.", 120);
  const file = optionalText(body.file, 240) ?? `spells/${slugForFile(name)}.md`;

  return {
    uid: optionalText(body.uid, 160),
    name,
    description: requiredText(body.description, "Description is required.", 500),
    tags: parseTags(body.tags),
    file: validatedFile(file),
    content: requiredText(body.content, "Markdown content is required.", 50000)
  };
}

export function rowToSpell(row: SpellRow): SpellResponse {
  return {
    uid: row.id,
    name: row.name,
    description: row.description,
    tags: parseTagsJson(row.tags_json),
    file: row.file,
    content: row.content,
    ownerEmail: row.owner_email,
    publishedAt: row.published_at || null,
    starCount: row.star_count,
    starredByMe: row.starred_by_viewer === 1
  };
}

export function rowsToSpells(rows: SpellRow[]): SpellResponse[] {
  return rows.map(rowToSpell);
}

function requiredText(value: unknown, message: string, maxLength: number): string {
  const text = optionalText(value, maxLength);
  if (!text) {
    throw new AppError(message, 400);
  }

  return text;
}

function optionalText(value: unknown, maxLength: number): string | null {
  if (value === undefined || value === null) {
    return null;
  }

  if (typeof value !== "string") {
    return null;
  }

  const text = value.trim();
  if (text.length === 0) {
    return null;
  }

  if (text.length > maxLength) {
    throw new AppError("One of the spell fields is too long.", 400);
  }

  return text;
}

function parseTags(value: unknown): string[] {
  if (value === undefined || value === null) {
    return ["review"];
  }

  if (!Array.isArray(value)) {
    throw new AppError("Tags must be a list of text values.", 400);
  }

  const tags = value
    .filter((tag): tag is string => typeof tag === "string")
    .map((tag) => tag.trim().toLowerCase())
    .filter((tag) => tag.length > 0)
    .slice(0, 20);

  const deduped = Array.from(new Set(tags.map((tag) => tag.slice(0, 40))));
  return deduped.length === 0 ? ["review"] : deduped;
}

function parseTagsJson(value: string): string[] {
  let parsed: unknown;

  try {
    parsed = JSON.parse(value);
  } catch {
    return [];
  }

  if (!Array.isArray(parsed)) {
    return [];
  }

  return parsed.filter((tag): tag is string => typeof tag === "string");
}

function validatedFile(value: string): string {
  if (value.startsWith("/") || value.includes("..")) {
    throw new AppError("Spell files must live under ./spells and end in .md.", 400);
  }

  const parts = value.split("/");
  const [directory, fileName] = parts;
  if (parts.length !== 2 || directory !== "spells" || !fileName || !fileName.endsWith(".md") || fileName.length <= 3) {
    throw new AppError("Spell files must live under ./spells and end in .md.", 400);
  }

  return value;
}

function slugForFile(value: string): string {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return slug || "spell";
}

export function isSpellResponse(value: unknown): value is SpellResponse {
  return (
    isRecord(value) &&
    typeof value.uid === "string" &&
    typeof value.name === "string" &&
    typeof value.description === "string" &&
    Array.isArray(value.tags) &&
    typeof value.file === "string" &&
    typeof value.content === "string"
  );
}
