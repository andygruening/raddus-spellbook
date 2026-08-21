import { useEffect, useMemo, useState, type CSSProperties, type FormEvent } from "react";
import {
  buttonRecipe,
  cardRecipe,
  designTokens,
  overlayRecipe
} from "../styling.gen";

const apiURL = "https://api.spellbook.raddus.dev/";
const installURL = "https://github.com/andygruening/raddus-spellbook/releases/download/v1.0.0/Spellbook-1.0.0.dmg";
const sessionStorageKey = "spellbook-web-session";

type LifecycleState =
  | "draft"
  | "submitted_for_review"
  | "needs_changes"
  | "approved"
  | "withdrawn"
  | "archived";

type ArtifactType = "rule" | "pack";
type View = "library" | "creator" | "admin";

type Session = {
  token: string;
  email: string;
  role: "user" | "admin";
  expiresAt: string;
};

type Rule = {
  uid: string;
  version: number;
  lifecycleState: LifecycleState;
  name: string;
  description: string;
  appliesWhen: string;
  file: string;
  body: string;
  ownerEmail: string;
  createdAt: string;
  updatedAt: string;
  submittedAt: string | null;
  approvedAt: string | null;
  reviewedAt: string | null;
  reviewerEmail: string | null;
  reviewNotes: string | null;
  starCount: number;
  starredByMe: boolean;
};

type PackRuleRef = {
  uid: string;
  version: number;
  lifecycleState: LifecycleState;
  name: string;
  ownerEmail: string;
  includedDraftRule: boolean;
};

type Pack = {
  uid: string;
  version: number;
  lifecycleState: LifecycleState;
  name: string;
  description: string;
  audience: string;
  suggestedWorkspaceType: string;
  compatibility: Record<string, unknown>;
  releaseNotes: string;
  ownerEmail: string;
  createdAt: string;
  updatedAt: string;
  submittedAt: string | null;
  approvedAt: string | null;
  reviewedAt: string | null;
  reviewerEmail: string | null;
  reviewNotes: string | null;
  rules: PackRuleRef[];
};

type ReviewItem = {
  artifactType: ArtifactType;
  uid: string;
  version: number;
  name: string;
  ownerEmail: string;
  submittedAt: string | null;
};

type FocusedArtifact = {
  type: ArtifactType;
  uid: string;
  version?: number;
};

type RouteState = {
  view: View;
  focused: FocusedArtifact | null;
};

type DesignStyle = CSSProperties & Record<`--${string}`, string | number>;

const designStyle: DesignStyle = {
  "--page-bg": "#f7f8f4",
  "--surface-bg": "rgba(255, 255, 255, 0.94)",
  "--header-bg": "rgba(255, 255, 255, 0.82)",
  "--text-primary": "#17201a",
  "--text-secondary": "#516056",
  "--text-muted": "#6a776e",
  "--border-default": "rgba(23, 32, 26, 0.14)",
  "--border-subtle": "rgba(23, 32, 26, 0.08)",
  "--border-divider": "rgba(23, 32, 26, 0.11)",
  "--focus-ring": "#3b82f6",
  "--hover-bg": "rgba(245, 248, 244, 0.9)",
  "--selected-bg": "rgba(45, 118, 89, 0.12)",
  "--brand-accent": "#2d7659",
  "--brand-accent-hover": "#245f49",
  "--brand-blue": "#245f9f",
  "--brand-amber": "#9a5f12",
  "--glass-bg": "rgba(255, 255, 255, 0.76)",
  "--glass-strong-bg": "rgba(255, 255, 255, 0.96)",
  "--logo-bg": "linear-gradient(135deg, #ffffff 0%, #edf4ed 100%)",
  "--logo-border": "rgba(23, 32, 26, 0.14)",
  "--score-bg": "#eef0ea",
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
  "--radius-card": px(designTokens.radii.button),
  "--radius-modal": px(designTokens.radii.button),
  "--shadow-card": "0 16px 48px rgba(23, 32, 26, 0.08)",
  "--shadow-modal": "0 24px 80px rgba(23, 32, 26, 0.18)",
  "--shadow-button": "0 12px 30px rgba(23, 32, 26, 0.12)",
  "--motion-hover": designTokens.motion.hover,
  "--top-nav-height": "76px",
  "--button-primary-bg": "#17201a",
  "--button-primary-text": buttonRecipe.primary.color,
  "--button-primary-border": "1px solid #17201a",
  "--button-primary-hover-bg": "#0f1712",
  "--button-primary-active-bg": "#0f1712",
  "--button-secondary-bg": buttonRecipe.secondary.background,
  "--button-secondary-text": "#17201a",
  "--button-secondary-border": "1px solid rgba(23, 32, 26, 0.16)",
  "--button-secondary-hover-border": "#17201a",
  "--button-secondary-active-bg": "#e7eee9",
  "--button-secondary-active-border": buttonRecipe.secondary.activeBorderColor ?? designTokens.colors.border,
  "--button-height": px(buttonRecipe.secondary.minHeight),
  "--button-font-size": px(designTokens.typography.raw.scale.body4.size),
  "--button-padding-x": px(buttonRecipe.secondary.paddingInline),
  "--card-border": "1px solid rgba(23, 32, 26, 0.12)",
  "--card-padding": px(cardRecipe.default.padding),
  "--modal-border": "1px solid rgba(23, 32, 26, 0.14)",
  "--modal-max-width": px(overlayRecipe.modal.maxWidth)
};

