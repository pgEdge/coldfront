.PHONY: build test test-cover lint ci-local clean

build:
	CGO_ENABLED=0 go build -ldflags="-s -w" -o bin/archiver ./cmd/archiver

test:
	go test -race -v ./...

test-cover:
	go test -race -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html

lint:
	~/go/bin/golangci-lint run --timeout=5m

ci-local:
	./run-ci-local.sh

clean:
	rm -rf bin/ coverage.out coverage.html ci-*.log
