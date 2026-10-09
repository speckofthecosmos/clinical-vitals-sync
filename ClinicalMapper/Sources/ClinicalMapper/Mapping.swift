import Foundation

/// A Health data type that a clinical observation can be copied into.
/// `canonicalUnit` is the unit every `MappedSample` value is expressed in;
/// the app turns it into the matching HKUnit.
public enum Metric: String, CaseIterable, Sendable {
    case bodyMass, height, bodyMassIndex, heartRate, bloodPressure
    case bodyTemperature, respiratoryRate, oxygenSaturation, bloodGlucose

    public var canonicalUnit: String {
        switch self {
        case .bodyMass: return "lb"
        case .height: return "in"
        case .bodyMassIndex: return "count"
        case .heartRate, .respiratoryRate: return "count/min"
        case .bloodPressure: return "mmHg"
        case .bodyTemperature: return "degF"
        case .oxygenSaturation: return "%"
        case .bloodGlucose: return "mg/dL"
        }
    }

    public var label: String {
        switch self {
        case .bodyMass: return "Weight"
        case .height: return "Height"
        case .bodyMassIndex: return "Body Mass Index"
        case .heartRate: return "Heart Rate"
        case .bloodPressure: return "Blood Pressure"
        case .bodyTemperature: return "Body Temperature"
        case .respiratoryRate: return "Respiratory Rate"
        case .oxygenSaturation: return "Blood Oxygen"
        case .bloodGlucose: return "Blood Glucose"
        }
    }
}

public struct MappedSample: Equatable, Sendable {
    public var metric: Metric
    /// Value in `metric.canonicalUnit`. For blood pressure this is systolic.
    public var value: Double
    /// Diastolic for blood pressure, nil otherwise.
    public var secondaryValue: Double?
    public var date: Date
    /// Stable id for idempotent writes (FHIR resource id, or a caller-supplied fallback).
    public var sourceID: String
    public var display: String
}

public struct Skipped: Equatable, Sendable {
    public var code: String
    public var display: String
    public var reason: String
}

public struct MappingOutcome: Sendable {
    public var samples: [MappedSample] = []
    public var skipped: [Skipped] = []
    public init() {}
}

// LOINC → metric. Panels (blood pressure) are handled by component codes.
enum LOINC {
    static let metricByCode: [String: Metric] = [
        "29463-7": .bodyMass, "3141-9": .bodyMass, "8335-2": .bodyMass,
        "8302-2": .height, "3137-7": .height, "8308-9": .height,
        "39156-5": .bodyMassIndex,
        "8867-4": .heartRate, "8889-8": .heartRate,
        "8310-5": .bodyTemperature, "8331-1": .bodyTemperature,
        "9279-1": .respiratoryRate,
        "2708-6": .oxygenSaturation, "59408-5": .oxygenSaturation,
        "2339-4": .bloodGlucose, "2345-7": .bloodGlucose, "41653-7": .bloodGlucose,
        "14749-6": .bloodGlucose, "15074-8": .bloodGlucose,
    ]
    static let bloodPressurePanels: Set<String> = ["85354-9", "55284-4"]
    static let systolic: Set<String> = ["8480-6"]
    static let diastolic: Set<String> = ["8462-4"]
}

enum UnitConversion {
    /// Convert `value` in FHIR unit token to the metric's canonical unit. nil = unit not understood.
    static func canonical(_ value: Double, unit: String?, for metric: Metric) -> Double? {
        let u = (unit ?? "").trimmingCharacters(in: .whitespaces)
        switch metric {
        case .bodyMass:
            switch u { case "[lb_av]", "lb", "lbs", "lb_av": return value
                       case "kg": return value * 2.20462262
                       case "g": return value / 1000 * 2.20462262
                       case "[oz_av]", "oz": return value / 16
                       default: return nil }
        case .height:
            switch u { case "[in_i]", "in", "in_i": return value
                       case "cm": return value / 2.54
                       case "m": return value * 39.3700787
                       case "[ft_i]", "ft": return value * 12
                       default: return nil }
        case .bodyMassIndex:
            switch u { case "kg/m2", "kg/m^2", "": return value; default: return nil }
        case .heartRate, .respiratoryRate:
            switch u { case "/min", "{beats}/min", "{breaths}/min", "bpm", "min-1", "1/min": return value
                       default: return nil }
        case .bloodPressure:
            switch u { case "mm[Hg]", "mmHg", "mm Hg": return value; default: return nil }
        case .bodyTemperature:
            switch u { case "[degF]", "degF", "F", "°F": return value
                       case "Cel", "C", "°C", "degC": return value * 9 / 5 + 32
                       default: return nil }
        case .oxygenSaturation:
            switch u { case "%": return value; default: return nil }
        case .bloodGlucose:
            switch u { case "mg/dL", "mg/dl": return value
                       case "mmol/L", "mmol/l": return value * 18.0156
                       default: return nil }
        }
    }
}