function px(value: string | number): string {
  return typeof value === "number" ? `${value}px` : value;
}

export function App() {
  const initialRoute = useMemo(() => routeFromLocation(), []);
  const [view, setView] = useState<View>(initialRoute.view);
  const [focused, setFocused] = useState<FocusedArtifact | null>(initialRoute.focused);
  const [session, setSession] = useState<Session | null>(() => readStoredSession());
  const [publicRules, setPublicRules] = useState<Rule[]>([]);
  const [publicPacks, setPublicPacks] = useState<Pack[]>([]);
  const [myRules, setMyRules] = useState<Rule[]>([]);
  const [myPacks, setMyPacks] = useState<Pack[]>([]);
  const [reviews, setReviews] = useState<ReviewItem[]>([]);
  const [isLoadingPublic, setIsLoadingPublic] = useState(true);
  const [isLoadingMine, setIsLoadingMine] = useState(false);
  const [isLoadingReviews, setIsLoadingReviews] = useState(false);
  const [detailStatus, setDetailStatus] = useState<"idle" | "loading" | "missing">("idle");
  const [publicError, setPublicError] = useState<string | null>(null);
  const [privateError, setPrivateError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const focusedRule = focused?.type === "rule" ? findRule([...myRules, ...publicRules], focused.uid, focused.version) : null;
  const focusedPack = focused?.type === "pack" ? findPack([...myPacks, ...publicPacks], focused.uid, focused.version) : null;

  useEffect(() => {
    const handlePopState = () => {
      const next = routeFromLocation();
      setView(next.view);
      setFocused(next.focused);
    };

    window.addEventListener("popstate", handlePopState);
    return () => window.removeEventListener("popstate", handlePopState);
  }, []);

  useEffect(() => {
    void loadPublic();
  }, [session?.token]);

  useEffect(() => {
    if (!session) {
      setMyRules([]);
      setMyPacks([]);
      setReviews([]);
      return;
    }

    if (view === "creator") {
      void loadMine(session);
    }
    if (view === "admin" && session.role === "admin") {
      void loadReviews(session);
    }
  }, [session, view]);

  useEffect(() => {
    if (!focused) {
      setDetailStatus("idle");
      return;
    }

    if ((focused.type === "rule" && focusedRule) || (focused.type === "pack" && focusedPack)) {
      setDetailStatus("idle");
      return;
    }

    void loadFocusedArtifact(focused);
  }, [focused?.type, focused?.uid, focused?.version, focusedRule?.uid, focusedPack?.uid]);

  useEffect(() => {
    if (!focused) {
      return;
    }

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeDetail();
      }
    };

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [focused]);

  useEffect(() => {
    if (!toast) {
      return;
    }

    const timeoutId = window.setTimeout(() => setToast(null), 2600);
    return () => window.clearTimeout(timeoutId);
  }, [toast]);

  async function loadPublic() {
    setIsLoadingPublic(true);
    setPublicError(null);

    try {
      const [rulesData, packsData] = await Promise.all([
        apiGet<{ rules: Rule[] }>("/api/rules/public?limit=100", session),
        apiGet<{ packs: Pack[] }>("/api/packs/public?limit=100", session)
      ]);
      setPublicRules(rulesData.rules);
      setPublicPacks(packsData.packs);
    } catch (error) {
      setPublicError(errorMessage(error, "Spellbook could not load the public library."));
    } finally {
      setIsLoadingPublic(false);
    }
  }

  async function loadMine(activeSession = session) {
    if (!activeSession) {
      return;
    }

    setIsLoadingMine(true);
    setPrivateError(null);

    try {
      const [rulesData, packsData] = await Promise.all([
        apiGet<{ rules: Rule[] }>("/api/rules/mine", activeSession),
        apiGet<{ packs: Pack[] }>("/api/packs/mine", activeSession)
      ]);
      setMyRules(rulesData.rules);
      setMyPacks(packsData.packs);
    } catch (error) {
      setPrivateError(errorMessage(error, "Spellbook could not load your rules and packs."));
    } finally {
      setIsLoadingMine(false);
    }
  }

  async function loadReviews(activeSession = session) {
    if (!activeSession || activeSession.role !== "admin") {
      return;
    }

    setIsLoadingReviews(true);
    setPrivateError(null);

    try {
      const data = await apiGet<{ reviews: ReviewItem[] }>("/api/admin/reviews", activeSession);
      setReviews(data.reviews);
    } catch (error) {
      setPrivateError(errorMessage(error, "Spellbook could not load the review queue."));
    } finally {
      setIsLoadingReviews(false);
    }
  }

  async function loadFocusedArtifact(nextFocused: FocusedArtifact) {
    setDetailStatus("loading");

    try {
      if (nextFocused.type === "rule") {
        const suffix = nextFocused.version ? `/versions/${nextFocused.version}` : "";
        const data = await apiGet<{ rule: Rule }>(`/api/rules/${encodeURIComponent(nextFocused.uid)}${suffix}`, session);
        setPublicRules((current) => mergeRule(current, data.rule));
      } else {
        if (!nextFocused.version) {
          setDetailStatus("missing");
          return;
        }

        const data = await apiGet<{ pack: Pack }>(
          `/api/packs/${encodeURIComponent(nextFocused.uid)}/versions/${nextFocused.version}`,
          session
        );
        setPublicPacks((current) => mergePack(current, data.pack));
      }
      setDetailStatus("idle");
    } catch {
      setDetailStatus("missing");
    }
  }

  function navigate(nextView: View) {
    setView(nextView);
    setFocused(null);
    const nextUrl = nextView === "library" ? "/" : `/?view=${nextView}`;
    window.history.pushState(null, "", nextUrl);
  }

  function openDetail(nextFocused: FocusedArtifact) {
    setFocused(nextFocused);
    window.history.pushState(null, "", artifactPath(nextFocused));
  }

  function closeDetail() {
    setFocused(null);
    const nextUrl = view === "library" ? "/" : `/?view=${view}`;
    window.history.pushState(null, "", nextUrl);
  }

  function handleSession(nextSession: Session) {
    setSession(nextSession);
    localStorage.setItem(sessionStorageKey, JSON.stringify(nextSession));
    setToast(`Signed in as ${nextSession.email}`);
  }

  function signOut() {
    localStorage.removeItem(sessionStorageKey);
    setSession(null);
    setView("library");
    setFocused(null);
    window.history.pushState(null, "", "/");
  }

  async function submitArtifact(type: ArtifactType, uid: string) {
    if (!session) {
      return;
    }

    try {
      const path = type === "rule" ? `/api/rules/${encodeURIComponent(uid)}/submit` : `/api/packs/${encodeURIComponent(uid)}/submit`;
      await apiPost(path, session);
      setToast(type === "rule" ? "Rule submitted for review." : "Pack submitted for review.");
      await loadMine(session);
    } catch (error) {
      setPrivateError(errorMessage(error, "Submit failed."));
    }
  }

  async function reviewArtifact(item: ReviewItem, action: "approve" | "needs-changes", notes: string) {
    if (!session || session.role !== "admin") {
      return;
    }

    try {
      const plural = item.artifactType === "rule" ? "rules" : "packs";
      const path = `/api/admin/${plural}/${encodeURIComponent(item.uid)}/versions/${item.version}/${action}`;
      await apiPost(path, session, action === "needs-changes" ? { notes } : undefined);
      setToast(action === "approve" ? "Submission approved." : "Submission sent back.");
      await Promise.all([loadReviews(session), loadPublic(), loadMine(session)]);
    } catch (error) {
      setPrivateError(errorMessage(error, "Review action failed."));
    }
  }

  async function createRule(input: RuleDraftInput) {
    if (!session) {
      return;
    }

    try {
      await apiPost("/api/rules", session, input);
      setToast("Rule draft created.");
      await loadMine(session);
    } catch (error) {
      setPrivateError(errorMessage(error, "Rule draft could not be created."));
    }
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

          <nav className="top-nav" aria-label="Primary">
            <button className={navClass(view, "library")} onClick={() => navigate("library")} type="button">Library</button>
            <button className={navClass(view, "creator")} onClick={() => navigate("creator")} type="button">My Work</button>
            {session?.role === "admin" ? (
              <button className={navClass(view, "admin")} onClick={() => navigate("admin")} type="button">Review</button>
            ) : null}
          </nav>

          <div className="header-actions">
            {session ? (
              <button className="button button-secondary compact-button" onClick={signOut} type="button">
                Sign out
              </button>
            ) : null}
            <a className="button button-primary install-button" href={installURL} target="_blank" rel="noreferrer">
              <span className="install-icon" aria-hidden="true">v</span>
              Install on macOS
            </a>
          </div>
        </div>
      </header>

      <main className="app-main page-container">
        {view === "library" ? (
          <LibraryView
            error={publicError}
            isLoading={isLoadingPublic}
            onOpen={openDetail}
            onRetry={() => void loadPublic()}
            packs={publicPacks}
            rules={publicRules}
          />
        ) : null}

        {view === "creator" ? (
          <CreatorView
            error={privateError}
            isLoading={isLoadingMine}
            onCreateRule={(input) => void createRule(input)}
            onOpen={openDetail}
            onRefresh={() => session ? void loadMine(session) : undefined}
            onSession={handleSession}
            onSubmit={(type, uid) => void submitArtifact(type, uid)}
            packs={myPacks}
            rules={myRules}
            session={session}
          />
        ) : null}

        {view === "admin" ? (
          <AdminView
            error={privateError}
            isLoading={isLoadingReviews}
            onRefresh={() => session ? void loadReviews(session) : undefined}
            onReview={(item, action, notes) => void reviewArtifact(item, action, notes)}
            onSession={handleSession}
            reviews={reviews}
            session={session}
          />
        ) : null}
      </main>

      {focused ? (
        <ArtifactDetails
          focused={focused}
          isLoading={detailStatus === "loading"}
          isMissing={detailStatus === "missing"}
          onClose={closeDetail}
          pack={focusedPack}
          rule={focusedRule}
        />
      ) : null}

      {toast ? <div className="toast" role="status">{toast}</div> : null}
    </div>
  );
}

