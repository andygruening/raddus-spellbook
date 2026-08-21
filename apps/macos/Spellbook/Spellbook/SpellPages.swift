import AppKit
import SwiftUI

struct LocalSpellsView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @EnvironmentObject private var sessionModel: SessionModel
    @EnvironmentObject private var deepLinkModel: DeepLinkModel
    @State private var editingSpell: Spell?
    @State private var viewingPublicRule: Spell?
    @State private var isShowingNewSpellForm = false
    @State private var errorMessage: String?
    @State private var publishedSpellsByUID: [String: Spell] = [:]
    @State private var workingStarIds: Set<String> = []

    var body: some View {
        PageContainer(
            title: "Rules",
            subtitle: "My Rules, drafts, review state, public rules, and installed local rules."
        ) {
            HStack(spacing: 8) {
                Button {
                    isShowingNewSpellForm = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .help("Create rule draft")

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .help("Refresh")
            }
        } content: {
            if localStore.latestSpells.isEmpty {
                EmptyState(title: "No installed rules", message: "Create a rule draft or install an approved public rule.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(localStore.latestSpells) { spell in
                            let displaySpell = displaySpell(for: spell)
                            SpellCard(
                                spell: displaySpell,
                                onOpen: {
                                    editingSpell = spell
                                },
                                isStarWorking: workingStarIds.contains(spell.id),
                                onStar: spell.uid == nil ? nil : {
                                    toggleStar(spell)
                                },
                                showsLiveBadge: spell.uid != nil
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .spellbookErrorAlert(message: $errorMessage)
        .sheet(isPresented: $isShowingNewSpellForm) {
            SpellFormView(mode: .create, onSave: { spell in
                try await create(spell)
            })
        }
        .sheet(item: $editingSpell) { spell in
            SpellFormView(
                mode: .local(spell, editable: canEdit(spell)),
                onSave: canEdit(spell) ? { updatedSpell in
                    try await saveDraftFromDetail(updatedSpell, replacing: spell)
                } : nil,
                onPublish: canPublish(spell) ? { updatedSpell in
                    try await submitForReview(updatedSpell, replacing: spell)
                } : nil,
                onFinish: canFinish(spell) ? { finishingSpell in
                    try await finish(finishingSpell)
                } : nil
            )
        }
        .sheet(item: $viewingPublicRule) { spell in
            SpellFormView(
                mode: .published(spell, editable: canEdit(spell)),
                onInstall: { installedSpell in
                    try localStore.upsertLocal(installedSpell)
                    viewingPublicRule = nil
                }
            )
        }
        .onAppear {
            refresh()
            openPendingPublicRuleIfAvailable()
        }
        .onChange(of: deepLinkModel.pendingPublishedSpellID) { _ in
            openPendingPublicRuleIfAvailable()
        }
    }

    private func canPublish(_ spell: Spell) -> Bool {
        guard let email = sessionModel.signedInEmail else {
            return false
        }

        return spell.ownerEmail == nil || spell.ownerEmail == email
    }

    private func canEdit(_ spell: Spell) -> Bool {
        guard let ownerEmail = spell.ownerEmail else {
            return true
        }

        return ownerEmail == sessionModel.signedInEmail
    }

    private func refresh() {
        do {
            try localStore.refresh()
            errorMessage = nil
            loadPublishedMetadataForInstalledSpells()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveDraftFromDetail(_ spell: Spell, replacing originalSpell: Spell) async throws {
        guard let session = sessionModel.session else {
            throw SpellbookError.message("Sign in to save this rule draft.")
        }

        do {
            let remote = try await SpellbookAPI.shared.saveRuleDraft(spell: spell, token: session.token)
            try localStore.updateAfterPublish(localIdentifier: originalSpell.id, remoteSpell: remote, signedInEmail: session.email)
            if let uid = remote.uid {
                publishedSpellsByUID[uid] = remote
            }
            errorMessage = nil
            editingSpell = nil
        } catch SpellbookError.expiredSession {
            sessionModel.clearExpiredSession()
            throw SpellbookError.expiredSession
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func create(_ spell: Spell) async throws {
        guard let session = sessionModel.session else {
            throw SpellbookError.message("Sign in to create a rule draft.")
        }

        do {
            let remote = try await SpellbookAPI.shared.createRuleDraft(spell: spell, token: session.token)
            try localStore.updateAfterPublish(localIdentifier: spell.id, remoteSpell: remote, signedInEmail: session.email)
            if let uid = remote.uid {
                publishedSpellsByUID[uid] = remote
            }
            errorMessage = nil
            isShowingNewSpellForm = false
        } catch SpellbookError.expiredSession {
            sessionModel.clearExpiredSession()
            throw SpellbookError.expiredSession
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func submitForReview(_ spell: Spell, replacing originalSpell: Spell) async throws {
        guard let session = sessionModel.session else {
            throw SpellbookError.message("Sign in to submit this rule.")
        }
        guard let uid = spell.uid else {
            throw SpellbookError.message("Save this rule draft before submitting it.")
        }

        do {
            let saved = try await SpellbookAPI.shared.saveRuleDraft(spell: spell, token: session.token)
            let submitted = try await SpellbookAPI.shared.submitRuleDraft(uid: uid, version: saved.normalizedVersion, token: session.token)
            try localStore.updateAfterPublish(localIdentifier: originalSpell.id, remoteSpell: submitted, signedInEmail: session.email)
            if let uid = submitted.uid {
                publishedSpellsByUID[uid] = submitted
            }
            errorMessage = nil
            editingSpell = nil
        } catch SpellbookError.expiredSession {
            sessionModel.clearExpiredSession()
            throw SpellbookError.expiredSession
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func finish(_ spell: Spell) async throws {
        guard let session = sessionModel.session else {
            throw SpellbookError.message("Sign in to finish this rule.")
        }
        guard let uid = spell.uid else {
            throw SpellbookError.message("Only uid-backed rules can be finished.")
        }

        do {
            let remote = try await SpellbookAPI.shared.finishRule(uid: uid, version: spell.normalizedVersion, token: session.token)
            try localStore.upsertLocal(remote)
            if let uid = remote.uid {
                publishedSpellsByUID[uid] = remote
            }
            errorMessage = nil
            editingSpell = nil
        } catch SpellbookError.expiredSession {
            sessionModel.clearExpiredSession()
            throw SpellbookError.expiredSession
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func canFinish(_ spell: Spell) -> Bool {
        spell.lifecycleState == .approved
    }

    private func update(_ spell: Spell) throws {
        do {
            try localStore.updateLocal(spell)
            errorMessage = nil
            editingSpell = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func displaySpell(for spell: Spell) -> Spell {
        guard let uid = spell.uid, let remoteSpell = publishedSpellsByUID[uid] else {
            return spell
        }

        var displaySpell = spell
        displaySpell.starCount = remoteSpell.starCount
        displaySpell.starredByMe = remoteSpell.starredByMe
        displaySpell.ownerEmail = displaySpell.ownerEmail ?? remoteSpell.ownerEmail
        displaySpell.publishedAt = displaySpell.publishedAt ?? remoteSpell.publishedAt
        return displaySpell
    }

    private func loadPublishedMetadataForInstalledSpells() {
        let publishedUIDs = Set(localStore.spells.compactMap(\.uid))
        publishedSpellsByUID = publishedSpellsByUID.filter { publishedUIDs.contains($0.key) }

        guard !publishedUIDs.isEmpty else {
            return
        }

        Task {
            do {
                let publicSpells = try await SpellbookAPI.shared.publicSpells(token: sessionModel.session?.token)
                var matchingSpells = publicSpells.reduce(into: [String: Spell]()) { result, spell in
                    if let uid = spell.uid, publishedUIDs.contains(uid) {
                        result[uid] = spell
                    }
                }
                var unpublishedUIDs: Set<String> = []

                for uid in publishedUIDs.subtracting(matchingSpells.keys) {
                    do {
                        let spell = try await SpellbookAPI.shared.publicSpell(uid: uid, token: sessionModel.session?.token)
                        matchingSpells[uid] = spell
                    } catch SpellbookError.missingPublishedSpell {
                        unpublishedUIDs.insert(uid)
                    } catch SpellbookError.expiredSession {
                        throw SpellbookError.expiredSession
                    } catch {
                        continue
                    }
                }

                await MainActor.run {
                    for uid in unpublishedUIDs { publishedSpellsByUID.removeValue(forKey: uid) }
                    for (uid, spell) in matchingSpells {
                        publishedSpellsByUID[uid] = spell
                    }
                }
            } catch SpellbookError.expiredSession {
                await MainActor.run {
                    sessionModel.clearExpiredSession()
                }
            } catch {
                // Installed spells remain usable even if live star metadata cannot refresh.
            }
        }
    }

    private func toggleStar(_ spell: Spell) {
        guard let uid = spell.uid, let token = sessionModel.session?.token else {
            return
        }

        let currentSpell = displaySpell(for: spell)
        workingStarIds.insert(spell.id)
        errorMessage = nil

        Task {
            do {
                let updatedSpell = try await SpellbookAPI.shared.setStarred(uid: uid, starred: !currentSpell.starredByMe, token: token)
                await MainActor.run {
                    publishedSpellsByUID[uid] = updatedSpell
                    workingStarIds.remove(spell.id)
                }
            } catch SpellbookError.expiredSession {
                await MainActor.run {
                    workingStarIds.remove(spell.id)
                    sessionModel.clearExpiredSession()
                }
            } catch {
                await MainActor.run {
                    workingStarIds.remove(spell.id)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openPendingPublicRuleIfAvailable() {
        guard let uid = deepLinkModel.pendingPublishedSpellID else {
            return
        }

        Task {
            do {
                let rule = try await SpellbookAPI.shared.publicRule(uid: uid, token: sessionModel.session?.token)
                await MainActor.run {
                    viewingPublicRule = rule
                    deepLinkModel.pendingPublishedSpellID = nil
                }
            } catch SpellbookError.expiredSession {
                await MainActor.run {
                    sessionModel.clearExpiredSession()
                    deepLinkModel.pendingPublishedSpellID = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    deepLinkModel.pendingPublishedSpellID = nil
                }
            }
        }
    }
}

enum InstructionDetailActionStyle {
    case normal
    case prominent
}

struct InstructionDetailAction: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var role: ButtonRole?
    var style: InstructionDetailActionStyle = .normal
    var isDisabled = false
    var help: String?
    var action: (Spell) async throws -> Void
}

struct InstructionDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var spell: Spell
    var actions: [InstructionDetailAction] = []
    var onEdit: (() -> Void)?

    @State private var isRunningAction = false
    @State private var isShowingFullDescription = false
    @State private var errorMessage: String?

    private var shouldOfferFullDescription: Bool {
        spell.description.count > 90 || spell.description.contains("\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(spell.name)
                        .font(.title2.bold())
                        .textSelection(.enabled)

                    Text(spell.description)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(spell.description)

                    if shouldOfferFullDescription {
                        Button {
                            isShowingFullDescription = true
                        } label: {
                            Text("View more")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .popover(isPresented: $isShowingFullDescription, arrowEdge: .bottom) {
                            ScrollView {
                                Text(spell.description)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(14)
                            }
                            .frame(width: 360, height: 180)
                        }
                    }
                }

                Spacer(minLength: 12)

                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .labelStyle(.iconOnly)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRunningAction)
                    .help("Edit rule")
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Applies when")
                    .font(.callout.weight(.medium))

                Text(spell.trigger.isEmpty ? "Not set" : spell.trigger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
            }

            if let lifecycleState = spell.lifecycleState {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review state")
                        .font(.callout.weight(.medium))

                    HStack(spacing: 8) {
                        SpellPill(text: lifecycleState.label, tint: lifecycleState == .approved ? .green : lifecycleState == .needsChanges ? .orange : .blue)
                        if let reviewNotes = spell.reviewNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !reviewNotes.isEmpty {
                            Text(reviewNotes)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Advanced Markdown")
                    .font(.callout.weight(.medium))

                ScrollView {
                    Text(spell.content ?? "No markdown content found.")
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                }
                .frame(height: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
            }

            if spell.uid != nil || !actions.isEmpty {
                HStack(spacing: 10) {
                    if spell.uid != nil {
                        SpellShareButton(spell: spell)
                            .disabled(isRunningAction)
                    }

                    Spacer()

                    ForEach(actions) { action in
                        actionButton(action)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 660)
        .spellbookErrorAlert(message: $errorMessage)
    }

    @ViewBuilder
    private func actionButton(_ action: InstructionDetailAction) -> some View {
        if action.style == .prominent {
            Button(role: action.role) {
                run(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunningAction || action.isDisabled)
            .help(action.help ?? action.title)
        } else {
            Button(role: action.role) {
                run(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(isRunningAction || action.isDisabled)
            .help(action.help ?? action.title)
        }
    }

    private func run(_ action: InstructionDetailAction) {
        guard !action.isDisabled else {
            return
        }

        isRunningAction = true
        errorMessage = nil

        Task {
            do {
                try await action.action(spell)
                await MainActor.run {
                    isRunningAction = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRunningAction = false
                }
            }
        }
    }
}

enum SpellFormMode {
    case create
    case local(Spell, editable: Bool)
    case published(Spell, editable: Bool)

    var title: String {
        switch self {
        case .create:
            return "New Rule"
        case .local(let spell, _), .published(let spell, _):
            return spell.name
        }
    }

    var subtitle: String {
        switch self {
        case .create:
            return "Create a private backend-owned rule draft."
        case .local(let spell, _), .published(let spell, _):
            return spell.description
        }
    }

    var buttonTitle: String {
        switch self {
        case .create:
            return "Create Rule"
        case .local:
            return "Save Rule"
        case .published:
            return "Save Rule"
        }
    }

    var isEditable: Bool {
        switch self {
        case .create:
            return true
        case .local(_, let editable), .published(_, let editable):
            return editable
        }
    }

    var existingSpell: Spell? {
        switch self {
        case .create:
            return nil
        case .local(let spell, _), .published(let spell, _):
            return spell
        }
    }
}

private enum InstructionFlowStep: Int, CaseIterable, Identifiable {
    case basics
    case behavior
    case boundary
    case examples
    case preview

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .basics:
            return "Basics"
        case .behavior:
            return "Behavior"
        case .boundary:
            return "Boundary"
        case .examples:
            return "Examples"
        case .preview:
            return "Preview"
        }
    }

    var systemImage: String {
        switch self {
        case .basics:
            return "text.cursor"
        case .behavior:
            return "list.bullet.rectangle"
        case .boundary:
            return "hand.raised"
        case .examples:
            return "quote.bubble"
        case .preview:
            return "doc.plaintext"
        }
    }
}

private struct InstructionFlowView: View {
    @Environment(\.dismiss) private var dismiss

    var mode: SpellFormMode
    var onSave: ((Spell) async throws -> Void)?

    @State private var currentStep: InstructionFlowStep = .basics
    @State private var name = ""
    @State private var purpose = ""
    @State private var appliesWhen = ""
    @State private var desiredBehavior = ""
    @State private var avoidedBehavior = ""
    @State private var permissionBoundary = ""
    @State private var examples = ""
    @State private var content = ""
    @State private var isAdvancedMarkdown = false
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(
        mode: SpellFormMode,
        onSave: ((Spell) async throws -> Void)? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        let spell = mode.existingSpell
        _name = State(initialValue: spell?.name ?? "")
        _purpose = State(initialValue: spell?.description ?? "")
        _appliesWhen = State(initialValue: spell?.trigger ?? "")
        _desiredBehavior = State(initialValue: Self.section("Desired Behavior", in: spell?.content ?? ""))
        _avoidedBehavior = State(initialValue: Self.section("Avoided Behavior", in: spell?.content ?? ""))
        _permissionBoundary = State(initialValue: Self.section("Permission Boundary", in: spell?.content ?? ""))
        _examples = State(initialValue: Self.section("Examples", in: spell?.content ?? ""))
        _content = State(initialValue: spell?.content ?? "")
    }

    private var canCreate: Bool {
        !trimmed(name).isEmpty
            && !trimmed(purpose).isEmpty
            && !trimmed(appliesWhen).isEmpty
            && !trimmed(desiredBehavior).isEmpty
            && !trimmed(avoidedBehavior).isEmpty
            && !trimmed(permissionBoundary).isEmpty
            && !generatedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canMoveForward: Bool {
        switch currentStep {
        case .basics:
            return !trimmed(name).isEmpty && !trimmed(purpose).isEmpty && !trimmed(appliesWhen).isEmpty
        case .behavior:
            return !trimmed(desiredBehavior).isEmpty && !trimmed(avoidedBehavior).isEmpty
        case .boundary:
            return !trimmed(permissionBoundary).isEmpty
        case .examples:
            return true
        case .preview:
            return !generatedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var generatedContent: String {
        if isAdvancedMarkdown {
            return trimmed(content)
        }

        return Spell.generatedMarkdown(
            name: trimmed(name),
            purpose: trimmed(purpose),
            appliesWhen: trimmed(appliesWhen),
            desiredBehavior: trimmed(desiredBehavior),
            avoidedBehavior: trimmed(avoidedBehavior),
            permissionBoundary: trimmed(permissionBoundary),
            examples: trimmed(examples)
        )
    }

    private var hasPreviousStep: Bool {
        currentStep.rawValue > 0
    }

    private var hasNextStep: Bool {
        currentStep.rawValue < InstructionFlowStep.allCases.count - 1
    }

    private var canSubmit: Bool {
        mode.isEditable && canCreate && !isSaving && onSave != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.existingSpell == nil ? "New Rule" : "Edit Rule")
                        .font(.title2.bold())

                    Text(mode.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(mode.subtitle)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                .help("Close")
            }

            stepProgress

            Divider()

            stepContent
                .disabled(!mode.isEditable || isSaving)

            HStack(spacing: 10) {
                Button {
                    moveBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!hasPreviousStep || isSaving)

                Spacer()

                Text("\(currentStep.rawValue + 1) of \(InstructionFlowStep.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if hasNextStep {
                    Button {
                        moveForward()
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMoveForward || isSaving)
                } else {
                    Button {
                        submit()
                    } label: {
                        Label(mode.buttonTitle, systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
        }
        .padding(24)
        .frame(width: 660)
        .spellbookErrorAlert(message: $validationMessage)
    }

    private var stepProgress: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(Array(InstructionFlowStep.allCases.enumerated()), id: \.element.id) { index, step in
                stepMarker(for: step)

                if index < InstructionFlowStep.allCases.count - 1 {
                    Rectangle()
                        .fill(index < currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.25))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func stepMarker(for step: InstructionFlowStep) -> some View {
        let isActive = step == currentStep
        let isComplete = step.rawValue < currentStep.rawValue
        let tint = isActive || isComplete ? Color.accentColor : Color.gray.opacity(0.55)

        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tint.opacity(isActive || isComplete ? 0.18 : 0.08))
                    .frame(width: 32, height: 32)
                Circle()
                    .stroke(tint.opacity(isActive || isComplete ? 0.95 : 0.45), lineWidth: 1)
                    .frame(width: 32, height: 32)

                Image(systemName: isComplete ? "checkmark" : step.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }

            Text(step.title)
                .font(.caption2.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
        .onTapGesture {
            if step.rawValue <= currentStep.rawValue || canMoveForward {
                currentStep = step
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .basics:
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Name") {
                    TextField("Rule name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Purpose") {
                    TextField("What should this rule help with?", text: $purpose)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Applies when")
                        .font(.callout.weight(.medium))
                    TextEditor(text: $appliesWhen)
                        .font(.body)
                        .frame(height: 92)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
                }
            }
        case .behavior:
            VStack(alignment: .leading, spacing: 12) {
                Text("Desired Behavior")
                    .font(.callout.weight(.medium))
                TextEditor(text: $desiredBehavior)
                    .font(.body)
                    .frame(height: 110)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))

                Text("Avoided Behavior")
                    .font(.callout.weight(.medium))
                TextEditor(text: $avoidedBehavior)
                    .font(.body)
                    .frame(height: 110)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
            }
        case .boundary:
            VStack(alignment: .leading, spacing: 6) {
                Text("Permission Boundary")
                    .font(.callout.weight(.medium))
                TextEditor(text: $permissionBoundary)
                    .font(.body)
                    .frame(height: 190)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
            }
        case .examples:
            VStack(alignment: .leading, spacing: 6) {
                Text("Examples")
                    .font(.callout.weight(.medium))
                TextEditor(text: $examples)
                    .font(.body)
                    .frame(height: 220)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
            }
        case .preview:
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Advanced Markdown", isOn: $isAdvancedMarkdown)
                    .toggleStyle(.checkbox)

                Text(isAdvancedMarkdown ? "Advanced Markdown" : "Preview")
                    .font(.callout.weight(.medium))
                TextEditor(text: isAdvancedMarkdown ? $content : .constant(generatedContent))
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 260)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
            }
        }
    }

    private func moveBack() {
        guard let previousStep = InstructionFlowStep(rawValue: currentStep.rawValue - 1) else {
            return
        }

        currentStep = previousStep
    }

    private func moveForward() {
        guard canMoveForward,
              let nextStep = InstructionFlowStep(rawValue: currentStep.rawValue + 1) else {
            return
        }

        currentStep = nextStep
    }

    private func submit() {
        guard mode.isEditable, let onSave else {
            return
        }

        guard let spell = draftSpell() else {
            return
        }

        isSaving = true
        validationMessage = nil

        Task {
            do {
                try await onSave(spell)
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    validationMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }

    private func draftSpell() -> Spell? {
        guard canCreate else {
            validationMessage = "Fill in Purpose, Applies when, Desired Behavior, Avoided Behavior, Permission Boundary, and Preview."
            return nil
        }

        let existing = mode.existingSpell
        return Spell(
            uid: existing?.uid,
            localID: nil,
            name: trimmed(name),
            description: trimmed(purpose),
            trigger: trimmed(appliesWhen),
            file: existing?.file ?? "",
            content: generatedContent,
            version: existing?.version ?? 1,
            ownerEmail: existing?.ownerEmail,
            publishedAt: existing?.publishedAt,
            starCount: existing?.starCount ?? 0,
            starredByMe: existing?.starredByMe ?? false,
            lifecycleState: existing?.lifecycleState ?? .draft,
            reviewNotes: existing?.reviewNotes
        )
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func section(_ heading: String, in markdown: String) -> String {
        var isCollecting = false
        var lines: [String] = []

        for line in markdown.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("#") {
                let headingText = String(trimmedLine.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)
                if isCollecting {
                    break
                }
                if headingText.caseInsensitiveCompare(heading) == .orderedSame {
                    isCollecting = true
                }
                continue
            }

            if isCollecting {
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SpellFormView: View {
    @EnvironmentObject private var localStore: LocalSpellStore

    var mode: SpellFormMode
    var onSave: ((Spell) async throws -> Void)?
    var onPublish: ((Spell) async throws -> Void)?
    var onFinish: ((Spell) async throws -> Void)?
    var onInstall: ((Spell) throws -> Void)?
    var onDelete: ((Spell) async throws -> Void)?

    @State private var isShowingEditFlow = false

    init(
        mode: SpellFormMode,
        onSave: ((Spell) async throws -> Void)? = nil,
        onPublish: ((Spell) async throws -> Void)? = nil,
        onFinish: ((Spell) async throws -> Void)? = nil,
        onInstall: ((Spell) throws -> Void)? = nil,
        onDelete: ((Spell) async throws -> Void)? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onPublish = onPublish
        self.onFinish = onFinish
        self.onInstall = onInstall
        self.onDelete = onDelete
    }

    var body: some View {
        if let existingSpell = mode.existingSpell {
            InstructionDetailView(
                spell: existingSpell,
                actions: detailActions(for: existingSpell),
                onEdit: mode.isEditable && onSave != nil ? {
                    isShowingEditFlow = true
                } : nil
            )
            .sheet(isPresented: $isShowingEditFlow) {
                InstructionFlowView(mode: mode, onSave: onSave)
            }
        } else {
            InstructionFlowView(mode: mode, onSave: onSave)
        }
    }

    private func detailActions(for spell: Spell) -> [InstructionDetailAction] {
        var actions: [InstructionDetailAction] = []

        if let onDelete {
            actions.append(InstructionDetailAction(
                title: "Remove",
                systemImage: "trash",
                role: .destructive,
                action: { deletingSpell in
                    try await onDelete(deletingSpell)
                }
            ))
        }

        if let onInstall {
            actions.append(InstructionDetailAction(
                title: "Install Locally",
                systemImage: "square.and.arrow.down",
                role: nil,
                style: .prominent,
                action: { installedSpell in
                    try onInstall(installedSpell)
                }
            ))
        }

        if let onPublish {
            actions.append(InstructionDetailAction(
                title: "Submit for Review",
                systemImage: "icloud.and.arrow.up",
                role: nil,
                action: { publishingSpell in
                    try await onPublish(publishingSpell)
                }
            ))
        }

        if let onFinish {
            actions.append(InstructionDetailAction(
                title: "Finish",
                systemImage: "checkmark.seal",
                role: nil,
                style: .prominent,
                action: { finishingSpell in
                    try await onFinish(finishingSpell)
                }
            ))
        }

        return actions
    }

}

struct SpellMetadataValue: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpellShareButton: View {
    var spell: Spell

    var body: some View {
        if let uid = spell.uid {
            ShareLink(item: SpellbookAPI.shared.dynamicSpellLink(uid: uid)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share dynamic link")
        } else {
            Button {
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(true)
            .help("Submit and finish this rule before sharing")
        }
    }
}

struct PacksView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @EnvironmentObject private var sessionModel: SessionModel
    @State private var packs: [RulePack] = []
    @State private var expandedPackIDs: Set<String> = []
    @State private var installingPack: RulePack?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        PageContainer(title: "Packs", subtitle: "Browse approved public packs and install their pinned rule versions into a workspace.") {
            Button {
                load()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .disabled(isLoading)
            .help("Refresh")
        } content: {
            if isLoading && packs.isEmpty {
                EmptyState(title: "Loading", message: "Fetching packs.")
            } else if packs.isEmpty {
                EmptyState(title: "No packs", message: "Approved public packs will appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(packs) { pack in
                            packTile(pack)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task {
            if packs.isEmpty {
                await loadAsync()
            }
        }
        .sheet(item: $installingPack) { pack in
            PackInstallPreviewView(pack: pack)
                .environmentObject(localStore)
                .environmentObject(sessionModel)
        }
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func packTile(_ pack: RulePack) -> some View {
        let isExpanded = expandedPackIDs.contains(pack.id)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggle(pack)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)

                        Image(systemName: "shippingbox")
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(pack.name)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                SpellPill(text: "v\(pack.version)", tint: .gray)
                            }
                            Text(pack.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 12)

                        Text("\(pack.includedRules.count)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    installingPack = pack
                } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pack.includedRules.isEmpty || localStore.targets.isEmpty)
                .help(localStore.targets.isEmpty ? "Add a workspace first" : "Install pack")
            }
            .padding(12)

            if isExpanded {
                Divider()

                VStack(spacing: 0) {
                    ForEach(Array(pack.includedRules.enumerated()), id: \.element.id) { index, ruleRef in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ruleRef.name ?? ruleRef.uid)
                                    .font(.callout.weight(.medium))
                                Text(ruleRef.description ?? "\(ruleRef.uid)@\(ruleRef.version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            SpellPill(text: "v\(ruleRef.version)", tint: .gray)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if index < pack.includedRules.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18), lineWidth: 1))
    }

    private func toggle(_ pack: RulePack) {
        if expandedPackIDs.contains(pack.id) {
            expandedPackIDs.remove(pack.id)
        } else {
            expandedPackIDs.insert(pack.id)
        }
    }

    private func load() {
        Task {
            await loadAsync()
        }
    }

    private func loadAsync() async {
        isLoading = true
        errorMessage = nil

        do {
            packs = try await SpellbookAPI.shared.publicPacks(token: sessionModel.session?.token)
            isLoading = false
        } catch SpellbookError.expiredSession {
            isLoading = false
            sessionModel.clearExpiredSession()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

private enum PackRuleInstallState: Equatable {
    case exact
    case different(Int)
    case missing

    var label: String {
        switch self {
        case .exact:
            return "Exact version already installed"
        case .different(let version):
            return "Different version installed: v\(version)"
        case .missing:
            return "Missing"
        }
    }

    var tint: Color {
        switch self {
        case .exact:
            return .green
        case .different:
            return .orange
        case .missing:
            return .blue
        }
    }
}

struct PackInstallPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localStore: LocalSpellStore
    @EnvironmentObject private var sessionModel: SessionModel

    var pack: RulePack

    @State private var selectedTargetID: String?
    @State private var resolvedRules: [String: Spell] = [:]
    @State private var isLoadingRules = false
    @State private var isInstalling = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var selectedTarget: SpellbookTarget? {
        localStore.targets.first { $0.id == selectedTargetID } ?? localStore.targets.first
    }

    private var canInstall: Bool {
        selectedTarget != nil
            && !isLoadingRules
            && !isInstalling
            && pack.includedRules.allSatisfy { resolvedRules[$0.id] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install Pack")
                        .font(.title2.bold())
                    Text(pack.name)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .disabled(isInstalling)
                .help("Close")
            }

            Picker("Workspace", selection: Binding(
                get: { selectedTargetID ?? localStore.targets.first?.id ?? "" },
                set: { selectedTargetID = $0 }
            )) {
                ForEach(localStore.targets) { target in
                    Text(target.name).tag(target.id)
                }
            }
            .disabled(localStore.targets.isEmpty || isInstalling)

            if localStore.targets.isEmpty {
                EmptyState(title: "No workspaces", message: "Add a workspace before installing a pack.")
                    .frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(pack.includedRules) { ruleRef in
                            previewRow(ruleRef)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 320)
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isInstalling)

                Button {
                    install()
                } label: {
                    Label(isInstalling ? "Installing" : "Install Pack", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInstall)
            }
        }
        .padding(24)
        .frame(width: 680, height: 620)
        .onAppear {
            selectedTargetID = selectedTargetID ?? localStore.targets.first?.id
            loadRules()
        }
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func previewRow(_ ruleRef: PackRuleVersionRef) -> some View {
        let rule = resolvedRules[ruleRef.id]
        let state = installState(for: ruleRef)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(rule?.name ?? ruleRef.name ?? ruleRef.uid)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    SpellPill(text: "v\(ruleRef.version)", tint: .gray)
                }

                Text(rule?.description ?? ruleRef.description ?? ruleRef.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            SpellPill(text: state.label, tint: state.tint)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.16), lineWidth: 1))
    }

    private func installState(for ruleRef: PackRuleVersionRef) -> PackRuleInstallState {
        guard let selectedTarget,
              let installedVersion = localStore.installedVersion(uid: ruleRef.uid, in: selectedTarget) else {
            return .missing
        }

        return installedVersion == ruleRef.version ? .exact : .different(installedVersion)
    }

    private func loadRules() {
        guard !pack.includedRules.isEmpty else {
            return
        }

        isLoadingRules = true
        errorMessage = nil

        Task {
            do {
                var loaded: [String: Spell] = [:]
                for ruleRef in pack.includedRules {
                    let rule = try await SpellbookAPI.shared.publicRule(
                        uid: ruleRef.uid,
                        version: ruleRef.version,
                        token: sessionModel.session?.token
                    )
                    loaded[ruleRef.id] = rule
                }

                await MainActor.run {
                    resolvedRules = loaded
                    isLoadingRules = false
                }
            } catch SpellbookError.expiredSession {
                await MainActor.run {
                    sessionModel.clearExpiredSession()
                    isLoadingRules = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoadingRules = false
                }
            }
        }
    }

    private func install() {
        guard let selectedTarget else {
            errorMessage = "Choose a workspace."
            return
        }

        let rules = pack.includedRules.compactMap { resolvedRules[$0.id] }
        guard rules.count == pack.includedRules.count else {
            errorMessage = "Spellbook could not load every pinned rule version."
            return
        }

        isInstalling = true
        do {
            try localStore.installPackRules(rules, into: selectedTarget)
            statusMessage = localStore.statusMessage
            errorMessage = nil
            isInstalling = false
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isInstalling = false
        }
    }
}

struct PublishedSpellsView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @EnvironmentObject private var sessionModel: SessionModel
    @EnvironmentObject private var deepLinkModel: DeepLinkModel
    @State private var spells: [Spell] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var viewingSpell: Spell?
    @State private var workingStarIds: Set<String> = []

    private var filteredSpells: [Spell] {
        spells.filter { spell in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else {
                return true
            }

            let searchable = [spell.name, spell.description, spell.trigger, spell.content ?? ""]
                .joined(separator: " ")
                .lowercased()
            return searchable.contains(query)
        }
    }

    var body: some View {
        PageContainer(title: "Public rules", subtitle: "Approved Spellbook rules") {
            HStack(spacing: 12) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)

                Spacer()

                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .disabled(isLoading)
                .help("Refresh")
            }

            if isLoading && spells.isEmpty {
                EmptyState(title: "Loading", message: "Fetching public rules.")
            } else if filteredSpells.isEmpty {
                EmptyState(title: "No public rules", message: "Approved public rules will appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredSpells) { spell in
                            SpellCard(
                                spell: spell,
                                onOpen: {
                                    viewingSpell = spell
                                },
                                isStarWorking: workingStarIds.contains(spell.id),
                                onStar: {
                                    toggleStar(spell)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task {
            if spells.isEmpty {
                await loadAsync()
            } else {
                await openPendingPublishedSpellIfAvailable()
            }
        }
        .onChange(of: deepLinkModel.pendingPublishedSpellID) { _ in
            Task {
                if spells.isEmpty {
                    await loadAsync()
                } else {
                    await openPendingPublishedSpellIfAvailable()
                }
            }
        }
        .sheet(item: $viewingSpell) { spell in
            SpellFormView(
                mode: .published(spell, editable: canEdit(spell)),
                onSave: canEdit(spell) ? { updatedSpell in
                    try await updatePublished(updatedSpell, replacing: spell)
                } : nil,
                onInstall: { installedSpell in
                    try installFromDetail(installedSpell)
                },
                onDelete: canDelete(spell) ? { deletingSpell in
                    try await deletePublished(deletingSpell)
                } : nil
            )
        }
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func load() {
        Task {
            await loadAsync()
        }
    }

    private func loadAsync() async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpellbookAPI.shared.publicSpells(token: sessionModel.session?.token)
            spells = response
            isLoading = false
            await openPendingPublishedSpellIfAvailable()
        } catch SpellbookError.expiredSession {
            isLoading = false
            sessionModel.clearExpiredSession()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func openPendingPublishedSpellIfAvailable() async {
        guard let uid = deepLinkModel.pendingPublishedSpellID else {
            return
        }

        if let spell = spells.first(where: { $0.uid == uid }) {
            viewingSpell = spell
            deepLinkModel.pendingPublishedSpellID = nil
            return
        }

        do {
            let spell = try await SpellbookAPI.shared.publicSpell(uid: uid, token: sessionModel.session?.token)
            replacePublishedSpell(spell, matching: spell)
            viewingSpell = spell
            deepLinkModel.pendingPublishedSpellID = nil
        } catch SpellbookError.expiredSession {
            sessionModel.clearExpiredSession()
        } catch {
            errorMessage = error.localizedDescription
            deepLinkModel.pendingPublishedSpellID = nil
        }
    }

    private func installFromDetail(_ spell: Spell) throws {
        do {
            try localStore.upsertLocal(spell)
            errorMessage = nil
            viewingSpell = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func canDelete(_ spell: Spell) -> Bool {
        spell.ownerEmail == sessionModel.signedInEmail
    }

    private func canEdit(_ spell: Spell) -> Bool {
        canDelete(spell)
    }

    private func toggleStar(_ spell: Spell) {
        guard let uid = spell.uid, let token = sessionModel.session?.token else {
            return
        }

        workingStarIds.insert(spell.id)
        errorMessage = nil

        Task {
            do {
                let updatedSpell = try await SpellbookAPI.shared.setStarred(uid: uid, starred: !spell.starredByMe, token: token)
                await MainActor.run {
                    replacePublishedSpell(updatedSpell, matching: spell)
                    workingStarIds.remove(spell.id)
                }
            } catch SpellbookError.expiredSession {
                await MainActor.run {
                    workingStarIds.remove(spell.id)
                    sessionModel.clearExpiredSession()
                }
            } catch {
                await MainActor.run {
                    workingStarIds.remove(spell.id)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updatePublished(_ spell: Spell, replacing originalSpell: Spell) async throws {
        guard let token = sessionModel.session?.token else {
            throw SpellbookError.expiredSession
        }

        do {
            let updatedSpell = try await SpellbookAPI.shared.publish(spell: spell, token: token)
            replacePublishedSpell(updatedSpell, matching: originalSpell)
            try localStore.upsertLocal(updatedSpell)

            errorMessage = nil
            viewingSpell = nil
        } catch SpellbookError.expiredSession {
            sessionModel.clearExpiredSession()
            throw SpellbookError.expiredSession
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func replacePublishedSpell(_ updatedSpell: Spell, matching originalSpell: Spell) {
        let replacementUID = updatedSpell.uid ?? originalSpell.uid

        if let replacementUID,
           let index = spells.firstIndex(where: { $0.uid == replacementUID }) {
            spells[index] = updatedSpell
        } else if let index = spells.firstIndex(where: { $0.id == originalSpell.id }) {
            spells[index] = updatedSpell
        } else {
            spells.insert(updatedSpell, at: 0)
        }
    }

    private func deletePublished(_ spell: Spell) async throws {
        guard let uid = spell.uid, let token = sessionModel.session?.token else {
            throw SpellbookError.expiredSession
        }

        do {
            try await SpellbookAPI.shared.delete(uid: uid, token: token)
            spells.removeAll { $0.uid == uid }
            errorMessage = nil
            viewingSpell = nil
        } catch SpellbookError.missingPublishedSpell {
            spells.removeAll { $0.uid == uid }
            errorMessage = nil
            viewingSpell = nil
        } catch SpellbookError.expiredSession {
            sessionModel.clearExpiredSession()
            throw SpellbookError.expiredSession
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}

private struct ProjectInstructionRemoval {
    var spell: Spell
    var target: SpellbookTarget
}

struct ProjectsView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @EnvironmentObject private var sessionModel: SessionModel
    @AppStorage("spellbook.expandedProjectIDs") private var expandedProjectIDsData = "[]"
    @State private var expandedTargetIDs: Set<String> = []
    @State private var isShowingAddTargetForm = false
    @State private var editingTarget: SpellbookTarget?
    @State private var reviewingTarget: SpellbookTarget?
    @State private var viewingProjectSpell: Spell?
    @State private var targetForAddingInstruction: SpellbookTarget?
    @State private var pendingProjectInstructionRemoval: ProjectInstructionRemoval?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var latestRemoteSpellsByUID: [String: Spell] = [:]
    @State private var updatingInstructionIDs: Set<String> = []

    var body: some View {
        PageContainer(
            title: "Workspaces",
            subtitle: "Attach installed rules to workspace directories."
        ) {
            HStack(spacing: 8) {
                Button {
                    isShowingAddTargetForm = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .help("Add workspace")

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .help("Refresh")
            }
        } content: {
            if localStore.targets.isEmpty {
                EmptyState(title: "No workspaces", message: "Add a workspace directory before attaching rules.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(localStore.targets) { target in
                            projectTile(target)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isShowingAddTargetForm) {
            TargetFormView(mode: .add) { directoryURL, harnessFileNames, name in
                try localStore.addTarget(directoryURL: directoryURL, harnessFileNames: harnessFileNames, name: name)
                if let target = localStore.targets.first(where: { $0.directoryPath == directoryURL.path(percentEncoded: false) }) {
                    expandedTargetIDs.insert(target.id)
                    persistExpandedTargetIDs()
                }
                statusMessage = "Added \(SpellbookTarget.displayName(for: directoryURL.path(percentEncoded: false)))."
            }
        }
        .sheet(item: $editingTarget) { target in
            TargetFormView(mode: .edit(target), initialDirectoryURL: localStore.directoryURL(for: target)) { directoryURL, harnessFileNames, name in
                try localStore.updateTarget(target, directoryURL: directoryURL, harnessFileNames: harnessFileNames, name: name)
                statusMessage = "Updated \(SpellbookTarget.displayName(for: directoryURL.path(percentEncoded: false)))."
            }
        }
        .sheet(item: $reviewingTarget) { target in
            TargetInstructionReviewView(target: target)
                .environmentObject(localStore)
        }
        .sheet(item: $viewingProjectSpell) { spell in
            InstructionDetailView(spell: spell)
        }
        .sheet(item: $targetForAddingInstruction) { target in
            ProjectInstructionPickerView(target: target)
                .environmentObject(localStore)
        }
        .onAppear {
            loadExpandedTargetIDs()
            refresh()
        }
        .onReceive(localStore.$targets) { _ in
            pruneExpandedTargetIDs()
        }
        .alert("Remove rule from workspace?", isPresented: Binding(
            get: { pendingProjectInstructionRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    pendingProjectInstructionRemoval = nil
                }
            }
        )) {
            Button("Remove", role: .destructive) {
                confirmRemoveProjectInstruction()
            }
            Button("Cancel", role: .cancel) {
                pendingProjectInstructionRemoval = nil
            }
        } message: {
            Text(projectInstructionRemovalMessage)
        }
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func projectTile(_ target: SpellbookTarget) -> some View {
        let isExpanded = expandedTargetIDs.contains(target.id)
        let installedSpells = localStore.projectSpells(for: target)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggleTarget(target)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)

                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.name)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(target.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 12)

                        Text("\(installedSpells.count)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        editingTarget = target
                    } label: {
                        Label("Edit Workspace", systemImage: "pencil")
                    }

                    Button {
                        reviewingTarget = target
                    } label: {
                        Label("Review Rules Block", systemImage: "doc.text.magnifyingglass")
                    }

                    Divider()

                    Button(role: .destructive) {
                        removeTarget(target)
                    } label: {
                        Label("Remove Workspace", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .help("Workspace actions")

                Button {
                    targetForAddingInstruction = target
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .help("Add rule to workspace")
            }
            .padding(12)

            if isExpanded {
                Divider()

                if installedSpells.isEmpty {
                    EmptyState(title: "No workspace rules", message: "Use the plus button to attach an installed rule.")
                        .frame(minHeight: 120)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(installedSpells.enumerated()), id: \.offset) { index, spell in
                            projectInstructionRow(spell, target: target)
                            if index < installedSpells.count - 1 {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18), lineWidth: 1))
    }

    private func projectInstructionRow(_ spell: Spell, target: SpellbookTarget) -> some View {
        let latestSpell = latestAvailableSpell(for: spell)
        let updateID = projectInstructionUpdateID(spell, target: target)

        return HStack(alignment: .center, spacing: 12) {
            Button {
                viewingProjectSpell = spell
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(spell.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if let latestSpell {
                                SpellPill(
                                    text: "Update v\(spell.normalizedVersion) -> v\(latestSpell.normalizedVersion)",
                                    tint: .blue
                                )
                            } else {
                                SpellPill(text: "v\(spell.normalizedVersion)", tint: .gray)
                            }
                        }

                        Text(spell.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if let latestSpell {
                Button {
                    update(spell, to: latestSpell, in: target)
                } label: {
                    Image(systemName: updatingInstructionIDs.contains(updateID) ? "hourglass" : "arrow.down.circle")
                        .frame(width: 24, height: 24)
                }
                .disabled(updatingInstructionIDs.contains(updateID))
                .buttonStyle(.borderless)
                .help("Update to version \(latestSpell.normalizedVersion)")
            }

            Button(role: .destructive) {
                pendingProjectInstructionRemoval = ProjectInstructionRemoval(spell: spell, target: target)
            } label: {
                Image(systemName: "minus.circle")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Remove from workspace")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func latestAvailableSpell(for spell: Spell) -> Spell? {
        let candidates = [
            localStore.latestInstalledSpell(for: spell),
            latestRemoteSpell(for: spell)
        ].compactMap { $0 }

        return candidates.max { left, right in
            left.normalizedVersion < right.normalizedVersion
        }
    }

    private func latestRemoteSpell(for spell: Spell) -> Spell? {
        guard let uid = spell.uid,
              let remoteSpell = latestRemoteSpellsByUID[uid],
              remoteSpell.normalizedVersion > spell.normalizedVersion
        else {
            return nil
        }

        return remoteSpell
    }

    private var projectInstructionRemovalMessage: String {
        guard let pendingProjectInstructionRemoval else {
            return ""
        }

        return "Remove \(pendingProjectInstructionRemoval.spell.name) from \(pendingProjectInstructionRemoval.target.name)?"
    }

    private func refresh() {
        do {
            try localStore.refresh()
            errorMessage = nil
            loadLatestRemoteVersions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadLatestRemoteVersions() {
        Task {
            do {
                let remoteSpells = try await SpellbookAPI.shared.publicSpells(token: sessionModel.session?.token)
                let latestByUID = remoteSpells.reduce(into: [String: Spell]()) { result, spell in
                    guard let uid = spell.uid else {
                        return
                    }

                    if let existing = result[uid], existing.normalizedVersion >= spell.normalizedVersion {
                        return
                    }

                    result[uid] = spell
                }

                await MainActor.run {
                    latestRemoteSpellsByUID = latestByUID
                }
            } catch SpellbookError.expiredSession {
                await MainActor.run {
                    sessionModel.clearExpiredSession()
                }
            } catch {
                // Workspace-installed rules remain usable if the remote catalog cannot refresh.
            }
        }
    }

    private func update(_ spell: Spell, to latestSpell: Spell, in target: SpellbookTarget) {
        let updateID = projectInstructionUpdateID(spell, target: target)
        guard !updatingInstructionIDs.contains(updateID) else {
            return
        }

        updatingInstructionIDs.insert(updateID)

        Task {
            do {
                let installableSpell = try await installableVersion(for: latestSpell)
                await MainActor.run {
                    do {
                        try localStore.upsertLocal(installableSpell)
                        try localStore.addToTarget(installableSpell, target: target)
                        if let uid = installableSpell.uid {
                            latestRemoteSpellsByUID[uid] = installableSpell
                        }
                        statusMessage = localStore.statusMessage
                        errorMessage = nil
                        updatingInstructionIDs.remove(updateID)
                    } catch {
                        errorMessage = error.localizedDescription
                        updatingInstructionIDs.remove(updateID)
                    }
                }
            } catch SpellbookError.expiredSession {
                await MainActor.run {
                    sessionModel.clearExpiredSession()
                    updatingInstructionIDs.remove(updateID)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    updatingInstructionIDs.remove(updateID)
                }
            }
        }
    }

    private func installableVersion(for spell: Spell) async throws -> Spell {
        if spell.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return spell
        }

        guard let uid = spell.uid else {
            throw SpellbookError.message("That rule is missing a uid.")
        }

        return try await SpellbookAPI.shared.publicSpell(
            uid: uid,
            version: spell.normalizedVersion,
            token: sessionModel.session?.token
        )
    }

    private func projectInstructionUpdateID(_ spell: Spell, target: SpellbookTarget) -> String {
        "\(target.id):\(spell.uid ?? spell.id)"
    }

    private func update(_ spell: Spell, in target: SpellbookTarget) {
        do {
            try localStore.updateTargetInstruction(spell, target: target)
            statusMessage = localStore.statusMessage
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ spell: Spell, from target: SpellbookTarget) {
        do {
            try localStore.removeFromTarget(spell, target: target)
            statusMessage = "Removed \(spell.name) from \(target.name)."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmRemoveProjectInstruction() {
        guard let pendingProjectInstructionRemoval else {
            return
        }

        remove(pendingProjectInstructionRemoval.spell, from: pendingProjectInstructionRemoval.target)
        self.pendingProjectInstructionRemoval = nil
    }

    private func removeTarget(_ target: SpellbookTarget) {
        do {
            try localStore.removeTarget(target)
            expandedTargetIDs.remove(target.id)
            persistExpandedTargetIDs()
            statusMessage = "Removed \(target.name)."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleTarget(_ target: SpellbookTarget) {
        if expandedTargetIDs.contains(target.id) {
            expandedTargetIDs.remove(target.id)
        } else {
            expandedTargetIDs.insert(target.id)
        }
        persistExpandedTargetIDs()
    }

    private func loadExpandedTargetIDs() {
        guard let data = expandedProjectIDsData.data(using: .utf8),
              let decoded = try? JSONDecoder.spellbook.decode([String].self, from: data) else {
            expandedTargetIDs = []
            return
        }

        expandedTargetIDs = Set(decoded)
        pruneExpandedTargetIDs()
    }

    private func pruneExpandedTargetIDs() {
        let validIDs = Set(localStore.targets.map(\.id))
        let pruned = expandedTargetIDs.intersection(validIDs)
        if pruned != expandedTargetIDs {
            expandedTargetIDs = pruned
            persistExpandedTargetIDs()
        }
    }

    private func persistExpandedTargetIDs() {
        let ids = expandedTargetIDs.sorted()
        guard let data = try? JSONEncoder.spellbook.encode(ids),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }

        expandedProjectIDsData = encoded
    }
}

struct ProjectInstructionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localStore: LocalSpellStore

    var target: SpellbookTarget

    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var filteredSpells: [Spell] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return localStore.latestSpells.filter { spell in
            guard !query.isEmpty else {
                return true
            }

            let searchable = [spell.name, spell.description, spell.trigger]
                .joined(separator: " ")
                .lowercased()
            return searchable.contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Rule")
                    .font(.title2.bold())
                Text(target.name)
                    .foregroundStyle(.secondary)
            }

            TextField("Search installed rules", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredSpells.isEmpty {
                EmptyState(title: "No installed rules", message: "Create or install rules before adding them to a workspace.")
                    .frame(minHeight: 240)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredSpells) { spell in
                            pickerRow(spell)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 320)
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 560)
        .onAppear {
            refresh()
        }
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func pickerRow(_ spell: Spell) -> some View {
        let isInstalled = localStore.target(target, contains: spell)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(spell.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if isInstalled {
                        SpellPill(text: "Added", tint: .green)
                    }
                }

                Text(spell.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                add(spell)
            } label: {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : "plus.circle")
                    .frame(width: 26, height: 26)
            }
            .disabled(isInstalled)
            .buttonStyle(.borderless)
            .help(isInstalled ? "Already added" : "Add to workspace")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.16), lineWidth: 1))
    }

    private func refresh() {
        do {
            try localStore.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ spell: Spell) {
        do {
            try localStore.addToTarget(spell, target: target)
            statusMessage = "Added \(spell.name)."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @EnvironmentObject private var sessionModel: SessionModel

    var body: some View {
        PageContainer(title: "Settings", subtitle: "Account and diagnostics") {
            HStack(spacing: 8) {
                Button {
                    repair()
                } label: {
                    Label("Repair", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderedProminent)
                .help("Repair the system store")

                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh diagnostics")
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accountSection
                    systemStoreSection
                    diagnosticsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var systemStoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Rule Store")
                .font(.headline)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(SpellbookUserStoreLayout.rootURL.path(percentEncoded: false), systemImage: "folder")
                        .lineLimit(1)
                        .textSelection(.enabled)

                    if let sandboxURL = SpellbookUserStoreLayout.sandboxContainerRootURL {
                        Label(sandboxURL.path(percentEncoded: false), systemImage: "shippingbox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }

                    if let lastError = localStore.lastError {
                        Text(lastError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    openSystemStore()
                } label: {
                    Label("Open in Finder", systemImage: "arrow.up.right.square")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .help("Open \(SpellbookUserStoreLayout.rootURL.path(percentEncoded: false)) in Finder")
                .accessibilityLabel("Open in Finder")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .font(.headline)

            HStack {
                Label(sessionModel.signedInEmail ?? "", systemImage: "person.crop.circle")
                    .lineLimit(1)

                Spacer()

                Button {
                    sessionModel.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18), lineWidth: 1))
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.headline)

            if localStore.diagnostics.isEmpty {
                EmptyState(title: "No diagnostics", message: "Startup scans did not find Spellbook target problems.")
                    .frame(minHeight: 120)
            } else {
                VStack(spacing: 8) {
                    ForEach(localStore.diagnostics) { diagnostic in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                SpellPill(text: diagnostic.severity, tint: diagnostic.severity == "error" ? .red : .orange)
                                Text(diagnostic.type)
                                    .font(.callout.weight(.semibold))
                                Spacer()
                            }

                            Text(diagnostic.message)
                                .foregroundStyle(.secondary)

                            if let targetRoot = diagnostic.targetRoot {
                                Text(targetRoot)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.16), lineWidth: 1))
                    }
                }
            }
        }
    }

    private func refresh() {
        do {
            try localStore.refresh()
            localStore.lastError = nil
        } catch {
            localStore.lastError = error.localizedDescription
        }
    }

    private func repair() {
        do {
            try localStore.repairSystemStore()
            localStore.lastError = nil
        } catch {
            localStore.lastError = error.localizedDescription
        }
    }

    private func openSystemStore() {
        NSWorkspace.shared.open(SpellbookUserStoreLayout.rootURL)
    }
}

enum TargetFormMode {
    case add
    case edit(SpellbookTarget)

    var title: String {
        switch self {
        case .add:
            return "Add Workspace"
        case .edit:
            return "Edit Workspace"
        }
    }

    var buttonTitle: String {
        switch self {
        case .add:
            return "Add Workspace"
        case .edit:
            return "Save Workspace"
        }
    }

    var existingTarget: SpellbookTarget? {
        switch self {
        case .add:
            return nil
        case .edit(let target):
            return target
        }
    }
}

struct TargetFormView: View {
    @Environment(\.dismiss) private var dismiss

    var mode: TargetFormMode
    var onSave: (URL, [String], String) throws -> Void

    @State private var directoryURL: URL?
    @State private var targetName = ""
    @State private var selectedHarnessFiles: Set<String> = [InstructionManager.supportedFiles[0]]
    @State private var errorMessage: String?

    init(mode: TargetFormMode, initialDirectoryURL: URL? = nil, onSave: @escaping (URL, [String], String) throws -> Void) {
        self.mode = mode
        self.onSave = onSave
        let existingTarget = mode.existingTarget
        _directoryURL = State(initialValue: initialDirectoryURL)
        _targetName = State(initialValue: existingTarget?.name ?? "")
        _selectedHarnessFiles = State(initialValue: Set(existingTarget?.harnesses.map(\.file) ?? [InstructionManager.supportedFiles[0]]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.title2.bold())
                Text("Choose the workspace directory and harness files Spellbook should manage.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        chooseDirectory()
                    } label: {
                        Label("Choose Directory", systemImage: "folder")
                    }

                    Text(directoryURL?.path(percentEncoded: false) ?? "No directory selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Harness files")
                        .font(.callout.weight(.medium))

                    ForEach(InstructionManager.supportedFiles, id: \.self) { fileName in
                        Toggle(isOn: binding(for: fileName)) {
                            HStack(spacing: 8) {
                                Text(fileName)

                                if let directoryURL {
                                    let exists = FileManager.default.fileExists(atPath: directoryURL.appending(path: fileName).path(percentEncoded: false))
                                    SpellPill(text: exists ? "exists" : "will create", tint: exists ? .green : .orange)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                if let directoryURL {
                    LabeledContent("Workspace name") {
                        Text(SpellbookTarget.displayName(for: directoryURL.path(percentEncoded: false)))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button {
                    addTarget()
                } label: {
                    Label(mode.buttonTitle, systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(directoryURL == nil || selectedHarnessFiles.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose workspace directory"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        directoryURL = url
        targetName = SpellbookTarget.displayName(for: url.path(percentEncoded: false))
        selectedHarnessFiles = Set(InstructionManager.defaultHarnessFileNames(in: url))
        errorMessage = nil
    }

    private func addTarget() {
        guard let directoryURL else {
            errorMessage = "Choose a workspace directory."
            return
        }

        guard !selectedHarnessFiles.isEmpty else {
            errorMessage = "Enable at least one harness file."
            return
        }

        do {
            try onSave(directoryURL, orderedSelectedHarnessFiles(), SpellbookTarget.displayName(for: directoryURL.path(percentEncoded: false)))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func binding(for fileName: String) -> Binding<Bool> {
        Binding {
            selectedHarnessFiles.contains(fileName)
        } set: { isSelected in
            if isSelected {
                selectedHarnessFiles.insert(fileName)
            } else {
                selectedHarnessFiles.remove(fileName)
            }
        }
    }

    private func orderedSelectedHarnessFiles() -> [String] {
        InstructionManager.supportedFiles.filter { selectedHarnessFiles.contains($0) }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TargetInstructionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var localStore: LocalSpellStore

    var target: SpellbookTarget

    @State private var preview: InstructionPreview?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var canApplyInstruction: Bool {
        preview != nil
    }

    private var isInstructionInstalled: Bool {
        preview?.isInstalled == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Rules Block")
                    .font(.title2.bold())
                Text(target.name)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    reviewInstruction()
                } label: {
                    Label("Review", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    applyInstruction()
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApplyInstruction)

                Button(role: .destructive) {
                    removeInstruction()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(!isInstructionInstalled)

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }

            if let preview {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        PreviewValue(label: "Workspace file", value: preview.targetInstructionURL.path(percentEncoded: false))
                        PreviewValue(label: "Agent", value: preview.agent)
                        PreviewValue(label: "Rules block", value: preview.isInstalled ? "Installed" : "Not installed")
                        PreviewValue(label: "Block", value: preview.action.rawValue)
                        PreviewValue(label: "Managed entries", value: "\(preview.managedInstructionCount)")
                        PreviewValue(label: "~/.spellbook/rules", value: preview.instructionStoreExists ? "Exists" : "Will create")
                        PreviewValue(label: "~/.spellbook/registry/targets.json", value: preview.targetsExists ? "Exists" : "Will create")
                    }

                    ScrollView {
                        Text(preview.previewContent)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18), lineWidth: 1))
                }
            } else {
                EmptyState(title: "No preview", message: "Review the rules block before applying it.")
            }
        }
        .padding(24)
        .frame(width: 760, height: 620)
        .onAppear {
            reviewInstruction()
        }
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func reviewInstruction() {
        do {
            guard let directoryURL = localStore.directoryURL(for: target) else {
                throw SpellbookError.message("Choose the workspace directory again.")
            }

            preview = try InstructionManager.preview(
                selectedURL: target.instructionURL(in: directoryURL),
                preferredFileName: target.instructionFileName
            )
            errorMessage = nil
            statusMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func applyInstruction() {
        do {
            guard let directoryURL = localStore.directoryURL(for: target) else {
                throw SpellbookError.message("Choose the workspace directory again.")
            }

            try InstructionManager.apply(
                directoryURL: directoryURL,
                harnessFileNames: target.harnesses.map(\.file),
                installedSpells: localStore.spells
            )
            try localStore.refresh()
            errorMessage = nil
            reviewInstruction()
            statusMessage = "Applied Spellbook rules block."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeInstruction() {
        do {
            guard let directoryURL = localStore.directoryURL(for: target) else {
                throw SpellbookError.message("Choose the workspace directory again.")
            }

            try InstructionManager.removeManagedBlocks(from: directoryURL, harnesses: target.harnesses)
            try localStore.refresh()
            errorMessage = nil
            reviewInstruction()
            statusMessage = "Removed Spellbook rules block."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PageContainer<Content: View, HeaderActions: View>: View {
    var title: String
    var subtitle: String
    var headerActions: HeaderActions
    var content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder headerActions: () -> HeaderActions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.headerActions = headerActions()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.largeTitle.bold())
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                headerActions
                    .padding(.top, 2)
            }

            content

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension PageContainer where HeaderActions == EmptyView {
    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            headerActions: { EmptyView() },
            content: content
        )
    }
}

struct SpellCard: View {
    var spell: Spell
    var onOpen: (() -> Void)? = nil
    var isStarWorking = false
    var onStar: (() -> Void)? = nil
    var showsLiveBadge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(spell.name)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)

                        if showsLiveBadge {
                            SpellPill(text: "Live", tint: .green)
                        }
                    }

                    Text(spell.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                }

                Spacer()

                SpellStarButton(spell: spell, isWorking: isStarWorking, action: onStar)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen?()
        }
    }
}

struct SpellPill: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint.opacity(0.82))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.32), lineWidth: 1))
    }
}

struct SpellStarButton: View {
    var spell: Spell
    var isWorking = false
    var action: (() -> Void)?

    private var displayCount: Int {
        spell.uid == nil ? 0 : spell.starCount
    }

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 5) {
                Text("\(displayCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Image(systemName: spell.starredByMe ? "star.fill" : "star")
            }
            .frame(minWidth: 48, minHeight: 28)
        }
        .disabled(action == nil || spell.uid == nil || isWorking)
        .help(spell.starredByMe ? "Remove star" : "Star")
    }
}

struct EmptyState: View {
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

extension View {
    func spellbookErrorAlert(message: Binding<String?>) -> some View {
        alert("Spellbook", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { presented in
                if !presented {
                    message.wrappedValue = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                message.wrappedValue = nil
            }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

struct PreviewValue: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
        }
        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
    }
}
