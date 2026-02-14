# Understanding Test Modes

This project has **multiple test modes** that test different aspects of the system. Understanding the difference is crucial for debugging.

## TL;DR

| Test | What It Tests | Provider | Headers Set | Command |
|------|---------------|----------|-------------|---------|
| **E2E Test** | Traefik architecture | Docker | `X-Forwarded-By` | `./test-e2e.sh` |
| **Provider Test** | Cloud Run provider | File | `X-Serverless-Authorization` | `./test-provider.sh` |
| **Cloud Run Sim** | Full simulation with real tokens | File | `X-Serverless-Authorization` | `./test-cloudrun-sim.sh` |
| **Plugin Local** | ⚠️ Yaegi plugin (fails) | Plugin | N/A | `./test-plugin-local.sh` |

**Traefik Version:** All tests use `traefik:v2.10` for consistency.

---

## Traefik Plugin Architecture

This provider can run in two modes:

### Mode 1: Native Traefik Plugin (Yaegi)

For Traefik >= 3.0, plugins use the [Yaegi](https://github.com/traefik/yaegi) Go interpreter. Key requirements:

1. **Dependencies must be vendored** - Yaegi cannot resolve Go modules at runtime
2. **Run `go mod vendor`** to create the `vendor/` directory
3. **Include vendor in repository** - All dependencies must be committed

```bash
# Vendor dependencies
go mod vendor

# Verify vendor directory
ls vendor/
```

See [Traefik Plugin Development Guide](https://doc.traefik.io/traefik-hub/api-gateway/guides/plugin-development-guide) and [Go Vendoring](https://go.dev/ref/mod#vendoring).

**Plugin structure** (per [pluginproviderdemo](https://github.com/traefik/pluginproviderdemo)):
```
plugins-local/src/github.com/pci-tamper-protect/traefik-cloudrun-provider/
├── plugin/plugin.go    # Exports: Config, CreateConfig(), New()
├── go.mod
├── go.sum
├── vendor/             # All dependencies vendored
│   ├── cloud.google.com/
│   ├── google.golang.org/
│   └── modules.txt
└── .traefik.yml
```

**Verified Yaegi incompatibilities with GCP SDK** (see `go test -v ./plugin -run TestYaegi`):
- ❌ **gRPC** - `grpclog.init()` causes nil pointer dereference in Yaegi
- ❌ **GCP metadata** - Function signature mismatch: `func(*net.Dialer, string, string)` vs `func(string, string)`
- ✅ `internal/logging` loads successfully (no GCP deps)

### Mode 2: External Provider (Recommended) ⭐

Run the provider as an **external binary** with Traefik's File provider:

```
┌─────────────────────────┐     ┌─────────────────────────┐
│  traefik-cloudrun-      │     │      Traefik            │
│  provider (binary)      │────▶│   (File Provider)       │
│                         │     │                         │
│  - Discovers Cloud Run  │     │  - Reads routes.yml     │
│  - Fetches GCP tokens   │     │  - Routes traffic       │
│  - Writes routes.yml    │     │  - Applies middlewares  │
└─────────────────────────┘     └─────────────────────────┘
```

**Build the binary:**
```bash
go build -o traefik-cloudrun-provider ./cmd/provider
```

**Run modes:**
```bash
# One-shot mode (default) - generate once and exit
LABS_PROJECT_ID=my-project ./traefik-cloudrun-provider

# Daemon mode - continuous polling
MODE=daemon POLL_INTERVAL=30s LABS_PROJECT_ID=my-project ./traefik-cloudrun-provider
```

**Environment variables:**
| Variable | Default | Description |
|----------|---------|-------------|
| `LABS_PROJECT_ID` | (required) | Primary GCP project ID |
| `HOME_PROJECT_ID` | (optional) | Secondary GCP project ID |
| `REGION` | `us-central1` | GCP region |
| `MODE` | `once` | `once` or `daemon` |
| `POLL_INTERVAL` | `30s` | Polling interval for daemon mode |

**Advantages:**
- **Avoids Yaegi limitations** - Full Go runtime, no interpretation
- **Simpler debugging** - Standard Go binary with logs
- **Production-proven** - Used by `test-provider.sh` and `test-cloudrun-sim.sh`
- **Daemon mode** - Continuous updates with graceful shutdown

---

## Test 1: E2E Architecture Test 🏗️

**File:** `docker-compose.e2e.yml`
**Command:** `./test-e2e.sh`
**Purpose:** Validate Traefik gateway architecture

### What It Tests

✅ **Architecture validation:**
- Traefik as public gateway
- Frontend service (private, via Traefik)
- Backend service (private, via Traefik)
- Service-to-service communication through Traefik

✅ **Traefik functionality:**
- Routing rules work
- Middlewares can set headers
- Services accessible through gateway

❌ **What it does NOT test:**
- Cloud Run provider plugin
- Token generation from GCP
- `X-Serverless-Authorization` header
- Discovery of Cloud Run services

### How It Works

Uses **Docker provider** with static labels:

```yaml
services:
  backend:
    labels:
      - "traefik.http.routers.backend.middlewares=backend-headers"
      - "traefik.http.middlewares.backend-headers.headers.customrequestheaders.X-Forwarded-By=traefik"
```

**Key point:** Configuration is static Docker labels, not generated by the Cloud Run provider.

### Headers Set

- `X-Forwarded-By: traefik`

This simulates setting custom headers but doesn't test GCP authentication.

### When to Use

- ✅ Testing Traefik routing architecture
- ✅ Validating service-to-service communication patterns
- ✅ Quick smoke test that doesn't need GCP credentials
- ✅ CI/CD pipelines without GCP access

### Debug Output

When you run `./debug-headers.sh` against this test:

```
Test 7: Provider Sources
✓ Active providers:
  - docker

📝 NOTE: Using Docker provider (@docker)
   This is the e2e architecture test (docker-compose.e2e.yml)
   It tests Traefik routing but NOT the Cloud Run provider plugin
   Auth middlewares are named 'backend-headers@docker' not 'X-auth@file'
```

---

## Test 2: Cloud Run Provider Test 🔌

**File:** `docker-compose.provider.yml`
**Command:** `./test-provider.sh`
**Purpose:** Test the actual Cloud Run provider plugin

### What It Tests

✅ **Provider functionality:**
- Discovery of Cloud Run services
- Token generation from GCP metadata server or ADC
- Dynamic configuration generation
- Middleware creation with actual tokens
- `X-Serverless-Authorization` header injection

✅ **GCP integration:**
- Authentication with GCP APIs
- Identity token generation for each service
- Service label parsing (`traefik_*` labels)

✅ **Configuration output:**
- Generates `routes.yml` file
- Creates auth middlewares with real tokens
- Validates token format (JWT starting with `eyJ`)

### How It Works

1. **Provider runs** and connects to GCP Cloud Run API
2. **Discovers services** with `traefik_enable=true` label
3. **Fetches tokens** for each service (for service-to-service auth)
4. **Generates config** with middlewares containing `X-Serverless-Authorization: Bearer <token>`
5. **Traefik loads** the generated configuration from file

### Headers Set

- `X-Serverless-Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6I...`

This is the real header needed for Cloud Run service-to-service authentication.

### Requirements

**Local testing:**
```bash
export CLOUDRUN_PROVIDER_DEV_MODE=true
gcloud auth application-default login
export LABS_PROJECT_ID=your-project-stg
export HOME_PROJECT_ID=your-other-project  # optional
export REGION=us-central1
```

**Production:**
- Running in Cloud Run or GCE (metadata server access)
- Service account with `roles/iam.serviceAccountTokenCreator`

### When to Use

- ✅ Testing the actual Cloud Run provider plugin
- ✅ Validating token generation
- ✅ Testing against real GCP Cloud Run services
- ✅ Debugging header propagation issues
- ✅ Before deploying to production

### Debug Output

When you run `./debug-headers.sh` against this test:

```
Test 7: Provider Sources
✓ Active providers:
  - file

✓ Using File provider (@file)
   This is the actual Cloud Run provider generating configuration

Test 4: Authentication Middlewares
✓ Found authentication middlewares:
  - my-service-auth@file
  - another-service-auth@file

Test 5: Middleware Header Configuration
✓ Custom request headers configured
✓ X-Serverless-Authorization header is configured
  Token preview: Bearer eyJhbGciOiJS...
```

---

## Comparing the Two Tests

### E2E Test (Docker Provider)

```bash
$ ./test-e2e.sh

Test 7: Middleware Configuration (Docker Provider)
Note: This test uses Docker provider, not Cloud Run provider
      It sets X-Forwarded-By header, not X-Serverless-Authorization

✓ Backend headers middleware configured
✓ X-Forwarded-By header configured in middleware

Test 8: Header Propagation to Backend
✓ X-Forwarded-By header reaches backend
  Header value: traefik
✓ Header has expected value 'traefik'

NOTE: E2E Architecture Test Complete
This test validates Traefik gateway architecture using Docker provider.
It sets X-Forwarded-By header, not X-Serverless-Authorization.

To test the actual Cloud Run provider with X-Serverless-Authorization:
  ./test-provider.sh
```

### Provider Test (File Provider)

```bash
$ ./test-provider.sh

Step 2: Testing provider with ADC credentials
[CloudRunProvider] Initializing Cloud Run provider projects=[my-project-stg]
[CloudRunProvider] 🔍 Starting service discovery...
[CloudRunProvider] 🔍 Listing Cloud Run services in project project=my-project-stg
[CloudRunProvider] ✅ Discovered services project=my-project-stg count=5
[CloudRunProvider] 🔧 Processing Traefik-enabled service service=my-api
[CloudRunProvider] ✅ Successfully fetched identity token tokenLength=842
[ConfigBuilder] ✅ Created auth middleware 'my-api-auth' with X-Serverless-Authorization header (token length: 842, preview: eyJhbGciOi...)
[CloudRunProvider] ✅ Configuration generation complete routers=5 services=5 middlewares=7

✓ Routes file generated successfully
  Routers: 5
  Services: 5
  Middlewares: 7
```

---

## What to Test When

### Scenario: Local Development (Architecture Changes)

**Use:** `./test-e2e.sh`

You're working on:
- Traefik routing rules
- Service communication patterns
- Basic middleware functionality
- Frontend/backend integration

**Why:** Fast, no GCP credentials needed, tests architecture.

### Scenario: Provider Development (Plugin Logic)

**Use:** `./test-provider.sh`

You're working on:
- Service discovery logic
- Token generation
- Label parsing
- Middleware generation
- Configuration output

**Why:** Tests actual provider plugin against real GCP services.

### Scenario: Debugging Production Issues

**Use:** `./debug-headers.sh https://your-traefik:8081`

You need to:
- Check if middlewares are created
- Verify tokens are generated
- See what headers are configured
- Diagnose why headers aren't reaching services

**Why:** Diagnoses real configuration in deployed environment.

### Scenario: Before Deploying to labs-stg

**Run both:**
```bash
# 1. Architecture sanity check
./test-e2e.sh

# 2. Provider functionality check
./test-provider.sh

# 3. If both pass, deploy to labs-stg

# 4. After deploy, check production
./debug-headers.sh https://traefik-labs-stg.example.com:8081
```

---

## Common Confusion

### "Why does e2e test pass but production fails?"

The e2e test uses Docker provider with static config:
- ✅ Tests routing works
- ❌ Doesn't test provider plugin
- ❌ Doesn't test token generation

Your production uses the Cloud Run provider plugin:
- ✅ Needs to generate tokens
- ✅ Needs to discover services
- ✅ Needs GCP credentials

**Solution:** Run `./test-provider.sh` to test the actual provider.

### "Headers work in e2e but not production?"

E2E sets `X-Forwarded-By`, production needs `X-Serverless-Authorization`:
- Different headers
- Different configuration source
- Different auth mechanism

**Solution:** `./test-provider.sh` tests the production headers.

### "Debug script says no auth middlewares?"

If running against e2e test:
- Expected! It doesn't create `-auth` suffix middlewares
- It creates `backend-headers@docker` middleware instead
- This is NOT a problem

If running against provider test:
- Problem! Should have `-auth` middlewares
- Check provider logs for token generation errors
- Verify GCP credentials

---

## Summary

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  E2E Test (./test-e2e.sh)                                  │
│  ├── Purpose: Architecture validation                       │
│  ├── Provider: Docker                                       │
│  ├── Headers: X-Forwarded-By                               │
│  └── Use: Quick routing tests, no GCP needed               │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Provider Test (./test-provider.sh)                          │
│  ├── Purpose: Plugin functionality                          │
│  ├── Provider: File (from Cloud Run provider)              │
│  ├── Headers: X-Serverless-Authorization                   │
│  └── Use: Test actual provider, needs GCP credentials      │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Debug Script (./debug-headers.sh)                         │
│  ├── Purpose: Production diagnosis                          │
│  ├── Detects: Provider type automatically                   │
│  └── Use: Troubleshoot deployed Traefik                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Bottom line:** If you're debugging why headers aren't in labs-stg, run `./test-provider.sh` and `./debug-headers.sh` against labs-stg, not the e2e test.
