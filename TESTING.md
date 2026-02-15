# Testing Guide

## Overview

This document describes the testing strategy for traefik-cloudrun-provider, including unit tests, integration tests with Docker, and E2E tests with Traefik.

## Logging Configuration

The provider uses structured logging with configurable output formats.

### Environment Variables

```bash
# Log level: DEBUG, INFO, WARN, ERROR (default: INFO)
export LOG_LEVEL=DEBUG

# Log format: text, json (default: text)
export LOG_FORMAT=json

# Development mode: enables ADC fallback for local testing
export CLOUDRUN_PROVIDER_DEV_MODE=true
```

### Example Outputs

**Text format** (human-readable):
```
2026-01-10T12:00:00Z [INFO] CloudRunProvider: Initializing Cloud Run provider projects=[my-project-stg,my-home-stg] region=us-central1 pollInterval=30s
2026-01-10T12:00:01Z [DEBUG] CloudRunProvider: Cloud Run API client initialized
2026-01-10T12:00:01Z [WARN] CloudRunProvider: Running in development mode - will use ADC for tokens if metadata server unavailable
2026-01-10T12:00:02Z [INFO] CloudRunProvider: Discovered services project=my-project-stg count=5
2026-01-10T12:00:03Z [INFO] CloudRunProvider: Configuration generation complete totalServices=8 routers=15 services=8 middlewares=8 duration=1.2s
```

**JSON format** (machine-readable, for Cloud Logging):
```json
{"timestamp":"2026-01-10T12:00:00Z","level":"INFO","component":"CloudRunProvider","message":"Initializing Cloud Run provider","projects":"[my-project-stg my-home-stg]","region":"us-central1","pollInterval":"30s"}
{"timestamp":"2026-01-10T12:00:01Z","level":"DEBUG","component":"CloudRunProvider","message":"Cloud Run API client initialized"}
{"timestamp":"2026-01-10T12:00:01Z","level":"WARN","component":"CloudRunProvider","message":"Running in development mode - will use ADC for tokens if metadata server unavailable"}
```

## Local Development Testing

### Prerequisites

1. **GCP Authentication**:
```bash
gcloud auth application-default login
```

2. **Environment Setup** (choose one method):

**Method 1: Using .env file (recommended)**:
```bash
# Copy sample configuration
cp .env.sample .env

# Edit .env with your values
cat > .env << 'EOF'
CLOUDRUN_PROVIDER_DEV_MODE=true
LOG_LEVEL=DEBUG
ENVIRONMENT=stg
LABS_PROJECT_ID=my-project-stg
HOME_PROJECT_ID=my-home-stg
REGION=us-central1
EOF
```

**Method 2: Export environment variables**:
```bash
export CLOUDRUN_PROVIDER_DEV_MODE=true
export LOG_LEVEL=DEBUG
export ENVIRONMENT=stg
export LABS_PROJECT_ID=my-project-stg
export HOME_PROJECT_ID=my-home-stg
export REGION=us-central1
```

### Run Provider Locally

```bash
# Build
go build -o bin/traefik-cloudrun-provider ./cmd/provider

# Run (generates routes.yml once and exits)
./bin/traefik-cloudrun-provider /tmp/routes-test.yml

# Check output
cat /tmp/routes-test.yml
```

**Expected behavior**:
- Warns about dev mode (normal when running locally)
- Uses ADC to fetch tokens instead of metadata server
- Generates routes.yml with all discovered services

## Unit Tests

```bash
# Run all unit tests
go test ./...

# Run with coverage
go test -cover ./...

# Run with verbose output
go test -v ./...

# Run specific package
go test -v ./internal/gcp/
go test -v ./internal/logging/
```

### Unit Test Coverage

- ✅ `internal/gcp/token_manager_test.go` - Token caching and stats (2 tests, PASS)
- ✅ `internal/logging/logger_test.go` - Logging formats, levels, fields, parsing (9 tests, PASS)
- ✅ `provider/provider_test.go` - Provider initialization, config validation, service processing, dynamic config (12 tests, PASS)

