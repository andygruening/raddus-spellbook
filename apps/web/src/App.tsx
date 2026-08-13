import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from "react";
import {
  appShellRecipe,
  badgeRecipe,
  buttonRecipe,
  cardRecipe,
  designTokens,
  overlayRecipe
} from "../styling.gen";

const apiURL = "https://api.spellbook.raddus.dev/";
const installURL = "https://github.com/andygruening/raddus-spellbook/releases/download/v1.0.0/Spellbook-1.0.0.dmg";

type Spell = {
  uid: string;
  name: string;
  description: string;
  trigger: string;
  tags: string[];
  file: string;
  content: string;
  version: number;
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

type DesignStyle = CSSProperties & Record<`--${string}`, string | number>;

const designStyle: DesignStyle = {
  "--page-bg": "#f8fbff",
  "--surface-bg": "rgba(255, 255, 255, 0.9)",
  "--header-bg": "rgba(255, 255, 255, 0.18)",
  "--text-primary": "#10213c",
  "--text-secondary": "#526783",
  "--text-muted": "#60728d",
  "--border-default": "rgba(18, 35, 63, 0.1)",
  "--border-subtle": "rgba(18, 35, 63, 0.08)",
  "--border-divider": "rgba(18, 35, 63, 0.09)",
  "--focus-ring": "#78b8ff",
  "--hover-bg": "rgba(245, 249, 255, 0.9)",
  "--selected-bg": "rgba(20, 119, 255, 0.13)",
  "--brand-accent": "#1477ff",
  "--brand-accent-hover": "#0f5fd6",
  "--brand-green": "#0f766e",
  "--glass-bg": "rgba(255, 255, 255, 0.76)",
  "--glass-strong-bg": "rgba(255, 255, 255, 0.9)",
  "--logo-bg": "linear-gradient(135deg, #ffffff 0%, #edf5ff 100%)",
  "--logo-border": "rgba(18, 35, 63, 0.14)",
  "--tag-border": "rgba(20, 119, 255, 0.28)",
  "--tag-bg": "rgba(255, 255, 255, 0.76)",
  "--score-bg": "#efefef",
  "--danger-bg": designTokens.rawColors.semantic.danger.bg,
  "--danger-border": designTokens.rawColors.semantic.danger.border,
  "--danger-text": designTokens.rawColors.semantic.danger.fg,
  "--font-product": `${designTokens.typography.fontFamily}, Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`,
  "--font-documentation": `${designTokens.typography.raw.documentation.family}, ui-sans-serif, system-ui, sans-serif`,
  "--font-mono": `${designTokens.typography.raw.mono.family}, "SFMono-Regular", Consolas, monospace`,
  "--font-weight-body": designTokens.typography.bodyWeight,
  "--font-weight-bold": designTokens.typography.headingWeight,
  "--line-height": designTokens.typography.lineHeight,
  "--text-title": px(designTokens.typography.raw.scale.h5.size),
  "--text-emphasis": px(designTokens.typography.raw.scale.body3.size),
  "--text-body": px(designTokens.typography.raw.scale.body4.size),
  "--text-supporting": `calc(${px(designTokens.typography.raw.scale.body4.size)} - 1px)`,
  "--text-small": px(designTokens.typography.raw.scale.body5.size),
  "--text-micro": `calc(${px(designTokens.typography.raw.scale.body5.size)} - 1px)`,
  "--space-1": px(designTokens.spacing.scale[0]),
  "--space-2": px(designTokens.spacing.scale[1]),
  "--space-3": px(designTokens.spacing.scale[2]),
  "--space-4": px(designTokens.spacing.scale[3]),
  "--space-5": px(designTokens.spacing.scale[4]),
  "--space-6": px(designTokens.spacing.scale[5]),
  "--space-7": px(designTokens.spacing.scale[6]),
  "--space-8": px(designTokens.spacing.scale[7]),
  "--space-9": px(designTokens.spacing.scale[8]),
  "--radius-button": px(designTokens.radii.button),
  "--radius-badge": px(designTokens.radii.badge),
  "--radius-card": px(designTokens.radii.button),
  "--radius-modal": px(designTokens.radii.button),
  "--shadow-card": "0 18px 58px rgba(18, 71, 140, 0.08)",
  "--shadow-modal": "0 24px 80px rgba(18, 71, 140, 0.15)",
  "--shadow-button": "0 20px 54px rgba(18, 35, 63, 0.18)",
  "--motion-hover": designTokens.motion.hover,
  "--top-nav-height": "72px",
  "--button-primary-bg": "#10213c",
  "--button-primary-text": buttonRecipe.primary.color,
  "--button-primary-border": "1px solid #10213c",
  "--button-primary-hover-bg": "#0b182d",
  "--button-primary-active-bg": "#0b182d",
  "--button-secondary-bg": buttonRecipe.secondary.background,
  "--button-secondary-text": "#10213c",
  "--button-secondary-border": "1px solid rgba(18, 35, 63, 0.16)",
  "--button-secondary-hover-border": "#10213c",
  "--button-secondary-active-bg": "#e8f2ff",
  "--button-secondary-active-border": buttonRecipe.secondary.activeBorderColor ?? designTokens.colors.border,
  "--button-height": px(buttonRecipe.secondary.minHeight),
  "--button-font-size": px(designTokens.typography.raw.scale.body4.size),
  "--button-padding-x": px(buttonRecipe.secondary.paddingInline),
  "--badge-neutral-bg": "rgba(255, 255, 255, 0.76)",
  "--badge-neutral-text": "#1477ff",
  "--badge-info-bg": "rgba(237, 245, 255, 0.88)",
  "--badge-info-text": "#0f5fd6",
  "--badge-padding-block": px(badgeRecipe.neutral.paddingBlock),
  "--badge-padding-inline": px(badgeRecipe.neutral.paddingInline),
  "--badge-font-size": px(designTokens.typography.raw.scale.body5.size),
  "--card-border": "1px solid rgba(32, 34, 38, 0.1)",
  "--card-padding": px(cardRecipe.default.padding),
  "--modal-border": "1px solid rgba(18, 35, 63, 0.11)",
  "--modal-max-width": px(overlayRecipe.modal.maxWidth)
};

function px(value: string | number): string {
  return typeof value === "number" ? `${value}px` : value;
}

export function App() {
  const [spells, setSpells] = useState<Spell[]>([]);
  const [hasLoadedSpells, setHasLoadedSpells] = useState(false);
  const [isLoadingSpells, setIsLoadingSpells] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedSpellId, setSelectedSpellId] = useState<string | null>(() => spellIdFromURL());
  const [loadingSpellIds, setLoadingSpellIds] = useState<Set<string>>(() => new Set());
  const [missingSpellIds, setMissingSpellIds] = useState<Set<string>>(() => new Set());

  const selectedSpell = useMemo(
    () => spells.find((spell) => spell.uid === selectedSpellId) ?? null,
    [selectedSpellId, spells]
  );
  const selectedSpellIsMissing = Boolean(selectedSpellId && !selectedSpell && missingSpellIds.has(selectedSpellId));
  const selectedSpellIsLoading = Boolean(
    selectedSpellId && !selectedSpell && !selectedSpellIsMissing && (isLoadingSpells || loadingSpellIds.has(selectedSpellId))
  );

  useEffect(() => {
    const handlePopState = () => {
      setSelectedSpellId(spellIdFromURL());
    };

    window.addEventListener("popstate", handlePopState);
    return () => window.removeEventListener("popstate", handlePopState);
  }, []);

  useEffect(() => {
    void loadSpells(selectedSpellId);
  }, []);

  useEffect(() => {
    if (!selectedSpellId || !hasLoadedSpells || selectedSpell || missingSpellIds.has(selectedSpellId)) {
      return;
    }

    void loadLinkedSpell(selectedSpellId);
  }, [hasLoadedSpells, missingSpellIds, selectedSpell, selectedSpellId]);

  useEffect(() => {
    if (!selectedSpellId) {
      return;
    }

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeSpell();
      }
    };

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [selectedSpellId]);

  async function loadSpells(linkedSpellId: string | null = selectedSpellId) {
    setIsLoadingSpells(true);
    setError(null);

    try {
      const response = await fetch(apiEndpoint("/api/spells/public?limit=100"));
      if (!response.ok) {
        setError("Spellbook could not load published spells.");
        return;
      }

      const data = (await response.json()) as SpellsResponse;
      let nextSpells = data.spells;

      if (linkedSpellId && !nextSpells.some((spell) => spell.uid === linkedSpellId)) {
        const linkedSpell = await fetchSpell(linkedSpellId);
        if (linkedSpell) {
          nextSpells = [linkedSpell, ...nextSpells];
          forgetMissingSpell(linkedSpell.uid);
        } else {
          markMissingSpell(linkedSpellId);
        }
      }

      setSpells(nextSpells);
    } catch {
      setError("Spellbook could not reach the public registry.");
    } finally {
      setHasLoadedSpells(true);
      setIsLoadingSpells(false);
    }
  }

  async function loadLinkedSpell(uid: string) {
    markLoadingSpell(uid);

    try {
      const spell = await fetchSpell(uid);
      if (!spell) {
        markMissingSpell(uid);
        return;
      }

      setSpells((currentSpells) =>
        currentSpells.some((currentSpell) => currentSpell.uid === spell.uid)
          ? currentSpells
          : [spell, ...currentSpells]
      );
      forgetMissingSpell(spell.uid);
    } finally {
      forgetLoadingSpell(uid);
    }
  }

  function openSpell(uid: string) {
    setSelectedSpellId(uid);
    const nextPath = spellPath(uid);

    if (window.location.pathname !== nextPath || window.location.search) {
      window.history.pushState(null, "", nextPath);
    }
  }

  function closeSpell() {
    setSelectedSpellId(null);

    if (spellIdFromURL() || window.location.search) {
      window.history.pushState(null, "", "/");
    }
  }

  function markLoadingSpell(uid: string) {
    setLoadingSpellIds((currentSpellIds) => {
      if (currentSpellIds.has(uid)) {
        return currentSpellIds;
      }

      const nextSpellIds = new Set(currentSpellIds);
      nextSpellIds.add(uid);
      return nextSpellIds;
    });
  }

  function forgetLoadingSpell(uid: string) {
    setLoadingSpellIds((currentSpellIds) => {
      if (!currentSpellIds.has(uid)) {
        return currentSpellIds;
      }

      const nextSpellIds = new Set(currentSpellIds);
      nextSpellIds.delete(uid);
      return nextSpellIds;
    });
  }

  function markMissingSpell(uid: string) {
    setMissingSpellIds((currentSpellIds) => {
      if (currentSpellIds.has(uid)) {
        return currentSpellIds;
      }

      const nextSpellIds = new Set(currentSpellIds);
      nextSpellIds.add(uid);
      return nextSpellIds;
    });
  }

  function forgetMissingSpell(uid: string) {
    setMissingSpellIds((currentSpellIds) => {
      if (!currentSpellIds.has(uid)) {
        return currentSpellIds;
      }

      const nextSpellIds = new Set(currentSpellIds);
      nextSpellIds.delete(uid);
      return nextSpellIds;
    });
  }

  return (
    <div className="app-page" style={designStyle}>
      <header className="top-header">
        <div className="top-header-inner">
          <a className="brand-link" href="/">
            <span className="brand-mark-frame">
              <img src="/spellbook-mark.svg" alt="" className="brand-mark" />
            </span>
            <span>Spellbook</span>
          </a>
          <a className="button button-primary install-button" href={installURL} target="_blank" rel="noreferrer">
            <span className="install-icon" aria-hidden="true">↓</span>
            Install on MacOS
          </a>
        </div>
      </header>

      <main className="app-main page-container">
        <section className="spell-list" aria-busy={isLoadingSpells}>
          {error ? (
            <StatusPanel actionLabel="Retry" message={error} onAction={() => void loadSpells(selectedSpellId)} tone="danger" title="Registry unavailable" />
          ) : null}

          {isLoadingSpells && spells.length === 0 ? (
            <StatusPanel message="Spellbook is loading the public registry." title="Loading spells" />
          ) : null}

          {!isLoadingSpells && !error && spells.length === 0 ? (
            <StatusPanel message="No public spells have been published yet." title="No spells yet" />
          ) : null}

          {spells.map((spell) => (
            <SpellTile
              isOpen={spell.uid === selectedSpellId}
              key={spell.uid}
              onOpen={() => openSpell(spell.uid)}
              spell={spell}
            />
          ))}
        </section>
      </main>

      {selectedSpellId ? (
        <SpellDetailsWindow
          isLoading={selectedSpellIsLoading}
          isMissing={selectedSpellIsMissing}
          onClose={closeSpell}
          spell={selectedSpell}
        />
      ) : null}
    </div>
  );
}