function LibraryView({
  error,
  isLoading,
  onOpen,
  onRetry,
  packs,
  rules
}: {
  error: string | null;
  isLoading: boolean;
  onOpen: (focused: FocusedArtifact) => void;
  onRetry: () => void;
  packs: Pack[];
  rules: Rule[];
}) {
  return (
    <div className="view-stack">
      <section className="hero-strip">
        <div>
          <p className="eyebrow">Public Library</p>
          <h1>Rules and Packs</h1>
        </div>
        <p>Reviewed behavior patterns for workspaces.</p>
      </section>

      {error ? (
        <StatusPanel actionLabel="Retry" message={error} onAction={onRetry} tone="danger" title="Library unavailable" />
      ) : null}

      <ArtifactSection
        emptyMessage="No public rules have been approved yet."
        isLoading={isLoading}
        onOpen={onOpen}
        rules={rules}
        title="Latest Rules"
      />
      <ArtifactSection
        emptyMessage="No public packs have been approved yet."
        isLoading={isLoading}
        onOpen={onOpen}
        packs={packs}
        title="Latest Packs"
      />
    </div>
  );
}

function CreatorView({
  error,
  isLoading,
  onCreateRule,
  onOpen,
  onRefresh,
  onSession,
  onSubmit,
  packs,
  rules,
  session
}: {
  error: string | null;
  isLoading: boolean;
  onCreateRule: (input: RuleDraftInput) => void;
  onOpen: (focused: FocusedArtifact) => void;
  onRefresh: () => void;
  onSession: (session: Session) => void;
  onSubmit: (type: ArtifactType, uid: string) => void;
  packs: Pack[];
  rules: Rule[];
  session: Session | null;
}) {
  if (!session) {
    return <AuthGate onSession={onSession} title="Sign in" />;
  }

  return (
    <div className="view-stack">
      <section className="section-heading">
        <div>
          <p className="eyebrow">Creator</p>
          <h1>My Rules and Packs</h1>
        </div>
        <button className="button button-secondary compact-button" onClick={onRefresh} type="button">Refresh</button>
      </section>

      {error ? <StatusPanel message={error} tone="danger" title="Could not load your work" /> : null}

      <LifecycleSummary rules={rules} packs={packs} />
      <RuleDraftForm onCreate={onCreateRule} />

      <ArtifactSection
        emptyMessage={isLoading ? "Loading your rules." : "You have no rules yet."}
        isLoading={isLoading}
        mine
        onOpen={onOpen}
        onSubmit={onSubmit}
        rules={rules}
        title="My Rules"
      />
      <ArtifactSection
        emptyMessage={isLoading ? "Loading your packs." : "You have no packs yet."}
        isLoading={isLoading}
        mine
        onOpen={onOpen}
        onSubmit={onSubmit}
        packs={packs}
        title="My Packs"
      />
    </div>
  );
}