**Run all tests:**
```bash
go test ./...
# ok  	github.com/pci-tamper-protect/traefik-cloudrun-provider/internal/gcp	0.841s
# ok  	github.com/pci-tamper-protect/traefik-cloudrun-provider/internal/logging	0.401s
# ok  	github.com/pci-tamper-protect/traefik-cloudrun-provider/provider	1.214s
```

## Docker Integration Tests

### Test with Local ADC Credentials

```dockerfile
# Dockerfile.provider
FROM golang:1.21

WORKDIR /app
COPY . .

# Build provider
RUN go build -o bin/traefik-cloudrun-provider ./cmd/provider

# Run as non-root (Cloud Run best practice)
RUN useradd -m -u 1000 cloudrunner
USER cloudrunner

ENTRYPOINT ["./bin/traefik-cloudrun-provider"]
```

### Run Docker Test

```bash
# Build test image
docker build -f Dockerfile.provider -t traefik-cloudrun-provider:test .

# Run with ADC credentials mounted
docker run -it \
  -v $HOME/.config/gcloud:/home/cloudrunner/.config/gcloud:ro \
  -e CLOUDRUN_PROVIDER_DEV_MODE=true \
  -e LOG_LEVEL=DEBUG \
  -e ENVIRONMENT=stg \
  -e LABS_PROJECT_ID=my-project-stg \
  -e HOME_PROJECT_ID=my-home-stg \
  -e REGION=us-central1 \
  traefik-cloudrun-provider:test \
  /tmp/routes.yml
```

**Expected logs**:
```
INFO CloudRunProvider: Initializing Cloud Run provider
WARN CloudRunProvider: Running in development mode - will use ADC for tokens
INFO CloudRunProvider: Discovered services project=my-project-stg count=5
INFO CloudRunProvider: Configuration generation complete
```

### Simulated Cloud Run Environment

Test without ADC (simulating Cloud Run environment):

```bash
# This should fail gracefully with clear error message
docker run -it \
  -e K_SERVICE=traefik-example \
  -e LOG_LEVEL=DEBUG \
  -e ENVIRONMENT=stg \
  -e LABS_PROJECT_ID=my-project-stg \
  -e HOME_PROJECT_ID=my-home-stg \
  -e REGION=us-central1 \
  traefik-cloudrun-provider:test \
  /tmp/routes.yml
```

**Expected behavior**:
- Detects it's in Cloud Run (K_SERVICE is set)
- Dev mode automatically disabled
- Tries metadata server
- Fails with: "metadata server not available"

## E2E Tests with Traefik

### Architecture

The E2E test simulates the real Cloud Run deployment architecture:

**Production (Cloud Run)**:
```
Internet → Traefik (public) → Frontend (private) → Backend (private)
                    ↓
              Service-to-service auth via identity tokens
```

**Local Testing (Docker)**:
```
localhost → Traefik (docker provider) → Frontend → Backend
                    ↓
              Same routing logic, different provider
```

### Test Services

**Backend** (`tests/e2e/backend/main.go`):
- Simple HTTP server on port 8080
- Endpoint: `/api/hello` - Returns JSON with service info
- Endpoint: `/health` - Health check
- Private service (only accessible through Traefik)

**Frontend** (`tests/e2e/frontend/main.go`):
- HTTP server that calls backend
- Endpoint: `/` - Returns combined frontend + backend response
- Endpoint: `/health` - Health check
- Calls backend through Traefik gateway (service-to-service)
- Private service (only accessible through Traefik)

**Traefik**:
- Public gateway on port 80
- Dashboard on port 8081
- Uses Docker provider for local testing (instead of Cloud Run provider)
- Routes configured via Docker labels

### Run E2E Test

```bash
# Run comprehensive E2E test
./test-e2e.sh
```

The test script will:
1. Build and start all services (Traefik, Frontend, Backend)
2. Verify Traefik dashboard is accessible
3. Test backend privacy (should not be directly accessible)
4. Test backend access through Traefik gateway
5. Test full stack: Frontend → Traefik → Backend
6. Verify health checks
7. Validate routing configuration

