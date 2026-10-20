import Foundation
import LinumicCore
import Network
import Observation
import UserNotifications
#if os(macOS)
import AppKit
import ServiceManagement
#else
import BackgroundTasks
#endif

/// Automation (خودکارسازی): runs every job in `AutomationCatalog` on its own schedule for as long as the app runs,
/// with or without a window (the menu bar keeps it alive on the Mac). It owns the timing that each screen used to
/// keep for itself: retries with backoff after a failure, waits while offline and runs again when the network
/// returns, catches up after the Mac wakes, slows down in Low Power Mode, and records every run in
/// `automation.json` on this device. Jobs only read, as before; nothing here writes to a product.
@MainActor
@Observable
final class AutomationEngine {
    static let backgroundTaskID = "com.linumic.commandcenter.refresh"

    private(set) var ledger: AutomationLedger
    /// The job running right now.
    private(set) var running: AutomationJobID?
    /// Jobs waiting for the running one to finish ("Run all now" queues every job).
    private(set) var waiting: [AutomationJobID] = []
    private(set) var online = true
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var isReady = false
    let startedAt = Date.now
    /// What `Backups/` holds, read from the disk (newest file, its day, read back or not). The run log alone never
    /// stands for a backup: a "succeeded" run whose file is gone is shown as gone.
    private(set) var backupFolder: BackupFolderStatus?

    /// The jobs this device runs. Keys & Backups reads files on the Mac only.
    let specs: [AutomationJobSpec]

    private let store: AutomationStore?
    private let inventory: InventoryModel
    private let licences: LicenceModel
    private let platforms: PlatformHubModel
    private let worktrack: WorkTrackModel
    private let operations: OperationsModel
    private let releases: ReleaseCenterModel
    private let monitor: MonitorModel
    private let brief: BriefModel
    private let keys: KeysModel
    private let siteMessages: SiteMessagesModel
    private let sentinel: SentinelModel
    private let desk: DeskModel
    private let obligations: ObligationsModel
    private let deskSync: DeskSyncModel
    private let legal: LegalModel
    /// What a run that did the work left on disk (the backup's file name), recorded with the run.
    private var pendingArtifacts: [AutomationJobID: String] = [:]

    private var bootstrap: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var nudged: AutomationTrigger?
    /// Runs one job at a time, whoever asked for it (the schedule, "Run now", iOS background refresh).
    private var tail: Task<Void, Never>?
    private let path = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    init(inventory: InventoryModel, licences: LicenceModel, platforms: PlatformHubModel, worktrack: WorkTrackModel,
         operations: OperationsModel, releases: ReleaseCenterModel, monitor: MonitorModel, brief: BriefModel,
         keys: KeysModel, siteMessages: SiteMessagesModel, sentinel: SentinelModel, desk: DeskModel,
         obligations: ObligationsModel, deskSync: DeskSyncModel, legal: LegalModel) {
        self.inventory = inventory
        self.licences = licences
        self.platforms = platforms
        self.worktrack = worktrack
        self.operations = operations
        self.releases = releases
        self.monitor = monitor
        self.brief = brief
        self.keys = keys
        self.siteMessages = siteMessages
        self.sentinel = sentinel
        self.desk = desk
        self.obligations = obligations
        self.deskSync = deskSync
        self.legal = legal
        #if os(macOS)
        specs = AutomationCatalog.jobs
        #else
        // Keys & Backups, the ledgers and the legal folder are read on the Mac.
        specs = AutomationCatalog.jobs.filter { $0.id != .keys && $0.id != .ledgers && $0.id != .legal }
        #endif
        store = (try? AutomationStore.defaultFileURL()).map(AutomationStore.init(fileURL:))
        ledger = store?.load() ?? AutomationLedger()
        NotificationGate.quietHours = ledger.quietHours
        brief.automation = ledger
    }

    // MARK: Reading

    var conditions: AutomationConditions {
        AutomationConditions(online: online, lowPower: lowPower, pausedUntil: ledger.pausedUntil)
    }

    var health: AutomationHealth { AutomationHealth(ledger: ledger, specs: specs) }
    var isPaused: Bool { conditions.isPaused(at: .now) }
    func state(_ job: AutomationJobID) -> AutomationJobState? { ledger.states[job] }
    func isEnabled(_ job: AutomationJobID) -> Bool { !ledger.disabled.contains(job) }

