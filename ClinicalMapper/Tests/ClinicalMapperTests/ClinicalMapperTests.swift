import XCTest
@testable import ClinicalMapper

final class ClinicalMapperTests: XCTestCase {

    private func obs(_ body: String) -> Data { Data(body.utf8) }

    private func single(_ body: String, id: String = "fallback") -> MappingOutcome {
        ClinicalMapper.map(json: obs(body), fallbackID: id)
    }

    func testWeightInPoundsMapsAsIs() {
        let out = single(#"""
        {"resourceType":"Observation","id":"w1","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"29463-7","display":"Body weight"}]},
         "effectiveDateTime":"2025-03-05T14:22:00Z",
         "valueQuantity":{"value":182.5,"unit":"lb","system":"http://unitsofmeasure.org","code":"[lb_av]"}}
        """#)
        XCTAssertEqual(out.skipped, [])
        XCTAssertEqual(out.samples.count, 1)
        let s = out.samples[0]
        XCTAssertEqual(s.metric, .bodyMass)
        XCTAssertEqual(s.value, 182.5)
        XCTAssertEqual(s.sourceID, "w1")
        XCTAssertEqual(s.date, ISO8601DateFormatter().date(from: "2025-03-05T14:22:00Z"))
    }

    func testWeightInKilogramsConvertsToPounds() {
        let out = single(#"""
        {"resourceType":"Observation","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"29463-7"}]},
         "effectiveDateTime":"2025-03-05T14:22:00-07:00",
         "valueQuantity":{"value":80,"unit":"kg","code":"kg"}}
        """#, id: "fb")
        XCTAssertEqual(out.samples.count, 1)
        XCTAssertEqual(out.samples[0].value, 176.37, accuracy: 0.01)
        XCTAssertEqual(out.samples[0].sourceID, "fb", "falls back to caller id when FHIR id missing")
    }

    func testHeightCentimetresToInches() {
        let out = single(#"""
        {"resourceType":"Observation","id":"h","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"8302-2"}]},
         "effectiveDateTime":"2025-03-05",
         "valueQuantity":{"value":177.8,"unit":"cm","code":"cm"}}
        """#)
        XCTAssertEqual(out.samples.count, 1)
        XCTAssertEqual(out.samples[0].metric, .height)
        XCTAssertEqual(out.samples[0].value, 70.0, accuracy: 0.001)
    }

    func testTemperatureCelsiusToFahrenheit() {
        let out = single(#"""
        {"resourceType":"Observation","id":"t","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"8310-5"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":37,"unit":"Cel","code":"Cel"}}
        """#)
        XCTAssertEqual(out.samples[0].value, 98.6, accuracy: 0.01)
    }

    func testGlucoseMmolPerLitreToMgPerDl() {
        let out = single(#"""
        {"resourceType":"Observation","id":"g","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"2339-4"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":5.5,"unit":"mmol/L","code":"mmol/L"}}
        """#)
        XCTAssertEqual(out.samples[0].metric, .bloodGlucose)
        XCTAssertEqual(out.samples[0].value, 99.09, accuracy: 0.01)
    }

    func testBloodPressurePanelWithComponents() {
        let out = single(#"""
        {"resourceType":"Observation","id":"bp","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"85354-9","display":"Blood pressure panel"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "component":[
           {"code":{"coding":[{"system":"http://loinc.org","code":"8480-6"}]},"valueQuantity":{"value":118,"unit":"mmHg","code":"mm[Hg]"}},
           {"code":{"coding":[{"system":"http://loinc.org","code":"8462-4"}]},"valueQuantity":{"value":76,"unit":"mmHg","code":"mm[Hg]"}}]}
        """#)
        XCTAssertEqual(out.skipped, [])
        XCTAssertEqual(out.samples.count, 1)
        XCTAssertEqual(out.samples[0].metric, .bloodPressure)
        XCTAssertEqual(out.samples[0].value, 118)
        XCTAssertEqual(out.samples[0].secondaryValue, 76)
    }

    func testBloodPressurePanelMissingDiastolicIsSkipped() {
        let out = single(#"""
        {"resourceType":"Observation","id":"bp","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"85354-9"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "component":[
           {"code":{"coding":[{"system":"http://loinc.org","code":"8480-6"}]},"valueQuantity":{"value":118,"code":"mm[Hg]"}}]}
        """#)
        XCTAssertEqual(out.samples, [])
        XCTAssertEqual(out.skipped.count, 1)
        XCTAssertTrue(out.skipped[0].reason.hasPrefix("partial blood pressure"))
    }

    func testLoneSystolicAndDiastolicArePairedInBatch() {
        let sys = #"""
        {"resourceType":"Observation","id":"s","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"8480-6","display":"Systolic"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":120,"code":"mm[Hg]"}}
        """#
        let dia = #"""
        {"resourceType":"Observation","id":"d","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"8462-4","display":"Diastolic"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":80,"code":"mm[Hg]"}}
        """#
        let out = ClinicalMapper.map(batch: [(obs(sys), "a"), (obs(dia), "b")])
        XCTAssertEqual(out.skipped, [])
        XCTAssertEqual(out.samples.count, 1)
        XCTAssertEqual(out.samples[0].value, 120)
        XCTAssertEqual(out.samples[0].secondaryValue, 80)
        XCTAssertEqual(out.samples[0].sourceID, "s+d")
    }

    func testLoneSystolicWithoutPartnerIsReportedSkipped() {
        let sys = #"""
        {"resourceType":"Observation","id":"s","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"8480-6","display":"Systolic"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":120,"code":"mm[Hg]"}}
        """#
        let out = ClinicalMapper.map(batch: [(obs(sys), "a")])
        XCTAssertEqual(out.samples, [])
        XCTAssertEqual(out.skipped.count, 1)
        XCTAssertEqual(out.skipped[0].code, "8480-6")
    }

    func testUnmappedCodeIsSkippedWithDisplay() {
        let out = single(#"""
        {"resourceType":"Observation","id":"a1c","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"4548-4","display":"Hemoglobin A1c"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":5.4,"unit":"%","code":"%"}}
        """#)
        XCTAssertEqual(out.samples, [])
        XCTAssertEqual(out.skipped, [Skipped(code: "4548-4", display: "Hemoglobin A1c", reason: "no Health counterpart")])
    }

    func testUnknownUnitIsSkipped() {
        let out = single(#"""
        {"resourceType":"Observation","id":"w","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"29463-7"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":12,"unit":"stone","code":"[stone_av]"}}
        """#)
        XCTAssertEqual(out.samples, [])
        XCTAssertEqual(out.skipped[0].reason, "unknown unit [stone_av]")
    }

    func testMissingValueIsSkipped() {
        let out = single(#"""
        {"resourceType":"Observation","id":"w","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"29463-7"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueString":"declined"}
        """#)
        XCTAssertEqual(out.skipped[0].reason, "no numeric value")
    }

    func testEffectivePeriodStartIsUsedWhenNoDateTime() {
        let out = single(#"""
        {"resourceType":"Observation","id":"w","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"29463-7"}]},
         "effectivePeriod":{"start":"2025-03-05T10:00:00.000+00:00"},
         "valueQuantity":{"value":150,"code":"[lb_av]"}}
        """#)
        XCTAssertEqual(out.samples.count, 1)
        XCTAssertEqual(out.samples[0].date, ISO8601DateFormatter().date(from: "2025-03-05T10:00:00Z"))
    }

    func testEnteredInErrorIsIgnoredSilently() {
        let out = single(#"""
        {"resourceType":"Observation","id":"w","status":"entered-in-error",
         "code":{"coding":[{"system":"http://loinc.org","code":"29463-7"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":150,"code":"[lb_av]"}}
        """#)
        XCTAssertEqual(out.samples, [])
        XCTAssertEqual(out.skipped, [])
    }

    func testNonObservationResourceIsIgnored() {
        let out = single(#"{"resourceType":"DiagnosticReport","id":"r","code":{"text":"CBC"}}"#)
        XCTAssertEqual(out.samples, [])
        XCTAssertEqual(out.skipped, [])
    }

    func testVitalSignsPanelComponentsAreUnpacked() {
        let out = single(#"""
        {"resourceType":"Observation","id":"vs","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"8716-3","display":"Vital signs"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "component":[
           {"code":{"coding":[{"system":"http://loinc.org","code":"8867-4","display":"Heart rate"}]},"valueQuantity":{"value":64,"unit":"/min","code":"/min"}},
           {"code":{"coding":[{"system":"http://loinc.org","code":"9279-1","display":"Resp rate"}]},"valueQuantity":{"value":16,"code":"/min"}},
           {"code":{"coding":[{"system":"http://loinc.org","code":"39156-5","display":"BMI"}]},"valueQuantity":{"value":24.1,"code":"kg/m2"}},
           {"code":{"coding":[{"system":"http://loinc.org","code":"8480-6"}]},"valueQuantity":{"value":118,"code":"mm[Hg]"}},
           {"code":{"coding":[{"system":"http://loinc.org","code":"8462-4"}]},"valueQuantity":{"value":76,"code":"mm[Hg]"}},
           {"code":{"coding":[{"system":"http://loinc.org","code":"4548-4","display":"A1c"}]},"valueQuantity":{"value":5.4,"code":"%"}}]}
        """#)
        XCTAssertEqual(out.samples.map(\.metric), [.heartRate, .respiratoryRate, .bodyMassIndex, .bloodPressure])
        XCTAssertEqual(out.samples.map(\.sourceID), ["vs:8867-4", "vs:9279-1", "vs:39156-5", "vs"])
        XCTAssertEqual(out.samples[3].value, 118)
        XCTAssertEqual(out.samples[3].secondaryValue, 76)
        XCTAssertEqual(out.skipped, [Skipped(code: "4548-4", display: "A1c", reason: "no Health counterpart")],
                       "the panel code itself is not reported, only the unmapped component")
    }

    func testAudiogramReadingsFoldIntoOneSamplePerDay() {
        func tone(_ code: String, _ v: Double, id: String) -> String { #"""
        {"resourceType":"Observation","id":"\#(id)","status":"final",
         "code":{"coding":[{"system":"urn:oid:1.2.3","code":"\#(code)","display":"\#(code)"}]},
         "effectiveDateTime":"2025-03-05T10:00:00Z",
         "valueQuantity":{"value":\#(v),"unit":"dB"}}
        """# }
        let out = ClinicalMapper.map(batch: [
            (obs(tone("PureTone_AUL_01000", 15, id: "a")), "a"),
            (obs(tone("PureTone_AUR_01000", 20, id: "b")), "b"),
            (obs(tone("PureTone_AUL_04000", 30, id: "c")), "c"),
            (obs(tone("PureTone_BUR_01000", 10, id: "d")), "d"),   // bone conduction: skipped
        ])
        XCTAssertEqual(out.audiograms.count, 1)
        XCTAssertEqual(out.audiograms[0].points, [
            AudiogramPoint(frequencyHz: 1000, leftDB: 15, rightDB: 20),
            AudiogramPoint(frequencyHz: 4000, leftDB: 30, rightDB: nil),
        ])
        XCTAssertEqual(out.skipped.map(\.code), ["PureTone_BUR_01000"])
    }

    func testSpecificLoincWinsOverGenericPanelCodeOnSameObservation() {
        // Epic lists 8716-3 "Vital signs" before 9279-1 on a respiratory-rate observation.
        let out = single(#"""
        {"resourceType":"Observation","id":"rr","status":"final",
         "code":{"coding":[
            {"system":"urn:oid:1.2.840.114350.1.13.48.2.7.2.707679","code":"9","display":"Respirations"},
            {"system":"http://loinc.org","code":"8716-3","display":"Vital signs"},
            {"system":"http://loinc.org","code":"9279-1","display":"Respiratory rate"}],
           "text":"Respirations"},
         "effectiveDateTime":"2023-04-26T13:36:00Z",
         "valueQuantity":{"value":20,"unit":"/min","code":"/min"}}
        """#)
        XCTAssertEqual(out.skipped, [])
        XCTAssertEqual(out.samples.count, 1)
        XCTAssertEqual(out.samples[0].metric, .respiratoryRate)
        XCTAssertEqual(out.samples[0].display, "Respirations")
    }

    func testBatchIsSortedByDate() {
        let later = #"""
        {"resourceType":"Observation","id":"2","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"29463-7"}]},
         "effectiveDateTime":"2025-04-01T10:00:00Z","valueQuantity":{"value":150,"code":"[lb_av]"}}
        """#
        let earlier = #"""
        {"resourceType":"Observation","id":"1","status":"final",
         "code":{"coding":[{"system":"http://loinc.org","code":"29463-7"}]},
         "effectiveDateTime":"2025-01-01T10:00:00Z","valueQuantity":{"value":160,"code":"[lb_av]"}}
        """#
        let out = ClinicalMapper.map(batch: [(obs(later), "a"), (obs(earlier), "b")])
        XCTAssertEqual(out.samples.map(\.sourceID), ["1", "2"])
    }
}
