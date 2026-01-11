# Traefik Cloud Run Provider - Design Document

## Overview

Create a Traefik provider that discovers Google Cloud Run services and generates dynamic routing configuration based on labels, with integrated GCP service-to-service authentication via identity tokens.

It is critical that we can run traefik and test containers in a local docker-compose for local testing.  There should also be a way to simulare the traefik container running in cloud-run as well as landing page and lab services.  The first client repo for this traefik provider is $GIT_REPOS_PATH/e-skimming-labs/deploy/traefik.  You can read the design docs at $GIT_REPOS_PATH/e-skimming-labs/docs/TRAEFIK-ARCHITECTURE.md and TRAEFIK-IMPLEMENTATION-SUMMARY.md.

One major challenge is that cloudrun only exposes one port - 8080, whereas the traefik container has an api and dashboard (at 8081 for us).  This means that until we find a proper deployment model for traefik to expose via path the api/dashboard or run it as a separate container, we have to design around the limitation of not being able to access the traefik api.  This means we often have to read gcloud logs to debug in stg deploys. Hence we need to be able to thoroughly test everything in a local docker-compose environment that mimicks the stg env.  docker-compose.yml, docker-compose.stg-sim.yml should use Dockerfiles that are as similar as possible to the cloud-run Dockerfile.
Alternatively, if there is a clean path to exposing traefik API, we could develop that first and then leverate the Traefik API more.

We will be using the plugin(s) to refactor $GIT_REPOS_PATH/e-skimming-labs.

## Problem Statement

Current approach in $GIT_REPOS_PATH/e-skimming-labs/deploy/traefik  uses complex bash scripts (entrypoint.sh, generate-routes-from-labels.sh) that:
1. Run only at startup - no dynamic updates
2. Mix concerns - service discovery, token management, config generation
3. Difficult to test and maintain
4. Don't fit Traefik's architecture model
5. Require container restarts for route changes

**Key Challenge**: GCP service-to-service authentication requires injecting identity tokens in Authorization headers, but existing Traefik JWT middlewares only validate tokens, not inject them.

## Goals

1. **Replace shell scripts** with proper Traefik provider
2. **Enable dynamic routing** - detect Cloud Run service changes without restart
3. **Simplify deployment** - reduce complexity in Traefik container
4. **Maintain label-based config** - preserve existing label format
5. **Automatic token management** - fetch, cache, and refresh identity tokens
6. **Future-proof** - support both polling and event-driven approaches
7. **Local Testing** - should not require metadata service and leverage mounted in ADC creds to call go sdk for cloud run or event arc

## Architecture

### Component Overview

