# Clinical Vitals Sync

A small personal iOS app that copies the vitals and lab values a provider sends
to Apple Health's **Health Records** (FHIR clinical records) into the ordinary
Health categories: Weight, Height, BMI, Heart Rate, Blood Pressure, Body
Temperature, Respiratory Rate, Blood Oxygen, Blood Glucose.

Not for release. It exists so one person's provider data (Kaiser, in the
original case) shows up in Health's own charts, trends and third-party apps,
and so other people and agents can see what actually works.

## The problem it solves

Health Records data is stored as a separate HealthKit type
(`HKClinicalRecord`, e.g. `vitalSignRecord`) and shown under Profile → Health
Records → Clinical Vitals. Apple never merges it into the standard sample
types. A weight from a clinic visit therefore never appears on the Weight
chart, and apps reading `bodyMass` can't see it.

## What works, what doesn't (findings)

- **Shortcuts cannot read clinical records.** `Find Health Samples` only
  covers standard types. It can *write* standard types (`Log Health Sample`),
  so a Shortcut is fine as the last hop of a pipeline, never the first.
- **Health's "Export All Health Data" zip contains the FHIR JSON** under
  `apple_health_export/clinical-records/`. That is the only consumer path to
  the raw records without an app. A script + Shortcut pipeline built on it
  works but needs a manual export every time.
- **A third-party app can read clinical records** if it has the HealthKit
  capability with **Clinical Health Records** ticked
  (`com.apple.developer.healthkit.access = [health-records]`). On a paid
  developer team this is just a checkbox for development builds; Apple only
  scrutinises it at App Review, which a personal sideload never goes through.
  A free team can't use it.
- **Clinical records are read-only.** Nothing can write *into* Health Records.
  The app reads them and writes ordinary samples.
- **Idempotency comes free from HealthKit**: every written sample carries
  `HKMetadataKeySyncIdentifier` (derived from the FHIR resource id) and
  `HKMetadataKeySyncVersion`. A second save with the same identifier from the
  same app replaces rather than duplicates. Tap Sync as often as you like.
- **Blood pressure must be a correlation.** HealthKit refuses lone systolic
  or diastolic samples in the Blood Pressure category; the app builds an
  `HKCorrelation` from a systolic + diastolic pair. Epic-based providers send
  a panel observation (LOINC 85354-9 or 55284-4) with components; the mapper
  also pairs lone 8480-6 / 8462-4 observations taken at the same instant.
- **FHIR version doesn't matter for this.** The Observation fields used
  (`code`, `effectiveDateTime`/`effectivePeriod`, `valueQuantity`,
  `component`) are the same in DSTU2 and R4.
- **Only values with a Health counterpart can move.** Allergies, conditions,
  immunizations, procedures and notes have no standard Health type; they stay
  as clinical records (where Health already shows them). Most lab analytes
  (A1c, lipids, creatinine…) likewise have no Health type; only glucose does.
  The app lists every skipped code with its display name so the mapping
  table can be extended when something turns out to be mappable.

## Layout

- `ClinicalMapper/` — pure Swift package, no HealthKit. Decodes a FHIR
  Observation, maps LOINC → metric, normalises units to one canonical unit
  per metric. Fully unit-tested on macOS (`swift test`).
- `App/` — SwiftUI app with one screen: a Sync button, counts written per
  metric, and the skipped-code report. `SyncEngine` does the HealthKit I/O.
- `project.yml` — [xcodegen](https://github.com/yonaskolb/XcodeGen) spec;
  the `.xcodeproj` is generated and gitignored.
- `Makefile` — build/install/launch from the terminal via `xcodebuild` and
  `devicectl`.

## Build and install

Prerequisites: Xcode installed and signed in to a **paid** Apple Developer
team (Xcode → Settings → Accounts), `brew install xcodegen`, the phone paired
(Developer Mode on). The Xcode toolchain must be active; the Makefile sets
`DEVELOPER_DIR` so `xcode-select` can stay on the command-line tools.

```sh
echo -n TEAMID > .team                  # 10-char Team ID (OU on your dev cert)
xcrun devicectl list devices            # copy the phone's UDID
echo -n 00008140-XXXXXXXXXXXXXXXX > .device
make test                               # mapper unit tests
make run                                # generate, build, install, launch
```

First launch on the phone asks for Health permissions: allow all the
clinical-record reads and the sample writes. Then tap Sync.

Finding the Team ID without the Xcode GUI: Xcode 16+ keeps profiles under
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/`; any
`.mobileprovision` decodes with `security cms -D -i`. If a sideloading tool
(Sideloadly, AltStore) has already signed something, its stored certificate's
`OU=` is the Team ID (`openssl x509 -in cert.pem -noout -subject`).

## Extending the mapping

`ClinicalMapper/Sources/ClinicalMapper/Mapping.swift`:

- `LOINC.metricByCode` — add a LOINC code → `Metric`.
- `UnitConversion.canonical` — add a UCUM unit token for that metric.
- New metric: add a `Metric` case + canonical unit, the write type in
  `SyncEngine.writeTypes`, and the `HKQuantityTypeIdentifier` in
  `SyncEngine.healthObject(for:)`.

Add a test in `ClinicalMapperTests` for each new code or unit; the fixtures
are small inline FHIR JSON strings.
