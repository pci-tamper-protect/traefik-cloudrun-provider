# Migration Guide: From entrypoint.sh to traefik-cloudrun-provider

This guide explains how to migrate from the complex shell script approach to the new provider plugin.

## Current Architecture (entrypoint.sh)

```
┌─────────────────────────────────────┐
│  Traefik Container Startup          │
│                                     │
│  1. entrypoint.sh runs              │
│  2. Calls generate-routes-*.sh      │
│  3. Generates /etc/traefik/dynamic/ │
│     routes.yml (one-time)           │
│  4. Starts Traefik                  │
│                                     │
│  ❌ No dynamic updates               │
│  ❌ Restart required for changes     │
│  ❌ Complex bash scripting           │
└─────────────────────────────────────┘
```

## New Architecture (traefik-cloudrun-provider)

```
┌──────────────────────────────────────┐
│  Traefik with Cloud Run Provider    │
│                                      │
│  1. Traefik starts                   │
│  2. Provider polls Cloud Run API     │
│  3. Generates config dynamically     │
│  4. Updates routes automatically     │
│                                      │
│  ✅ Dynamic updates (no restart)      │
│  ✅ Clean Go code                     │
│  ✅ Proper error handling             │
└──────────────────────────────────────┘
```

## Migration Steps

### Phase 1: Parallel Deployment (Validation)

Deploy the provider alongside the existing entrypoint.sh to validate output without impacting production.

1. **Add provider binary to Traefik container**

```dockerfile
# In deploy/traefik/Dockerfile.cloudrun
FROM traefik:v2.10

# Install provider binary
COPY --from=builder /app/bin/traefik-cloudrun-provider /usr/local/bin/

# Keep existing entrypoint.sh for now (parallel run)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

2. **Run provider in parallel** (modify entrypoint.sh)

```bash
# In entrypoint.sh, before starting Traefik:

# Run old generator (existing)
./generate-routes-from-labels.sh > /etc/traefik/dynamic/routes.yml

# Run new provider (parallel)
/usr/local/bin/traefik-cloudrun-provider /etc/traefik/dynamic/routes-new.yml

# Compare outputs
if diff /etc/traefik/dynamic/routes.yml /etc/traefik/dynamic/routes-new.yml; then
  echo "✅ Provider output matches legacy generator"
else
  echo "⚠️  Provider output differs - review before cutover"
  diff /etc/traefik/dynamic/routes.yml /etc/traefik/dynamic/routes-new.yml
fi
```

3. **Deploy and validate**

```bash
cd deploy
./deploy-all-stg.sh
```

Check logs:
```bash
gcloud run services logs read traefik-stg --region=us-central1
```

### Phase 2: Cut Over to Provider

Once validated, switch Traefik to use the provider instead of shell scripts.

1. **Update Traefik configuration** (traefik.cloudrun.yml)

Remove file provider watching (if using continuous mode):
```yaml
# Before
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

# After (if using provider plugin integration - TBD)
providers:
  cloudrun:
    projectIDs:
      - labs-stg
      - labs-home-stg
    region: us-central1
    pollInterval: 30s
```

OR keep file provider for one-shot generation:
```yaml
# Keep file provider
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: false  # Provider generates once at startup
```

2. **Simplify entrypoint.sh**

```bash
#!/bin/sh
set -e

echo "🚀 Starting Traefik Cloud Run Provider..."

# Generate routes using provider
/usr/local/bin/traefik-cloudrun-provider /etc/traefik/dynamic/routes.yml

# Start Traefik
exec traefik "$@"
```

3. **Deploy updated configuration**

```bash
cd deploy
./deploy-all-stg.sh
```

### Phase 3: Cleanup

Remove legacy shell scripts once provider is stable.

1. **Remove files**

```bash
rm deploy/traefik/generate-routes-from-labels.sh
rm deploy/traefik/cmd/generate-routes/main.go
rm deploy/traefik/refresh-routes.sh
```

2. **Simplify Dockerfile**

```dockerfile
FROM golang:1.21 AS builder
WORKDIR /app
COPY traefik-cloudrun-provider/ ./
RUN go build -o bin/traefik-cloudrun-provider ./cmd/provider

FROM traefik:v2.10
COPY --from=builder /app/bin/traefik-cloudrun-provider /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
COPY dynamic/ /etc/traefik/dynamic/
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

3. **Update documentation**

Update README.md to reference provider instead of shell scripts.

## Comparison: Before vs After

### File Changes

**Before:**
```
deploy/traefik/
├── entrypoint.sh (300+ lines)
├── generate-routes-from-labels.sh (636 lines)
├── cmd/generate-routes/main.go (569 lines)
└── refresh-routes.sh
```

**After:**
```
traefik-cloudrun-provider/
├── provider/
│   ├── provider.go (200 lines)
│   ├── discovery.go (70 lines)
│   ├── labels.go (150 lines)
│   └── config.go (80 lines)
├── internal/gcp/
│   └── token_manager.go (120 lines)
└── cmd/provider/main.go (170 lines)

deploy/traefik/
├── entrypoint.sh (10 lines)
└── dynamic/routes.yml (middlewares only)
```

### Routes Generation

**Before:**
```bash
# Manual refresh required
./refresh-routes.sh

# Or container restart
gcloud run services update traefik-stg --image=...
```

**After:**
```bash
# Automatic (polls every 30s)
# Or deploy new service with traefik labels:
gcloud run services update my-service \
  --update-labels="traefik_enable=true,..."
```

### Debugging

**Before:**
```bash
# SSH into container to debug
gcloud run services exec traefik-stg -- /bin/sh
cat /etc/traefik/dynamic/routes.yml
```

**After:**
```bash
# View provider logs
gcloud run services logs read traefik-stg --region=us-central1 | grep "CloudRun Provider"

# Check Traefik API for current routes
curl https://stg.labs.pcioasis.com/api/http/routers
```

## Troubleshooting

### Provider generates different routes than shell script

**Check:**
1. Label format differences (underscores vs dashes)
2. Middleware references (@file suffix)
3. Rule ID mappings

**Debug:**
```bash
# Compare YAML outputs
diff <(./generate-routes-from-labels.sh) <(/usr/local/bin/traefik-cloudrun-provider -)
```

### Tokens not being injected

**Check:**
1. Metadata server accessible from Traefik container
2. Service account has required permissions
3. Token cache not stale

**Debug:**
```bash
# Test metadata server access
curl -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=https://my-service-xyz.run.app"
```

### Routes not updating

**If using continuous polling:**
- Check poll interval (default 30s)
- Verify provider is running
- Check for API quota limits

**If using one-shot generation:**
- Restart Traefik container to regenerate routes

## Rollback Plan

If issues arise, rollback to shell scripts:

1. **Revert entrypoint.sh**
```bash
git checkout HEAD~1 deploy/traefik/entrypoint.sh
```

2. **Redeploy**
```bash
./deploy-all-stg.sh
```

3. **Verify**
```bash
gcloud run services describe traefik-stg --region=us-central1
```

## Future Enhancements

Once provider is stable, consider:

1. **Event-driven updates** - Replace polling with Eventarc
2. **Multiple regions** - Support multi-region deployments
3. **Metrics** - Add Prometheus metrics for monitoring
4. **Traefik Plugin** - Package as official Traefik plugin

## Questions?

See [DESIGN.md](DESIGN.md) for architecture details or [README.md](README.md) for usage examples.
