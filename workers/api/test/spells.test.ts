import { describe, expect, it } from "vitest";
import { parseSpellInput, rowToSpell } from "../src/spells";

describe("spell helpers", () => {
  it("parses markdown-backed spell input", () => {
    expect(
      parseSpellInput({
        name: "Review Boundaries",
        description: "Keep review feedback scoped to the requested change.",
        trigger: "Use when reviewing code changes for scope drift.",
        tags: ["Review", " review ", "scope"],
        file: "instructions/review-boundaries.md",
        content: "# Review Boundaries\n\nCheck ownership and scope."
      })
    ).toEqual({
      uid: null,
      name: "Review Boundaries",
      description: "Keep review feedback scoped to the requested change.",
      trigger: "Use when reviewing code changes for scope drift.",
      tags: ["review", "scope"],
      file: "instructions/review-boundaries.md",
      content: "# Review Boundaries\n\nCheck ownership and scope."
    });
  });

  it("accepts legacy spell file paths", () => {
    expect(
      parseSpellInput({
        name: "Legacy Path",
        description: "Accept old local clients.",
        trigger: "Use when validating legacy file paths.",
        tags: ["review"],
        file: "spells/legacy-path.md",
        content: "# Legacy Path"
      }).file
    ).toBe("spells/legacy-path.md");
  });

  it("rejects files outside the instructions directory", () => {
    expect(() =>
      parseSpellInput({
        name: "Bad Path",
        description: "Do not allow path traversal.",
        trigger: "Use when validating spell file paths.",
        tags: ["review"],
        file: "../bad.md",
        content: "# Bad Path"
      })
    ).toThrow("Instruction files must live under ./instructions or legacy ./spells and end in .md.");
  });

  it("requires trigger metadata", () => {
    expect(() =>
      parseSpellInput({
        name: "Missing Trigger",
        description: "Do not publish incomplete activation metadata.",
        tags: ["review"],
        file: "instructions/missing-trigger.md",
        content: "# Missing Trigger"
      })
    ).toThrow("Trigger is required.");
  });

  it("maps D1 rows to uid-based spell responses", () => {
    expect(
      rowToSpell({
        id: "uid-123",
        name: "Review Boundaries",
        description: "Keep review feedback scoped.",
        trigger: "Use when reviewing code changes for scope drift.",
        file: "spells/review-boundaries.md",
        content: "# Review Boundaries",
        version: 4,
        tags_json: "[\"review\"]",
        owner_email: "ada@example.com",
        published: 1,
        created_at: "2026-08-06T00:00:00.000Z",
        updated_at: "2026-08-06T00:00:00.000Z",
        published_at: "2026-08-06T00:00:00.000Z",
        star_count: 3,
        starred_by_viewer: 1
      })
    ).toEqual({
      uid: "uid-123",
      name: "Review Boundaries",
      description: "Keep review feedback scoped.",
      trigger: "Use when reviewing code changes for scope drift.",
      tags: ["review"],
      file: "spells/review-boundaries.md",
      content: "# Review Boundaries",
      version: 4,
      ownerEmail: "ada@example.com",
      publishedAt: "2026-08-06T00:00:00.000Z",
      starCount: 3,
      starredByMe: true
    });
  });
});