    /// When the job runs next; nil when it is due now (never run yet).
    func nextDue(_ job: AutomationJobID) -> Date? {
        AutomationScheduler.nextDue(AutomationCatalog.spec(job), state: ledger.states[job], lowPower: lowPower, cadence: cadences[job],
                                    artifactMissing: missingArtifacts.contains(job))
    }

    /// Jobs whose last successful run's file is gone from the disk: the backup, when the copy it wrote or confirmed is
    /// no longer in `Backups/`. A directory listing only, cheap enough for every look of the loop.
    private var missingArtifacts: Set<AutomationJobID> {
        guard let backup = try? InventoryBackup.default() else { return [] }
        // A folder that can't be listed is left to the job's own run to report.
        guard let names = try? (backup.files() ?? []).map(\.name) else { return [] }
        return InventoryBackup.artifactMissing(ledger.states[.backup], fileNames: names) ? [.backup] : []
    }

    /// Reads `Backups/` and its newest copy now (off the main actor) for the Desk, the Brief and the Automation screen.
    func refreshBackupStatus() async {
        let status = await Task.detached(priority: .utility) { () -> BackupFolderStatus? in
            (try? InventoryBackup.default())?.status()
        }.value
        backupFolder = status
        brief.backup = status
    }

    /// The Monitor stretches its own interval after rounds in which nothing answered.
    private var cadences: [AutomationJobID: TimeInterval] {
        [.monitor: MonitorSchedule.interval(failedRounds: monitor.snapshot.failedRounds, lowPower: false)]
    }

    // MARK: Lifecycle

    /// Loads every model, then runs the schedule until the app quits. Called once, at launch.
    func start() {
        guard bootstrap == nil else { return }
        observeSystem()
        bootstrap = Task {
            await inventory.load()
            await licences.load()
            await platforms.load()
            await worktrack.load()
            await operations.load()
            await releases.load()
            // Local files only: the Desk shows the ledgers (or "not granted") from the first moment.
            await desk.refreshLedgers()
            // The legal folder too (or "not granted"): local files only, read-only.
            await legal.refresh()
            // The backup is what the folder holds, from the first moment too.
            await refreshBackupStatus()
            // Asked once, up front, so the first real alert isn't lost to a prompt nobody saw.
            await StoreNotifier.requestPermission()
            isReady = true
        }
        loop = Task { await run() }
    }

    private func run() async {
        await bootstrap?.value
        var trigger = AutomationTrigger.launch
        while !Task.isCancelled {
            let due = AutomationScheduler.dueJobs(specs, states: ledger.states, disabled: ledger.disabled, conditions: conditions,
                                                  now: .now, cadences: cadences, missingArtifacts: missingArtifacts)
            for job in due { await execute(job, trigger: trigger) }
            trigger = .schedule
            if nudged == nil {
                let wait = AutomationScheduler.sleepInterval(specs, states: ledger.states, disabled: ledger.disabled,
                                                             conditions: conditions, now: .now, cadences: cadences,
                                                             missingArtifacts: missingArtifacts)
                // A floor, so a job that can never finish "due" can't spin the loop.
                await sleep(max(wait, due.isEmpty ? 5 : 1))
            }
            if let t = nudged {
                trigger = t
                nudged = nil
            }
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        let t = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        sleeper = t
        await t.value
        sleeper = nil
    }

    /// Wakes the loop to look at once (the Mac woke, the network returned, a setting changed).
    func nudge(_ trigger: AutomationTrigger) {
        nudged = trigger
        sleeper?.cancel()
    }

    // MARK: Commands

    func runNow(_ job: AutomationJobID) {
        Task { await execute(job, trigger: .manual) }
    }

    func runAll() {
        let jobs = specs.map(\.id).filter(isEnabled)
        Task { for job in jobs { await execute(job, trigger: .manual) } }
    }

    func pause(for interval: TimeInterval) {
        ledger.pausedUntil = .now.addingTimeInterval(interval)
        save()
        nudge(.schedule)
    }

    func resume() {
        ledger.pausedUntil = nil
        save()
        nudge(.schedule)
    }

    func setEnabled(_ job: AutomationJobID, _ on: Bool) {
        if on { ledger.disabled.remove(job) } else { ledger.disabled.insert(job) }
        save()
        nudge(.schedule)
    }

    func setQuietHours(_ q: QuietHours) {
        ledger.quietHours = q
        NotificationGate.quietHours = q
        save()
    }

    // MARK: Running one job

    func execute(_ job: AutomationJobID, trigger: AutomationTrigger) async {
        waiting.append(job)
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            if let i = waiting.firstIndex(of: job) { waiting.remove(at: i) }
            await perform(job, trigger: trigger)
        }
        tail = task
        await task.value
    }