function SpellTile({ isOpen, onOpen, spell }: { isOpen: boolean; onOpen: () => void; spell: Spell }) {
  return (
    <button
      aria-expanded={isOpen}
      aria-haspopup="dialog"
      className={`spell-tile${isOpen ? " is-open" : ""}`}
      onClick={onOpen}
      type="button"
    >
      <span className="spell-copy">
        <span className="spell-name">{spell.name}</span>
        <span className="spell-description">{spell.description}</span>
        <span className="spell-tags">
          {spell.tags.length > 0 ? (
            spell.tags.map((tag) => (
              <Badge key={tag} variant="neutral">
                {tag}
              </Badge>
            ))
          ) : (
            <Badge variant="neutral">untagged</Badge>
          )}
        </span>
      </span>
      <span className="star-label" aria-label={`${spell.starCount} upvotes`}>
        <span aria-hidden="true">★</span>
        <span>{formatNumber(spell.starCount)}</span>
      </span>
    </button>
  );
}

function SpellDetailsWindow({
  isLoading,
  isMissing,
  onClose,
  spell
}: {
  isLoading: boolean;
  isMissing: boolean;
  onClose: () => void;
  spell: Spell | null;
}) {
  const [isSpecOpen, setIsSpecOpen] = useState(false);
  const [shareStatus, setShareStatus] = useState<"idle" | "copied" | "shared">("idle");

  useEffect(() => {
    setIsSpecOpen(false);
    setShareStatus("idle");
  }, [spell?.uid]);

  useEffect(() => {
    if (shareStatus === "idle") {
      return;
    }

    const timeoutId = window.setTimeout(() => setShareStatus("idle"), 1800);
    return () => window.clearTimeout(timeoutId);
  }, [shareStatus]);

  async function handleShare() {
    if (!spell) {
      return;
    }

    const shareURL = spellShareURL(spell.uid);

    try {
      if (typeof navigator.share === "function") {
        await navigator.share({
          text: spell.description,
          title: spell.name,
          url: shareURL
        });
        setShareStatus("shared");
        return;
      }

      await copyToClipboard(shareURL);
      setShareStatus("copied");
    } catch {
      try {
        await copyToClipboard(shareURL);
        setShareStatus("copied");
      } catch {
        setShareStatus("idle");
      }
    }
  }

  const shareLabel = shareStatus === "copied" ? "Copied" : shareStatus === "shared" ? "Shared" : "Share";

  return (
    <div
      className="detail-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) {
          onClose();
        }
      }}
    >
      <section
        className={`detail-window${isSpecOpen && spell ? " is-spec-page" : ""}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby={isSpecOpen && spell ? "spell-spec-title" : "spell-detail-title"}
      >
        <button className="icon-button close-button" onClick={onClose} type="button" aria-label="Close spell details">
          x
        </button>

        {spell && isSpecOpen ? (
          <>
            <div className="spec-page-header">
              <button className="button button-secondary spec-back-button" onClick={() => setIsSpecOpen(false)} type="button">
                Back
              </button>
              <div className="spec-page-title">
                <h2 id="spell-spec-title">SPEC.md</h2>
                <p>{spell.name}</p>
              </div>
            </div>

            <section className="spec-page-content" aria-label="SPEC.md content">
              <pre>{spell.content || "SPEC.md is empty."}</pre>
            </section>
          </>
        ) : spell ? (
          <>
            <div className="detail-heading">
              <h2 id="spell-detail-title">{spell.name}</h2>
              <p>{spell.description}</p>
            </div>

            <div className="detail-tags">
              {spell.tags.length > 0 ? (
                spell.tags.map((tag) => (
                  <Badge key={tag} variant="neutral">
                    {tag}
                  </Badge>
                ))
              ) : (
                <Badge variant="neutral">untagged</Badge>
              )}
            </div>

            <section className="detail-section">
              <h3>Trigger</h3>
              <p>{spell.trigger}</p>
            </section>

            <footer className="detail-footer">
              <p className="detail-owner">Created by {spell.ownerEmail}</p>
              <div className="detail-actions">
                <button
                  className="button button-secondary spec-button"
                  onClick={() => setIsSpecOpen(true)}
                  type="button"
                >
                  SPEC.md
                </button>
                <button className="button button-primary share-button" onClick={() => void handleShare()} type="button">
                  {shareLabel}
                </button>
              </div>
            </footer>
          </>
        ) : (
          <div className="detail-empty">
            <h2 id="spell-detail-title">{isMissing ? "Spell not found" : "Loading spell"}</h2>
            <p>
              {isMissing
                ? "That spell is not available in the public registry."
                : isLoading
                  ? "Spellbook is opening the spell details."
                  : "Spellbook is preparing the spell details."}
            </p>
          </div>
        )}
      </section>
    </div>
  );
}

function Badge({
  children,
  variant
}: {
  children: ReactNode;
  variant: "info" | "neutral";
}) {
  return <span className={`badge badge-${variant}`}>{children}</span>;
}

function StatusPanel({
  actionLabel,
  message,
  onAction,
  title,
  tone = "neutral"
}: {
  actionLabel?: string;
  message: string;
  onAction?: () => void;
  title: string;
  tone?: "neutral" | "danger";
}) {
  return (
    <section className={`status-panel status-${tone}`}>
      <h2>{title}</h2>
      <p>{message}</p>
      {actionLabel && onAction ? (
        <button className="button button-secondary" onClick={onAction} type="button">
          {actionLabel}
        </button>
      ) : null}
    </section>
  );
}

function spellIdFromURL(): string | null {
  const pathMatch = window.location.pathname.match(/^\/spell\/([^/]+)\/?$/);
  return pathMatch?.[1] ? decodeURLPart(pathMatch[1]) : null;
}

function spellPath(uid: string): string {
  return `/spell/${encodeURIComponent(uid)}`;
}

function spellShareURL(uid: string): string {
  return new URL(spellPath(uid), window.location.origin).toString();
}

function decodeURLPart(value: string): string | null {
  try {
    return decodeURIComponent(value).trim() || null;
  } catch {
    return value.trim() || null;
  }
}

async function fetchSpell(uid: string): Promise<Spell | null> {
  const response = await fetch(apiEndpoint(`/api/spells/${encodeURIComponent(uid)}`));
  if (!response.ok) {
    return null;
  }

  const data = (await response.json()) as SpellResponse;
  return data.spell;
}

function formatNumber(value: number): string {
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(value);
}

function apiEndpoint(path: string): string {
  return new URL(path, apiURL).toString();
}

async function copyToClipboard(value: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const textArea = document.createElement("textarea");
  textArea.value = value;
  textArea.setAttribute("readonly", "");
  textArea.style.position = "fixed";
  textArea.style.opacity = "0";
  document.body.append(textArea);
  textArea.select();
  document.execCommand("copy");
  textArea.remove();
}
