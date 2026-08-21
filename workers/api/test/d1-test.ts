import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

type SqlValue = string | number | null;

type RunResult = {
  changes: number;
  last_row_id: number | null;
};

export function createTestD1(): D1Database {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec("PRAGMA foreign_keys = ON");

  const migrationsDir = join(process.cwd(), "migrations");
  for (const file of readdirSync(migrationsDir).filter((name) => name.endsWith(".sql")).sort()) {
    sqlite.exec(readFileSync(join(migrationsDir, file), "utf8"));
  }

  return {
    prepare(query: string) {
      const statement = sqlite.prepare(query);
      let values: SqlValue[] = [];

      const prepared = {
        bind(...bound: SqlValue[]) {
          values = bound;
          return prepared;
        },
        async run() {
          const result = statement.run(...values);
          return {
            success: true,
            meta: {
              changes: Number(result.changes),
              last_row_id: typeof result.lastInsertRowid === "bigint" ? Number(result.lastInsertRowid) : null
            } satisfies RunResult,
            results: []
          };
        },
        async all<T = unknown>() {
          return {
            success: true,
            meta: {},
            results: statement.all(...values) as T[]
          };
        },
        async first<T = unknown>() {
          return (statement.get(...values) as T | undefined) ?? null;
        },
        raw() {
          throw new Error("raw() is not implemented in the D1 test adapter.");
        }
      };

      return prepared as unknown as D1PreparedStatement;
    },
    async batch<T = unknown>(statements: D1PreparedStatement[]) {
      const results: unknown[] = [];
      sqlite.exec("BEGIN");
      try {
        for (const statement of statements) {
          results.push(await statement.run());
        }
        sqlite.exec("COMMIT");
      } catch (error) {
        sqlite.exec("ROLLBACK");
        throw error;
      }
      return results as D1Result<T>[];
    },
    dump() {
      throw new Error("dump() is not implemented in the D1 test adapter.");
    },
    exec(query: string) {
      sqlite.exec(query);
      return Promise.resolve({ count: 0, duration: 0 });
    }
  } as unknown as D1Database;
}
