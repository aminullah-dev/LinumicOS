import Foundation
import LinumicCore
import Observation

/// Observable wrapper around the inventory store. Views read and mutate products
/// only through this type, and every mutation is persisted.
@MainActor
@Observable
final class InventoryModel {
    private(set) var products: [Product] = []
    /// Possible products, unresolved repositories and separate organizations found during discovery.
    private(set) var unresolved: [UnresolvedItem] = []
    private(set) var isLoaded = false
    var errorMessage: String?
    /// One-time information for the user, e.g. that an older inventory file was archived.
    var notice: String?

    /// State of the read-only GitHub refresh.
    private(set) var isSyncingGitHub = false
    private(set) var lastGitHubSync: (at: Date, report: RepositorySync.Report)?

    private let store: InventoryStore
    let secrets: SecretStore
    private var saveTask: Task<Void, Never>?

    init(store: InventoryStore, secrets: SecretStore = KeychainSecretStore()) {
        self.store = store
        self.secrets = secrets
    }

    /// Refreshes every GitHub repository snapshot, read-only. Without a token only public repositories succeed.
    func refreshGitHub() async {
        guard !isSyncingGitHub else { return }
        isSyncingGitHub = true
        defer { isSyncingGitHub = false }
        let token: String?
        do { token = try secrets.read(.gitHubToken) } catch {
            errorMessage = "Could not read the GitHub token from the Keychain: \(error.localizedDescription)"
            return
        }
        let (updated, report) = await RepositorySync.refresh(products, using: GitHubClient(token: token))
        // Apply only the snapshots, in case products changed while the sync was running.
        for product in updated {
            update(product.id) { current in
                for repo in product.repositories {
                    if let i = current.repositories.firstIndex(where: { $0.id == repo.id }), let snap = repo.gitHub {
                        current.repositories[i].gitHub = snap
                    }
                }
            }
        }
        lastGitHubSync = (.now, report)
    }

    var summary: DashboardSummary { DashboardSummary(products: products) }

    func product(id: Product.ID) -> Product? {
        products.first { $0.id == id }
    }

    /// Loads the stored inventory. On first launch it seeds from the verified seed file.
    /// A file from an older schema is archived (never deleted) and replaced by the current seed.
    func load() async {
        do {
            if let inventory = try await store.load() {
                apply(inventory)
            } else {
                try seed()
            }
        } catch InventoryStoreError.outdatedSchemaVersion(let version) {
            do {
                let archived = try await store.archive()
                try seed()
                notice = "The inventory was rebuilt from the verified seed (schema \(Inventory.currentSchemaVersion)). "
                    + "The previous schema-\(version) file was kept at \(archived?.path(percentEncoded: false) ?? "its original location")."
            } catch {
                errorMessage = "Could not upgrade inventory: \(error.localizedDescription)"
            }
        } catch {
            errorMessage = "Could not load inventory: \(error.localizedDescription)"
        }
        isLoaded = true
    }

    private func seed() throws {
        apply(try SeedInventory.load())
        persist()
    }

    private func apply(_ inventory: Inventory) {
        products = inventory.products
        unresolved = inventory.unresolved
    }

    /// Adds a product, or replaces the existing product with the same ID.
    func upsert(_ product: Product) {
        if let index = products.firstIndex(where: { $0.id == product.id }) {
            products[index] = product
        } else {
            products.append(product)
        }
        persist()
    }

    func update(_ id: Product.ID, _ mutate: (inout Product) -> Void) {
        guard let index = products.firstIndex(where: { $0.id == id }) else { return }
        mutate(&products[index])
        persist()
    }

    func delete(_ id: Product.ID) {
        products.removeAll { $0.id == id }
        persist()
    }

    /// Returns a unique product ID for a name, adding a numeric suffix if the slug is taken.
    func newProductID(for name: String) -> String {
        let base = Product.slug(for: name).isEmpty ? "product" : Product.slug(for: name)
        var candidate = base
        var n = 2
        while products.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Saves are chained so they reach the store in the same order as the mutations.
    private func persist() {
        let snapshot = Inventory(products: products, unresolved: unresolved)
        let previous = saveTask
        saveTask = Task { [store] in
            await previous?.value
            do {
                try await store.save(snapshot)
            } catch {
                await MainActor.run { self.errorMessage = "Could not save inventory: \(error.localizedDescription)" }
            }
        }
    }
}
