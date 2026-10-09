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
    @Published var audiogramsWritten = 0
    @Published var skipped: [SkippedGroup] = []
    @Published var lastError: String?

    /// Plain-text version of the result, for the Copy Report button.
    var reportText: String {
        var lines = ["Clinical Vitals Sync report", status, "Clinical records read: \(recordsRead)", "", "WRITTEN"]
        for (m, n) in written { lines.append("\(n)\t\(m.label)") }
        if audiogramsWritten > 0 { lines.append("\(audiogramsWritten)\tAudiogram") }
        lines += ["", "SKIPPED (count\tcode\treason\tdisplay)"]
        for g in skipped { lines.append("\(g.count)\t\(g.code)\t\(g.reason)\t\(g.display)") }
        return lines.joined(separator: "\n")
    }

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
        quantityType(.bloodGlucose), HKObjectType.audiogramSampleType(),
    ]

    /// Bump whenever the mapping changes shape or scale: HealthKit replaces an
    /// existing sample with the same sync identifier only if the version is higher.
    private static let syncVersion = 2

    func run() async {
        guard HKHealthStore.isHealthDataAvailable() else { lastError = "Health is not available on this device"; return }
        isRunning = true
        lastError = nil
        written = []
        audiogramsWritten = 0
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

            status = "Writing \(outcome.samples.count + outcome.audiograms.count) samples…"
            var objects = outcome.samples.map(Self.healthObject(for:))
            objects += outcome.audiograms.map(Self.audiogram(for:))
            if !objects.isEmpty { try await store.save(objects) }
            audiogramsWritten = outcome.audiograms.count

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

            status = "Done: \(outcome.samples.count + outcome.audiograms.count) written, \(outcome.skipped.count) skipped"
        } catch {
            lastError = error.localizedDescription
            status = "Failed"
        }
    }

    /// Pages through every record of a clinical type. A single HKSampleQuery
    /// returned exactly 1000 records on the first run, so page by start date
    /// and dedupe on UUID (the start-date predicate is inclusive).
    private func fetchClinicalRecords(of type: HKClinicalType) async throws -> [HKClinicalRecord] {
        let pageSize = 1000
        var all: [HKClinicalRecord] = []
        var seen = Set<UUID>()
        var predicate: NSPredicate? = nil
        while true {
            let page = try await fetchPage(of: type, predicate: predicate, limit: pageSize)
            let fresh = page.filter { seen.insert($0.uuid).inserted }
            all += fresh
            guard page.count == pageSize, !fresh.isEmpty, let last = page.last else { break }
            predicate = HKQuery.predicateForSamples(withStart: last.startDate, end: nil, options: [])
        }
        return all
    }

    private func fetchPage(of type: HKClinicalType, predicate: NSPredicate?, limit: Int) async throws -> [HKClinicalRecord] {
        try await withCheckedThrowingContinuation { cont in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: sort) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKClinicalRecord]) ?? [])
            }
            store.execute(q)
        }
    }

    private static func metadata(_ id: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: "clinical-vitals-sync:" + id,
         HKMetadataKeySyncVersion: syncVersion]
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
            // HKUnit.percent() is a fraction: 0.98, not 98.
            let value = s.metric == .oxygenSaturation ? s.value / 100 : s.value
            return HKQuantitySample(type: quantityType(id),
                                    quantity: HKQuantity(unit: unit, doubleValue: value),
                                    start: s.date, end: s.date, metadata: metadata(s.sourceID + ":" + s.metric.rawValue))
        }
    }

    private static func audiogram(for a: MappedAudiogram) -> HKObject {
        let points = a.points.map { p in
            try! HKAudiogramSensitivityPoint(
                frequency: HKQuantity(unit: .hertz(), doubleValue: p.frequencyHz),
                leftEarSensitivity: p.leftDB.map { HKQuantity(unit: .decibelHearingLevel(), doubleValue: $0) },
                rightEarSensitivity: p.rightDB.map { HKQuantity(unit: .decibelHearingLevel(), doubleValue: $0) })
        }
        return HKAudiogramSample(sensitivityPoints: points, start: a.date, end: a.date, metadata: metadata(a.sourceID + ":audiogram"))
    }
}