```
┌──────────────────────────────────────────────────────────┐
│                  Traefik Process                          │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │         Cloud Run Provider Plugin                   │ │
│  │                                                     │ │
│  │  ┌───────────────────────────────────────────────┐ │ │
│  │  │  Discovery Engine                             │ │ │
│  │  │  • Poll Cloud Run API every N seconds         │ │ │
│  │  │  • Filter services with traefik_enable=true   │ │ │
│  │  │  • Extract labels and metadata                │ │ │
│  │  │  • Detect configuration changes               │ │ │
│  │  └───────────────────────────────────────────────┘ │ │
│  │                                                     │ │
│  │  ┌───────────────────────────────────────────────┐ │ │
│  │  │  Configuration Generator                      │ │ │
│  │  │  • Parse traefik_* labels                     │ │ │
│  │  │  • Map GCP labels (underscores) to Traefik    │ │ │
│  │  │  • Generate routers, services, middlewares    │ │ │
│  │  │  • Apply priorities and rules                 │ │ │
│  │  └───────────────────────────────────────────────┘ │ │
│  │                                                     │ │
│  │  ┌───────────────────────────────────────────────┐ │ │
│  │  │  Token Manager                                │ │ │
│  │  │  • Fetch identity tokens from metadata server │ │ │
│  │  │  • Cache tokens by audience (service URL)     │ │ │
│  │  │  • Refresh before 1-hour expiry               │ │ │
│  │  │  • Handle token fetch failures gracefully     │ │ │
│  │  └───────────────────────────────────────────────┘ │ │
│  │                                                     │ │
│  │  ┌───────────────────────────────────────────────┐ │ │
│  │  │  Auth Middleware Factory                      │ │ │
│  │  │  • Create middleware per service              │ │ │
│  │  │  • Inject "Authorization: Bearer {token}"     │ │ │
│  │  │  • Reference from router configs              │ │ │
│  │  └───────────────────────────────────────────────┘ │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              Traefik Core Router                    │ │
│  │  • Receives dynamic config from provider           │ │
│  │  • Routes requests based on rules                  │ │
│  │  • Applies middlewares (including token injection) │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### Provider vs Middleware: Combined Approach

**Decision**: Combine provider and middleware in single repository because:

1. **Tight Coupling**: Provider generates middleware configurations that reference middleware components
2. **Shared Context**: Both need access to same GCP project, region, metadata server
3. **Token Lifecycle**: Provider creates middleware instances with token fetching logic
4. **Deployment Simplicity**: Single plugin installation instead of coordinating two separate plugins
5. **Existing Pattern**: cmd/generate-routes/main.go already does both in one binary

**Package Structure**:
```
github.com/your-org/traefik-cloudrun-provider
├── provider/    - Implements Traefik Provider interface
├── middleware/  - Implements token injection middleware
└── internal/    - Shared GCP SDK wrappers, token cache
```

## Implementation Plan

### Phase 1: Core Provider (Polling)

**Goal**: Replace entrypoint.sh with working provider that polls Cloud Run

#### 1.1 Provider Interface Implementation
```go
// provider/provider.go
type CloudRunProvider struct {
    projectID    string
    region       string
    pollInterval time.Duration
    runClient    *run.APIService
    tokenManager *internal.TokenManager
}

// Implement Traefik Provider interface
func (p *CloudRunProvider) Init() error
func (p *CloudRunProvider) Provide(configChan chan<- dynamic.Message) error
func (p *CloudRunProvider) Stop() error
```

**Key Methods**:
- `Init()`: Initialize Cloud Run API client, verify permissions
- `Provide()`: Start polling loop, send config updates to Traefik
- `Stop()`: Clean shutdown

#### 1.2 Service Discovery
```go
// provider/discovery.go
func (p *CloudRunProvider) listServices() ([]CloudRunService, error)
func (p *CloudRunProvider) getServiceDetails(name string) (*run.Service, error)
func (p *CloudRunProvider) filterEnabledServices(services) []CloudRunService
```

**Logic** (from cmd/generate-routes/main.go:237-275):
- List services in project/region
- Filter for `traefik_enable=true` label
- Paginate through results
- Extract service URL, labels, metadata

#### 1.3 Label Parsing
```go
// provider/labels.go
func extractRouterConfigs(labels map[string]string) []RouterConfig
func extractServiceConfigs(labels map[string]string) []ServiceConfig
func extractMiddlewareRefs(labels map[string]string) []string
func mapGCPLabelToTraefik(key string) string
```

**Label Mapping**:
```
GCP Label                                    → Traefik Config
traefik_http_routers_myapp_rule_id=myapp    → router.rule = PathPrefix(`/myapp`)
traefik_http_routers_myapp_priority=300     → router.priority = 300
traefik_http_routers_myapp_service=myapp    → router.service = "myapp"
traefik_http_services_myapp_lb_port=8080    → service.loadBalancer.servers[0].port = 8080
```

**Rule ID Mapping** (from generate-routes-from-labels.sh:42-56):
```bash
lab1          → PathPrefix(`/lab1`)
lab1-static   → Path(`/lab1/static/{path:.*}`)
lab1-c2       → PathPrefix(`/lab1/c2`)
```

#### 1.4 Configuration Generation
```go
// provider/config.go
func (p *CloudRunProvider) generateConfig(services []CloudRunService) *dynamic.Configuration
func createRouter(routerConfig RouterConfig, service CloudRunService) *dynamic.Router
func createService(serviceConfig ServiceConfig, service CloudRunService) *dynamic.Service
func createAuthMiddleware(service CloudRunService, token string) *dynamic.Middleware
```

**Output**: Traefik dynamic.Configuration with routers, services, and middlewares

### Phase 2: Token Management & Middleware

#### 2.1 Token Manager
```go
// internal/gcp/token_manager.go
type TokenManager struct {
    cache map[string]*CachedToken  // audience -> token
    mu    sync.RWMutex
}

