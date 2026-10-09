import Foundation

// Minimal Codable view of a FHIR Observation. The fields used here are
// identical in DSTU2 and R4, which is what Apple Health Records delivers.

public struct FHIRCoding: Decodable, Equatable, Sendable {
    public var system: String?
    public var code: String?
    public var display: String?
}

public struct FHIRCodeableConcept: Decodable, Sendable {
    public var coding: [FHIRCoding]?
    public var text: String?

    /// First LOINC code if present, else the first code of any system.
    var preferredCode: FHIRCoding? {
        guard let coding, !coding.isEmpty else { return nil }
        return coding.first { ($0.system ?? "").contains("loinc") } ?? coding.first
    }
}

public struct FHIRQuantity: Decodable, Sendable {
    public var value: Double?
    public var unit: String?
    public var system: String?
    public var code: String?

    /// UCUM code when present, else the human unit string.
    var unitToken: String? { code ?? unit }
}

public struct FHIRPeriod: Decodable, Sendable {
    public var start: String?
    public var end: String?
}

public struct FHIRComponent: Decodable, Sendable {
    public var code: FHIRCodeableConcept
    public var valueQuantity: FHIRQuantity?
}

public struct FHIRObservation: Decodable, Sendable {
    public var resourceType: String
    public var id: String?
    public var status: String?
    public var code: FHIRCodeableConcept
    public var effectiveDateTime: String?
    public var effectivePeriod: FHIRPeriod?
    public var issued: String?
    public var valueQuantity: FHIRQuantity?
    public var component: [FHIRComponent]?

    /// Best-effort instant the observation was taken.
    var effectiveDate: Date? {
        for candidate in [effectiveDateTime, effectivePeriod?.start, issued] {
            if let candidate, let date = FHIRDate.parse(candidate) { return date }
        }
        return nil
    }
}

enum FHIRDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s) ?? dateOnly.date(from: s)
    }
}