function AdminView({
  error,
  isLoading,
  onRefresh,
  onReview,
  onSession,
  reviews,
  session
}: {
  error: string | null;
  isLoading: boolean;
  onRefresh: () => void;
  onReview: (item: ReviewItem, action: "approve" | "needs-changes", notes: string) => void;
  onSession: (session: Session) => void;
  reviews: ReviewItem[];
  session: Session | null;
}) {
  if (!session) {
    return <AuthGate onSession={onSession} title="Admin sign in" />;
  }

  if (session.role !== "admin") {
    return <StatusPanel message="Admin access is required." tone="danger" title="Not authorized" />;
  }

  return (
    <div className="view-stack">
      <section className="section-heading">
        <div>
          <p className="eyebrow">Admin</p>
          <h1>Review Queue</h1>
        </div>
        <button className="button button-secondary compact-button" onClick={onRefresh} type="button">Refresh</button>
      </section>

      {error ? <StatusPanel message={error} tone="danger" title="Review queue unavailable" /> : null}
      {isLoading && reviews.length === 0 ? <StatusPanel message="Loading submitted rules and packs." title="Loading queue" /> : null}
      {!isLoading && reviews.length === 0 ? <StatusPanel message="No submitted rules or packs are waiting." title="Queue empty" /> : null}

      <div className="review-list">
        {reviews.map((item) => (
          <ReviewRow item={item} key={`${item.artifactType}:${item.uid}:${item.version}`} onReview={onReview} />
        ))}
      </div>
    </div>
  );
}

function ArtifactSection({
  emptyMessage,
  isLoading,
  mine = false,
  onOpen,
  onSubmit,
  packs,
  rules,
  title
}: {
  emptyMessage: string;
  isLoading: boolean;
  mine?: boolean;
  onOpen: (focused: FocusedArtifact) => void;
  onSubmit?: (type: ArtifactType, uid: string) => void;
  packs?: Pack[];
  rules?: Rule[];
  title: string;
}) {
  const artifacts = [
    ...(rules ?? []).map((rule) => ({ type: "rule" as const, value: rule })),
    ...(packs ?? []).map((pack) => ({ type: "pack" as const, value: pack }))
  ];

  return (
    <section className="artifact-section">
      <div className="section-title-row">
        <h2>{title}</h2>
        <span>{artifacts.length}</span>
      </div>

      {isLoading && artifacts.length === 0 ? <StatusPanel message="Loading." title={title} /> : null}
      {!isLoading && artifacts.length === 0 ? <StatusPanel message={emptyMessage} title="Nothing here yet" /> : null}

      <div className="artifact-grid">
        {artifacts.map((artifact) => artifact.type === "rule" ? (
          <RuleCard
            key={`rule:${artifact.value.uid}:${artifact.value.version}`}
            mine={mine}
            onOpen={() => onOpen({ type: "rule", uid: artifact.value.uid, version: artifact.value.version })}
            onSubmit={onSubmit ? () => onSubmit("rule", artifact.value.uid) : undefined}
            rule={artifact.value}
          />
        ) : (
          <PackCard
            key={`pack:${artifact.value.uid}:${artifact.value.version}`}
            mine={mine}
            onOpen={() => onOpen({ type: "pack", uid: artifact.value.uid, version: artifact.value.version })}
            onSubmit={onSubmit ? () => onSubmit("pack", artifact.value.uid) : undefined}
            pack={artifact.value}
          />
        ))}
      </div>
    </section>
  );
}