    private func perform(_ job: AutomationJobID, trigger: AutomationTrigger) async {
        let spec = AutomationCatalog.spec(job)
        running = job
        defer { running = nil }
        let started = Date.now
        let clock = ContinuousClock.now
        let outcome: AutomationOutcome
        if spec.needsNetwork, !online {
            outcome = .skipped(.offline)
        } else if let key = spec.settingsKey, UserDefaults.standard.object(forKey: key) as? Bool == false {
            outcome = .skipped(.turnedOff)
        } else if !isReady {
            outcome = .skipped(.notReady)
        } else {
            outcome = await workWithin(spec, started: started)
        }
        let elapsed = ContinuousClock.now - clock
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let failuresBefore = ledger.states[job]?.consecutiveFailures ?? 0
        ledger.record(AutomationRun(job: job, trigger: trigger, startedAt: started, duration: duration, outcome: outcome),
                      artifact: pendingArtifacts.removeValue(forKey: job))
        save()
        if job == .backup { await refreshBackupStatus() }
        let failures = ledger.states[job]?.consecutiveFailures ?? 0
        if failures == AutomationHealth.failingAfter, case .failed(let message) = outcome {
            await AutomationNotifier.failing(spec, count: failures, message: message)
        } else if failuresBefore >= AutomationHealth.failingAfter, failures == 0 {
            await AutomationNotifier.recovered(spec)
        }
    }

