.PHONY: build test test-cover lint licenses ci-local clean

build:
	CGO_ENABLED=0 go build -ldflags="-s -w" -o bin/archiver ./cmd/archiver
	CGO_ENABLED=0 go build -ldflags="-s -w" -o bin/partitioner ./cmd/partitioner

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