function RuleCard({
  mine,
  onOpen,
  onSubmit,
  rule
}: {
  mine: boolean;
  onOpen: () => void;
  onSubmit?: () => void;
  rule: Rule;
}) {
  return (
    <article className="artifact-card">
      <button className="card-main" onClick={onOpen} type="button">
        <span className="card-kicker">
          <span className={`state-pill state-${rule.lifecycleState}`}>{stateLabel(rule.lifecycleState)}</span>
          <span>Rule v{rule.version}</span>
        </span>
        <span className="card-title">{rule.name}</span>
        <span className="card-description">{rule.description}</span>
        <span className="card-meta">Applies when: {rule.appliesWhen}</span>
      </button>

      <CardFooter
        artifactType="rule"
        mine={mine}
        onSubmit={onSubmit}
        ownerEmail={rule.ownerEmail}
        reviewNotes={rule.reviewNotes}
        state={rule.lifecycleState}
        starCount={rule.starCount}
        uid={rule.uid}
      />
    </article>
  );
}

function PackCard({
  mine,
  onOpen,
  onSubmit,
  pack
}: {
  mine: boolean;
  onOpen: () => void;
  onSubmit?: () => void;
  pack: Pack;
}) {
  return (
    <article className="artifact-card">
      <button className="card-main" onClick={onOpen} type="button">
        <span className="card-kicker">
          <span className={`state-pill state-${pack.lifecycleState}`}>{stateLabel(pack.lifecycleState)}</span>
          <span>Pack v{pack.version}</span>
        </span>
        <span className="card-title">{pack.name}</span>
        <span className="card-description">{pack.description}</span>
        <span className="card-meta">{pack.rules.length} pinned rule{pack.rules.length === 1 ? "" : "s"}</span>
      </button>

      <CardFooter
        artifactType="pack"
        mine={mine}
        onSubmit={onSubmit}
        ownerEmail={pack.ownerEmail}
        reviewNotes={pack.reviewNotes}
        state={pack.lifecycleState}
        uid={pack.uid}
      />
    </article>
  );
}

function CardFooter({
  artifactType,
  mine,
  onSubmit,
  ownerEmail,
  reviewNotes,
  starCount,
  state,
  uid
}: {
  artifactType: ArtifactType;
  mine: boolean;
  onSubmit?: () => void;
  ownerEmail: string;
  reviewNotes: string | null;
  starCount?: number;
  state: LifecycleState;
  uid: string;
}) {
  return (
    <footer className="card-footer">
      <span className="owner-text">{ownerEmail}</span>
      <div className="card-actions">
        {artifactType === "rule" && starCount !== undefined ? <span className="score-pill">{formatNumber(starCount)} stars</span> : null}
        {artifactType === "rule" ? (
          <a className="small-link" href={macOpenURL(uid)} target="_blank" rel="noreferrer">Open on macOS</a>
        ) : null}
        {mine && reviewNotes ? <span className="notes-flag">Notes</span> : null}
        {mine && isSubmittable(state) && onSubmit ? (
          <button className="button button-secondary compact-button" onClick={onSubmit} type="button">Submit</button>
        ) : null}
      </div>
    </footer>
  );
}

