SHELL := /bin/bash

.PHONY: help tidy fmt test build-linux build-macos sign-macos-dev sign-macos-release notarize-macos sync-schema

help:
	@echo "Targets:"
	@echo "  tidy         - go mod tidy"
	@echo "  fmt          - gofmt all Go files"
	@echo "  test         - go test ./..."
	@echo "  build-linux  - build Linux nexusd + helper (amd64/arm64)"
	@echo "  build-macos  - build macOS nexusd (arm64)"
	@echo "  sync-schema  - sync protocol schema into Go package copy"

tidy:
	go mod tidy

fmt:
	gofmt -w $$(find client config daemon enroll logstream netpolicy protocol sandbox version nexus-linux nexus-macos -name '*.go' -type f)

test:
	go test ./...

VERSION   ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT    ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS   := -ldflags "-X cybros.ai/nexus/version.Version=$(VERSION) -X cybros.ai/nexus/version.Commit=$(COMMIT) -X cybros.ai/nexus/version.BuildDate=$(BUILD_DATE)"

build-linux:
	mkdir -p dist
	GOOS=linux GOARCH=amd64 go build $(LDFLAGS) -o dist/nexusd-linux-amd64 ./nexus-linux/cmd/nexusd
	GOOS=linux GOARCH=arm64 go build $(LDFLAGS) -o dist/nexusd-linux-arm64 ./nexus-linux/cmd/nexusd
	GOOS=linux GOARCH=amd64 go build $(LDFLAGS) -o dist/nexus-helper-linux-amd64 ./nexus-linux/cmd/nexus-helper
	GOOS=linux GOARCH=arm64 go build $(LDFLAGS) -o dist/nexus-helper-linux-arm64 ./nexus-linux/cmd/nexus-helper

build-macos:
	mkdir -p dist
	GOOS=darwin GOARCH=arm64 go build $(LDFLAGS) -o dist/nexusd-macos-arm64 ./nexus-macos/cmd/nexusd
	@echo "Run 'make sign-macos-dev' for ad-hoc signing (local dev)"

# macOS code signing targets

sign-macos-dev: ## Ad-hoc signing for local development
	codesign -s - dist/nexusd-macos-arm64

DEVELOPER_ID ?=
sign-macos-release: ## Developer ID signing for distribution (requires Apple Developer account)
	@test -n "$(DEVELOPER_ID)" || (echo "DEVELOPER_ID is required"; exit 1)
	codesign --sign "$(DEVELOPER_ID)" --timestamp --options runtime dist/nexusd-macos-arm64

notarize-macos: ## Apple notarization (requires Apple Developer account + app-specific password)
	@test -n "$(APPLE_ID)" || (echo "APPLE_ID is required"; exit 1)
	@test -n "$(TEAM_ID)" || (echo "TEAM_ID is required"; exit 1)
	cd dist && zip -j nexusd-macos-arm64.zip nexusd-macos-arm64
	xcrun notarytool submit dist/nexusd-macos-arm64.zip \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--wait

sync-schema:
	bash tools/sync_schema.sh