    /// Runs the job's work, but answers after `spec.timeLimit` at the latest: the work is then cancelled (URLSession
    /// requests stop on cancellation) and the run is recorded as failed. If the work ignores cancellation it finishes in
    /// the background; its model's own "already refreshing" guard keeps the next run from overlapping it.
    private func workWithin(_ spec: AutomationJobSpec, started: Date) async -> AutomationOutcome {
        let race = OutcomeRace()
        let work = Task { @MainActor in
            let outcome = await self.work(spec.id, started: started)
            race.finish(outcome)
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(spec.timeLimit))
            guard !Task.isCancelled else { return }
            work.cancel()
            race.finish(.failed(String(localized: "Stopped after \(Int(spec.timeLimit / 60)) minutes without an answer.")))
        }
        let outcome = await race.value
        timer.cancel()
        return outcome
    }

    private func save() {
        try? store?.save(ledger)
        brief.automation = ledger
    }

    /// Does the job's work through its screen's own model and says what happened. Read-only, as each model is.
    private func work(_ job: AutomationJobID, started: Date) async -> AutomationOutcome {
        switch job {
        case .monitor:
            guard !monitor.isChecking else { return .skipped(.alreadyRunning) }
            await monitor.checkNow()
            if monitor.snapshot.failedRounds > 0 {
                return .failed(String(localized: "No public address answered. The network may be down."))
            }
            let down = monitor.targets.filter { monitor.result(for: $0)?.state == .down }.count
            return .succeeded(down == 0
                ? String(localized: "\(monitor.targets.count) addresses up")
                : String(localized: "\(monitor.targets.count) addresses checked, \(down) down"))

        case .sentinel:
            switch await sentinel.refresh() {
            case .notConnected: return .skipped(.notConnected)
            case .notDeployed: return .skipped(.notDeployed)
            case .failed(let message): return .failed(message)
            case .read:
                guard let summary = sentinel.summary else { return .succeeded(nil) }
                switch summary.health {
                case .notRunning: return .failed(String(localized: "The server has not run a round yet."))
                case .stale(let at): return .failed(String(localized: "The server's last round was \(at.formatted(date: .omitted, time: .shortened)); its schedule may have stopped."))
                case .down(let count): return .succeeded(String(localized: "Server sees \(count) down; \(summary.unacknowledged) events not acknowledged"))
                case .allUp, .slow: return .succeeded(String(localized: "Server sees everything up; \(summary.unacknowledged) events not acknowledged"))
                }
            }

        case .stores:
            guard inventory.isLoaded else { return .skipped(.notReady) }
            await inventory.refreshAppStore()
            var failed = inventory.lastAppStoreSync?.report.failed.count ?? 0
            var updated = inventory.lastAppStoreSync?.report.updated.count ?? 0
            var errors: [String] = []
            for store in AppStore.allCases where inventory.hasConsoleCredentials(store) {
                let before = inventory.errorMessage
                await inventory.refreshFromConsole(store)
                if let message = inventory.errorMessage, message != before { errors.append(message) }
                if let sync = inventory.lastConsoleSync[store], sync.at >= started {
                    failed += sync.report.failed.count
                    updated += sync.report.updated.count
                }
            }
            if updated == 0, !errors.isEmpty || failed > 0 {
                return .failed(errors.first ?? String(localized: "\(failed) listings could not be read."))
            }
            if failed > 0 || !errors.isEmpty {
                return .partial(String(localized: "\(updated) listings read, \(failed + errors.count) failed"))
            }
            return .succeeded(String(localized: "\(updated) listings read"))

        case .oversight:
            guard inventory.isLoaded else { return .skipped(.notReady) }
            guard inventory.hasGitHubToken else { return .skipped(.notConnected) }
            guard !inventory.isSyncingOversight else { return .skipped(.alreadyRunning) }
            await inventory.refreshOversight()
            if inventory.hasWorkspace { await inventory.refreshLocal() }
            guard let sync = inventory.lastOversightSync, sync.at >= started else {
                return .failed(inventory.errorMessage ?? String(localized: "The sweep did not finish."))
            }
            if let listError = sync.report.listError { return .failed(listError) }
            if !sync.report.failed.isEmpty {
                return .partial(String(localized: "\(sync.report.updated.count) repositories read, \(sync.report.failed.count) failed")
                                + Self.firstFailure(sync.report.failed))
            }
            return .succeeded(String(localized: "\(sync.report.updated.count) repositories read"))

        case .platforms:
            guard inventory.isLoaded else { return .skipped(.notReady) }
            guard inventory.hasGitHubToken else { return .skipped(.notConnected) }
            guard !platforms.isRefreshing else { return .skipped(.alreadyRunning) }
            platforms.errorMessage = nil
            await platforms.refresh()
            guard let last = platforms.lastRefresh, last >= started, let report = platforms.lastReport else {
                return .failed(platforms.errorMessage ?? String(localized: "The platforms were not read."))
            }
            if !report.failed.isEmpty {
                return .partial(String(localized: "\(report.updated.count) repositories read, \(report.failed.count) failed")
                                + Self.firstFailure(report.failed))
            }
            return .succeeded(String(localized: "\(report.updated.count) repositories read"))

        case .releases:
            guard inventory.isLoaded else { return .skipped(.notReady) }
            guard releases.hasAppStoreKey || releases.hasPlayKey || inventory.hasGitHubToken else { return .skipped(.notConnected) }
            guard !releases.isRefreshing else { return .skipped(.alreadyRunning) }
            await releases.refresh()
            let s = releases.snapshot
            let sources: [(tried: Bool, readAt: Date?, note: String?)] = [
                (releases.hasAppStoreKey, s.appStoreReadAt, s.appStoreNote),
                (releases.hasPlayKey, s.playReadAt, s.playNote),
                (true, s.gitHubReadAt, s.gitHubNote),
            ]
            let tried = sources.filter(\.tried)
            let fresh = tried.filter { ($0.readAt ?? .distantPast) >= started }
            let notes = tried.filter { ($0.readAt ?? .distantPast) < started }.compactMap(\.note)
            if fresh.isEmpty { return .failed(notes.first ?? String(localized: "Nothing could be read.")) }
            if fresh.count < tried.count { return .partial(notes.joined(separator: " ")) }
            return .succeeded(String(localized: "\(s.waiting.count) items waiting on you"))

        case .licences:
            guard licences.isLoaded else { return .skipped(.notReady) }
            guard inventory.licenceRemote() != nil else { return .skipped(.notConnected) }
            await licences.sync()
            switch licences.syncState {
            case .synced: return .succeeded(String(localized: "\(licences.records.count) licences in step with the cloud"))
            case .offline(let m), .pendingUpload(let m): return .failed(m)
            case .localOnly: return .skipped(.notConnected)
            }

        case .worktrack:
            guard worktrack.isSignedIn else { return .skipped(.notConnected) }
            guard !worktrack.isRefreshing else { return .skipped(.alreadyRunning) }
            await worktrack.refresh()
            if let error = worktrack.loadError { return .failed(error) }
            guard (worktrack.lastRead ?? .distantPast) >= started else { return .failed(String(localized: "WorkTrack was not read.")) }
            // Money's parts are secondary: a failure there is partial, so renewal reminders keep their schedule.
            if let money = worktrack.moneyError { return .partial(String(localized: "\(worktrack.companies.count) companies read; money: \(money)")) }
            return .succeeded(String(localized: "\(worktrack.companies.count) companies read"))

        case .operations:
            var read: [String] = []
            var errors: [String] = []
            if operations.talar.isSignedIn {
                await operations.talar.refresh()
                if let e = operations.talar.loadError { errors.append("Talar: \(e)") } else { read.append("Talar") }
            }
            if operations.safeBeauty.isSignedIn {
                await operations.safeBeauty.refresh()
                if let e = operations.safeBeauty.loadError { errors.append("SafeBeauty: \(e)") } else { read.append("SafeBeauty") }
                if operations.safeBeauty.loadError == nil, let e = operations.safeBeauty.balancesError { errors.append("SafeBeauty money: \(e)") }
            }
            if operations.velro.isSignedIn {
                await operations.velro.refresh()
                if let e = operations.velro.loadError { errors.append("VELRO: \(e)") } else { read.append("VELRO") }
            }
            if read.isEmpty, errors.isEmpty { return .skipped(.notConnected) }
            if read.isEmpty { return .failed(errors.joined(separator: " ")) }
            if !errors.isEmpty { return .partial(errors.joined(separator: " ")) }
            return .succeeded(read.formatted(.list(type: .and)))

        case .siteMessages:
            guard !siteMessages.isRefreshing else { return .skipped(.alreadyRunning) }
            await siteMessages.refresh()
            guard siteMessages.isConfigured, !siteMessages.needsSiteSetup else { return .skipped(.notConnected) }
            if let error = siteMessages.loadError { return .failed(error) }
            return .succeeded(String(localized: "\(siteMessages.reading?.messages.count ?? 0) recent messages read"))

        case .keys:
            #if os(macOS)
            guard !KeysAccessStore.resolveAll().isEmpty else { return .skipped(.notConnected) }
            guard !keys.isChecking else { return .skipped(.alreadyRunning) }
            await keys.check()
            if let error = keys.errorMessage ?? keys.loadError { return .failed(error) }
            return .succeeded(String(localized: "\(keys.results.count) key files checked"))
            #else
            return .skipped(.notConnected)
            #endif

        case .backup:
            let result = await Task.detached(priority: .utility) { () -> Result<InventoryBackup.Result, Error> in
                Result { try InventoryBackup.default().run() }
            }.value
            switch result {
            case .success(let r) where r.kind == .unchanged:
                pendingArtifacts[.backup] = r.file.lastPathComponent
                return .succeeded(String(localized: "Unchanged since \(r.file.lastPathComponent); it still restores (\(r.products) products)"))
            case .success(let r):
                pendingArtifacts[.backup] = r.file.lastPathComponent
                return .succeeded(String(localized: "\(r.file.lastPathComponent) saved and read back: \(r.products) products"))
            case .failure(InventoryBackup.BackupError.noInventory):
                return .skipped(.notReady)
            case .failure(let error):
                return .failed(error.localizedDescription)
            }

        case .deskSync:
            switch await deskSync.sync() {
            case .notConnected: return .skipped(.notConnected)
            case .notDeployed: return .skipped(.notDeployed)
            case .failed(let message): return .failed(message)
            case .synced(let report):
                if report.conflicts > 0 {
                    return .partial(String(localized: "\(report.conflicts) changed on two devices: choose on the Desk"))
                }
                if report.refused > 0 {
                    return .partial(String(localized: "\(report.refused) not accepted by the server; see Settings → Account"))
                }
                return .succeeded(report.summary)
            }

        case .legal:
            #if os(macOS)
            guard !legal.isReading else { return .skipped(.alreadyRunning) }
            await legal.refresh()
            guard let access = legal.access, let reading = legal.reading else { return .failed(String(localized: "The legal folder was not read.")) }
            switch access {
            case .notGranted: return .skipped(.notConnected)
            case .granted, .readableWithoutGrant:
                guard reading.state == .read else { return .failed(LegalBrief.notReadText(access, reading: reading) ?? "") }
                let counts = LegalMarkerKind.allCases.map { "\(reading.count($0)) \($0.label)" }.joined(separator: ", ")
                if !reading.isComplete {
                    return .partial(String(localized: "At least \(counts); \(reading.unreadFiles.count) files not read"))
                }
                return .succeeded(String(localized: "\(counts) in \(reading.files.count) files; \(reading.asasnama.count) Asasnama files named"))
            default:
                return .failed(LegalBrief.notReadText(access, reading: reading) ?? access.ownerStep ?? "")
            }
            #else
            return .skipped(.notConnected)
            #endif

        case .ledgers:
            #if os(macOS)
            guard !desk.isReading else { return .skipped(.alreadyRunning) }
            // Read even without a grant: each ledger is then recorded as "not granted" for the Desk.
            await desk.refreshLedgers()
            guard let reading = desk.reading else { return .failed(String(localized: "The ledgers were not read.")) }
            if LedgerAccessStore.grantedPaths().isEmpty { return .skipped(.notConnected) }
            let read = reading.files.filter(\.isRead)
            let open = desk.desk().open.count { $0.item.kind == .task }
            if read.isEmpty {
                return .failed(String(localized: "No ledger could be read: \(reading.files.count) not granted, not found or unreadable."))
            }
            if read.count < reading.files.count {
                return .partial(String(localized: "\(read.count) of \(reading.files.count) ledgers read, \(open) open items"))
            }
            // Lines set aside are owner items that could not be read: not a clean success.
            let skipped = read.reduce(0) { sum, file in
                switch file.status {
                case .read(.priorities(let p)): sum + p.skippedLines.count
                case .read(.nextActions(let n)): sum + n.skippedLines.count
                default: sum
                }
            }
            if skipped > 0 {
                return .partial(String(localized: "\(read.count) ledgers read, \(open) open items, \(skipped) lines set aside"))
            }
            return .succeeded(String(localized: "\(read.count) ledgers read, \(open) open items"))
            #else
            return .skipped(.notConnected)
            #endif

        case .brief:
            await refreshBackupStatus()
            await brief.record()
            desk.pruneObsoleteMarks()
            await obligations.postDueAlerts()
            return .succeeded(nil)
        }
    }

    /// ": owner/repo: HTTP 404" for the first failure (by name), so a partial run says why without opening its screen.
    private static func firstFailure(_ failed: [String: String]) -> String {
        guard let name = failed.keys.sorted().first, let reason = failed[name] else { return "" }
        return ". \(name): \(reason)"
    }

    // MARK: System events

    private func observeSystem() {
        path.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.setOnline(satisfied) }
        }
        path.start(queue: DispatchQueue(label: "com.linumic.automation.path"))
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.nudge(.schedule)
            }
        })
        #if os(macOS)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.nudge(.wake) }
        })
        #endif
    }

    private func setOnline(_ value: Bool) {
        let cameBack = value && !online
        online = value
        if cameBack { nudge(.network) }
    }

    // MARK: iOS background refresh

    #if os(iOS)
    /// Asks iOS for a background refresh in about 30 minutes (iOS decides when, or whether, it happens).
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The few seconds iOS gives in the background: only the light jobs, and only when due.
    func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        await bootstrap?.value
        guard !isPaused else { return }
        for spec in specs where spec.runsInBackground && isEnabled(spec.id)
            && AutomationScheduler.isDue(spec, state: ledger.states[spec.id], now: .now, lowPower: lowPower, cadence: cadences[spec.id],
                                         artifactMissing: missingArtifacts.contains(spec.id)) {
            await execute(spec.id, trigger: .background)
        }
    }
    #endif
}

