# Next Steps

The traefik-cloudrun-provider is now scaffolded and ready for testing/deployment. Here's what to do next:

## ✅ Completed

- [x] Architecture design (see DESIGN.md)
- [x] Repository structure created
- [x] Core provider logic extracted from cmd/generate-routes/main.go
- [x] Token manager with caching implemented
- [x] Service discovery logic
- [x] Label parsing and routing config generation
- [x] Command-line tool for one-shot generation
- [x] Unit tests for token manager
- [x] Migration guide (see MIGRATION.md)
- [x] Example configurations

## 🚧 Next: Integration Testing

### 1. Test Locally Against Real Cloud Run

Test the provider against your actual staging environment:

```bash
cd /Users/kestenbroughton/projectos/traefik-cloudrun-provider

# Set environment variables
export ENVIRONMENT=stg
export LABS_PROJECT_ID=labs-stg
export HOME_PROJECT_ID=labs-home-stg
export REGION=us-central1

# Authenticate with GCP
gcloud auth application-default login

# Generate routes.yml
./bin/traefik-cloudrun-provider /tmp/routes-test.yml

# Compare with existing generator
cd /Users/kestenbroughton/projectos/e-skimming-labs/deploy/traefik
go run ./cmd/generate-routes/main.go /tmp/routes-old.yml

# Diff the outputs
diff /tmp/routes-old.yml /tmp/routes-test.yml
```

**Expected:** Outputs should be identical (or explain differences).

### 2. Integrate into e-skimming-labs

Add the provider as a Git submodule or copy into deploy/traefik:

```bash
cd /Users/kestenbroughton/projectos/e-skimming-labs

# Option A: Git submodule (recommended)
git submodule add https://github.com/kestenbroughton/traefik-cloudrun-provider deploy/traefik/cloudrun-provider

# Option B: Direct copy (for testing)
cp -r ../traefik-cloudrun-provider deploy/traefik/cloudrun-provider
```

### 3. Update Dockerfile

Modify `deploy/traefik/Dockerfile.cloudrun` to build and use the provider:

```dockerfile
FROM golang:1.21 AS builder
WORKDIR /app

# Build provider
COPY cloudrun-provider/ ./
RUN go build -o bin/traefik-cloudrun-provider ./cmd/provider

FROM traefik:v2.10

# Copy provider binary
COPY --from=builder /app/bin/traefik-cloudrun-provider /usr/local/bin/

# Keep existing entrypoint for now (parallel deployment)
COPY entrypoint.sh /entrypoint.sh
COPY dynamic/ /etc/traefik/dynamic/
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

### 4. Update entrypoint.sh (Parallel Deployment)

Test provider alongside existing generator:

```bash
#!/bin/sh
set -e

echo "🚀 Generating routes with new provider..."
/usr/local/bin/traefik-cloudrun-provider /etc/traefik/dynamic/routes-new.yml

echo "🔧 Generating routes with legacy generator..."
./generate-routes-from-labels.sh > /etc/traefik/dynamic/routes-old.yml

echo "📊 Comparing outputs..."
if diff /etc/traefik/dynamic/routes-old.yml /etc/traefik/dynamic/routes-new.yml; then
  echo "✅ Provider output matches! Using new provider."
  mv /etc/traefik/dynamic/routes-new.yml /etc/traefik/dynamic/routes.yml
else
  echo "⚠️  Outputs differ - using legacy for safety"
  mv /etc/traefik/dynamic/routes-old.yml /etc/traefik/dynamic/routes.yml
  echo "Diff:"
  diff /etc/traefik/dynamic/routes-old.yml /etc/traefik/dynamic/routes-new.yml || true
fi

# Start Traefik
exec traefik "$@"
```

### 5. Deploy to Staging

```bash
cd /Users/kestenbroughton/projectos/e-skimming-labs/deploy
./deploy-all-stg.sh
```

### 6. Verify Deployment

Check logs for comparison results:

```bash
gcloud run services logs read traefik-stg --region=us-central1 --limit=100
```

Expected logs:
```
🚀 Generating routes with new provider...
🔧 Generating routes with legacy generator...
📊 Comparing outputs...
✅ Provider output matches! Using new provider.
```

### 7. Monitor Service

After deployment, verify routing works:

```bash
# Test home page
curl https://stg.labs.pcioasis.com/

