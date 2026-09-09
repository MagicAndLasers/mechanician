import SwiftUI

/// Inspect AND edit what a signed managed configuration is doing.
///
/// A managed profile silently sets provider routing, the model list, the MCP registry and the
/// plugin marketplace. Until this existed the only view of it was the one-time import sheet, so a
/// user hitting a managed-configuration problem could neither see what their app had been told to
/// do nor change it — they had to wait for an administrator to publish a new signed document.
///
/// The signed document is never modified: the app holds only the public key, so it could not
/// re-sign one, and discarding the signature would mean any file on disk could activate an
/// enterprise route. Edits are written as ``ManagedConfigurationOverrides`` and layered on at
/// resolution time, which is why they take effect on the next launch exactly as an imported
/// profile does. Every edited field is marked and can be reset to what the profile says.
struct ManagedConfigurationView: View {
    /// The EFFECTIVE profile for this launch — signed document plus this install's overrides. Note
    /// this is also the SANITIZED document: a profile cannot rename or rebrand the app, so
    /// `displayName` reads "Mechanician" for every tenant and `tenantId` is the value that survives.
    let profile: TenantProfile
    /// The document as the administrator published it, for marking overrides and resetting.
    let signed: TenantProfile
    /// The profile installed on disk, used only to detect an installed-but-inactive configuration.
    let installed: TenantProfile?
    let onDone: () -> Void

    @ObservedObject private var catalog = ModelCatalogStore.shared
    @State private var draft = ManagedConfigurationOverrides.load()
    @State private var saved = ManagedConfigurationOverrides.load()
    @State private var retiredOverrideNote: [String] =
        TenantProfileUpdater.pendingRetirementNote()?.sentences ?? []
    @State private var retiredOverrideRevision: Int? =
        TenantProfileUpdater.pendingRetirementNote()?.revision
    @State private var notice: String?
    @State private var regionPickerOpen = false
    @State private var choosingBackend = false

    private var hasUnsavedEdits: Bool { draft != saved }

    private var profileIsDeliveredByMDM: Bool {
        ManagedEnterprisePolicy.current?.signedProfile != nil
    }