function ArtifactDetails({
  focused,
  isLoading,
  isMissing,
  onClose,
  pack,
  rule
}: {
  focused: FocusedArtifact;
  isLoading: boolean;
  isMissing: boolean;
  onClose: () => void;
  pack: Pack | null;
  rule: Rule | null;
}) {
  const [bodyOpen, setBodyOpen] = useState(false);
  const [shareStatus, setShareStatus] = useState<"idle" | "copied" | "shared">("idle");

  useEffect(() => {
    setBodyOpen(false);
    setShareStatus("idle");
  }, [focused.type, focused.uid, focused.version]);

  useEffect(() => {
    if (shareStatus === "idle") {
      return;
    }

    const timeoutId = window.setTimeout(() => setShareStatus("idle"), 1800);
    return () => window.clearTimeout(timeoutId);
  }, [shareStatus]);

  const artifact = focused.type === "rule" ? rule : pack;
  const title = artifact?.name ?? (isMissing ? "Not found" : "Loading");

  async function shareArtifact() {
    if (!artifact) {
      return;
    }

    const shareURL = new URL(artifactPath(focused), window.location.origin).toString();
    try {
      if (typeof navigator.share === "function") {
        await navigator.share({ title: artifact.name, text: artifact.description, url: shareURL });
        setShareStatus("shared");
        return;
      }

      await copyToClipboard(shareURL);
      setShareStatus("copied");
    } catch {
      setShareStatus("idle");
    }
  }

  return (
    <div
      className="detail-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) {
          onClose();
        }
      }}
    >
      <section className="detail-window" role="dialog" aria-modal="true" aria-labelledby="artifact-detail-title">
        <button className="icon-button close-button" onClick={onClose} type="button" aria-label="Close details">x</button>

        {artifact && focused.type === "rule" && rule ? (
          <>
            <DetailHeading artifactType="Rule" name={rule.name} state={rule.lifecycleState} version={rule.version} />
            <p className="detail-description">{rule.description}</p>

            <DetailBlock title="Applies when">
              <p>{rule.appliesWhen}</p>
            </DetailBlock>

            {rule.reviewNotes ? (
              <DetailBlock title="Review notes">
                <p>{rule.reviewNotes}</p>
              </DetailBlock>
            ) : null}

            {bodyOpen ? (
              <DetailBlock title="Advanced Markdown">
                <pre>{rule.body || "Rule body is empty."}</pre>
              </DetailBlock>
            ) : null}

            <DetailFooter
              bodyOpen={bodyOpen}
              onBodyToggle={() => setBodyOpen((current) => !current)}
              onShare={() => void shareArtifact()}
              ownerEmail={rule.ownerEmail}
              shareLabel={shareStatus === "copied" ? "Copied" : shareStatus === "shared" ? "Shared" : "Share"}
              uid={rule.uid}
            />
          </>
        ) : artifact && focused.type === "pack" && pack ? (
          <>
            <DetailHeading artifactType="Pack" name={pack.name} state={pack.lifecycleState} version={pack.version} />
            <p className="detail-description">{pack.description}</p>

            <div className="detail-grid">
              <DetailBlock title="Audience">
                <p>{pack.audience}</p>
              </DetailBlock>
              <DetailBlock title="Workspace">
                <p>{pack.suggestedWorkspaceType}</p>
              </DetailBlock>
            </div>

            {pack.releaseNotes ? (
              <DetailBlock title="Release notes">
                <p>{pack.releaseNotes}</p>
              </DetailBlock>
            ) : null}

            {pack.reviewNotes ? (
              <DetailBlock title="Review notes">
                <p>{pack.reviewNotes}</p>
              </DetailBlock>
            ) : null}

            <DetailBlock title="Pinned rule versions">
              <div className="pinned-list">
                {pack.rules.map((ref) => (
                  <div className="pinned-row" key={`${ref.uid}:${ref.version}`}>
                    <div>
                      <strong>{ref.name}</strong>
                      <span>{ref.uid}</span>
                    </div>
                    <div>
                      <span className={`state-pill state-${ref.lifecycleState}`}>{stateLabel(ref.lifecycleState)}</span>
                      <span>v{ref.version}</span>
                    </div>
                  </div>
                ))}
              </div>
            </DetailBlock>

            {Object.keys(pack.compatibility).length > 0 ? (
              <DetailBlock title="Compatibility">
                <div className="chip-row">
                  {Object.entries(pack.compatibility).map(([key, value]) => (
                    <span className="chip" key={key}>{key}: {String(value)}</span>
                  ))}
                </div>
              </DetailBlock>
            ) : null}

            <footer className="detail-footer">
              <p className="detail-owner">Created by {pack.ownerEmail}</p>
              <div className="detail-actions">
                <button className="button button-primary share-button" onClick={() => void shareArtifact()} type="button">
                  {shareStatus === "copied" ? "Copied" : shareStatus === "shared" ? "Shared" : "Share"}
                </button>
              </div>
            </footer>
          </>
        ) : (
          <div className="detail-empty">
            <h2 id="artifact-detail-title">{title}</h2>
            <p>
              {isMissing
                ? "That item is not available."
                : isLoading
                  ? "Loading details."
                  : "Preparing details."}
            </p>
          </div>
        )}
      </section>
    </div>
  );
}

function DetailHeading({
  artifactType,
  name,
  state,
  version
}: {
  artifactType: string;
  name: string;
  state: LifecycleState;
  version: number;
}) {
  return (
    <div className="detail-heading">
      <p className="card-kicker">
        <span className={`state-pill state-${state}`}>{stateLabel(state)}</span>
        <span>{artifactType} v{version}</span>
      </p>
      <h2 id="artifact-detail-title">{name}</h2>
    </div>
  );
}

function DetailBlock({ children, title }: { children: React.ReactNode; title: string }) {
  return (
    <section className="detail-section">
      <h3>{title}</h3>
      {children}
    </section>
  );
}

function DetailFooter({
  bodyOpen,
  onBodyToggle,
  onShare,
  ownerEmail,
  shareLabel,
  uid
}: {
  bodyOpen: boolean;
  onBodyToggle: () => void;
  onShare: () => void;
  ownerEmail: string;
  shareLabel: string;
  uid: string;
}) {
  return (
    <footer className="detail-footer">
      <p className="detail-owner">Created by {ownerEmail}</p>
      <div className="detail-actions">
        <a className="button button-secondary spec-button" href={macOpenURL(uid)} target="_blank" rel="noreferrer">
          Open on macOS
        </a>
        <button className="button button-secondary spec-button" onClick={onBodyToggle} type="button">
          {bodyOpen ? "Hide Markdown" : "Markdown"}
        </button>
        <button className="button button-primary share-button" onClick={onShare} type="button">
          {shareLabel}
        </button>
      </div>
    </footer>
  );
}

