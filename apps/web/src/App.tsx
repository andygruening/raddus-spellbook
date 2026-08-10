import { useEffect, useMemo, useState } from "react";

const apiURL = "https://api.spellbook.raddus.dev/";

type Spell = {
  uid: string;
  name: string;
  description: string;
  trigger: string;
  tags: string[];
  file: string;
  content: string;
  ownerEmail: string;
  publishedAt: string | null;
  starCount: number;
  starredByMe: boolean;
};

type SpellsResponse = {
  spells: Spell[];
};

type SpellResponse = {
  spell: Spell;
};

type APIErrorResponse = {
  error: string;
};

export function App() {
  const [spells, setSpells] = useState<Spell[]>([]);
  const [query, setQuery] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const selectedSpellId = useMemo(() => spellIdFromURL(), []);

  const filteredSpells = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return spells.filter((spell) => {
      if (!normalizedQuery) {
        return true;
      }

      const searchable = [
        spell.name,
        spell.description,
        spell.trigger,
        spell.file,
        spell.content,
        spell.tags.join(" ")
      ]
        .join(" ")
        .toLowerCase();

      return searchable.includes(normalizedQuery);
    });
  }, [query, spells]);

  useEffect(() => {
    void loadSpells();
  }, []);

  useEffect(() => {
    if (!selectedSpellId) {
      return;
    }

    const frame = window.requestAnimationFrame(() => {
      document.getElementById(`spell-${selectedSpellId}`)?.scrollIntoView({
        block: "center",
        behavior: "smooth"
      });
    });

    return () => window.cancelAnimationFrame(frame);
  }, [selectedSpellId, spells]);

  async function loadSpells() {
    setIsLoading(true);
    setError(null);

    try {
      const response = await fetch(apiEndpoint("/api/spells/public?limit=100"));
      if (!response.ok) {
        setError(await productSafeError(response));
        return;
      }

      const data = (await response.json()) as SpellsResponse;
      let nextSpells = data.spells;

      if (selectedSpellId && !nextSpells.some((spell) => spell.uid === selectedSpellId)) {
        const linkedSpell = await loadSpell(selectedSpellId);
        if (linkedSpell) {
          nextSpells = [linkedSpell, ...nextSpells];
        }
      }

      setSpells(nextSpells);
    } catch {
      setError("Spellbook could not reach the public registry.");
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <img src="/spellbook-mark.svg" alt="" className="brand-mark" />
          <div>
            <p className="brand-kicker">Raddus</p>
            <h1>Spellbook</h1>
          </div>
        </div>
        <div className="stat">
          <span>{spells.length}</span>
          <p>published spells</p>
        </div>
      </aside>

      <section className="content">
        <header className="toolbar">
          <div>
            <h2>Published spells</h2>
            <p>Read-only public registry</p>
          </div>
          <button type="button" className="refresh-button" onClick={loadSpells} disabled={isLoading}>
            Refresh
          </button>
        </header>

        <div className="filters">
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search" />
        </div>

        {error ? <p className="error">{error}</p> : null}

        <div className="spell-list" aria-busy={isLoading}>
          {isLoading && spells.length === 0 ? <p className="empty">Loading published spells.</p> : null}
          {!isLoading && filteredSpells.length === 0 ? <p className="empty">No spells match this view.</p> : null}
          {filteredSpells.map((spell) => (
            <article
              className={`spell-card${spell.uid === selectedSpellId ? " is-selected" : ""}`}
              id={`spell-${spell.uid}`}
              key={spell.uid}
              aria-current={spell.uid === selectedSpellId ? "true" : undefined}
            >
              <div className="spell-card-header">
                <div>
                  <h3>{spell.name}</h3>
                  <p>{spell.description}</p>
                </div>
                <span>{spell.file}</span>
              </div>
              <p className="star-count" aria-label={`${spell.starCount} stars`}>
                <span aria-hidden="true">{spell.starredByMe ? "★" : "☆"}</span>
                {spell.starCount}
              </p>
              <div className="tags">
                {spell.tags.map((tag) => (
                  <span key={tag}>{tag}</span>
                ))}
              </div>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}

function spellIdFromURL(): string | null {
  const params = new URLSearchParams(window.location.search);
  const spell = params.get("spell")?.trim();
  return spell || null;
}

async function loadSpell(uid: string): Promise<Spell | null> {
  const response = await fetch(apiEndpoint(`/api/spells/${encodeURIComponent(uid)}`));
  if (!response.ok) {
    return null;
  }

  const data = (await response.json()) as SpellResponse;
  return data.spell;
}

async function productSafeError(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as APIErrorResponse;
    return body.error || "Spellbook could not load published spells.";
  } catch {
    return "Spellbook could not load published spells.";
  }
}

function apiEndpoint(path: string): string {
  return new URL(path, apiURL).toString();
}
