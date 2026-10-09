# Build and install on a paired iPhone from the command line. No Xcode GUI needed
# once the account is signed in. Put your Team ID in .team and the phone's UDID
# (from `xcrun devicectl list devices`) in .device; both files are gitignored.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
TEAM   ?= $(shell cat .team 2>/dev/null)
DEVICE ?= $(shell cat .device 2>/dev/null)
BUNDLE  = health.speck.ClinicalVitalsSync
APP     = build/Build/Products/Debug-iphoneos/ClinicalVitalsSync.app

.PHONY: gen test build install launch run clean

gen:
	xcodegen generate

test:
	cd ClinicalMapper && swift test

build: gen
	xcodebuild -project ClinicalVitalsSync.xcodeproj -scheme ClinicalVitalsSync \
	  -configuration Debug -destination "id=$(DEVICE)" -derivedDataPath build \
	  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
	  DEVELOPMENT_TEAM=$(TEAM) build

install:
	xcrun devicectl device install app --device $(DEVICE) $(APP)

launch:
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE)

run: build install launch

clean:
	rm -rf build ClinicalVitalsSync.xcodeproj ClinicalMapper/.build
