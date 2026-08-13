import AppKit
import SwiftUI

struct LocalSpellsView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @EnvironmentObject private var sessionModel: SessionModel
    @State private var editingSpell: Spell?
    @State private var isShowingNewSpellForm = false
    @State private var errorMessage: String?
    @State private var publishedSpellsByUID: [String: Spell] = [:]
    @State private var workingStarIds: Set<String> = []

    var body: some View {
        PageContainer(
            title: "Installed spells",
            subtitle: "Installed spells are picked up by the agent automatically."
        ) {
            HStack(spacing: 8) {
                Button {
                    isShowingNewSpellForm = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .disabled(localStore.spellsURL == nil)
                .help(localStore.spellsURL == nil ? "Choose a local target in Settings before creating spells." : "Create a local spell.")

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .help("Refresh")
            }
        } content: {
            if localStore.spells.isEmpty {
                EmptyState(title: "No local spells", message: "Create a spell, install one from Published spells, or select a target in Settings.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(localStore.spells) { spell in
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
                try create(spell)
            })
        }
        .sheet(item: $editingSpell) { spell in
            SpellFormView(
                mode: .local(spell, editable: canEdit(spell)),
                onSave: canEdit(spell) ? { updatedSpell in
                    try update(updatedSpell)
                } : nil,
                onPublish: canPublish(spell) ? { updatedSpell in
                    try await publishFromDetail(updatedSpell, replacing: spell)
                } : nil,
                onArchive: { archivedSpell in
                    try archive(archivedSpell)
                }
            )
        }
        .onAppear {
            refresh()
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

    private func publishFromDetail(_ spell: Spell, replacing originalSpell: Spell) async throws {
        guard let session = sessionModel.session else {
            throw SpellbookError.message("Sign in to publish this spell.")
        }

        do {
            try localStore.updateLocal(spell)
            let remote = try await SpellbookAPI.shared.publish(spell: spell, token: session.token)
            try localStore.updateAfterPublish(localIdentifier: originalSpell.id, remoteSpell: remote, signedInEmail: session.email)
            if let uid = remote.uid {
                publishedSpellsByUID[uid] = remote
            }
            errorMessage = nil
            editingSpell = nil
        } catch SpellbookError.missingPublishedSpell {
            do {
                try await republishMissingRemote(spell, replacing: originalSpell, session: session)
            } catch SpellbookError.expiredSession {
                sessionModel.clearExpiredSession()
                throw SpellbookError.expiredSession
            } catch {
                errorMessage = error.localizedDescription
                throw error
            }
        } catch SpellbookError.expiredSession {
            sessionModel.clearExpiredSession()
            throw SpellbookError.expiredSession
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func republishMissingRemote(_ spell: Spell, replacing originalSpell: Spell, session: SpellbookSession) async throws {
        guard let staleUID = originalSpell.uid ?? spell.uid else {
            throw SpellbookError.missingPublishedSpell
        }

        var localOnly = spell
        localOnly.uid = nil
        localOnly.ownerEmail = nil
        localOnly.publishedAt = nil
        localOnly.starCount = 0
        localOnly.starredByMe = false

        guard let resetSpell = try localStore.markUnpublished(uid: staleUID, replacement: localOnly) else {
            throw SpellbookError.message("That local spell could not be reconciled with the published registry.")
        }

        let remote = try await SpellbookAPI.shared.publish(spell: resetSpell, token: session.token)
        try localStore.updateAfterPublish(localIdentifier: resetSpell.id, remoteSpell: remote, signedInEmail: session.email)
        publishedSpellsByUID.removeValue(forKey: staleUID)
        if let uid = remote.uid {
            publishedSpellsByUID[uid] = remote
        }
        errorMessage = nil
        editingSpell = nil
    }

    private func create(_ spell: Spell) throws {
        do {
            try localStore.upsertLocal(spell)
            errorMessage = nil
            isShowingNewSpellForm = false
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
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

    private func archive(_ spell: Spell) throws {
        do {
            try localStore.removeLocal(spell)
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
                    for uid in unpublishedUIDs {
                        _ = try? localStore.markUnpublished(uid: uid)
                        publishedSpellsByUID.removeValue(forKey: uid)
                    }
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
}

struct StagingSpellsView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @State private var viewingSpell: Spell?
    @State private var errorMessage: String?

    var body: some View {
        PageContainer(
            title: "Staging spells",
            subtitle: "Staged spells are generated by the agent and need your review."
        ) {
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .help("Refresh")
        } content: {
            if localStore.stagingSpells.isEmpty {
                EmptyState(title: "No staged spells", message: "Agent-captured spells waiting for approval will appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(localStore.stagingSpells) { spell in
                            SpellCard(spell: spell, onOpen: {
                                viewingSpell = spell
                            })
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .spellbookErrorAlert(message: $errorMessage)
        .sheet(item: $viewingSpell) { spell in
            StagedSpellDetailView(
                spell: spell,
                onApprove: { stagedSpell in
                    try localStore.approveStaged(stagedSpell)
                    viewingSpell = nil
                },
                onArchive: { stagedSpell in
                    try localStore.removeStaged(stagedSpell)
                    viewingSpell = nil
                }
            )
        }
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        do {
            try localStore.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct StagedSpellDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var spell: Spell
    var onApprove: (Spell) throws -> Void
    var onArchive: (Spell) throws -> Void

    @State private var isConfirmingArchive = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Staged Spell")
                    .font(.title2.bold())
                Text("Inspect this captured spell before approving it into registry.json.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Name") {
                    Text(spell.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                LabeledContent("Description") {
                    Text(spell.description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                LabeledContent("Trigger") {
                    Text(spell.trigger.isEmpty ? "Not set" : spell.trigger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                LabeledContent("Tags") {
                    Text(spell.tags.joined(separator: ", "))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    SpellMetadataValue(label: "UID", value: spell.uid ?? "Not published")
                    SpellMetadataValue(label: "Version", value: "\(spell.version)")
                    SpellMetadataValue(label: "Storage", value: "\(spell.storageID)/\(spell.normalizedVersion)/SPEC.md")
                    SpellMetadataValue(label: "Owner", value: spell.ownerEmail ?? "Local only")
                    SpellMetadataValue(label: "Published at", value: spell.publishedAt ?? "Not published")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SPEC.md content")
                    .font(.callout.weight(.medium))

                ScrollView {
                    Text(spell.content ?? "No markdown content found.")
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                }
                .frame(minHeight: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
            }

            HStack {
                Button("Done") {
                    dismiss()
                }

                Spacer()

                SpellShareButton(spell: spell)

                Button {
                    isConfirmingArchive = true
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }

                Button {
                    approve()
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 660, height: 700)
        .alert("Archive staged spell?", isPresented: $isConfirmingArchive) {
            Button("Archive") {
                archive()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(spell.name)
        }
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func approve() {
        do {
            try onApprove(spell)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive() {
        do {
            try onArchive(spell)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ArchivedSpellsView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @State private var viewingSpell: Spell?
    @State private var errorMessage: String?

    var body: some View {
        PageContainer(
            title: "Archived spells",
            subtitle: "Archived spells are your trash."
        ) {
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .help("Refresh")
        } content: {
            if localStore.archivedSpells.isEmpty {
                EmptyState(title: "No archived spells", message: "Archived local and staged spells will appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(localStore.archivedSpells) { spell in
                            SpellCard(spell: spell, onOpen: {
                                viewingSpell = spell
                            })
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .spellbookErrorAlert(message: $errorMessage)
        .sheet(item: $viewingSpell) { spell in
            ArchivedSpellDetailView(
                spell: spell,
                onRestore: { archivedSpell in
                    try localStore.restoreArchived(archivedSpell)
                    viewingSpell = nil
                }
            )
        }
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        do {
            try localStore.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ArchivedSpellDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var spell: Spell
    var onRestore: (Spell) throws -> Void

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Archived Spell")
                    .font(.title2.bold())
                Text("Inspect this archived spell or restore it into registry.json.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Name") {
                    Text(spell.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                LabeledContent("Description") {
                    Text(spell.description)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                LabeledContent("Trigger") {
                    Text(spell.trigger.isEmpty ? "Not set" : spell.trigger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                LabeledContent("Tags") {
                    Text(spell.tags.joined(separator: ", "))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    SpellMetadataValue(label: "UID", value: spell.uid ?? "Not published")
                    SpellMetadataValue(label: "Version", value: "\(spell.version)")
                    SpellMetadataValue(label: "Storage", value: "\(spell.storageID)/\(spell.normalizedVersion)/SPEC.md")
                    SpellMetadataValue(label: "Owner", value: spell.ownerEmail ?? "Local only")
                    SpellMetadataValue(label: "Published at", value: spell.publishedAt ?? "Not published")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SPEC.md content")
                    .font(.callout.weight(.medium))

                ScrollView {
                    Text(spell.content ?? "No markdown content found.")
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                }
                .frame(minHeight: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
            }

            HStack {
                Button("Done") {
                    dismiss()
                }

                Spacer()

                SpellShareButton(spell: spell)

                Button {
                    restore()
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 660, height: 700)
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func restore() {
        do {
            try onRestore(spell)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
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
            return "New Spell"
        case .local:
            return "Local Spell"
        case .published:
            return "Published Spell"
        }
    }

    var subtitle: String {
        switch self {
        case .create:
            return "Add a local spell and paste its markdown instructions."
        case .local(_, let editable):
            return editable ? "View or edit this local spell." : "This installed spell belongs to another creator, so it is read-only."
        case .published(_, let editable):
            return editable ? "View or edit your published spell." : "View this published spell."
        }
    }

    var buttonTitle: String {
        switch self {
        case .create:
            return "Create Spell"
        case .local:
            return "Save Spell"
        case .published:
            return "Update Spell"
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

struct SpellFormView: View {
    @Environment(\.dismiss) private var dismiss

    var mode: SpellFormMode
    var onSave: ((Spell) async throws -> Void)?
    var onPublish: ((Spell) async throws -> Void)?
    var onInstall: ((Spell) throws -> Void)?
    var onArchive: ((Spell) throws -> Void)?
    var onDelete: ((Spell) async throws -> Void)?

    @State private var name = ""
    @State private var spellDescription = ""
    @State private var trigger = ""
    @State private var content = ""
    @State private var tags = "review"
    @State private var validationMessage: String?
    @State private var isSaving = false
    @State private var isWorkingAction = false
    @State private var isConfirmingArchive = false
    @State private var isConfirmingDelete = false

    init(
        mode: SpellFormMode,
        onSave: ((Spell) async throws -> Void)? = nil,
        onPublish: ((Spell) async throws -> Void)? = nil,
        onInstall: ((Spell) throws -> Void)? = nil,
        onArchive: ((Spell) throws -> Void)? = nil,
        onDelete: ((Spell) async throws -> Void)? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onPublish = onPublish
        self.onInstall = onInstall
        self.onArchive = onArchive
        self.onDelete = onDelete
        let spell = mode.existingSpell
        _name = State(initialValue: spell?.name ?? "")
        _spellDescription = State(initialValue: spell?.description ?? "")
        _trigger = State(initialValue: spell?.trigger ?? "")
        _content = State(initialValue: spell?.content ?? "")
        _tags = State(initialValue: spell?.tags.joined(separator: ", ") ?? "review")
    }

    private var canCreate: Bool {
        !trimmed(name).isEmpty
            && !trimmed(spellDescription).isEmpty
            && !trimmed(trigger).isEmpty
            && !trimmed(content).isEmpty
    }

    private var isBusy: Bool {
        isSaving || isWorkingAction
    }

    private var canSubmit: Bool {
        mode.isEditable && canCreate && !isBusy && onSave != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.title2.bold())
                Text(mode.subtitle)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Name") {
                    TextField("Spell name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.callout.weight(.medium))
                    TextEditor(text: $spellDescription)
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Trigger")
                        .font(.callout.weight(.medium))
                    TextEditor(text: $trigger)
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("SPEC.md content")
                        .font(.callout.weight(.medium))
                    TextEditor(text: $content)
                        .font(.body)
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.22), lineWidth: 1))
                }

                LabeledContent("Tags") {
                    TextField("review, security", text: $tags)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .disabled(!mode.isEditable || isBusy)

            metadataSection

            HStack {
                if onArchive != nil, mode.existingSpell != nil {
                    Button(role: .destructive) {
                        isConfirmingArchive = true
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .disabled(isBusy)
                }

                if onDelete != nil, mode.existingSpell != nil {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(isBusy)
                }

                Spacer()

                Button(mode.isEditable ? "Cancel" : "Done") {
                    dismiss()
                }
                .disabled(isBusy)

                if let existingSpell = mode.existingSpell {
                    SpellShareButton(spell: existingSpell)
                        .disabled(isBusy)
                }

                if onInstall != nil {
                    Button {
                        installCurrent()
                    } label: {
                        Label("Install", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canCreate || isBusy)
                }

                if onPublish != nil {
                    Button {
                        publishCurrent()
                    } label: {
                        Label(mode.existingSpell?.uid == nil ? "Publish" : "Update Published", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(!mode.isEditable || !canCreate || isBusy)
                }

                if mode.isEditable {
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
        .alert("Archive spell?", isPresented: $isConfirmingArchive) {
            Button("Archive", role: .destructive) {
                archiveCurrent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mode.existingSpell?.name ?? "")
        }
        .alert("Remove published spell?", isPresented: $isConfirmingDelete) {
            Button("Remove", role: .destructive) {
                deleteCurrent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mode.existingSpell?.name ?? "")
        }
        .spellbookErrorAlert(message: $validationMessage)
    }

    @ViewBuilder
    private var metadataSection: some View {
        if let spell = mode.existingSpell {
            VStack(alignment: .leading, spacing: 10) {
                Divider()

                Text("Details")
                    .font(.headline)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    SpellMetadataValue(label: "UID", value: spell.uid ?? "Not published")
                    SpellMetadataValue(label: "Version", value: "\(spell.version)")
                    SpellMetadataValue(label: "Storage", value: "\(spell.storageID)/\(spell.normalizedVersion)/SPEC.md")
                    SpellMetadataValue(label: "Owner", value: spell.ownerEmail ?? "Local only")
                    SpellMetadataValue(label: "Published at", value: spell.publishedAt ?? "Not published")
                }
            }
        }
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

    private func publishCurrent() {
        guard let spell = draftSpell(), let onPublish else {
            return
        }

        isWorkingAction = true
        validationMessage = nil

        Task {
            do {
                try await onPublish(spell)
                await MainActor.run {
                    isWorkingAction = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    validationMessage = error.localizedDescription
                    isWorkingAction = false
                }
            }
        }
    }

    private func installCurrent() {
        guard let spell = draftSpell(), let onInstall else {
            return
        }

        isWorkingAction = true
        validationMessage = nil

        do {
            try onInstall(spell)
            isWorkingAction = false
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isWorkingAction = false
        }
    }

    private func archiveCurrent() {
        guard let spell = mode.existingSpell, let onArchive else {
            return
        }

        isWorkingAction = true
        validationMessage = nil

        do {
            try onArchive(spell)
            isWorkingAction = false
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
            isWorkingAction = false
        }
    }

    private func deleteCurrent() {
        guard let spell = mode.existingSpell, let onDelete else {
            return
        }

        isWorkingAction = true
        validationMessage = nil

        Task {
            do {
                try await onDelete(spell)
                await MainActor.run {
                    isWorkingAction = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    validationMessage = error.localizedDescription
                    isWorkingAction = false
                }
            }
        }
    }

    private func draftSpell() -> Spell? {
        guard canCreate else {
            validationMessage = "Fill in name, description, trigger, and markdown content."
            return nil
        }

        let existing = mode.existingSpell
        return Spell(
            uid: existing?.uid,
            localID: existing?.localID,
            name: trimmed(name),
            description: trimmed(spellDescription),
            trigger: trimmed(trigger),
            tags: parsedTags(),
            file: existing?.file ?? "",
            content: trimmed(content),
            version: existing?.version ?? 1,
            ownerEmail: existing?.ownerEmail,
            publishedAt: existing?.publishedAt,
            starCount: existing?.starCount ?? 0,
            starredByMe: existing?.starredByMe ?? false
        )
    }

    private func parsedTags() -> [String] {
        let parsed = tags
            .split(separator: ",")
            .map { trimmed(String($0)).lowercased() }
            .filter { !$0.isEmpty }

        return parsed.isEmpty ? ["review"] : Array(Set(parsed)).sorted()
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .help("Publish this spell before sharing")
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

            let searchable = [spell.name, spell.description, spell.trigger, spell.tags.joined(separator: " "), spell.content ?? ""]
                .joined(separator: " ")
                .lowercased()
            return searchable.contains(query)
        }
    }

    var body: some View {
        PageContainer(title: "Published spells", subtitle: "Public Spellbook registry") {
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
                EmptyState(title: "Loading", message: "Fetching published spells.")
            } else if filteredSpells.isEmpty {
                EmptyState(title: "No published spells", message: "Published spells will appear here.")
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
            _ = try? localStore.markUnpublished(uid: uid)
            spells.removeAll { $0.uid == uid }
            errorMessage = nil
            viewingSpell = nil
        } catch SpellbookError.missingPublishedSpell {
            _ = try? localStore.markUnpublished(uid: uid)
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

struct SettingsView: View {
    @EnvironmentObject private var localStore: LocalSpellStore
    @EnvironmentObject private var sessionModel: SessionModel
    @State private var isShowingAddTargetForm = false
    @State private var editingTarget: SpellbookTarget?
    @State private var reviewingTarget: SpellbookTarget?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        PageContainer(title: "Settings", subtitle: "Targets and account") {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accountSection
                    targetSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isShowingAddTargetForm) {
            TargetFormView(mode: .add) { directoryURL, instructionFileName, name in
                try localStore.addTarget(directoryURL: directoryURL, instructionFileName: instructionFileName, name: name)
                statusMessage = "Added \(name)."
            }
        }
        .sheet(item: $editingTarget) { target in
            TargetFormView(mode: .edit(target), initialDirectoryURL: localStore.directoryURL(for: target)) { directoryURL, instructionFileName, name in
                try localStore.updateTarget(target, directoryURL: directoryURL, instructionFileName: instructionFileName, name: name)
                statusMessage = "Updated \(name)."
            }
        }
        .sheet(item: $reviewingTarget) { target in
            TargetInstructionReviewView(target: target)
                .environmentObject(localStore)
        }
        .onChange(of: localStore.selectedTargetID) { _ in
            statusMessage = nil
            errorMessage = nil
        }
        .spellbookErrorAlert(message: $errorMessage)
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

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Targets")
                    .font(.headline)

                Spacer()

                Button {
                    isShowingAddTargetForm = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .help("Add target")
            }

            if localStore.targets.isEmpty {
                EmptyState(title: "No targets", message: "Add a target directory before creating local spells.")
                    .frame(minHeight: 140)
            } else {
                VStack(spacing: 8) {
                    ForEach(localStore.targets) { target in
                        targetRow(target)
                    }
                }
            }
        }
    }

    private func targetRow(_ target: SpellbookTarget) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(target.name)
                        .font(.callout.weight(.semibold))

                    if target.id == localStore.selectedTargetID {
                        Text("Current")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }

                Text(target.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                editingTarget = target
            }

            Spacer()

            Button {
                localStore.selectTarget(id: target.id)
            } label: {
                Label("Use", systemImage: "checkmark.circle")
            }
            .disabled(target.id == localStore.selectedTargetID)

            Button {
                reviewingTarget = target
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .frame(width: 24, height: 24)
            }
            .help("Review instruction")

            Button(role: .destructive) {
                removeTarget(target)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .help("Remove target")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18), lineWidth: 1))
    }

    private func removeTarget(_ target: SpellbookTarget) {
        do {
            try localStore.removeTarget(target)
            statusMessage = "Removed \(target.name)."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum TargetFormMode {
    case add
    case edit(SpellbookTarget)

    var title: String {
        switch self {
        case .add:
            return "Add Target"
        case .edit:
            return "Edit Target"
        }
    }

    var buttonTitle: String {
        switch self {
        case .add:
            return "Add Target"
        case .edit:
            return "Save Target"
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
    var onSave: (URL, String, String) throws -> Void

    @State private var directoryURL: URL?
    @State private var targetName = ""
    @State private var instructionFileName = InstructionManager.supportedFiles[0]
    @State private var errorMessage: String?

    init(mode: TargetFormMode, initialDirectoryURL: URL? = nil, onSave: @escaping (URL, String, String) throws -> Void) {
        self.mode = mode
        self.onSave = onSave
        let existingTarget = mode.existingTarget
        _directoryURL = State(initialValue: initialDirectoryURL)
        _targetName = State(initialValue: existingTarget?.name ?? "")
        _instructionFileName = State(initialValue: existingTarget?.instructionFileName ?? InstructionManager.supportedFiles[0])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.title2.bold())
                Text("Choose the directory and instruction file Spellbook should manage.")
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

                Picker("File to write", selection: $instructionFileName) {
                    ForEach(InstructionManager.supportedFiles, id: \.self) { fileName in
                        Text(fileName).tag(fileName)
                    }
                }
                .frame(width: 260)

                LabeledContent("Dropdown name") {
                    TextField("Target name", text: $targetName)
                        .textFieldStyle(.roundedBorder)
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
                .disabled(directoryURL == nil || trimmed(targetName).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .spellbookErrorAlert(message: $errorMessage)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose target directory"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        directoryURL = url
        if trimmed(targetName).isEmpty {
            targetName = url.lastPathComponent.isEmpty ? url.path(percentEncoded: false) : url.lastPathComponent
        }
        instructionFileName = existingSupportedFile(in: url) ?? instructionFileName
        errorMessage = nil
    }

    private func addTarget() {
        guard let directoryURL else {
            errorMessage = "Choose a target directory."
            return
        }

        let name = trimmed(targetName)
        guard !name.isEmpty else {
            errorMessage = "Enter a dropdown name."
            return
        }

        do {
            try onSave(directoryURL, instructionFileName, name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func existingSupportedFile(in directoryURL: URL) -> String? {
        InstructionManager.supportedFiles.first { fileName in
            FileManager.default.fileExists(atPath: directoryURL.appending(path: fileName).path(percentEncoded: false))
        }
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
                Text("Review Instruction")
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
                        PreviewValue(label: "Target", value: preview.targetInstructionURL.path(percentEncoded: false))
                        PreviewValue(label: "Instruction", value: preview.isInstalled ? "Installed" : "Not installed")
                        PreviewValue(label: "Block", value: preview.action.rawValue)
                        PreviewValue(label: ".agent-context", value: preview.packageURL.path(percentEncoded: false))
                        PreviewValue(label: "manifest.json", value: preview.manifestExists ? "Exists" : "Will create")
                        PreviewValue(label: "registry.json", value: preview.registryExists ? "Exists" : "Will create")
                        PreviewValue(label: "~/.spellbook/registry/staging.json", value: preview.stagingExists ? "Exists" : "Will create")
                        PreviewValue(label: "~/.spellbook/registry/archive.json", value: preview.archiveExists ? "Exists" : "Will create")
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
                EmptyState(title: "No preview", message: "Review the instruction block before applying it.")
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
                throw SpellbookError.message("Choose the target directory again.")
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
        guard let preview else {
            return
        }

        do {
            try InstructionManager.apply(preview)
            if target.id == localStore.selectedTargetID {
                try localStore.refresh()
            }
            errorMessage = nil
            reviewInstruction()
            statusMessage = "Applied Spellbook instruction."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeInstruction() {
        do {
            guard let directoryURL = localStore.directoryURL(for: target) else {
                throw SpellbookError.message("Choose the target directory again.")
            }

            try InstructionManager.removeManagedBlock(from: target.instructionURL(in: directoryURL))
            if target.id == localStore.selectedTargetID {
                try localStore.refresh()
            }
            errorMessage = nil
            reviewInstruction()
            statusMessage = "Removed Spellbook instruction."
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

                    if !spell.tags.isEmpty {
                        TagFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            ForEach(spell.tags, id: \.self) { tag in
                                SpellPill(text: tag, tint: .blue)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

struct TagFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let additionalWidth = rowWidth == 0 ? size.width : horizontalSpacing + size.width

            if rowWidth > 0, rowWidth + additionalWidth > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += additionalWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight

        return CGSize(width: proposal.width ?? totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
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
