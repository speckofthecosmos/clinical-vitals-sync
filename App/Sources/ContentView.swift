import SwiftUI
import ClinicalMapper

struct ContentView: View {
    @StateObject private var engine = SyncEngine()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await engine.run() }
                    } label: {
                        HStack {
                            if engine.isRunning { ProgressView().padding(.trailing, 4) }
                            Text(engine.isRunning ? engine.status : "Sync clinical records into Health")
                        }
                    }
                    .disabled(engine.isRunning)
                    if !engine.isRunning {
                        Text(engine.status).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let err = engine.lastError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Copies vitals and lab values from Health Records (your provider's FHIR data) into the ordinary Health categories so charts, trends and other apps can see them. Safe to run repeatedly.")
                }

                if engine.recordsRead > 0 {
                    Section("Clinical records read") {
                        Text("\(engine.recordsRead)")
                        Button("Copy report") { UIPasteboard.general.string = engine.reportText }
                    }
                }

                if !engine.written.isEmpty || engine.audiogramsWritten > 0 {
                    Section("Written") {
                        ForEach(engine.written, id: \.0) { metric, count in
                            HStack { Text(metric.label); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
                        }
                        if engine.audiogramsWritten > 0 {
                            HStack { Text("Audiogram"); Spacer(); Text("\(engine.audiogramsWritten)").foregroundStyle(.secondary) }
                        }
                    }
                }

                if !engine.skipped.isEmpty {
                    Section {
                        ForEach(engine.skipped) { g in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(g.display).lineLimit(1); Spacer(); Text("\(g.count)").foregroundStyle(.secondary) }
                                Text("\(g.code) · \(g.reason)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("Skipped") } footer: {
                        Text("Codes with no Health counterpart, or units the mapper doesn't know. Add them to LOINC.metricByCode / UnitConversion in ClinicalMapper.")
                    }
                }
            }
            .navigationTitle("Clinical Vitals Sync")
        }
    }
}
