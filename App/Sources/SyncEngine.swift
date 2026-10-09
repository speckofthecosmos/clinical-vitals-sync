import Foundation
import HealthKit
import ClinicalMapper

/// Reads every clinical record Health holds (vitals + lab results), maps the
/// FHIR Observations to ordinary Health sample types, and writes them.
///
/// Idempotency: each written sample carries HKMetadataKeySyncIdentifier derived
/// from the FHIR resource id. HealthKit treats a second save with the same
/// identifier (and version) from the same app as an update, not a duplicate,
/// so the Sync button can be tapped any number of times.
@MainActor
final class SyncEngine: ObservableObject {
    struct SkippedGroup: Identifiable, Hashable {
        var id: String { code + "|" + reason }
        let code: String
        let display: String
        let reason: String
        let count: Int
    }

    @Published var status = "Ready"
    @Published var isRunning = false
    @Published var recordsRead = 0
    @Published var written: [(Metric, Int)] = []
    @Published var skipped: [SkippedGroup] = []
    @Published var lastError: String?

    private let store = HKHealthStore()

    private static let clinicalTypes: [HKClinicalType] = [
        .vitalSignRecord, .labResultRecord,
    ].compactMap { HKObjectType.clinicalType(forIdentifier: $0) }

    private static func quantityType(_ id: HKQuantityTypeIdentifier) -> HKQuantityType {
        HKObjectType.quantityType(forIdentifier: id)!
    }

    private static let writeTypes: Set<HKSampleType> = [
        quantityType(.bodyMass), quantityType(.height), quantityType(.bodyMassIndex),
        quantityType(.heartRate), quantityType(.bloodPressureSystolic), quantityType(.bloodPressureDiastolic),
        quantityType(.bodyTemperature), quantityType(.respiratoryRate), quantityType(.oxygenSaturation),
        quantityType(.bloodGlucose),
    ]

    func run() async {
        guard HKHealthStore.isHealthDataAvailable() else { lastError = "Health is not available on this device"; return }
        isRunning = true
        lastError = nil
        written = []
        skipped = []
        recordsRead = 0
        defer { isRunning = false }

        do {
            status = "Requesting Health access…"
            try await store.requestAuthorization(toShare: Self.writeTypes, read: Set(Self.clinicalTypes))

            status = "Reading clinical records…"
            var batch: [(json: Data, fallbackID: String)] = []
            for type in Self.clinicalTypes {
                let records = try await fetchClinicalRecords(of: type)
                for record in records {
                    guard let resource = record.fhirResource else { continue }
                    batch.append((resource.data, resource.identifier))
                }
            }
            recordsRead = batch.count

            status = "Mapping…"
            let outcome = ClinicalMapper.map(batch: batch)

            status = "Writing \(outcome.samples.count) samples…"
            let objects = outcome.samples.map(Self.healthObject(for:))
            if !objects.isEmpty { try await store.save(objects) }

            var counts: [Metric: Int] = [:]
            for s in outcome.samples { counts[s.metric, default: 0] += 1 }
            written = Metric.allCases.compactMap { m in counts[m].map { (m, $0) } }

            var groups: [String: SkippedGroup] = [:]
            for s in outcome.skipped {
                let key = s.code + "|" + s.reason
                let prev = groups[key]?.count ?? 0
                groups[key] = SkippedGroup(code: s.code, display: s.display, reason: s.reason, count: prev + 1)
            }
            skipped = groups.values.sorted { $0.count > $1.count }

            status = "Done: \(outcome.samples.count) written, \(outcome.skipped.count) skipped"
        } catch {
            lastError = error.localizedDescription
            status = "Failed"
        }
    }

    private func fetchClinicalRecords(of type: HKClinicalType) async throws -> [HKClinicalRecord] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKClinicalRecord]) ?? [])
            }
            store.execute(q)
        }
    }

    private static func metadata(_ id: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: "clinical-vitals-sync:" + id,
         HKMetadataKeySyncVersion: 1]
    }

    private static func healthObject(for s: MappedSample) -> HKObject {
        let unit = HKUnit(from: s.metric.canonicalUnit)
        switch s.metric {
        case .bloodPressure:
            let sys = HKQuantitySample(type: quantityType(.bloodPressureSystolic),
                                       quantity: HKQuantity(unit: unit, doubleValue: s.value),
                                       start: s.date, end: s.date, metadata: metadata(s.sourceID + ":sys"))
            let dia = HKQuantitySample(type: quantityType(.bloodPressureDiastolic),
                                       quantity: HKQuantity(unit: unit, doubleValue: s.secondaryValue ?? 0),
                                       start: s.date, end: s.date, metadata: metadata(s.sourceID + ":dia"))
            return HKCorrelation(type: HKObjectType.correlationType(forIdentifier: .bloodPressure)!,
                                 start: s.date, end: s.date, objects: [sys, dia], metadata: metadata(s.sourceID + ":bp"))
        default:
            let id: HKQuantityTypeIdentifier
            switch s.metric {
            case .bodyMass: id = .bodyMass
            case .height: id = .height
            case .bodyMassIndex: id = .bodyMassIndex
            case .heartRate: id = .heartRate
            case .bodyTemperature: id = .bodyTemperature
            case .respiratoryRate: id = .respiratoryRate
            case .oxygenSaturation: id = .oxygenSaturation
            case .bloodGlucose: id = .bloodGlucose
            case .bloodPressure: fatalError("handled above")
            }
            // oxygenSaturation is stored as a fraction; "%" HKUnit handles the scale.
            return HKQuantitySample(type: quantityType(id),
                                    quantity: HKQuantity(unit: unit, doubleValue: s.value),
                                    start: s.date, end: s.date, metadata: metadata(s.sourceID + ":" + s.metric.rawValue))
        }
    }
}