**Expected Output**:
```
🧪 E2E Testing: Traefik Gateway + Frontend + Backend
=====================================================

Step 1: Building and starting services
[+] Running 3/3
 ✔ Container traefik   Started
 ✔ Container backend   Started
 ✔ Container frontend  Started

Test 1: Traefik Dashboard
✓ Traefik dashboard is accessible
  Routers configured: 3
  Services configured: 3

Test 2: Backend Privacy (should not be directly accessible)
⚠ Backend is running (internal access works)

Test 3: Backend Access Through Traefik
✓ Backend accessible through Traefik gateway
  Response: {"message":"Hello from Backend!","service":"backend","version":"1.0.0"}

Test 4: Frontend → Traefik → Backend Communication
✓ Full stack working: Frontend → Traefik → Backend
  Response:
  {
    "frontend": "Hello from Frontend!",
    "backend": {
      "message": "Hello from Backend!",
      "service": "backend",
      "version": "1.0.0"
    }
  }

Test 5: Service Health Checks
✓ Frontend health check passed
✓ Backend health check passed

Test 6: Routing Configuration
✓ Frontend router configured
✓ Backend router configured

========================================
All E2E tests passed! 🎉
========================================

Architecture verified:
  ✓ Traefik Gateway (Public)
  ✓ Frontend Service (Private, accessible via Traefik)
  ✓ Backend Service (Private, accessible via Traefik)
  ✓ Frontend → Traefik → Backend communication

Access points:
  Frontend:  http://app.localhost/
  Backend:   http://api.localhost/api/hello
  Dashboard: http://traefik.localhost:${TRAEFIK_API_PORT:-8091}/dashboard/
```

### Manual Testing

```bash
# Start services
docker-compose -f docker-compose.e2e.yml up -d

# Test frontend (which calls backend internally)
curl -H "Host: app.localhost" http://localhost/

# Test backend directly
curl -H "Host: api.localhost" http://localhost/api/hello

# View Traefik dashboard
open http://traefik.localhost:${TRAEFIK_API_PORT:-8091}/dashboard/

# View logs
docker-compose -f docker-compose.e2e.yml logs -f

# Cleanup
docker-compose -f docker-compose.e2e.yml down
```

**Assertions**:
- ✅ Traefik starts and configures routes from Docker labels
- ✅ Frontend accessible through Traefik on `app.localhost`
- ✅ Backend accessible through Traefik on `api.localhost`
- ✅ Frontend successfully calls backend through Traefik
- ✅ Services are private (not directly accessible, only through gateway)
- ✅ Health checks work
- ✅ Routing configuration matches expected architecture

## Continuous Polling Tests

Test the polling loop (not just one-shot generation):

```go
// tests/integration/provider_test.go
package integration

import (
	"testing"
	"time"
	"github.com/pci-tamper-protect/traefik-cloudrun-provider/provider"
)

func TestProviderPolling(t *testing.T) {
	config := &provider.Config{
		ProjectIDs:   []string{"my-project-stg"},
		Region:       "us-central1",
		PollInterval: 5 * time.Second,
	}

	p, err := provider.New(config)
	if err != nil {
		t.Fatalf("Failed to create provider: %v", err)
	}

	configChan := make(chan *provider.DynamicConfig, 10)

	// Start provider
	if err := p.Start(configChan); err != nil {
		t.Fatalf("Failed to start provider: %v", err)
	}
	defer p.Stop()

	// Should receive initial config immediately
	select {
	case config := <-configChan:
		if len(config.HTTP.Routers) == 0 {
			t.Error("Expected routers in initial config")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Timeout waiting for initial config")
	}

	// Should receive another config after poll interval
	select {
	case <-configChan:
		t.Log("Received config update from polling")
	case <-time.After(15 * time.Second):
		t.Fatal("Timeout waiting for poll update")
	}
}
```

## Performance Tests

### Measure Configuration Generation Time

```go
// tests/performance/benchmark_test.go
func BenchmarkConfigGeneration(b *testing.B) {
	// Setup with mock services
	config := &provider.Config{
		ProjectIDs: []string{"test-project"},
		Region:     "us-central1",
	}

	p, _ := provider.New(config)
	configChan := make(chan *provider.DynamicConfig, 1)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		p.Start(configChan)
		<-configChan
		p.Stop()
	}
}
```

### Expected Performance