type CachedToken struct {
    Token     string
    ExpiresAt time.Time
}

func (tm *TokenManager) GetToken(audience string) (string, error)
func (tm *TokenManager) fetchFromMetadata(audience string) (string, error)
func (tm *TokenManager) startRefreshLoop()
```

**Token Fetching** (from cmd/generate-routes/main.go:509-543):
```go
url := fmt.Sprintf(
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=%s",
    urlEncodedAudience,
)
req.Header.Set("Metadata-Flavor", "Google")
```

**Token Caching**:
- Key: Service URL (audience)
- Expiry: 1 hour (GCP default)
- Refresh: 5 minutes before expiry
- Error handling: Retry with exponential backoff

#### 2.2 Auth Middleware
```go
// middleware/auth.go
type ServiceAccountAuth struct {
    tokenManager *internal.TokenManager
    audience     string
}

func New(tokenManager *internal.TokenManager, audience string) *ServiceAccountAuth
func (m *ServiceAccountAuth) ServeHTTP(rw http.ResponseWriter, req *http.Request, next http.HandlerFunc)
```

**Middleware Logic**:
1. Fetch token from manager (cached or fresh)
2. Inject `Authorization: Bearer {token}` header
3. Call next handler
4. Handle token fetch failures (503 Service Unavailable)

**Integration with Provider**:
```go
// In provider/config.go
authMiddleware := &dynamic.Middleware{
    Headers: &dynamic.Headers{
        CustomRequestHeaders: map[string]string{
            "Authorization": fmt.Sprintf("Bearer %s", token),
        },
    },
}
config.HTTP.Middlewares[fmt.Sprintf("auth-%s", serviceName)] = authMiddleware
```

### Phase 3: Polling Loop & Change Detection

#### 3.1 Polling Engine
```go
// provider/provider.go
func (p *CloudRunProvider) startPolling(configChan chan<- dynamic.Message) {
    ticker := time.NewTicker(p.pollInterval)
    defer ticker.Stop()

    var lastConfig *dynamic.Configuration

    for {
        select {
        case <-ticker.C:
            services, err := p.listServices()
            if err != nil {
                log.Error(err)
                continue
            }

            newConfig := p.generateConfig(services)

            if !configEqual(lastConfig, newConfig) {
                configChan <- dynamic.Message{
                    ProviderName: "cloudrun",
                    Configuration: newConfig,
                }
                lastConfig = newConfig
            }
        case <-p.stopChan:
            return
        }
    }
}
```

**Change Detection**:
- Compare new config with last sent config
- Only send update if configuration changed
- Detect: new services, removed services, label changes
- Log changes at INFO level

### Phase 4: Error Handling & Resilience

#### 4.1 Error Scenarios

1. **Cloud Run API Failures**
   - Network errors: Retry with exponential backoff
   - Permission errors: Log error, continue with last known config
   - Service not found: Remove from config

2. **Token Fetch Failures**
   - Metadata server unavailable: Use cached token if available
   - Invalid audience: Log error, skip middleware injection
   - Expired token: Fetch new token immediately

3. **Configuration Errors**
   - Invalid labels: Log warning, skip malformed router
   - Missing required labels: Use sensible defaults
   - Conflicting router names: Append service name suffix

#### 4.2 Health Checks
```go
// provider/health.go
type Health struct {
    LastSuccessfulPoll time.Time
    LastError          error
    ServicesDiscovered int
    TokensCached       int
}

