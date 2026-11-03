import Domain
import Foundation

public struct MemoryBudgetConfig: Sendable, Codable, Equatable {
    /// Upper bound for this process' footprint as a fraction of physical RAM.
    public var maxProcessFractionOfRAM: Double
    /// Extra headroom kept free on top of the estimate.
    public var safetyMarginGB: Double
    /// Jobs are refused at or above this thermal level.
    public var rejectAtThermal: ThermalLevel
    /// Jobs are refused at or above this pressure level.
    public var rejectAtPressure: MemoryPressureLevel

    public init(
        maxProcessFractionOfRAM: Double = 0.80,
        safetyMarginGB: Double = 1.0,
        rejectAtThermal: ThermalLevel = .critical,
        rejectAtPressure: MemoryPressureLevel = .critical
    ) {
        self.maxProcessFractionOfRAM = maxProcessFractionOfRAM
        self.safetyMarginGB = safetyMarginGB
        self.rejectAtThermal = rejectAtThermal
        self.rejectAtPressure = rejectAtPressure
    }
}

public struct MemoryEstimate: Sendable, Equatable {
    public var loadGB: Double
    public var activationGB: Double
    public var referencesGB: Double
    public var totalGB: Double { loadGB + activationGB + referencesGB }
}

public enum AdmissionDecision: Sendable, Equatable {
    case allowed(warnings: [String])
    case rejected(GenerationError)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Admission control for model loads and jobs on unified memory.
///
/// Uses the measured `ModelDescriptor.memory` profile, current process footprint,
/// system available pages, kernel memory pressure, thermal state and the backend's
/// reclaimable cache. A job is refused *before* it runs when the estimate does not fit.
public struct MemoryBudgetManager: Sendable {
    public let probe: any SystemMemoryProbe
    public var config: MemoryBudgetConfig

    public init(probe: any SystemMemoryProbe, config: MemoryBudgetConfig = MemoryBudgetConfig()) {
        self.probe = probe
        self.config = config
    }

    public func estimate(
        model: ModelDescriptor,
        width: Int,
        height: Int,
        referenceImages: Int,
        includeLoad: Bool
    ) -> MemoryEstimate {
        guard let profile = model.memory else {
            return MemoryEstimate(loadGB: 0, activationGB: 0, referencesGB: 0)
        }
        let mp = Double(width * height) / 1_000_000
        return MemoryEstimate(
            loadGB: includeLoad ? profile.residentGB : 0,
            activationGB: profile.activationGBPerMegapixel * mp,
            referencesGB: profile.perReferenceImageGB * Double(referenceImages) * mp
        )
    }

    /// Memory this process may still claim: min(system available, process ceiling),
    /// both counting the backend cache as reclaimable.
    public func availableGB(_ s: MemorySnapshot) -> Double {
        let reclaimable = s.gpuCacheBytes.gigabytes
        let system = s.systemAvailableBytes.gigabytes + reclaimable
        let ceiling = s.physicalBytes.gigabytes * config.maxProcessFractionOfRAM
            - s.processFootprintBytes.gigabytes + reclaimable
        return max(0, min(system, ceiling))
    }

    /// Before loading `model`. `unloading` is the model that will be released first.
    public func admitLoad(_ model: ModelDescriptor, unloading: ModelDescriptor? = nil) -> AdmissionDecision {
        let s = probe.snapshot()
        var warnings: [String] = []
        let physicalGB = s.physicalBytes.gigabytes
        if physicalGB + 0.5 < model.minimumMemoryGB {
            return .rejected(.insufficientMemory(
                requiredGB: model.minimumMemoryGB, availableGB: physicalGB,
                detail: "Model \(model.name) wymaga (próg aplikacji) \(Int(model.minimumMemoryGB)) GB RAM."))
        }
        if let rejection = systemRejection(s) { return .rejected(rejection) }
        guard let profile = model.memory else {
            warnings.append("Brak zmierzonego profilu pamięci dla \(model.id) — sprawdzono tylko próg minimalny.")
            return .allowed(warnings: warnings)
        }
        let freed = unloading?.memory?.residentGB ?? 0
        let available = availableGB(s) + freed
        let required = profile.residentGB + config.safetyMarginGB
        if required > available {
            return .rejected(.insufficientMemory(
                requiredGB: required, availableGB: available,
                detail: "Zamknij inne aplikacje lub wybierz mniejszy model/kwantyzację."))
        }
        warnings += thermalWarnings(s)
        return .allowed(warnings: warnings)
    }

    /// Before running `request` on `model` (already loaded or about to be loaded).
    public func admitJob(_ request: GenerationRequest, model: ModelDescriptor, modelLoaded: Bool) -> AdmissionDecision {
        let s = probe.snapshot()
        if let rejection = systemRejection(s) { return .rejected(rejection) }
        var warnings = thermalWarnings(s)
        guard model.memory != nil else {
            warnings.append("Brak zmierzonego profilu pamięci dla \(model.id).")
            return .allowed(warnings: warnings)
        }
        let e = estimate(
            model: model, width: request.width, height: request.height,
            referenceImages: request.inputImages.count, includeLoad: !modelLoaded)
        let available = availableGB(s)
        let required = e.totalGB + config.safetyMarginGB
        if required > available {
            let refs = request.inputImages.count
            let detail = refs > 0
                ? String(format: "Obrazy wejściowe (%d) dodają ~%.1f GB. Zmniejsz rozdzielczość lub liczbę obrazów.", refs, e.referencesGB)
                : "Zmniejsz rozdzielczość."
            return .rejected(.insufficientMemory(requiredGB: required, availableGB: available, detail: detail))
        }
        return .allowed(warnings: warnings)
    }

    private func systemRejection(_ s: MemorySnapshot) -> GenerationError? {
        if s.pressure >= config.rejectAtPressure {
            return .insufficientMemory(
                requiredGB: 0, availableGB: availableGB(s),
                detail: "System zgłasza krytyczną presję pamięci.")
        }
        if Self.rank(s.thermal) >= Self.rank(config.rejectAtThermal) {
            return .thermalThrottling("Mac jest przegrzany (stan termiczny: \(s.thermal.rawValue)). Poczekaj, aż ostygnie.")
        }
        return nil
    }

    private func thermalWarnings(_ s: MemorySnapshot) -> [String] {
        var w: [String] = []
        if s.thermal == .serious { w.append("Wysoka temperatura — generowanie może być wolniejsze.") }
        if s.pressure == .warning { w.append("Podwyższona presja pamięci systemowej.") }
        return w
    }

    private static func rank(_ t: ThermalLevel) -> Int {
        switch t {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }
}