/// The first of two finishers wins: the job's work or its time limit.
private final class OutcomeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AutomationOutcome?
    private var waiter: CheckedContinuation<AutomationOutcome, Never>?

    func finish(_ outcome: AutomationOutcome) {
        let resume: CheckedContinuation<AutomationOutcome, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = outcome
            defer { waiter = nil }
            return waiter
        }
        resume?.resume(returning: outcome)
    }

    var value: AutomationOutcome {
        get async {
            await withCheckedContinuation { continuation in
                let ready: AutomationOutcome? = lock.withLock {
                    if let result { return result }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

// MARK: - Notifications

/// Quiet hours for every alert the app posts: during them a notification still arrives in Notification Center, but
/// silently (no banner, no sound). Scheduled reminders (licences, the morning Brief) keep the time the owner chose.
@MainActor
enum NotificationGate {
    static var quietHours = QuietHours()

    static func apply(_ content: UNMutableNotificationContent, now: Date = .now) {
        guard quietHours.contains(now) else { return }
        content.sound = nil
        content.interruptionLevel = .passive
    }
}

@MainActor
enum AutomationNotifier {
    static let notifyKey = "LCCNotifyAutomation"
    static var isOn: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }

    static func failing(_ spec: AutomationJobSpec, count: Int, message: String) async {
        await post(id: "automation.\(spec.id.rawValue).failing",
                   title: String(localized: "\(L(spec.title)) keeps failing"),
                   body: String(localized: "\(count) times in a row: \(message)"))
    }

    static func recovered(_ spec: AutomationJobSpec) async {
        await post(id: "automation.\(spec.id.rawValue).recovered",
                   title: String(localized: "\(L(spec.title)) works again"),
                   body: String(localized: "The last automatic run succeeded."))
    }

    private static func post(id: String, title: String, body: String) async {
        guard isOn else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        NotificationGate.apply(content)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// MARK: - Mac: login item, menu bar and Dock

#if os(macOS)
/// Opens Linumic OS when the owner logs in (System Settings > General > Login Items), through `SMAppService`.
/// The owner's choice is also kept in `wantedKey`, and every launch makes the system match it, so the login item
/// survives a reinstall or a move of the app (the registration belongs to one copy of the app).
enum LoginItem {
    static let wantedKey = "LCCOpenAtLogin"
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isOn: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) throws {
        UserDefaults.standard.set(on, forKey: wantedKey)
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// At launch: registers when the owner asked for it and this copy isn't registered yet. Never unregisters on its
    /// own, and does nothing when the owner never chose.
    static func reconcile() {
        guard UserDefaults.standard.bool(forKey: wantedKey), status == .notRegistered || status == .notFound else { return }
        try? SMAppService.mainApp.register()
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Where the app shows itself when no window is open.
enum MacPresence {
    static let menuBarKey = "LCCShowMenuBar"
    static let hideDockKey = "LCCHideDockWhenClosed"
    static let startHiddenKey = "LCCStartInMenuBar"

    static var hidesDock: Bool { UserDefaults.standard.bool(forKey: hideDockKey) }
    static var startsHidden: Bool { UserDefaults.standard.bool(forKey: startHiddenKey) }

    /// The app's own document windows (not the menu bar panel, sheets or alerts).
    static var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Back to a normal app with a Dock icon, in front.
    static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// After the last window closes: leave only the menu bar item if the owner chose that.
    static func windowClosed() {
        guard hidesDock, UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true else { return }
        // The closing window is still listed until the next run loop turn.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if mainWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observer: NSObjectProtocol?

    /// Closing the last window doesn't quit: the automation keeps running behind the menu bar item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.reconcile()
        if MacPresence.startsHidden, MacPresence.hidesDock { NSApp.setActivationPolicy(.accessory) }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacPresence.windowClosed() }
        }
    }
}
#endif