func (p *CloudRunProvider) HealthCheck() Health
```

**Metrics** (future):
- Poll success/failure rate
- Config update frequency
- Token refresh success rate
- Average token fetch latency

### Phase 5: Eventarc Support (Future)

**Goal**: Replace polling with event-driven updates

#### 5.1 Permission Detection
```go
// provider/permissions.go
func (p *CloudRunProvider) detectPermissions() Permissions
func (p *CloudRunProvider) canUseEventarc() bool
```

**Check for**:
- `pubsub.subscriptions.consume`
- Eventarc topic configuration
- Pub/Sub subscription exists

#### 5.2 Event Listener
```go
// provider/eventarc.go
func (p *CloudRunProvider) subscribeToEvents(configChan chan<- dynamic.Message)
func (p *CloudRunProvider) handleServiceEvent(event CloudRunEvent)
```

**Events**:
- `google.cloud.run.service.v1.created`
- `google.cloud.run.service.v1.updated`
- `google.cloud.run.service.v1.deleted`

**Hybrid Mode**:
- Use Eventarc for real-time updates when available
- Fall back to polling if Eventarc not configured
- Still poll occasionally to catch missed events

## Configuration Schema

### Traefik Static Config
```yaml
providers:
  cloudrun:
    # Required: GCP project and region
    projectID: "my-gcp-project"
    region: "us-central1"

    # Optional: Polling interval (default: 30s)
    pollInterval: 30s

    # Optional: Token cache settings
    tokenCache:
      refreshBeforeExpiry: 5m  # Refresh 5 min before expiry

    # Optional: Eventarc (future)
    eventarc:
      enabled: false
      topic: "projects/my-project/topics/cloudrun-changes"
      subscription: "traefik-updates"
```

### Cloud Run Service Labels
```yaml
# Enable Traefik routing for this service
traefik_enable: "true"

# Router: lab1-api
traefik_http_routers_lab1-api_rule_id: "lab1-api"
traefik_http_routers_lab1-api_priority: "300"
traefik_http_routers_lab1-api_entrypoints: "web"
traefik_http_routers_lab1-api_middlewares: "auth-lab1-file"
traefik_http_routers_lab1-api_service: "lab1"

# Service: lab1
traefik_http_services_lab1_lb_port: "8080"
```

## Migration Path

### Step 1: Parallel Deployment
- Deploy provider alongside existing entrypoint.sh
- Provider writes to different file: `routes-new.yml`
- Compare outputs to verify correctness
- No traffic impact

### Step 2: Validation
- Verify all services discovered
- Check all routes generated correctly
- Confirm tokens injected properly
- Test service-to-service auth

### Step 3: Cutover
- Switch Traefik to use provider instead of file
- Remove entrypoint.sh route generation code
- Keep entrypoint.sh for other initialization (if needed)
- Monitor for issues

### Step 4: Cleanup
- Remove generate-routes-from-labels.sh
- Remove cmd/generate-routes/ directory
- Update documentation
- Simplify Dockerfile

## Testing Strategy

### Unit Tests
```
provider/
├── discovery_test.go   - Mock Cloud Run API responses
├── labels_test.go      - Test label parsing edge cases
├── config_test.go      - Test config generation
└── provider_test.go    - Test provider lifecycle

middleware/
├── auth_test.go        - Test header injection
└── token_test.go       - Mock metadata server

