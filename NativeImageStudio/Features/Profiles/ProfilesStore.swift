import Domain
import Foundation
import Infrastructure
import Observation
import SwiftUI

/// Main-actor façade over `ProfileStore` for menus and sheets.
@MainActor
@Observable
public final class ProfilesStore {
    public private(set) var profiles: [ModelProfile] = []
    public var lastError: String?
    private let store: ProfileStore

    public init(store: ProfileStore) {
        self.store = store
    }

    public func reload() async {
        profiles = await store.all()
    }

    public func save(_ profile: ModelProfile) async {
        do {
            try await store.save(profile)
            await reload()
        } catch {
            lastError = userMessage(error)
        }
    }

    public func delete(_ id: UUID) async {
        do {
            try await store.delete(id)
            await reload()
        } catch {
            lastError = userMessage(error)
        }
    }

    public func profiles(for workflows: Set<ModelProfile.Workflow>) -> [ModelProfile] {
        profiles.filter { workflows.contains($0.workflow) }
    }
}

/// "Profil" menu: apply a saved profile or save the current settings as a new one.
public struct ProfilesMenu: View {
    let profiles: ProfilesStore
    let workflows: Set<ModelProfile.Workflow>
    let capabilities: (String) -> EngineCapabilities?
    let apply: (ModelProfile) -> Void
    let makeProfile: (String) -> ModelProfile?
    @State private var naming = false
    @State private var name = ""

    public init(profiles: ProfilesStore, workflows: Set<ModelProfile.Workflow>,
                capabilities: @escaping (String) -> EngineCapabilities?,
                apply: @escaping (ModelProfile) -> Void,
                makeProfile: @escaping (String) -> ModelProfile?) {
        self.profiles = profiles
        self.workflows = workflows
        self.capabilities = capabilities
        self.apply = apply
        self.makeProfile = makeProfile
    }

    public var body: some View {
        Menu {
            let list = profiles.profiles(for: workflows)
            if list.isEmpty { Text("Brak zapisanych profili") }
            ForEach(list) { p in
                let issues = capabilities(p.modelID).map { p.incompatibilities(with: $0) } ?? ["Model niedostępny."]
                Button(p.name + (issues.isEmpty ? "" : " ⚠︎")) { apply(p) }
                    .disabled(!issues.isEmpty)
                    .help(issues.joined(separator: " "))
            }
            Divider()
            Button("Zapisz bieżące ustawienia jako profil…") { naming = true }
            if !list.isEmpty {
                Menu("Usuń profil") {
                    ForEach(list) { p in Button(p.name) { Task { await profiles.delete(p.id) } } }
                }
            }
        } label: {
            Label("Profil", systemImage: "slider.horizontal.below.square.filled.and.square")
        }
        .alert("Nazwa profilu", isPresented: $naming) {
            TextField("np. Portret 1024", text: $name)
            Button("Zapisz") {
                if let p = makeProfile(name.isEmpty ? "Profil" : name) { Task { await profiles.save(p) } }
                name = ""
            }
            Button("Anuluj", role: .cancel) { name = "" }
        }
    }
}
