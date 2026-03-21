.PHONY: build test release

build:
	xcodebuild -scheme TestTicket19CLI -configuration Debug -destination "platform=macOS,arch=arm64" -quiet build

test:
	direnv exec . sh -lc 'SOLIX_EMAIL="$$SOLIX_EMAIL" SOLIX_PASSWORD="$$SOLIX_PASSWORD" SOLIX_COUNTRY="EU" SOLIX_REQUEST_TIMEOUT=60 \
	~/Library/Developer/Xcode/DerivedData/SolixMenu-*/Build/Products/Debug/TestTicket19CLI'

release:
	# Uses latest git tag for version (or pass TAG)
	# Defaults: NOTARIZE=1, PUBLISH=1 (make release completes the flow)
	./scripts/release.sh
	@echo "Tip: TAG=1.0.0 make release"
	@echo "Tip: SIGN_IDENTITY=... NOTARY_PROFILE=... make release"
	@echo "Tip: PUBLISH=0 make release (skip GitHub/Homebrew publish)"
