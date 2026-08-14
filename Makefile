.PHONY: build test test-cover lint licenses compactor ci-local clean

# golangci-lint path: PATH first, else the default go install location. ci/matrix.sh
# passes GOLANGCI=<resolved path> so the compactor gate uses the same linter.
GOLANGCI ?= $(shell command -v golangci-lint 2>/dev/null || echo $(HOME)/go/bin/golangci-lint)
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
BUILD_TIME  = $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

build:
	CGO_ENABLED=0 go build -ldflags="-s -w -X github.com/pgedge/coldfront/internal/version.Version=$(VERSION) -X github.com/pgedge/coldfront/internal/version.BuildTime=$(BUILD_TIME)" -o bin/archiver ./cmd/archiver
	CGO_ENABLED=0 go build -ldflags="-s -w -X github.com/pgedge/coldfront/internal/version.Version=$(VERSION) -X github.com/pgedge/coldfront/internal/version.BuildTime=$(BUILD_TIME)" -o bin/partitioner ./cmd/partitioner

# compactor: a SEPARATE Go module (cmd/compactor/go.mod) so iceberg-go's heavy
# dependency tree never links into the lean archiver. Its full gate — vet, lint,
# test, static CGO-free build — is wired into ci/matrix.sh preflight so every
# compactor test runs in CI, never ad-hoc. (No -race: `go test` already compiles
# the whole iceberg-go tree via main.go's backend imports; -race would instrument
# all of it for currently-pure config tests — add it when concurrency code lands.)
compactor:
	cd cmd/compactor && go vet ./...
	cd cmd/compactor && "$(GOLANGCI)" run --timeout=5m
	cd cmd/compactor && go test ./...
	cd cmd/compactor && CGO_ENABLED=0 go build -ldflags="-s -w -X main.Version=$(VERSION) -X main.BuildTime=$(BUILD_TIME)" -o $(CURDIR)/bin/compactor .

test:
	go test -race -v ./...

test-cover:
	go test -race -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html

lint:
	~/go/bin/golangci-lint run --timeout=5m

licenses:
	go install github.com/google/go-licenses@latest
	"$$(go env GOPATH)/bin/go-licenses" check ./cmd/... ./internal/... --ignore github.com/pgedge/coldfront
	"$$(go env GOPATH)/bin/go-licenses" report ./cmd/archiver ./cmd/partitioner --ignore github.com/pgedge/coldfront > THIRD_PARTY_GO.txt
	@echo "wrote THIRD_PARTY_GO.txt"

ci-local:
	./run-ci-local.sh

clean:
	rm -rf bin/ coverage.out coverage.html ci-*.log
