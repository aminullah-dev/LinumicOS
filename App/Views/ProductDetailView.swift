import LinumicCore
import SwiftUI

enum ProductTab: String, CaseIterable, Identifiable {
    case overview = "Overview", platforms = "Platforms", repositories = "Repos", stores = "Stores",
         releases = "Releases", roadmap = "Roadmap", issues = "Issues", deployments = "Deploys", links = "Links",
         verification = "Verification"
    var id: String { rawValue }
}

/// Which editor sheet is open. A `nil` ID means adding a new record.
enum RecordEditing: Identifiable {
    case product
    case field(ProductField)
    case platform(UUID?), repository(UUID?), storeListing(UUID?)
    case release(UUID?), roadmap(UUID?), issue(UUID?), deployment(UUID?)

    var id: String {
        switch self {
        case .product: "product"
        case .field(let f): "field-\(f.rawValue)"
        case .platform(let id): "platform-\(id?.uuidString ?? "new")"
        case .repository(let id): "repo-\(id?.uuidString ?? "new")"
        case .storeListing(let id): "listing-\(id?.uuidString ?? "new")"
        case .release(let id): "release-\(id?.uuidString ?? "new")"
        case .roadmap(let id): "roadmap-\(id?.uuidString ?? "new")"
        case .issue(let id): "issue-\(id?.uuidString ?? "new")"
        case .deployment(let id): "deployment-\(id?.uuidString ?? "new")"
        }
    }
}