- **Cold start**: < 2s (includes Cloud Run API calls)
- **Config generation**: < 500ms for 50 services
- **Token fetch**: < 100ms (cached) or < 500ms (fresh)
- **Memory usage**: < 100 MB for 100 services

## Test Scenarios

### Scenario 1: Happy Path
- ✅ Metadata server available (in Cloud Run)
- ✅ All services have proper labels
- ✅ Tokens fetch successfully
- ✅ Routes generated correctly

### Scenario 2: Development Mode
- ✅ Metadata server unavailable (local)
- ✅ Dev mode enabled
- ✅ ADC credentials present
- ✅ Fallback to ADC successful

### Scenario 3: Partial Failures
- ✅ Some services fail token fetch
- ✅ Provider continues with other services
- ✅ Failed services get error marker in middleware

### Scenario 4: API Errors
- ✅ Cloud Run API returns 403 (permissions)
- ✅ Provider logs error clearly
- ✅ Retries on next poll

## Test Checklist

Before merging:

- [ ] All unit tests pass
- [ ] Docker test with ADC credentials works
- [ ] E2E test with Traefik container works
- [ ] Logging output is clear and useful
- [ ] Performance benchmarks meet targets
- [ ] Error messages are helpful
- [ ] Documentation is up-to-date

## Debugging

### Enable Verbose Logging

```bash
export LOG_LEVEL=DEBUG
export LOG_FORMAT=text  # Easier to read during debugging
```

### Common Issues

**"metadata server not available"**
- Expected when running locally
- Solution: Set `CLOUDRUN_PROVIDER_DEV_MODE=true` and use ADC

**"failed to create token source with ADC"**
- ADC credentials not configured
- Solution: Run `gcloud auth application-default login`

**"no router labels found"**
- Service missing Traefik labels
- Solution: Add `traefik_enable=true` and router labels to service

**Empty routes.yml**
- No services found with traefik_enable=true
- Check project IDs and region are correct

---

## Cloud Run Simulation Testing (⭐ Recommended for Debugging)

### Overview

The Cloud Run simulation (`test-cloudrun-sim.sh`) provides a full local replica of your production environment with real authentication and complete instrumentation.

### What It Does

1. **Generates real configuration** from your GCP Cloud Run services
2. **Fetches real identity tokens** using traefik-stg service account
3. **Runs Traefik locally** with the generated routes
4. **Provides mock services** for testing authentication
5. **Enables full debugging** with access logs and instrumentation

### Usage

```bash
./test-cloudrun-sim.sh
```

### Architecture

```
┌─────────────────────────────────────────────────┐
│  Your Machine (Local)                           │
│                                                  │
│  ┌───────────────────────────────────────────┐ │
│  │ Traefik Gateway (Port 8090/8091)          │ │
│  │ • Loads routes.yml (real services)        │ │
│  │ • Adds X-Serverless-Authorization headers │ │
│  │ • Routes to Cloud Run services            │ │
│  └───────────────────────────────────────────┘ │
│                 ↓                                │
│  ┌───────────────────────────────────────────┐ │
│  │ Mock Services (for testing)               │ │
│  │ • Header Inspector: Shows all headers    │ │
│  │ • Mock Cloud Run Service: Validates auth │ │
│  └───────────────────────────────────────────┘ │
│                                                  │
│  Routes point to real Cloud Run services ────── ┼ ──→ GCP
│  (with real identity tokens)                    │
└─────────────────────────────────────────────────┘
```

### Debug Endpoints

Once running, you have access to:

- **Traefik Dashboard:** http://localhost:8091/dashboard/
- **API Endpoints:** http://localhost:8091/api/http/routers
- **Real Service Test:** `curl -v http://localhost:8090/lab1`
- **Header Inspector:** `docker exec header-inspector wget -qO- http://localhost:8080/`

### Debugging Authentication

#### 1. Check Token Generation

```bash
# View generated tokens (sanitized in routes.yml)
grep "X-Serverless-Authorization" test-output/routes.yml | head -5
```

#### 2. Verify Headers Reach Backend