function LifecycleSummary({ packs, rules }: { packs: Pack[]; rules: Rule[] }) {
  const artifacts = [...rules, ...packs];
  const states: LifecycleState[] = ["draft", "submitted_for_review", "needs_changes", "approved"];

  return (
    <section className="summary-grid">
      {states.map((state) => (
        <div className="summary-tile" key={state}>
          <span>{stateLabel(state)}</span>
          <strong>{artifacts.filter((artifact) => artifact.lifecycleState === state).length}</strong>
        </div>
      ))}
    </section>
  );
}

type RuleDraftInput = {
  name: string;
  description: string;
  appliesWhen: string;
  file: string;
  body: string;
};

function RuleDraftForm({ onCreate }: { onCreate: (input: RuleDraftInput) => void }) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [appliesWhen, setAppliesWhen] = useState("");
  const [body, setBody] = useState("");

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    onCreate({
      name,
      description,
      appliesWhen,
      file: "SPEC.md",
      body
    });
    setName("");
    setDescription("");
    setAppliesWhen("");
    setBody("");
  }

  return (
    <form className="draft-form" onSubmit={handleSubmit}>
      <div className="section-title-row">
        <h2>New Rule Draft</h2>
      </div>
      <label>
        Name
        <input required maxLength={120} onChange={(event) => setName(event.target.value)} value={name} />
      </label>
      <label>
        Description
        <textarea required maxLength={500} onChange={(event) => setDescription(event.target.value)} rows={2} value={description} />
      </label>
      <label>
        Applies when
        <textarea required maxLength={1000} onChange={(event) => setAppliesWhen(event.target.value)} rows={2} value={appliesWhen} />
      </label>
      <label>
        Advanced Markdown
        <textarea required maxLength={50000} onChange={(event) => setBody(event.target.value)} rows={7} value={body} />
      </label>
      <button className="button button-primary compact-button" type="submit">Create draft</button>
    </form>
  );
}

function AuthGate({ onSession, title }: { onSession: (session: Session) => void; title: string }) {
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [hasRequestedCode, setHasRequestedCode] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function requestCode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setIsSubmitting(true);
    setError(null);

    try {
      await apiPost("/api/auth/request-otp", null, { email });
      setHasRequestedCode(true);
    } catch (requestError) {
      setError(errorMessage(requestError, "Sign-in code could not be sent."));
    } finally {
      setIsSubmitting(false);
    }
  }

  async function verifyCode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setIsSubmitting(true);
    setError(null);

    try {
      const session = await apiPost<Session>("/api/auth/verify-otp", null, { email, code });
      onSession(session);
    } catch (verifyError) {
      setError(errorMessage(verifyError, "Sign in failed."));
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <section className="auth-panel">
      <div className="section-heading">
        <div>
          <p className="eyebrow">Account</p>
          <h1>{title}</h1>
        </div>
      </div>

      {error ? <StatusPanel message={error} tone="danger" title="Authentication error" /> : null}

      {!hasRequestedCode ? (
        <form className="auth-form" onSubmit={requestCode}>
          <label>
            Email
            <input autoComplete="email" inputMode="email" onChange={(event) => setEmail(event.target.value)} required type="email" value={email} />
          </label>
          <button className="button button-primary" disabled={isSubmitting} type="submit">
            {isSubmitting ? "Sending" : "Send code"}
          </button>
        </form>
      ) : (
        <form className="auth-form" onSubmit={verifyCode}>
          <label>
            Code
            <input autoComplete="one-time-code" inputMode="numeric" maxLength={6} onChange={(event) => setCode(event.target.value)} required value={code} />
          </label>
          <button className="button button-primary" disabled={isSubmitting} type="submit">
            {isSubmitting ? "Checking" : "Sign in"}
          </button>
        </form>
      )}
    </section>
  );
}

function ReviewRow({
  item,
  onReview
}: {
  item: ReviewItem;
  onReview: (item: ReviewItem, action: "approve" | "needs-changes", notes: string) => void;
}) {
  const [notes, setNotes] = useState("");

  return (
    <article className="review-card">
      <div className="review-copy">
        <p className="card-kicker">
          <span>{item.artifactType === "rule" ? "Rule" : "Pack"} v{item.version}</span>
          <span>{formatDate(item.submittedAt)}</span>
        </p>
        <h2>{item.name}</h2>
        <p>{item.ownerEmail}</p>
      </div>
      <label>
        Notes
        <textarea onChange={(event) => setNotes(event.target.value)} rows={3} value={notes} />
      </label>
      <div className="review-actions">
        <button className="button button-secondary compact-button" onClick={() => onReview(item, "needs-changes", notes)} type="button">
          Needs Changes
        </button>
        <button className="button button-primary compact-button" onClick={() => onReview(item, "approve", notes)} type="button">
          Approve
        </button>
      </div>
    </article>
  );
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
        <button className="button button-secondary compact-button" onClick={onAction} type="button">
          {actionLabel}
        </button>
      ) : null}
    </section>
  );
}

