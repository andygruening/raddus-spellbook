import { AppError, isRecord } from "./http";

export type SpellInput = {
  uid: string | null;
  name: string;
  description: string;
  trigger: string;
  file: string;
  content: string;
};

export type SpellRow = {
  id: string;
  name: string;
  description: string;
  trigger: string;
  file: string;
  content: string;
  version: number;
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
  trigger: string;
  file: string;
  content: string;
  version: number;
  ownerEmail: string;
  publishedAt: string | null;
  starCount: number;
  starredByMe: boolean;
};

export function parseSpellInput(body: Record<string, unknown>): SpellInput {
  const name = requiredText(body.name, "Name is required.", 120);
  if (body.file !== undefined && body.file !== null && typeof body.file !== "string") {
    throw new AppError("Instruction files must live under ./instructions and end in .md.", 400);
  }

  const file = optionalText(body.file, 240) ?? `instructions/${slugForFile(name)}.md`;

  return {
    uid: optionalText(body.uid, 160),
    name,
    description: requiredText(body.description, "Description is required.", 500),
    trigger: requiredText(body.trigger, "Trigger is required.", 1000),
    file: validatedFile(file),
    content: requiredText(body.content, "Markdown content is required.", 50000)
  };
}

export function rowToSpell(row: SpellRow): SpellResponse {
  return {
    uid: row.id,
    name: row.name,
    description: row.description,
    trigger: row.trigger,
    file: row.file,
    content: row.content,
    version: row.version,
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

function validatedFile(value: string): string {
  if (value.startsWith("/") || value.includes("..")) {
    throw new AppError("Instruction files must live under ./instructions and end in .md.", 400);
  }

  const parts = value.split("/");
  const [directory, fileName] = parts;
  if (
    parts.length !== 2 ||
    directory !== "instructions" ||
    !fileName ||
    !fileName.endsWith(".md") ||
    fileName.length <= 3
  ) {
    throw new AppError("Instruction files must live under ./instructions and end in .md.", 400);
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
    typeof value.trigger === "string" &&
    typeof value.file === "string" &&
    typeof value.content === "string" &&
    typeof value.version === "number"
  );
}