public enum ClinicalMapper {
    /// Map one FHIR Observation (raw JSON). Returns a sample, a skip, or neither
    /// (non-Observation resources and non-final statuses are silently ignored).
    public static func map(json: Data, fallbackID: String) -> MappingOutcome {
        var out = MappingOutcome()
        let obs: FHIRObservation
        do { obs = try JSONDecoder().decode(FHIRObservation.self, from: json) }
        catch {
            out.skipped.append(Skipped(code: "?", display: "undecodable", reason: "not an Observation: \(error.localizedDescription)"))
            return out
        }
        guard obs.resourceType == "Observation" else { return out }
        if let status = obs.status, ["entered-in-error", "cancelled"].contains(status) {
            return out
        }

        let coding = obs.code.preferredCode
        let code = coding?.code ?? "?"
        let display = coding?.display ?? obs.code.text ?? code
        let id = obs.id ?? fallbackID

        func skip(_ reason: String) { out.skipped.append(Skipped(code: code, display: display, reason: reason)) }

        guard let date = obs.effectiveDate else { skip("no date"); return out }

        // Blood pressure: panel with components, or a lone systolic/diastolic.
        if LOINC.bloodPressurePanels.contains(code) || LOINC.systolic.contains(code) || LOINC.diastolic.contains(code) {
            var sys: Double?, dia: Double?
            for c in obs.component ?? [] {
                guard let ccode = c.code.preferredCode?.code, let q = c.valueQuantity, let v = q.value else { continue }
                guard let conv = UnitConversion.canonical(v, unit: q.unitToken, for: .bloodPressure) else {
                    skip("unknown unit \(q.unitToken ?? "nil")"); return out
                }
                if LOINC.systolic.contains(ccode) { sys = conv }
                if LOINC.diastolic.contains(ccode) { dia = conv }
            }
            if let q = obs.valueQuantity, let v = q.value, let conv = UnitConversion.canonical(v, unit: q.unitToken, for: .bloodPressure) {
                if LOINC.systolic.contains(code) { sys = conv }
                if LOINC.diastolic.contains(code) { dia = conv }
            }
            guard let s = sys, let d = dia else {
                skip(sys == nil && dia == nil ? "no systolic/diastolic values" : "partial blood pressure (only one of systolic/diastolic)")
                return out
            }
            out.samples.append(MappedSample(metric: .bloodPressure, value: s, secondaryValue: d, date: date, sourceID: id, display: display))
            return out
        }

        guard let metric = LOINC.metricByCode[code] else { skip("no Health counterpart"); return out }
        guard let q = obs.valueQuantity, let v = q.value else { skip("no numeric value"); return out }
        guard let conv = UnitConversion.canonical(v, unit: q.unitToken, for: metric) else {
            skip("unknown unit \(q.unitToken ?? "nil")"); return out
        }
        out.samples.append(MappedSample(metric: metric, value: conv, secondaryValue: nil, date: date, sourceID: id, display: display))
        return out
    }

    /// Map a batch. Lone systolic and diastolic observations taken at the same
    /// instant are paired into one blood pressure sample.
    public static func map(batch: [(json: Data, fallbackID: String)]) -> MappingOutcome {
        var out = MappingOutcome()
        var loneSys: [Date: (Double, String, String)] = [:]
        var loneDia: [Date: (Double, String, String)] = [:]
        for item in batch {
            let one = map(json: item.json, fallbackID: item.fallbackID)
            out.samples += one.samples
            for s in one.skipped {
                if s.reason.hasPrefix("partial blood pressure"),
                   let obs = try? JSONDecoder().decode(FHIRObservation.self, from: item.json),
                   let date = obs.effectiveDate, let q = obs.valueQuantity, let v = q.value,
                   let conv = UnitConversion.canonical(v, unit: q.unitToken, for: .bloodPressure) {
                    let id = obs.id ?? item.fallbackID
                    if LOINC.systolic.contains(s.code) { loneSys[date] = (conv, id, s.display); continue }
                    if LOINC.diastolic.contains(s.code) { loneDia[date] = (conv, id, s.display); continue }
                }
                out.skipped.append(s)
            }
        }
        for (date, sys) in loneSys {
            if let dia = loneDia.removeValue(forKey: date) {
                out.samples.append(MappedSample(metric: .bloodPressure, value: sys.0, secondaryValue: dia.0, date: date, sourceID: sys.1 + "+" + dia.1, display: "Blood pressure"))
            } else {
                out.skipped.append(Skipped(code: "8480-6", display: sys.2, reason: "partial blood pressure (no diastolic at same time)"))
            }
        }
        for (_, dia) in loneDia {
            out.skipped.append(Skipped(code: "8462-4", display: dia.2, reason: "partial blood pressure (no systolic at same time)"))
        }
        out.samples.sort { $0.date < $1.date }
        return out
    }
}