function navClass(current: View, expected: View): string {
  return `nav-button${current === expected ? " is-active" : ""}`;
}

function routeFromLocation(): RouteState {
  const ruleMatch = window.location.pathname.match(/^\/(?:rules|spell)\/([^/]+)(?:\/versions\/(\d+))?\/?$/);
  if (ruleMatch?.[1]) {
    return {
      view: "library",
      focused: {
        type: "rule",
        uid: decodeURLPart(ruleMatch[1]) ?? ruleMatch[1],
        version: ruleMatch[2] ? Number(ruleMatch[2]) : undefined
      }
    };
  }

  const packMatch = window.location.pathname.match(/^\/packs\/([^/]+)(?:\/versions\/(\d+))?\/?$/);
  if (packMatch?.[1]) {
    return {
      view: "library",
      focused: {
        type: "pack",
        uid: decodeURLPart(packMatch[1]) ?? packMatch[1],
        version: packMatch[2] ? Number(packMatch[2]) : undefined
      }
    };
  }

  const viewParam = new URLSearchParams(window.location.search).get("view");
  return {
    view: viewParam === "creator" || viewParam === "admin" ? viewParam : "library",
    focused: null
  };
}

function artifactPath(focused: FocusedArtifact): string {
  const base = focused.type === "rule" ? "rules" : "packs";
  const version = focused.version ? `/versions/${focused.version}` : "";
  return `/${base}/${encodeURIComponent(focused.uid)}${version}`;
}

function macOpenURL(uid: string): string {
  return apiEndpoint(`/open/${encodeURIComponent(uid)}`);
}

function decodeURLPart(value: string): string | null {
  try {
    return decodeURIComponent(value).trim() || null;
  } catch {
    return value.trim() || null;
  }
}

function readStoredSession(): Session | null {
  try {
    const raw = localStorage.getItem(sessionStorageKey);
    if (!raw) {
      return null;
    }

    const parsed = JSON.parse(raw) as Session;
    if (!parsed.token || !parsed.email || new Date(parsed.expiresAt).getTime() <= Date.now()) {
      localStorage.removeItem(sessionStorageKey);
      return null;
    }

    return parsed;
  } catch {
    localStorage.removeItem(sessionStorageKey);
    return null;
  }
}

function findRule(rules: Rule[], uid: string, version?: number): Rule | null {
  return rules.find((rule) => rule.uid === uid && (!version || rule.version === version)) ?? null;
}

function findPack(packs: Pack[], uid: string, version?: number): Pack | null {
  return packs.find((pack) => pack.uid === uid && (!version || pack.version === version)) ?? null;
}

function mergeRule(rules: Rule[], nextRule: Rule): Rule[] {
  const exists = rules.some((rule) => rule.uid === nextRule.uid && rule.version === nextRule.version);
  return exists
    ? rules.map((rule) => rule.uid === nextRule.uid && rule.version === nextRule.version ? nextRule : rule)
    : [nextRule, ...rules];
}

function mergePack(packs: Pack[], nextPack: Pack): Pack[] {
  const exists = packs.some((pack) => pack.uid === nextPack.uid && pack.version === nextPack.version);
  return exists
    ? packs.map((pack) => pack.uid === nextPack.uid && pack.version === nextPack.version ? nextPack : pack)
    : [nextPack, ...packs];
}

function stateLabel(state: LifecycleState): string {
  switch (state) {
    case "draft":
      return "Draft";
    case "submitted_for_review":
      return "In Review";
    case "needs_changes":
      return "Needs Changes";
    case "approved":
      return "Approved";
    case "withdrawn":
      return "Withdrawn";
    case "archived":
      return "Archived";
  }
}

function isSubmittable(state: LifecycleState): boolean {
  return state === "draft" || state === "submitted_for_review" || state === "needs_changes";
}

function formatDate(value: string | null): string {
  if (!value) {
    return "Not submitted";
  }

  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function formatNumber(value: number): string {
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(value);
}

function apiEndpoint(path: string): string {
  return new URL(path, apiURL).toString();
}

async function apiGet<T>(path: string, session: Session | null): Promise<T> {
  return apiRequest<T>(path, { method: "GET" }, session);
}

async function apiPost<T = unknown>(path: string, session: Session | null, body?: unknown): Promise<T> {
  return apiRequest<T>(path, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) }, session);
}

async function apiRequest<T>(path: string, init: RequestInit, session: Session | null): Promise<T> {
  const headers = new Headers(init.headers);

  if (init.body !== undefined) {
    headers.set("Content-Type", "application/json");
  }
  if (session) {
    headers.set("Authorization", `Bearer ${session.token}`);
  }

  const response = await fetch(apiEndpoint(path), { ...init, headers });
  const json = await readResponseJson(response);
  if (!response.ok) {
    throw new Error(apiErrorMessage(json) ?? `Request failed with status ${response.status}.`);
  }

  return json as T;
}

async function readResponseJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (!text) {
    return {};
  }

  try {
    return JSON.parse(text);
  } catch {
    return {};
  }
}

function apiErrorMessage(value: unknown): string | null {
  if (value && typeof value === "object" && "error" in value) {
    const error = (value as { error?: unknown }).error;
    if (typeof error === "string") {
      return error;
    }
  }

  return null;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
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