internal/gcp/
└── token_manager_test.go - Test caching, refresh
```

### Integration Tests
```
tests/integration/
├── cloudrun_test.go    - Test against real Cloud Run (test project)
├── traefik_test.go     - Test with Traefik instance
└── e2e_test.go         - Full flow: service → routing → auth
```

**Test Scenarios**:
1. Service with traefik labels appears → Route created
2. Service removed → Route removed
3. Service labels updated → Route updated
4. Token expires → Token refreshed
5. Metadata server unavailable → Use cached token
6. Multiple routers per service → All routers created
7. Conflicting router names → Error logged, skip

## Security Considerations

### Permissions
**Required**:
- `run.services.list` - List services in project/region
- `run.services.get` - Get service details and labels

**Optional** (for Eventarc):
- `pubsub.subscriptions.consume` - Receive event notifications

**Implicit** (via metadata server):
- `iam.serviceAccounts.actAs` - Generate identity tokens

### Token Handling
- Tokens fetched from GCP metadata server (trusted source)
- Tokens cached in memory (not persisted to disk)
- Tokens specific to service audience (least privilege)
- Tokens expire after 1 hour (GCP default)
- No token logging (sensitive data)

### Label Validation
- Sanitize label values before parsing
- Validate rule IDs match expected patterns
- Prevent injection via malicious labels
- Limit router/service name lengths

## Performance Considerations

### Polling Frequency
- Default: 30 seconds
- Trade-off: Freshness vs API quota usage
- Cloud Run Admin API quota: 1000 requests/100s
- With 30s polling: 200 requests/100s (well within quota)

### Token Caching
- Avoid fetching token on every request
- Cache by audience (service URL)
- Memory usage: ~500 bytes per cached token
- 100 services = ~50 KB memory

### Config Generation
- Generate config only when services change
- Diff detection prevents unnecessary Traefik reloads
- O(n) complexity for n services

### Concurrency
- Single polling goroutine
- Token manager with concurrent access (sync.RWMutex)
- Middleware instances can run concurrently

## Open Questions

1. **Provider Plugin vs External Binary**
   - Start as external binary, package as plugin later?
   - Traefik plugin API limitations for Cloud Run SDK?

2. **Token Scope**
   - One token per service (current approach)
   - Or one token for Traefik, use for all services?

3. **Middleware Naming**
   - Auto-generate: `auth-{service-name}`
   - Or allow custom names via labels?

4. **Error Recovery**
   - How long to retry after Cloud Run API failure?
   - Should provider stop after N consecutive failures?

5. **Multi-region Support**
   - Single provider instance per region?
   - Or one provider managing multiple regions?

## Success Metrics

- [ ] Provider discovers all Cloud Run services with traefik labels
- [ ] Routes generated match entrypoint.sh output
- [ ] Service-to-service auth works (tokens injected correctly)
- [ ] Dynamic updates work (route appears within poll interval)
- [ ] No restarts needed for route changes
- [ ] Token refresh works before expiry
- [ ] Graceful degradation on API failures
- [ ] Performance: <100ms config generation for 50 services

## References

### Existing Code to Refactor
- `deploy/traefik/cmd/generate-routes/main.go` - Core logic to extract
- `deploy/traefik/generate-routes-from-labels.sh` - Legacy approach
- `deploy/traefik/entrypoint.sh` - To be simplified

### Traefik Documentation
- [Provider Plugins](https://doc.traefik.io/traefik/plugins/providers/)
- [Middleware Plugins](https://doc.traefik.io/traefik/plugins/middleware/)
- [Dynamic Configuration](https://doc.traefik.io/traefik/providers/overview/)

### GCP Documentation
- [Cloud Run Admin API](https://cloud.google.com/run/docs/reference/rest)
- [Service Account Identity Tokens](https://cloud.google.com/run/docs/securing/service-identity)
- [Metadata Server](https://cloud.google.com/compute/docs/metadata/overview)

### Similar Projects
- [traefik-proxmox-provider](https://github.com/molleer/traefik-proxmox-provider) - Reference architecture
- [Traefik Plugin Demo](https://github.com/traefik/pluginproviderdemo) - Official example


### Resources
- [Traefik Plugin Provider API](https://doc.traefik.io/traefik/plugins/providers/)
- [Traefik Middleware Provider API](https://doc.traefik.io/traefik/plugins/middleware/)
- [Traefik Plugin Provider Demo](https://plugins.traefik.io/create)
- [GCP Service-to-Service Authentication](https://docs.cloud.google.com/run/docs/authenticating/service-to-service)
- [GCP Metadata Server](https://cloud.google.com/compute/docs/metadata/overview)