```bash
# Direct test of header inspector
docker exec header-inspector wget -qO- http://localhost:8080/ | jq .

# Should show:
# {
#   "auth_headers": {
#     "x_serverless_authorization": "Bearer eyJ..."
#   }
# }
```

#### 3. Test Real Service Routing

```bash
# This should work because Traefik adds the identity token
curl -v http://localhost:8090/lab1

# Should return 200 OK from the real Cloud Run service
```

#### 4. View Traefik's Perspective

```bash
# See all middlewares (including auth)
curl http://localhost:8091/api/http/middlewares | jq .

# See all routers
curl http://localhost:8091/api/http/routers | jq .

# See all services
curl http://localhost:8091/api/http/services | jq .
```

### Mock Services

#### Header Inspector

Shows all headers received by the backend:

```bash
docker exec header-inspector wget -qO- http://localhost:8080/
```

**Output:**
```json
{
  "timestamp": "2026-01-12T03:30:00Z",
  "method": "GET",
  "path": "/",
  "headers": {
    "X-Serverless-Authorization": ["Bearer eyJ..."],
    "X-Forwarded-For": ["172.18.0.1"],
    "X-Forwarded-Host": ["localhost:8090"],
    ...
  },
  "auth_headers": {
    "x_serverless_authorization": "Bearer eyJhbG...ndg",
    "x_forwarded_for": "172.18.0.1",
    "x_forwarded_host": "localhost:8090"
  }
}
```

#### Mock Cloud Run Service

Simulates a Cloud Run service with authentication validation:

```bash
# Test authentication (should pass via Traefik)
curl http://localhost:8090/mock

# Test without auth (should fail)
docker exec mock-cloudrun-service wget -qO- http://localhost:8080/
```

**Authenticated Response:**
```json
{
  "message": "Hello from mock-cloudrun-service",
  "service": "mock-cloudrun-service",
  "timestamp": "2026-01-12T03:30:00Z",
  "auth": {
    "authenticated": true,
    "method": "X-Serverless-Authorization",
    "token_preview": "eyJhbGciOiJSUzI1...m8ndg"
  }
}
```

**Unauthenticated Response (401):**
```json
{
  "message": "Hello from mock-cloudrun-service",
  "service": "mock-cloudrun-service",
  "timestamp": "2026-01-12T03:30:00Z",
  "auth": {
    "authenticated": false,
    "error": "No authentication header present"
  }
}
```

### Troubleshooting

#### "Routes not loaded in Traefik"

```bash
# 1. Check routes.yml was generated
cat test-output/routes.yml

# 2. Check Traefik logs
docker-compose -f docker-compose.cloudrun-sim.yml logs traefik

# 3. Look for "Configuration reload detected"
```

#### "No X-Serverless-Authorization header"

```bash
# 1. Check middleware was created
curl http://localhost:8091/api/http/middlewares | jq '.[] | select(.name | contains("auth"))'

# 2. Check router is using middleware
curl http://localhost:8091/api/http/routers | jq '.[] | {name, middlewares}'

# 3. Verify token in routes.yml
grep -A 3 "lab1-auth:" test-output/routes.yml
```

#### "Service account impersonation failed"

```bash
# Check current impersonation
gcloud config get-value auth/impersonate_service_account

# Set it manually
gcloud config set auth/impersonate_service_account traefik-stg@labs-stg.iam.gserviceaccount.com

# Verify IAM permissions
gcloud projects get-iam-policy labs-stg \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/iam.serviceAccountTokenCreator"
```

### Development Workflow

Typical debugging workflow:

```bash
# 1. Start simulation
./test-cloudrun-sim.sh

# 2. In another terminal, test your route
curl -v http://localhost:8090/your-route

# 3. Check headers
docker exec header-inspector wget -qO- http://localhost:8080/ | jq .

# 4. View logs
docker-compose -f docker-compose.cloudrun-sim.yml logs -f traefik

# 5. Make code changes
# Edit provider code...

# 6. Rebuild and retest
docker build -f Dockerfile.provider -t traefik-cloudrun-provider:test .
./test-cloudrun-sim.sh
```

### Stopping the Simulation

```bash
# Ctrl+C in the running terminal, or:
docker-compose -f docker-compose.cloudrun-sim.yml down
```