struct ProductDetailView: View {
    let productID: String
    @Environment(InventoryModel.self) private var model
    @State private var tab: ProductTab = .overview
    @State private var editing: RecordEditing?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    var body: some View {
        if let product = model.product(id: productID) {
            VStack(alignment: .leading, spacing: 0) {
                header(product)
                sectionPicker
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                Divider()
                ScrollView {
                    tabContent(product)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(product.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button { editing = .product } label: { Label("Edit Name & Notes", systemImage: "pencil") }
                    .keyboardShortcut("e")
                    .help("Edit name and notes (⌘E). Edit each fact from its row.")
            }
            .sheet(item: $editing) { editor(for: $0, product: product) }
        } else {
            ContentUnavailableView("Product not found", systemImage: "questionmark.folder")
        }
    }

    /// Ten segments don't fit on a phone, so it gets a menu instead.
    @ViewBuilder
    private var sectionPicker: some View {
        let picker = Picker("Section", selection: $tab) {
            ForEach(ProductTab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        if compact {
            FitRow {
                Text("Section").foregroundStyle(.secondary)
                picker.pickerStyle(.menu)
                Spacer(minLength: 0)
            }
        } else {
            picker.pickerStyle(.segmented).labelsHidden()
        }
    }

    private func header(_ p: Product) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FitRow(spacing: 10, alignment: .firstTextBaseline) {
                Text(p.name).font(compact ? .title.weight(.semibold) : .largeTitle.weight(.semibold))
                VerificationBadge(status: p.overallVerification)
            }
            AdaptiveStack(spacing: compact ? 4 : 12) {
                let pending = p.needsConfirmation
                let conflicts = pending.filter { $0.verification.status == .conflicting }.count
                if conflicts > 0 {
                    Label("\(conflicts) conflicting", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Label("\(pending.count) items need your confirmation", systemImage: "person.badge.clock")
                    .foregroundStyle(pending.isEmpty ? Color.secondary : Color.orange)
                Text("Last verified \(p.lastVerifiedAt?.shortDate ?? String(localized: "never"))").foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    @ViewBuilder
    private func tabContent(_ p: Product) -> some View {
        switch tab {
        case .overview: OverviewTab(product: p) { editing = .field($0) }
        case .platforms:
            RecordSection(title: "Platforms", items: p.platforms,
                          empty: "No platforms recorded. Add one only with evidence such as a build file or a store listing, not a folder name.",
                          onAdd: { editing = .platform(nil) }, onEdit: { editing = .platform($0.id) },
                          onDelete: { r in model.update(p.id) { $0.platforms.removeAll { $0.id == r.id } } }) { pl in
                HStack(alignment: .firstTextBaseline) {
                    Text(pl.platform.title).bold().frame(width: 80, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pl.component ?? "—")
                        if let id = pl.identifier { Text(id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let v = pl.sourceVersion { Text("build \(v)").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                    EvidenceButton(verification: pl.verification)
                }
            }
        case .repositories:
            RecordSection(title: "Repositories", items: p.repositories, empty: "No repositories recorded.",
                          onAdd: { editing = .repository(nil) }, onEdit: { editing = .repository($0.id) },
                          onDelete: { r in model.update(p.id) { $0.repositories.removeAll { $0.id == r.id } } }) { r in
                RepositoryRow(repository: r, platforms: p.platforms(for: r))
            }
        case .stores:
            RecordSection(title: "Store listings", items: p.storeListings,
                          empty: "No store listings recorded. Unknown whether this product is on the App Store or Google Play.",
                          onAdd: { editing = .storeListing(nil) }, onEdit: { editing = .storeListing($0.id) },
                          onDelete: { r in model.update(p.id) { $0.storeListings.removeAll { $0.id == r.id } } }) { l in
                StoreListingRow(listing: l)
            }
        case .releases:
            RecordSection(title: "Releases", items: p.releases.sorted { ($0.releaseDate ?? .distantFuture) > ($1.releaseDate ?? .distantFuture) },
                          empty: "No releases recorded.", onAdd: { editing = .release(nil) },
                          onEdit: { editing = .release($0.id) },
                          onDelete: { r in model.update(p.id) { $0.releases.removeAll { $0.id == r.id } } }) { r in
                HStack {
                    Text(r.version).monospacedDigit().bold()
                    if let build = r.buildNumber { Text("(\(build))").foregroundStyle(.secondary) }
                    Text(r.platform.title)
                    Text(r.environment.title).foregroundStyle(.secondary)
                    if r.isReleaseCandidate { StatusBadge(text: "RC", color: .indigo) }
                    Spacer()
                    if let d = r.releaseDate { Text(d.shortDate).foregroundStyle(.secondary) }
                    StatusBadge(text: r.stage.title, color: r.stage.color)
                }
            }
        case .roadmap:
            RecordSection(title: "Roadmap", items: p.roadmap, empty: "No roadmap items recorded.",
                          onAdd: { editing = .roadmap(nil) }, onEdit: { editing = .roadmap($0.id) },
                          onDelete: { r in model.update(p.id) { $0.roadmap.removeAll { $0.id == r.id } } }) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.title).bold()
                        if !r.detail.isEmpty { Text(r.detail).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let v = r.targetVersion { Text(v).monospacedDigit().foregroundStyle(.secondary) }
                    if let d = r.targetDate { Text(d.shortDate).foregroundStyle(.secondary) }
                    StatusBadge(text: r.status.title, color: r.status.color)
                }
            }
        case .issues:
            RecordSection(title: "Issues", items: p.issues.sorted { ($0.isOpen ? 1 : 0, $0.severity) > ($1.isOpen ? 1 : 0, $1.severity) },
                          empty: "No issues recorded. GitHub issue sync is planned.",
                          onAdd: { editing = .issue(nil) }, onEdit: { editing = .issue($0.id) },
                          onDelete: { r in model.update(p.id) { $0.issues.removeAll { $0.id == r.id } } }) { i in
                HStack {
                    Image(systemName: i.isOpen ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(i.isOpen ? Color.primary : Color.green)
                    Text(i.title).strikethrough(!i.isOpen)
                    Spacer()
                    StatusBadge(text: i.severity.title, color: i.severity.color)
                }
            }
        case .deployments:
            RecordSection(title: "Deployments", items: p.deployments, empty: "No deployments recorded.",
                          onAdd: { editing = .deployment(nil) }, onEdit: { editing = .deployment($0.id) },
                          onDelete: { r in model.update(p.id) { $0.deployments.removeAll { $0.id == r.id } } }) { d in
                HStack {
                    Text(d.target).bold()
                    Text(d.environment.title).foregroundStyle(.secondary)
                    Spacer()
                    if let v = d.version { Text(v).monospacedDigit() }
                    if let at = d.deployedAt { Text(at.shortDate).foregroundStyle(.secondary) }
                    StatusBadge(text: d.status.title, color: d.status.color)
                }
            }
        case .links:
            LinksTab(product: p)
        case .verification:
            VerificationTab(product: p)
        }
    }

    @ViewBuilder
    private func editor(for editing: RecordEditing, product p: Product) -> some View {
        switch editing {
        case .product:
            ProductEditor(product: p) { model.upsert($0) }
        case .field(let field):
            FactEditor(field: field, state: p.state(of: field)) { text, verification in
                var updated = p
                guard updated.setField(field, text: text, verification: verification) else { return false }
                model.upsert(updated)
                return true
            }
        case .platform(let id):
            PlatformEditor(record: p.platforms.first { $0.id == id }) { r in model.update(p.id) { $0.platforms.upsert(r) } }
        case .repository(let id):
            RepositoryEditor(repository: p.repositories.first { $0.id == id }) { r in model.update(p.id) { $0.repositories.upsert(r) } }
        case .storeListing(let id):
            StoreListingEditor(listing: p.storeListings.first { $0.id == id }) { l in model.update(p.id) { $0.storeListings.upsert(l) } }
        case .release(let id):
            ReleaseEditor(release: p.releases.first { $0.id == id }, defaultPlatform: p.platforms.first?.platform ?? .unknown) { r in
                model.update(p.id) { $0.releases.upsert(r) }
            }
        case .roadmap(let id):
            RoadmapEditor(item: p.roadmap.first { $0.id == id }) { r in model.update(p.id) { $0.roadmap.upsert(r) } }
        case .issue(let id):
            IssueEditor(issue: p.issues.first { $0.id == id }) { r in model.update(p.id) { $0.issues.upsert(r) } }
        case .deployment(let id):
            DeploymentEditor(deployment: p.deployments.first { $0.id == id }) { r in model.update(p.id) { $0.deployments.upsert(r) } }
        }
    }
}

extension Array where Element: Identifiable {
    mutating func upsert(_ element: Element) {
        if let i = firstIndex(where: { $0.id == element.id }) { self[i] = element } else { append(element) }
    }
}

/// Every product fact on one row: label, value (or Unknown), verification badge with evidence, and Edit.
private struct OverviewTab: View {
    let product: Product
    let onEdit: (ProductField) -> Void
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if compact { compactFields } else { fieldGrid }
            footer
        }
    }

    /// One card-like block per field: label, badge and edit on top, the value below.
    private var compactFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(product.fieldStates) { state in
                VStack(alignment: .leading, spacing: 4) {
                    FitRow(spacing: 8) {
                        Text(state.field.title).font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        FitRow(spacing: 8) {
                            EvidenceButton(verification: state.verification)
                            Button("Edit…") { onEdit(state.field) }.buttonStyle(.borderless).font(.subheadline).fixedSize().minTapTarget()
                        }
                    }
                    fieldValue(state)
                    if !state.verification.notes.isEmpty {
                        Text(state.verification.notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func fieldValue(_ state: FieldState) -> some View {
        if state.field == .website, let text = state.displayValue, let url = URL(string: text) {
            Link(text, destination: url)
        } else {
            ValueOrUnknown(value: state.displayValue)
        }
    }

    private var fieldGrid: some View {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                ForEach(product.fieldStates) { state in
                    GridRow {
                        Text(state.field.title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            if state.field == .website, let text = state.displayValue, let url = URL(string: text) {
                                Link(text, destination: url)
                            } else {
                                ValueOrUnknown(value: state.displayValue)
                            }
                            if !state.verification.notes.isEmpty {
                                Text(state.verification.notes).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        EvidenceButton(verification: state.verification)
                            .gridColumnAlignment(.leading)
                        Button("Edit…") { onEdit(state.field) }
                            .buttonStyle(.borderless)
                    }
                }
            }
    }

    @ViewBuilder
    private var footer: some View {
            if !product.notes.isEmpty {
                GroupBox("Notes") {
                    Text(product.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            let issues = product.integrityIssues
            if !issues.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues, id: \.self) { Text($0).font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Record problems", systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                }
            }
    }
}

private struct RepositoryRow: View {
    let repository: RepositoryRecord
    /// Platforms whose evidence is a file in this repository.
    let platforms: [PlatformRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: repository.host == .github ? "externaldrive.connected.to.line.below" : "folder")
                if let url = repository.url {
                    Link(repository.gitHubSlug ?? repository.name, destination: url).bold()
                } else {
                    Text(repository.name).bold()
                }
                StatusBadge(text: repository.type.title, color: .indigo)
                if let vis = repository.gitHub?.visibility { StatusBadge(text: vis.title, color: vis == .public ? .teal : .gray) }
                Spacer()
                Text("Link").font(.caption).foregroundStyle(.secondary)
                EvidenceButton(verification: repository.link)
            }
            if let gh = repository.gitHub {
                Text(gh.description ?? String(localized: "No GitHub description")).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(gh.defaultBranch, systemImage: "arrow.triangle.branch")
                    if let c = gh.latestCommit {
                        Label("\(String(c.sha.prefix(7))) \(c.date?.shortDate ?? "")", systemImage: "circle.dotted")
                            .help(c.message)
                    }
                    Label(gh.latestRelease.map { String(localized: "\(gh.releaseCount ?? 0) releases · latest \($0.tag)") } ?? String(localized: "\(gh.releaseCount ?? 0) releases"), systemImage: "tag")
                    Label(String(localized: "\(gh.openPullRequests ?? 0) PRs"), systemImage: "arrow.triangle.pull")
                    Label(String(localized: "\(gh.openIssues ?? 0) issues"), systemImage: "exclamationmark.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    if !gh.languages.isEmpty {
                        Text(gh.languages.prefix(5).joined(separator: " · ")).font(.caption)
                    }
                    Spacer()
                    Text("GitHub snapshot \(gh.fetchedAt.shortDate)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(repository.localCheckouts) { c in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer").font(.caption)
                        Text(c.path).font(.caption.monospaced()).textSelection(.enabled)
                        if let b = c.branch { Text("on \(b)").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let commit = c.lastCommit {
                        Text("\(String(commit.sha.prefix(7))) \(commit.date?.shortDate ?? "") — \(commit.message)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !c.notes.isEmpty { Text(c.notes).font(.caption).foregroundStyle(.orange) }
                }
            }
            if !platforms.isEmpty {
                let names = Array(Set(platforms.map(\.platform))).sorted { $0.rawValue < $1.rawValue }.map(\.title)
                Label("Platforms from this repository: \(names.joined(separator: " · "))", systemImage: "square.stack.3d.up")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !repository.notes.isEmpty { Text(repository.notes).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// How the product's verification state is derived: per-area counts, open questions and every source.
private struct VerificationTab: View {
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                VerificationBadge(status: product.verificationState)
                if let at = product.lastVerifiedAt {
                    Text("Last verified \(at.shortDate)").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Never verified").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(product.sources.count) sources").font(.callout).foregroundStyle(.secondary)
            }
            Text("Derived from the evidence below. It can't be set by hand: add or confirm evidence instead.")
                .font(.caption).foregroundStyle(.secondary)

            GroupBox("By area") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                    ForEach(product.verificationBreakdown) { area in
                        GridRow {
                            Text(area.area.title).bold()
                            VerificationBadge(status: area.status, compact: true)
                            Text(area.total == 0 ? String(localized: "None recorded") : summary(area))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            let open = product.needsConfirmation
            if !open.isEmpty {
                GroupBox("Needs confirmation") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(open.indices, id: \.self) { i in
                            HStack {
                                Text(open[i].label)
                                Spacer()
                                EvidenceButton(verification: open[i].verification)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            GroupBox("Evidence") {
                if product.sources.isEmpty {
                    Text("No sources recorded.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(product.sources) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    StatusBadge(text: s.sourceType.title, color: s.sourceType.isLocal ? .indigo : .teal)
                                    Text(s.sourceReference).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(s.verifiedAt.shortDate).font(.caption).foregroundStyle(.secondary)
                                }
                                if let value = s.observedValue {
                                    Text(value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ area: AreaVerification) -> String {
        VerificationStatus.allCases.compactMap { status in
            let n = area.count(status)
            return n == 0 ? nil : "\(n.formatted()) \(status.title)"
        }.joined(separator: " · ")
    }
}

private struct StoreListingRow: View {
    let listing: StoreListing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: listing.store == .appStore ? "applelogo" : "play.rectangle")
                Text(listing.appName ?? String(localized: "Unnamed app")).bold()
                if let id = listing.appIdentifier { Text(id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Spacer()
                if listing.reviewStatus != nil { ReviewPhaseBadge(phase: listing.reviewPhase).help(listing.reviewStatus ?? "") }
                EvidenceButton(verification: listing.verification)
            }
            HStack(spacing: 14) {
                Text("Live: \(listing.productionVersion ?? String(localized: "unknown"))")
                if let s = listing.latestSubmittedVersion { Text("Submitted: \(s)") }
                if let r = listing.reviewStatus { Text(r).lineLimit(1) }
                if let sf = listing.storefront { Text("Storefront: \(sf)") }
                if let seller = listing.seller { Text("Seller: \(seller)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let url = listing.url { Link(url.absoluteString, destination: url).font(.caption) }
            if let insights = listing.insights {
                if listing.store == .appStore { RatingLabel(insights: insights).font(.callout) }
                if !insights.reviews.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(insights.reviews.prefix(5)) { ReviewRow(review: $0) }
                        }
                        .padding(.top, 4)
                    } label: {
                        Label("Recent reviews (\(insights.reviews.count))", systemImage: "text.bubble").font(.callout)
                    }
                }
                if !insights.testBuilds.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(insights.testBuilds) { TestBuildRow(build: $0) }
                        }
                        .padding(.top, 4)
                    } label: {
                        Label("TestFlight builds (\(insights.testBuilds.count))", systemImage: "airplane").font(.callout)
                    }
                }
            }
        }
    }
}

private struct ReviewRow: View {
    let review: CustomerReview

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Stars as text plus a label, so the rating isn't carried by the glyphs alone.
                Text(String(repeating: "★", count: max(0, min(5, review.rating))) + String(repeating: "☆", count: max(0, 5 - review.rating)))
                    .foregroundStyle(review.rating <= 2 ? .orange : .yellow)
                    .accessibilityLabel(Text("\(review.rating) of 5 stars"))
                if let title = review.title { Text(title).bold() }
                Spacer(minLength: 0)
                if let date = review.createdAt { Text(date.shortDate).foregroundStyle(.secondary) }
            }
            if let body = review.body { Text(body).lineLimit(3).textSelection(.enabled) }
            if let who = review.reviewer { Text(verbatim: "— \(who)\(review.territory.map { " · \($0)" } ?? "")").foregroundStyle(.secondary) }
        }
        .font(.caption)
    }
}

private struct TestBuildRow: View {
    let build: TestBuild

    var body: some View {
        HStack(spacing: 8) {
            Text(build.label).monospacedDigit().bold()
            if let p = build.platform { Text(p == "MAC_OS" ? "macOS" : p == "IOS" ? "iOS" : p).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if build.expired {
                StatusBadge(text: "Expired", color: .gray)
            } else if build.processingState == "VALID" {
                if let days = build.daysUntilExpiry(from: .now) {
                    StatusBadge(text: String(localized: "Expires in \(days) days"), color: .orange)
                } else if let expires = build.expiresAt {
                    Text("Expires \(expires.shortDate)").foregroundStyle(.secondary)
                }
            } else {
                StatusBadge(text: build.processingState.map(humanizeState) ?? String(localized: "Unknown"), color: .blue)
            }
        }
        .font(.caption)
    }
}

private struct LinksTab: View {
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            linkGroup("Documentation", product.documentation)
            linkGroup("Analytics", product.analytics)
            GroupBox("Social accounts") {
                if product.socialAccounts.isEmpty {
                    Text("None recorded.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(product.socialAccounts) { a in
                        LabeledContent(a.network.title, value: a.handle)
                    }
                }
            }
            Text("Editing documentation, analytics and social links will come with the Marketing module.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func linkGroup(_ title: String, _ links: [DocumentLink]) -> some View {
        GroupBox(title) {
            if links.isEmpty {
                Text("None recorded.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(links) { Link($0.title, destination: $0.url).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
}

/// A titled list of child records with Add, Edit (double-click) and Delete actions.
struct RecordSection<Item: Identifiable, Row: View>: View {
    let title: String
    let items: [Item]
    let empty: String
    let onAdd: () -> Void
    let onEdit: (Item) -> Void
    let onDelete: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(title)).font(.headline)
                Text(items.count, format: .number).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(action: onAdd) { Label("Add", systemImage: "plus") }
            }
            if items.isEmpty {
                Text(LocalizedStringKey(empty)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onEdit(item) }
                            .contextMenu {
                                Button("Edit…") { onEdit(item) }
                                Button("Delete", role: .destructive) { onDelete(item) }
                            }
                        Divider()
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                Text("Double-click a row to edit. Right-click for more actions. Click a badge to see its evidence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