    /// Both documents come back from `loadSignedProfile` already sanitized, so this compares like
    /// with like rather than a raw file against a running configuration.
    private var installedButInactive: TenantProfile? {
        guard let installed, installed != signed else { return nil }
        return installed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if installedButInactive != nil { restartNotice }
                    if let error = TenantProfile.startupError { startupErrorNotice(error) }
                    if !draft.isEmpty { overrideNotice }
                    if signed.routes.isEmpty && draft.addedRoutes.isEmpty { gettingStarted }
                    profileSection
                    ForEach(Array(signed.routes.enumerated()), id: \.offset) { _, route in
                        routeSection(route)
                    }
                    ForEach(draft.addedRoutes.indices, id: \.self) { index in
                        addedRouteSection(index)
                    }
                    addConnectionButton
                    registrySection
                    marketplaceSection
                    networkSection
                    policySection
                }
                .padding(20)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 680, height: 660)
        .background(Color.nBg)
        .alert("Managed Configuration", isPresented: .constant(notice != nil)) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2.crop.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Managed Configuration")
                    .font(.title3.weight(.semibold))
                Text(profile.isDefault
                     ? "No managed configuration is active."
                     : "\(profile.tenantId.capitalized) · signature verified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !draft.isEmpty {
                Button(signed.isDefault ? "Clear Configuration" : "Reset All to Profile") {
                    draft = ManagedConfigurationOverrides()
                }
                .buttonStyle(PillButtonStyle(kind: .plain))
            }
            // The step that turns authoring-on-one-Mac into distribution: export, sign with
            // scripts/sign-enterprise-profile.swift, hand out the result.
            Button("Export…") { export() }
                .buttonStyle(PillButtonStyle(kind: .plain))
                .disabled(draft.applied(to: signed).routes.isEmpty
                          && draft.applied(to: signed).extensions.managedSources.isEmpty)
                .accessibilityLabel("Export this configuration as an unsigned profile")
            Spacer()
            Button(hasUnsavedEdits ? "Discard Changes" : "Done") {
                if hasUnsavedEdits { draft = saved } else { onDone() }
            }
            .buttonStyle(PillButtonStyle(kind: .plain))
            Button("Save") { save() }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(!hasUnsavedEdits)
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private func export() {
        let effective = draft.applied(to: signed)
        let document = ManagedConfigurationOverrides.exportableProfile(from: effective)
        guard let data = try? JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            notice = "This configuration could not be written."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(effective.tenantId)-tenant.json"
        panel.message = "Save this configuration so it can be signed and distributed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            notice = """
                Saved. This document is UNSIGNED — Mechanician will not load it as it is. To \
                distribute it, sign it with scripts/sign-enterprise-profile.swift, which produces \
                the .mechanician-profile that Import Configuration… accepts.
                """
        } catch {
            NSLog("[managed] configuration could not be saved: %@", error.localizedDescription)
            notice = "The configuration could not be saved. Check that you can write to "
                + "Application Support, then try again."
        }
    }

    private func save() {
        do {
            try draft.save()
            saved = draft
            notice = "Saved. Quit and reopen Mechanician for these changes to take effect. A "
                + "configuration is resolved once per launch."
        } catch {
            NSLog("[managed] changes could not be saved: %@", error.localizedDescription)
            notice = "The changes could not be saved. Check that you can write to "
                + "Application Support, then try again."
        }
    }

    // MARK: Authoring

    /// The empty state. Someone opening this with no configuration at all should learn what one is
    /// for and be one click from having it, not be shown an inventory of nothing.
    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No provider connection is configured", systemImage: "sparkles")
                .font(.callout.weight(.semibold))
            Text("""
                 A configuration adds a provider route this build supports but cannot discover on \
                 its own — today, Claude on Google Vertex AI, which needs the project and region \
                 your organization runs it in. Add one here to use it on this Mac, then export it \
                 if you want the same setup on other machines.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12, strokeOpacity: 0.45)
    }

    /// Choosing the backend is the first real decision, so it is a step rather than an assumption.
    ///
    /// Bedrock is listed and visibly unavailable instead of hidden. Hiding it reads as "Mechanician
    /// doesn't do AWS"; showing it greyed with the reason reads as "not yet, and here's the state of
    /// it" — and it stops someone hunting for a setting that does not exist. It is NOT offered as a
    /// selectable route, because `ModelAccess(adapter:)` maps only `claude-vertex`: a Bedrock route
    /// would activate nothing, which is exactly the silent-no-op this surface exists to expose.
    private var backendChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which backend runs Claude for your organization?")
                .font(.callout.weight(.semibold))
            backendRow(
                title: "Google Vertex AI",
                detail: "Needs your GCP project and region. Sign in with your organization's "
                    + "Google account after adding it.",
                icon: "cloud.fill", available: true) {
                choosingBackend = false
                addVertexConnection()
            }
            backendRow(
                title: "AWS Bedrock",
                detail: "Needs the region your organization enabled Claude in. Credentials come "
                    + "from your existing AWS setup, the same profile the aws CLI uses, so there "
                    + "is nothing to sign in to here.",
                icon: "shippingbox.fill", available: true) {
                choosingBackend = false
                addBedrockConnection()
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(Color.nBg)
    }

    private func backendRow(
        title: String, detail: String, icon: String, available: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(available ? Color.nInfoText : Color.nText.opacity(0.35))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(available ? Color.nText : Color.nText.opacity(0.5))
                        if !available {
                            Text("NOT AVAILABLE")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.nText.opacity(0.1)))
                        }
                    }
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(available ? Color.nElevated.opacity(0.7) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(available ? "Add a \(title) connection" : "\(title), not available")
    }

    private func addVertexConnection() {
        draft.addedRoutes.append(TenantProfile.Route(
            routeId: "local-claude-vertex-\(draft.addedRoutes.count + 1)",
            displayName: "Claude (Vertex)",
            adapter: "claude-vertex",
            vertex: TenantProfile.Vertex(projectId: "", region: "global"),
            models: [TenantProfile.Model(
                id: "claude-opus-4-8", displayName: "Opus 4.8", isDefault: true)],
            isDefault: signed.routes.isEmpty && draft.addedRoutes.isEmpty))
    }

    private func addBedrockConnection() {
        draft.addedRoutes.append(TenantProfile.Route(
            routeId: "local-claude-bedrock-\(draft.addedRoutes.count + 1)",
            displayName: "Claude (Bedrock)",
            adapter: "claude-bedrock",
            bedrock: TenantProfile.Bedrock(region: "us-east-1", profile: nil),
            models: [TenantProfile.Model(
                id: "global.anthropic.claude-opus-4-8", displayName: "Opus 4.8", isDefault: true)],
            isDefault: signed.routes.isEmpty && draft.addedRoutes.isEmpty))
    }

    private var addConnectionButton: some View {
        HStack(spacing: 8) {
            Button { choosingBackend = true } label: {
                Label("Add Provider Connection", systemImage: "plus.circle")
            }
            .buttonStyle(PillButtonStyle(kind: signed.routes.isEmpty && draft.addedRoutes.isEmpty
                                         ? .accent : .plain))
            .accessibilityLabel("Add a provider connection")
            .popover(isPresented: $choosingBackend, arrowEdge: .bottom) { backendChooser }
            Text("Claude on Google Vertex AI or AWS Bedrock.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// A route authored on this machine. Unlike a published one its identity is editable, because
    /// nobody else depends on it — but its ADAPTER is still fixed, since that selects which audited
    /// runtime runs and only one is implemented.
    private func addedRouteSection(_ index: Int) -> some View {
        let route = draft.addedRoutes[index]
        return section(route.displayName?.nonBlank ?? route.routeId,
                       icon: "plus.rectangle.on.folder") {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                fieldLabel("Added here")
                Text("Not part of a signed profile. It exists only on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Remove") { draft.addedRoutes.remove(at: index) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("Remove this connection")
            }
            editableRow("Name", binding: addedBinding(index, .displayNameText), published: "")
            row("Adapter", route.adapter, monospaced: true)
            if route.bedrock == nil {
                editableRow("Vertex project", binding: addedBinding(index, .vertexProject),
                            published: "", placeholder: "my-gcp-project")
                regionPicker(addedBinding(index, .vertexRegion))
            }
            if route.vertex != nil,
               route.vertex?.projectId.trimmingCharacters(in: .whitespaces).isEmpty != false {
                Text("A project is required. Without one this connection cannot start.")
                    .font(.caption)
                    .foregroundStyle(Color.nWarningText)
                    .padding(.leading, 146)
            }
            if route.bedrock != nil {
                regionPicker(addedBinding(index, .vertexRegion), title: "AWS region",
                             options: Self.bedrockRegions)
                editableRow("AWS profile", binding: addedBinding(index, .vertexProject),
                            published: "", placeholder: "default")
                Text("Optional. Names a profile in your ~/.aws config. Mechanician never stores "
                     + "AWS keys, and this configuration carries none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 146)
                    .fixedSize(horizontal: false, vertical: true)
            }
            addedModelEditor(index)
        }
    }

    /// Bedrock model ids, verified by invoking them against a live account. The invokable id is a
    /// cross-region INFERENCE PROFILE (`global.`/`us.` prefix) — neither Anthropic's own id nor the
    /// bare `anthropic.*` foundation id works for the current generation, the latter failing with
    /// "on-demand throughput isn't supported". Access is granted per model family, so tick only what
    /// your account actually holds; "Other id…" covers a region-specific profile or an ARN.
    static let knownBedrockModels: [(id: String, label: String)] = [
        ("global.anthropic.claude-opus-4-8", "Opus 4.8"),
        ("global.anthropic.claude-opus-5", "Opus 5"),
        ("global.anthropic.claude-sonnet-5", "Sonnet 5"),
        ("global.anthropic.claude-sonnet-4-6", "Sonnet 4.6"),
        ("global.anthropic.claude-haiku-4-5-20251001-v1:0", "Haiku 4.5"),
    ]

    @ViewBuilder
    private func addedModelEditor(_ index: Int) -> some View {
        let models = Binding<[TenantProfile.Model]>(
            get: { index < draft.addedRoutes.count ? draft.addedRoutes[index].models : [] },
            set: { guard index < draft.addedRoutes.count else { return }
                   draft.addedRoutes[index].models = $0 })
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                fieldLabel("Models")
                Spacer(minLength: 0)
                Button {
                    models.wrappedValue.append(TenantProfile.Model(
                        id: "", displayName: nil, isDefault: models.wrappedValue.isEmpty))
                } label: { Label("Other id…", systemImage: "plus") }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Add a model id not in the list")
            }
            modelChecklist(models, catalog: catalogFor(index))
            ForEach(models.wrappedValue.indices.filter { position in
                !catalogFor(index).contains { $0.id == models.wrappedValue[position].id }
            }, id: \.self) { modelIndex in
                modelRow(models: models, index: modelIndex)
            }
            Text("Tick only what your deployment actually carries. Anything unticked is not "
                 + "offered, which is the point: a model the project cannot serve fails every turn. "
                 + "Use “Other id…” for a publisher-pinned id such as claude-opus-4-8@20260101.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 146)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which model vocabulary this route speaks. Bedrock names inference profiles; Vertex names
    /// Anthropic model ids. Showing the wrong list would offer ids the backend has never heard of.
    private func catalogFor(_ index: Int) -> [(id: String, label: String)] {
        guard index < draft.addedRoutes.count else { return Self.knownClaudeModels }
        return draft.addedRoutes[index].bedrock != nil
            ? Self.knownBedrockModels : Self.knownClaudeModels
    }

    private func addedBinding(
        _ index: Int, _ field: AddedRouteField
    ) -> Binding<String> {
        Binding(
            get: {
                guard index < draft.addedRoutes.count else { return "" }
                let route = draft.addedRoutes[index]
                switch field {
                case .displayNameText: return route.displayName ?? ""
                // One field pair serves both clouds: "the endpoint's account selector" and "the
                // region". On Bedrock those are the AWS profile name and the AWS region.
                case .vertexProject:
                    return route.bedrock.map { $0.profile ?? "" } ?? route.vertex?.projectId ?? ""
                case .vertexRegion:
                    return route.bedrock?.region ?? route.vertex?.region ?? ""
                }
            },
            set: { value in
                guard index < draft.addedRoutes.count else { return }
                var route = draft.addedRoutes[index]
                switch field {
                case .displayNameText:
                    route.displayName = value.nonBlank
                case .vertexProject:
                    if let bedrock = route.bedrock {
                        route.bedrock = TenantProfile.Bedrock(
                            region: bedrock.region, profile: value.nonBlank)
                    } else {
                        route.vertex = TenantProfile.Vertex(
                            projectId: value, region: route.vertex?.region ?? "global")
                    }
                case .vertexRegion:
                    if let bedrock = route.bedrock {
                        route.bedrock = TenantProfile.Bedrock(
                            region: value, profile: bedrock.profile)
                    } else {
                        route.vertex = TenantProfile.Vertex(
                            projectId: route.vertex?.projectId ?? "", region: value)
                    }
                }
                draft.addedRoutes[index] = route
            })
    }

    enum AddedRouteField { case displayNameText, vertexProject, vertexRegion }

    /// Regions Claude is served from on Vertex. `global` first because it is what a multi-region
    /// deployment uses and what gets a project working with the fewest questions asked; anything
    /// else can still be typed, since Google adds regions on their own schedule.
    /// Regions AWS serves Claude from on Bedrock. Same reasoning as `vertexRegions`: a picker, with
    /// an escape hatch, because AWS enables models region by region on its own schedule.
    static let bedrockRegions = [
        "us-east-1", "us-west-2", "eu-central-1", "eu-west-3", "ap-northeast-1", "ap-southeast-2",
    ]

    static let vertexRegions = [
        "global", "us-east5", "us-central1", "europe-west1", "europe-west4", "asia-southeast1",
    ]

    private func regionPicker(
        _ binding: Binding<String>,
        title: String = "Vertex region",
        options: [String]? = nil
    ) -> some View {
        let regions = options ?? Self.vertexRegions
        let isKnown = regions.contains(binding.wrappedValue)
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            fieldLabel(title)
            // The app's own choice control, not an Aqua pop-up: these controls sit inside
            // Mechanician's surfaces and a stock NSPopUpButton reads as a foreign object here, the
            // same way a stock push button did on the transcript's code blocks.
            Button { regionPickerOpen = true } label: {
                MechanicianControlTrigger(
                    title: binding.wrappedValue.isEmpty ? "Choose…" : binding.wrappedValue,
                    systemImage: "globe",
                    showsChevron: true)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(binding.wrappedValue)
            .popover(isPresented: $regionPickerOpen, arrowEdge: .bottom) {
                MechanicianControlChoicePopover(
                    title: title,
                    choices: regions.map {
                        MechanicianControlChoice(
                            id: $0, title: $0,
                            detail: $0 == "global"
                                ? "Routes to wherever your project is provisioned. Start here."
                                : nil)
                    } + [MechanicianControlChoice(
                        id: customRegionID, title: "Other…",
                        detail: "Type a region Google has added since this build.")],
                    selectedID: isKnown ? binding.wrappedValue : customRegionID,
                    footer: "Must match the region your organization provisioned Claude in."
                ) { choice in
                    regionPickerOpen = false
                    binding.wrappedValue = choice.id == customRegionID ? "" : choice.id
                }
            }
            .id(title)
            if !isKnown {
                mechField("region", text: binding, width: 150, monospaced: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var customRegionID: String { "__custom__" }

    private func addSource(kind: String) {
        draft.addedSources.append(TenantProfile.ManagedSource(
            kind: kind,
            name: kind == "registry" ? "My MCP Registry" : "My Plugin Marketplace",
            url: "https://",
            repo: nil,
            format: kind == "registry"
                ? RegistryFormat.officialV01.rawValue : MarketplaceFormat.claudeMarketplace.rawValue,
            authentication: nil,
            networkScope: "public"))
    }

    @ViewBuilder
    private func addedSourceEditor(_ index: Int) -> some View {
        let source = draft.addedSources[index]
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                mechField("name", text: Binding(
                    get: { index < draft.addedSources.count ? draft.addedSources[index].name : "" },
                    set: { guard index < draft.addedSources.count else { return }
                           draft.addedSources[index].name = $0 }), width: 132)
                mechField("https://…", text: Binding(
                    get: { index < draft.addedSources.count
                           ? (draft.addedSources[index].url ?? "") : "" },
                    set: { guard index < draft.addedSources.count else { return }
                           draft.addedSources[index].url = $0 }), monospaced: true)
                Button("Remove") { draft.addedSources.remove(at: index) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("Remove this source")
            }
            if source.url?.hasPrefix("https://") != true || source.url == "https://" {
                Text("An https:// address is required.")
                    .font(.caption)
                    .foregroundStyle(Color.nWarningText)
                    .padding(.leading, 140)
            }
        }
    }

    // MARK: Sections

    private var profileSection: some View {
        section("Profile", icon: "checkmark.shield.fill") {
            // Deliberately NOT `displayName`: sanitization resets it to the app's own name, so it
            // would read "Mechanician" for every tenant.
            row("Organization", profile.tenantId.capitalized)
            row("Tenant ID", profile.tenantId, monospaced: true)
            // The revision is what answers "did the change I published arrive?". The app refuses a
            // document whose revision does not advance, so a number that has not moved is the
            // clearest evidence a publish did not land — and until now reading it meant opening a
            // file in Application Support by hand.
            row("Revision", activeRevisionSummary)
            if let url = TenantProfile.currentProfileURL {
                row("Installed at", url.path, monospaced: true)
            }
            row("Local overrides", draft.isEmpty
                ? "None. Running exactly what the profile declares."
                : ManagedConfigurationOverrides.fileURL().path, monospaced: !draft.isEmpty)
            // A retired override is the one change the user did not make and cannot see the cause
            // of: their edit is simply gone, one launch after the revision that took it back.
            if !retiredOverrideNote.isEmpty {
                row("Replaced", retiredOverrideNoteSentence, tint: Color.nWarningText)
                HStack(spacing: 14) {
                    Color.clear.frame(width: 132, height: 0)
                    Button("Got it") {
                        TenantProfileUpdater.clearRetirementNote()
                        retiredOverrideNote = []
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("Dismiss the note about replaced local edits")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Names the revision as well as the fields. "Your edit was replaced" invites the question the
    /// user cannot otherwise answer, which is by what.
    private var retiredOverrideNoteSentence: String {
        let list = retiredOverrideNote.joined(separator: ", ")
        guard let revision = retiredOverrideRevision else {
            return "Your organization has since published its own values for settings you changed "
                 + "here, so theirs are in use again: \(list)."
        }
        return "Revision \(revision) changed settings you had edited on this Mac, so your "
             + "organization's values are in use again: \(list)."
    }

    /// The active revision, and the installed one when they differ.
    ///
    /// Naming both is the point: "10, restart to use it" and "8, the update never arrived" are the
    /// two very different problems this screen gets opened for, and they are indistinguishable
    /// from a single number.
    private var activeRevisionSummary: String {
        let active = signed.update?.revision
        let onDisk = installed?.update?.revision
        let activeText = active.map(String.init) ?? "not declared"
        guard let onDisk, onDisk != active else {
            return activeText
        }
        return "\(activeText) — revision \(onDisk) is installed. "
            + "Quit and reopen Mechanician to use it."
    }

    private func routeSection(_ route: TenantProfile.Route) -> some View {
        let access = ModelAccess(adapter: route.adapter)
        return section(route.displayName ?? route.routeId,
                       icon: "point.3.connected.trianglepath.dotted") {
            // Not editable: these select which audited code path runs, not how it is configured.
            row("Route ID", route.routeId, monospaced: true)
            row("Adapter", route.adapter, monospaced: true)
            if let access {
                row("Account", access.displayName)
            } else {
                row("Account", "This build has no adapter named “\(route.adapter)”, so this route "
                    + "activates nothing.", tint: .orange)
            }
            if let vertex = route.vertex {
                editableRow("Vertex project", binding: projectBinding(route),
                            published: vertex.projectId)
                regionPicker(regionBinding(route))
                row("Daemon environment",
                    "MECHANICIAN_VERTEX_PROJECT=\(effectiveVertex(route)?.projectId ?? "")\n"
                    + "MECHANICIAN_VERTEX_REGION=\(effectiveVertex(route)?.region ?? "")",
                    monospaced: true)
            }
            modelEditor(route: route, access: access)
        }
    }

    @ViewBuilder
    private func modelEditor(route: TenantProfile.Route, access: ModelAccess?) -> some View {
        let models = modelsBinding(route)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                fieldLabel("Models")
                if draft.routes[route.routeId]?.models != nil { overriddenBadge }
                Spacer(minLength: 0)
                Button {
                    models.wrappedValue.append(
                        TenantProfile.Model(id: "", displayName: nil,
                                            isDefault: models.wrappedValue.isEmpty))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Add a model to this route")
                if draft.routes[route.routeId]?.models != nil {
                    Button("Reset") { setModels(route, nil) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("Reset models to the profile's declared list")
                }
            }
            if models.wrappedValue.isEmpty {
                Text("No models declared. This route offers Mechanician's built-in list, which may "
                     + "include models your deployment cannot serve.")
                    .font(.caption)
                    .foregroundStyle(Color.nWarningText)
                    .padding(.leading, 146)
                    .fixedSize(horizontal: false, vertical: true)
            }
            modelChecklist(models)
            ForEach(models.wrappedValue.indices.filter { position in
                !Self.knownClaudeModels.contains { $0.id == models.wrappedValue[position].id }
            }, id: \.self) { index in
                modelRow(models: models, index: index)
            }
            if let access { catalogComparison(route: route, access: access) }
        }
    }

    /// Claude models a Vertex deployment can carry, as concrete ids.
    ///
    /// Deliberately no aliases. `default`, `opus` and `sonnet` are re-resolved by the Claude
    /// runtime at request time, so declaring one on a managed lane hands model choice back to the
    /// runtime's build-time list — which is the exact defect that made a managed-route turn 404 on every
    /// send. A publisher-pinned id can still be typed in below.
    static let knownClaudeModels: [(id: String, label: String)] = [
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-opus-5", "Opus 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-haiku-4-5", "Haiku 4.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-fable-5", "Fable 5"),
    ]

    /// Tick what the deployment carries instead of typing ids. A wrong id here is not a typo you
    /// notice — it is a lane that 404s on every turn — so the common case should not involve
    /// spelling anything.
    private func modelChecklist(
        _ models: Binding<[TenantProfile.Model]>,
        catalog knownModels: [(id: String, label: String)]? = nil
    ) -> some View {
        let offered = knownModels ?? Self.knownClaudeModels
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(offered, id: \.id) { known in
                HStack(spacing: 8) {
                    Spacer().frame(width: 132)
                    mechCheck(known.label, isOn: Binding(
                        get: { models.wrappedValue.contains { $0.id == known.id } },
                        set: { include in
                            if include {
                                models.wrappedValue.append(TenantProfile.Model(
                                    id: known.id, displayName: known.label,
                                    isDefault: models.wrappedValue.isEmpty))
                            } else {
                                models.wrappedValue.removeAll { $0.id == known.id }
                                if !models.wrappedValue.contains(where: \.isDefault),
                                   !models.wrappedValue.isEmpty {
                                    models.wrappedValue[0].isDefault = true
                                }
                            }
                        }))
                    Text(known.id)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if models.wrappedValue.contains(where: { $0.id == known.id }) {
                        Button {
                            for i in models.wrappedValue.indices {
                                models.wrappedValue[i].isDefault =
                                    models.wrappedValue[i].id == known.id
                            }
                        } label: {
                            Image(systemName: models.wrappedValue
                                .first { $0.id == known.id }?.isDefault == true
                                ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Use as this route's default model")
                        .accessibilityLabel("Use \(known.label) as the default model")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func modelRow(
        models: Binding<[TenantProfile.Model]>, index: Int
    ) -> some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 132)
            mechField("model id", text: Binding(
                get: { index < models.wrappedValue.count ? models.wrappedValue[index].id : "" },
                set: { value in
                    guard index < models.wrappedValue.count else { return }
                    models.wrappedValue[index].id = value
                }), width: 230, monospaced: true)
            mechField("display name", text: Binding(
                get: {
                    index < models.wrappedValue.count
                        ? (models.wrappedValue[index].displayName ?? "") : ""
                },
                set: { value in
                    guard index < models.wrappedValue.count else { return }
                    models.wrappedValue[index].displayName =
                        value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
                }), width: 150)
            Button {
                // Exactly one default: it is what a cold start and every new conversation take.
                for i in models.wrappedValue.indices {
                    models.wrappedValue[i].isDefault = (i == index)
                }
            } label: {
                Image(systemName: index < models.wrappedValue.count
                      && models.wrappedValue[index].isDefault
                      ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.borderless)
            .help("Use as this route's default model")
            .accessibilityLabel("Use as default model")
            Button {
                guard index < models.wrappedValue.count else { return }
                models.wrappedValue.remove(at: index)
                if !models.wrappedValue.contains(where: \.isDefault),
                   !models.wrappedValue.isEmpty {
                    models.wrappedValue[0].isDefault = true
                }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove this model")
            Spacer(minLength: 0)
        }
    }

    /// What the provider reported versus what this route offers. The gap is the cost of making a
    /// declared list authoritative, so it is named rather than left for a support call.
    @ViewBuilder
    private func catalogComparison(route: TenantProfile.Route, access: ModelAccess) -> some View {
        let declared = effectiveModels(route)
        let reported = catalog.providerReportedModelIDs(for: access)
        let withheld = reported.filter { id in !declared.contains { $0.id == id } }
        if declared.isEmpty {
            EmptyView()
        } else if reported.isEmpty {
            row("Provider catalog", "Not loaded yet in this session.")
        } else if withheld.isEmpty {
            row("Provider catalog",
                "Reported \(reported.count) model\(reported.count == 1 ? "" : "s"); none withheld.")
        } else {
            row("Provider catalog",
                """
                Reported \(reported.count) model\(reported.count == 1 ? "" : "s"). \
                \(withheld.count) not declared here and therefore not offered:
                \(withheld.joined(separator: ", "))
                """)
        }
    }

    private var registrySection: some View {
        section("MCP Registry", icon: "square.grid.2x2") {
            let declared = signed.extensions.managedSources.filter { $0.kind == "registry" }
            if declared.isEmpty, !draft.addedSources.contains(where: { $0.kind == "registry" }) {
                row("Sources", "No managed MCP registry is configured.")
            }
            ForEach(Array(declared.enumerated()), id: \.offset) { _, source in
                sourceEditor(source)
            }
            ForEach(draft.addedSources.indices.filter { draft.addedSources[$0].kind == "registry" },
                    id: \.self) { index in
                addedSourceEditor(index)
            }
            HStack {
                Button { addSource(kind: "registry") } label: {
                    Label("Add Registry", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Add an MCP registry source")
                Spacer()
            }
            row("Public sources", signed.extensions.allowPublic
                ? "Allowed alongside managed sources."
                : "Blocked. Only managed sources are available.")
        }
    }

    private var marketplaceSection: some View {
        section("Plugin Marketplace", icon: "shippingbox") {
            let declared = signed.extensions.managedSources.filter { $0.kind == "marketplace" }
            if declared.isEmpty, !draft.addedSources.contains(where: { $0.kind == "marketplace" }) {
                row("Sources", "No managed plugin marketplace is configured.")
            }
            ForEach(Array(declared.enumerated()), id: \.offset) { _, source in
                sourceEditor(source)
            }
            ForEach(draft.addedSources.indices.filter { draft.addedSources[$0].kind == "marketplace" },
                    id: \.self) { index in
                addedSourceEditor(index)
            }
            HStack {
                Button { addSource(kind: "marketplace") } label: {
                    Label("Add Marketplace", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Add a plugin marketplace source")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func sourceEditor(_ source: TenantProfile.ManagedSource) -> some View {
        let disabled = Binding(
            get: { draft.sources[source.name]?.disabled ?? false },
            set: { setSource(source.name) { $0.disabled = $1 ? true : nil }($0) })
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                fieldLabel(source.name)
                mechCheck(disabled.wrappedValue ? "Disabled" : "Enabled",
                          isOn: Binding(get: { !disabled.wrappedValue },
                                        set: { disabled.wrappedValue = !$0 }))
                    .accessibilityLabel("Enable \(source.name)")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 132)
                mechField("https://…", text: Binding(
                    get: { draft.sources[source.name]?.url ?? source.url ?? "" },
                    set: { value in
                        setSource(source.name) { override, new in
                            override.url = (new == (source.url ?? "")) ? nil : new
                        }(value)
                    }), monospaced: true, disabled: disabled.wrappedValue)
                if draft.sources[source.name]?.url != nil {
                    Button("Reset") { setSource(source.name) { $0.url = nil; _ = $1 }("") }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("Reset \(source.name) URL to the profile's value")
                }
            }
            let urlChanged = draft.sources[source.name]?.url != nil
            row("", [
                "Format: \(source.format ?? "—")",
                source.authentication == "googleIdentity"
                    ? (urlChanged ? "Sign-in: removed, see below" : "Sign-in: Google identity")
                    : "Sign-in: none",
                source.networkScope == "vpnOnly"
                    ? "Network: corporate VPN only" : "Network: public",
                source.sha256.map { "Pinned digest: \($0.prefix(12))…" },
                source.governance.map {
                    "Approved statuses: " + $0.approvedStatuses.joined(separator: ", ")
                },
            ].compactMap { $0 }.joined(separator: " · "))
            if urlChanged, source.authentication == "googleIdentity" {
                Text("Changing this URL removes its managed Google sign-in. A token minted for the "
                     + "address your organization published is never sent to a different host.")
                    .font(.caption)
                    .foregroundStyle(Color.nWarningText)
                    .padding(.leading, 146)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var policySection: some View {
        section("Servers & Policy", icon: "lock.shield") {
            row("Managed MCP servers", signed.extensions.managedServers.isEmpty
                ? "None declared."
                : signed.extensions.managedServers
                    .map { "\($0.name) (\($0.transport))" }
                    .joined(separator: "\n"))
            row("Not editable here",
                "A route's adapter, a source's format, and any managed MCP server are fixed by the "
                + "signed profile. Those select which code runs, and a stdio server names a command to "
                + "launch, so they are the part the signature exists to protect.")
        }
    }

    private var networkSection: some View {
        let disclosure = NetworkConfigurationDisclosure(profile: profile)
        return section("Network & Configuration", icon: "network") {
            if let host = disclosure.profileUpdateHost {
                row("Profile update host", host, monospaced: true)
                if profileIsDeliveredByMDM {
                    row("Profile update checks",
                        "Delivered by macOS device management; the app does not check this host.")
                } else {
                    row("Profile update checks",
                        disclosure.profileUpdateMode == .manual
                            ? "Manual. Contacted only when you choose Check."
                            : "Automatic. May be contacted when Mechanician opens.")
                }
            } else {
                row("Profile updates", profileIsDeliveredByMDM
                    ? "Delivered by macOS device management."
                    : "No host configured. Replace this profile by hand.")
            }
            row("Managed source hosts", disclosure.managedSourceHosts.isEmpty
                ? "None declared."
                : disclosure.managedSourceHosts.joined(separator: "\n"), monospaced: true)
            row("Managed MCP hosts", disclosure.managedMCPHosts.isEmpty
                ? "None declared."
                : disclosure.managedMCPHosts.joined(separator: "\n"), monospaced: true)
            row("Displayed values",
                "Hostnames only. URL paths, query values, credentials, and configuration secrets are not shown here.")
        }
    }

    // MARK: Override plumbing

    private func effectiveVertex(_ route: TenantProfile.Route) -> TenantProfile.Vertex? {
        draft.applied(to: signed).routes.first { $0.routeId == route.routeId }?.vertex
    }

    private func effectiveModels(_ route: TenantProfile.Route) -> [TenantProfile.Model] {
        draft.routes[route.routeId]?.models ?? route.models
    }

    private func setModels(_ route: TenantProfile.Route, _ models: [TenantProfile.Model]?) {
        var override = draft.routes[route.routeId] ?? ManagedConfigurationOverrides.Route()
        override.models = models
        draft.routes[route.routeId] = override.isEmpty ? nil : override
    }

    private func modelsBinding(_ route: TenantProfile.Route) -> Binding<[TenantProfile.Model]> {
        Binding(
            get: { effectiveModels(route) },
            set: { setModels(route, $0 == route.models ? nil : $0) })
    }

    private func projectBinding(_ route: TenantProfile.Route) -> Binding<String> {
        Binding(
            get: { draft.routes[route.routeId]?.vertexProjectId ?? route.vertex?.projectId ?? "" },
            set: { value in
                var override = draft.routes[route.routeId] ?? ManagedConfigurationOverrides.Route()
                override.vertexProjectId = value == (route.vertex?.projectId ?? "") ? nil : value
                draft.routes[route.routeId] = override.isEmpty ? nil : override
            })
    }

    private func regionBinding(_ route: TenantProfile.Route) -> Binding<String> {
        Binding(
            get: { draft.routes[route.routeId]?.vertexRegion ?? route.vertex?.region ?? "" },
            set: { value in
                var override = draft.routes[route.routeId] ?? ManagedConfigurationOverrides.Route()
                override.vertexRegion = value == (route.vertex?.region ?? "") ? nil : value
                draft.routes[route.routeId] = override.isEmpty ? nil : override
            })
    }

    private func setSource(
        _ name: String,
        _ apply: @escaping (inout ManagedConfigurationOverrides.Source, String) -> Void
    ) -> (String) -> Void {
        { value in
            var override = draft.sources[name] ?? ManagedConfigurationOverrides.Source()
            apply(&override, value)
            draft.sources[name] = override.isEmpty ? nil : override
        }
    }

    private func setSource(
        _ name: String,
        _ apply: @escaping (inout ManagedConfigurationOverrides.Source, Bool) -> Void
    ) -> (Bool) -> Void {
        { value in
            var override = draft.sources[name] ?? ManagedConfigurationOverrides.Source()
            apply(&override, value)
            draft.sources[name] = override.isEmpty ? nil : override
        }
    }

    // MARK: Building blocks

    private var overrideNotice: some View {
        notice("This install has local edits",
               "The signed profile is unchanged; these edits are layered on top of it and apply on "
               + "the next launch. Reset any field to go back to what your organization published.",
               icon: "pencil.circle.fill", tint: Color.nAccent)
    }

    private var restartNotice: some View {
        notice("A different configuration is installed",
               "Quit and reopen Mechanician for it to take effect. Everything below is the "
               + "configuration this launch is actually using.",
               icon: "arrow.clockwise.circle.fill", tint: .orange)
    }

    private func startupErrorNotice(_ error: String) -> some View {
        notice("The installed configuration could not be used", error,
               icon: "exclamationmark.triangle.fill", tint: .orange)
    }

    private var overriddenBadge: some View {
        Text("OVERRIDDEN")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.nInfoText)
    }

    @ViewBuilder
    private func editableRow(
        _ label: String, binding: Binding<String>, published: String, placeholder: String = ""
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            fieldLabel(label)
            mechField(placeholder.isEmpty ? published : placeholder, text: binding,
                      width: 260, monospaced: true)
            // A locally authored field has no published value to differ from, so it is never
            // "overridden" — showing that badge on every field of a new route would be noise.
            if !published.isEmpty, binding.wrappedValue != published {
                overriddenBadge
                Button("Reset") { binding.wrappedValue = published }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("Reset \(label) to the profile's value")
                Text("was \(published)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Mechanician-styled control primitives
    //
    // Stock `.roundedBorder` fields, `.checkbox` toggles and Aqua pop-ups read as foreign objects
    // inside the app's own surfaces. These match `MechanicianControlTrigger`'s geometry (26pt tall,
    // 7pt radius) so a field, a choice control and a pill button line up as one system.

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 132, alignment: .leading)
    }

    @ViewBuilder
    private func mechField(
        _ placeholder: String,
        text: Binding<String>,
        width: CGFloat? = nil,
        monospaced: Bool = false,
        disabled: Bool = false
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
            .foregroundStyle(disabled ? Color.nText.opacity(0.45) : Color.nText)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(width: width)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.nElevated.opacity(disabled ? 0.4 : 0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.nText.opacity(0.12), lineWidth: 1)
                    }
            }
            .disabled(disabled)
    }

    /// A tick that belongs to this app rather than to Aqua. Also a larger hit target than a stock
    /// checkbox, since the whole row is clickable.
    private func mechCheck(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(
                        isOn.wrappedValue ? Color.nInfoText : Color.nText.opacity(0.5))
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.nText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }

    private func notice(_ title: String, _ body: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 10, strokeOpacity: 0.45)
    }

    private func section<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) { content() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 12, strokeOpacity: 0.45)
    }

    @ViewBuilder
    private func row(
        _ label: String,
        _ value: String,
        monospaced: Bool = false,
        tint: Color? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private extension String {
    /// Empty and whitespace-only are the same thing for a user-typed name.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
