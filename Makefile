# Makefile for traefik-cloudrun-provider
.PHONY: help build test lint fmt vet clean install-tools docker-test e2e-test coverage pre-commit-install pre-commit-run

# Variables
BINARY_NAME=traefik-cloudrun-provider
BUILD_DIR=bin
MAIN_PATH=./cmd/provider
GO=go
GOFLAGS=-v
COVERAGE_FILE=coverage.out

# Colors for output
GREEN=\033[0;32m
YELLOW=\033[1;33m
RED=\033[0;31m
NC=\033[0m # No Color

## help: Display this help message
help:
	@echo "$(GREEN)traefik-cloudrun-provider - Makefile commands:$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make $(YELLOW)<target>$(NC)\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(GREEN)%s$(NC)\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

## build: Build the provider binary
build:
	@echo "$(GREEN)Building $(BINARY_NAME)...$(NC)"
	@mkdir -p $(BUILD_DIR)
	$(GO) build $(GOFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME) $(MAIN_PATH)
	@echo "$(GREEN)✓ Built: $(BUILD_DIR)/$(BINARY_NAME)$(NC)"

## build-static: Build static binary for containers
build-static:
	@echo "$(GREEN)Building static binary...$(NC)"
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=linux $(GO) build -a -installsuffix cgo -o $(BUILD_DIR)/$(BINARY_NAME) $(MAIN_PATH)
	@echo "$(GREEN)✓ Built static binary: $(BUILD_DIR)/$(BINARY_NAME)$(NC)"

## run: Run the provider locally (requires ADC auth)
run: build
	@echo "$(GREEN)Running $(BINARY_NAME)...$(NC)"
	@export CLOUDRUN_PROVIDER_DEV_MODE=true && \
	export LOG_LEVEL=DEBUG && \
	$(BUILD_DIR)/$(BINARY_NAME) /tmp/routes-test.yml

## clean: Clean build artifacts
clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	rm -rf $(BUILD_DIR)
	rm -f $(COVERAGE_FILE)
	@echo "$(GREEN)✓ Clean complete$(NC)"

##@ Testing

## test: Run all unit tests
test:
	@echo "$(GREEN)Running tests...$(NC)"
	$(GO) test -v ./...

## test-short: Run tests without long-running tests
test-short:
	@echo "$(GREEN)Running short tests...$(NC)"
	$(GO) test -short -v ./...

## coverage: Run tests with coverage
coverage:
	@echo "$(GREEN)Running tests with coverage...$(NC)"
	$(GO) test -coverprofile=$(COVERAGE_FILE) -covermode=atomic ./...
	@echo "$(GREEN)Coverage report saved to $(COVERAGE_FILE)$(NC)"
	@echo ""
	@echo "$(YELLOW)Coverage summary:$(NC)"
	$(GO) tool cover -func=$(COVERAGE_FILE) | grep total

## coverage-html: Generate HTML coverage report
coverage-html: coverage
	@echo "$(GREEN)Generating HTML coverage report...$(NC)"
	$(GO) tool cover -html=$(COVERAGE_FILE) -o coverage.html
	@echo "$(GREEN)✓ Coverage report: coverage.html$(NC)"

## docker-test: Run tests in Docker with ADC credentials
docker-test:
	@echo "$(GREEN)Building Docker test image...$(NC)"
	docker build -f Dockerfile.test -t $(BINARY_NAME):test .
	@echo "$(GREEN)Running tests in Docker...$(NC)"
	docker run -it \
		-v $(HOME)/.config/gcloud:/home/cloudrunner/.config/gcloud:ro \
		-e CLOUDRUN_PROVIDER_DEV_MODE=true \
		-e LOG_LEVEL=DEBUG \
		-e ENVIRONMENT=stg \
		-e LABS_PROJECT_ID=my-project-stg \
		-e HOME_PROJECT_ID=my-home-stg \
		-e REGION=us-central1 \
		$(BINARY_NAME):test \
		/tmp/routes.yml

## e2e-test: Run end-to-end tests
e2e-test:
	@echo "$(GREEN)Running E2E tests...$(NC)"
	./test-e2e.sh

##@ Code Quality

## fmt: Format Go code
fmt:
	@echo "$(GREEN)Formatting Go code...$(NC)"
	$(GO) fmt ./...
	@echo "$(GREEN)✓ Format complete$(NC)"

## vet: Run go vet
vet:
	@echo "$(GREEN)Running go vet...$(NC)"
	$(GO) vet ./...
	@echo "$(GREEN)✓ Vet complete$(NC)"

## lint: Run golangci-lint
lint:
	@echo "$(GREEN)Running golangci-lint...$(NC)"
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run ./...; \
	else \
		echo "$(RED)golangci-lint not installed. Run 'make install-tools'$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Lint complete$(NC)"

## lint-fix: Run golangci-lint with auto-fix
lint-fix:
	@echo "$(GREEN)Running golangci-lint with auto-fix...$(NC)"
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run --fix ./...; \
	else \
		echo "$(RED)golangci-lint not installed. Run 'make install-tools'$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Lint fix complete$(NC)"

## tidy: Tidy go.mod and go.sum
tidy:
	@echo "$(GREEN)Tidying go modules...$(NC)"
	$(GO) mod tidy
	@echo "$(GREEN)✓ Tidy complete$(NC)"

## check: Run all quality checks (fmt, vet, lint, test)
check: fmt vet lint test
	@echo "$(GREEN)✓ All checks passed$(NC)"

##@ Tools Installation

## install-tools: Install development tools
install-tools:
	@echo "$(GREEN)Installing development tools...$(NC)"
	@echo "$(YELLOW)Installing golangci-lint...$(NC)"
	@if ! command -v golangci-lint >/dev/null 2>&1; then \
		curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $$(go env GOPATH)/bin v1.55.2; \
	else \
		echo "golangci-lint already installed"; \
	fi
	@echo "$(YELLOW)Installing pre-commit...$(NC)"
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo "Please install pre-commit: pip install pre-commit"; \
	else \
		echo "pre-commit already installed"; \
	fi
	@echo "$(GREEN)✓ Tools installation complete$(NC)"

##@ Pre-commit Hooks

## pre-commit-install: Install pre-commit hooks
pre-commit-install:
	@echo "$(GREEN)Installing pre-commit hooks...$(NC)"
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit install; \
		echo "$(GREEN)✓ Pre-commit hooks installed$(NC)"; \
	else \
		echo "$(RED)pre-commit not installed. Run: pip install pre-commit$(NC)"; \
		exit 1; \
	fi

## pre-commit-run: Run pre-commit hooks on all files
pre-commit-run:
	@echo "$(GREEN)Running pre-commit hooks...$(NC)"
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		echo "$(RED)pre-commit not installed. Run: pip install pre-commit$(NC)"; \
		exit 1; \
	fi

##@ Docker

## docker-build: Build Docker image
docker-build:
	@echo "$(GREEN)Building Docker image...$(NC)"
	docker build -t $(BINARY_NAME):latest .

## docker-run: Run Docker container
docker-run:
	@echo "$(GREEN)Running Docker container...$(NC)"
	docker run -it --rm $(BINARY_NAME):latest

##@ CI/CD

## ci: Run CI checks locally
ci: tidy fmt vet lint test
	@echo "$(GREEN)✓ CI checks passed$(NC)"

.DEFAULT_GOAL := help