# Test lab1
curl https://stg.labs.pcioasis.com/lab1/

# Test lab1-c2
curl https://stg.labs.pcioasis.com/lab1/c2/

# Check Traefik API
curl https://stg.labs.pcioasis.com/api/http/routers
```

## 🔄 Next: Full Migration (After Validation)

Once parallel deployment shows identical output:

### 1. Simplify entrypoint.sh

Remove legacy generator:

```bash
#!/bin/sh
set -e

echo "🚀 Starting Traefik Cloud Run Provider..."

# Generate routes
/usr/local/bin/traefik-cloudrun-provider /etc/traefik/dynamic/routes.yml

# Start Traefik
exec traefik "$@"
```

### 2. Clean Up Legacy Code

```bash
cd /Users/kestenbroughton/projectos/e-skimming-labs

# Remove shell scripts
rm deploy/traefik/generate-routes-from-labels.sh
rm deploy/traefik/refresh-routes.sh

# Remove old Go generator
rm -rf deploy/traefik/cmd/generate-routes

# Commit changes
git add deploy/traefik
git commit -m "Migrate to traefik-cloudrun-provider"
```

### 3. Update Documentation

Update deployment docs to reference provider instead of shell scripts.

## 🚀 Future: Continuous Polling Mode

Once one-shot generation is stable, enable continuous polling:

### 1. Create Traefik Plugin Package

Package provider as Traefik plugin (requires Traefik plugin architecture).

### 2. Configure for Polling

Update traefik.cloudrun.yml:

```yaml
providers:
  cloudrun:
    projectIDs:
      - labs-stg
      - labs-home-stg
    region: us-central1
    pollInterval: 30s
```

### 3. Remove entrypoint.sh

With native plugin, no startup script needed - Traefik handles everything.

## 🎯 Future: Eventarc Integration

For real-time updates without polling:

### 1. Create Pub/Sub Topic

```bash
gcloud pubsub topics create cloudrun-changes --project=labs-stg
```

### 2. Configure Eventarc

```bash
gcloud eventarc triggers create cloudrun-service-updates \
  --location=us-central1 \
  --destination-run-service=traefik-stg \
  --event-filters="type=google.cloud.run.service.v1.created" \
  --event-filters="type=google.cloud.run.service.v1.updated" \
  --event-filters="type=google.cloud.run.service.v1.deleted"
```

### 3. Update Provider

Add Eventarc support to provider/provider.go:

```go
func (p *Provider) subscribeToEvents() {
  // Listen for Pub/Sub messages
  // Trigger config updates on events
}
```

## 📝 Testing Checklist

Before considering migration complete:

- [ ] Provider generates identical routes.yml to legacy generator
- [ ] All lab routes work correctly
- [ ] Service-to-service auth works (tokens injected)
- [ ] Traefik dashboard accessible
- [ ] No errors in Traefik logs
- [ ] No errors in Cloud Run logs
- [ ] Performance is acceptable (startup time, CPU, memory)
- [ ] Token refresh works (check after 55 minutes)
- [ ] Handles API failures gracefully
- [ ] Works with new service deployments

## 🐛 Known Issues / TODOs

1. **Provider doesn't detect config changes yet** - Only generates once at startup. Need polling loop or Eventarc.
2. **No middleware plugin** - Auth tokens injected via headers middleware. Future: separate middleware plugin.
3. **No health checks** - Add `/health` endpoint for provider.
4. **No metrics** - Add Prometheus metrics for monitoring.
5. **Hard-coded rule mappings** - ruleMap in labels.go is specific to e-skimming-labs. Make configurable.

## 📚 Reference

- [DESIGN.md](DESIGN.md) - Full architecture documentation
- [MIGRATION.md](MIGRATION.md) - Detailed migration guide
- [README.md](README.md) - Usage and features

## ❓ Questions

- Should provider be a separate binary or integrated into Traefik container?
- Polling interval: 30s good, or too frequent for Cloud Run Admin API?
- Keep file provider for static middlewares, or move those to provider too?
- Git submodule vs copy for deployment?
