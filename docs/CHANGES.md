# Recent Changes: Header Debugging & Validation

## Summary

Enhanced the project with comprehensive header debugging and validation tools to diagnose why `X-Serverless-Authorization` headers may not be reaching Cloud Run services in production.

## Changes Made

### 1. Enhanced Test Backend (`tests/e2e/backend/main.go`)

**Added:**
- `/debug/headers` endpoint - Returns all received headers as JSON
- Header logging in `/api/hello` endpoint
- Specific logging for auth headers with warnings when missing

**What it does:**
```bash
curl http://api.localhost/debug/headers
# Returns:
{
  "headers": {
    "X-Serverless-Authorization": ["Bearer eyJ..."],
    "User-Agent": ["curl/7.84.0"],
    ...
  },
  "path": "/debug/headers",
  "method": "GET"
}
```

**Logs:**
```
Backend: All headers received:
  Accept: */*
  User-Agent: curl/7.84.0
  X-Serverless-Authorization: Bearer eyJ...
Backend: X-Serverless-Authorization header present (length: 842)
```

Or warning:
```
Backend: ⚠️  X-Serverless-Authorization header NOT present
```

### 2. Enhanced E2E Tests (`test-e2e.sh`)

**Added:**
- **Test 7**: Validates middleware configuration via Traefik API
- **Test 8**: Verifies headers actually reach the backend service
- Backend header inspection in test output

**Now validates:**
- ✅ Middlewares are configured in Traefik
- ✅ Custom headers are set in middleware config
- ✅ Headers actually propagate to backend service
- ✅ Backend logs show received headers

### 3. New Debug Script (`debug-headers.sh`)

**Usage:**
```bash
./debug-headers.sh https://your-traefik.example.com:8081
```

**Checks:**
1. Traefik API accessibility
2. Configured routers (with counts)
3. Configured middlewares (with counts)
4. Auth-specific middlewares (filters for `-auth` suffix)
5. Middleware header configuration details
6. X-Serverless-Authorization header presence
7. Router-middleware associations
8. Provider sources

**Output example:**
```
✓ Traefik API is accessible
✓ Found 5 routers
✓ Found 3 middlewares
✓ Found authentication middlewares:
  - my-service-auth@file
✓ Custom request headers configured
✓ X-Serverless-Authorization header is configured
  Token preview: Bearer eyJhbGciOi...
```

### 4. Enhanced Logging (`plugin/plugin.go`)

**Added:**
- Middleware conversion logging
- Auth middleware detection and logging
- Token information in logs (length, preview)

**Logs you'll see:**
```
[CloudRunPlugin] Converting middlewares to Traefik format count=3
[CloudRunPlugin] ✅ Auth middleware converted name=my-service-auth headerCount=1
```

### 5. Enhanced Config Builder (`provider/config.go`)

**Added:**
- Detailed logging when creating auth middlewares
- Token preview in logs (first 10 chars)
- Warning when middleware created without token

**Logs you'll see:**
```
[ConfigBuilder] ✅ Created auth middleware 'my-service-auth' with X-Serverless-Authorization header (token length: 842, preview: eyJhbGciOi...)
```

Or warning:
```
[ConfigBuilder] ⚠️  Created auth middleware 'my-service-auth' WITHOUT token (will not set X-Serverless-Authorization header)
```

### 6. Documentation (`docs/DEBUGGING_HEADERS.md`)

Comprehensive debugging guide covering:
- Quick start for local and production debugging
- What to look for in logs and dashboards
- Common issues and solutions
- Step-by-step troubleshooting
- Backend debugging examples

## What Was NOT Working Before

### The Tests Were Lying! 🔴

**Before these changes:**
- ✅ Tests checked services were reachable
- ✅ Tests checked HTTP responses
- ✅ Tests checked Traefik configuration loaded
- ❌ Tests **never checked if headers were set**
- ❌ Tests **never validated middleware configuration**
- ❌ Backend **never logged received headers**

The tests appeared to pass, but gave no indication whether headers were actually being propagated.

### No Production Debugging Tools

**Before:**
- No way to see if middlewares were configured
- No way to check if headers reached backend
- No visibility into token generation
- Hard to diagnose production issues

## How to Use These Changes

### 1. Local Development

```bash
# Run enhanced e2e tests
./test-e2e.sh

# Watch backend logs for header validation
docker-compose -f docker-compose.e2e.yml logs -f backend | grep -E "(Authorization|header)"
```

**Look for:**
```
Backend: X-Serverless-Authorization header present (length: 842)
```

### 2. Production Debugging

```bash
# Run debug script against your labs-stg deployment
./debug-headers.sh https://your-traefik-labs-stg.com:8081
```

**Check the output for:**
- ✅ Number of middlewares (should be > 0)
- ✅ Auth middlewares exist
- ✅ X-Serverless-Authorization configured
- ⚠️ Any warnings about missing config

### 3. Check Provider Logs

```bash
# Docker deployment
docker logs <provider-container> 2>&1 | grep -E "ConfigBuilder|middleware|token"

# Cloud Run deployment
gcloud run logs read <traefik-service> \
  --project=<project-id> \
  --format="table(timestamp, textPayload)" | \
  grep -E "ConfigBuilder|middleware|token"
```

**Look for:**
```
[ConfigBuilder] ✅ Created auth middleware 'my-service-auth' with X-Serverless-Authorization header
```

**Red flags:**
```
[ConfigBuilder] ⚠️  Created auth middleware 'my-service-auth' WITHOUT token
```

### 4. Add Debug Endpoint to Your Backend

If your production backend doesn't have a debug endpoint, add one:

```go
http.HandleFunc("/debug/headers", func(w http.ResponseWriter, r *http.Request) {
    headers := make(map[string][]string)
    for name, values := range r.Header {
        headers[name] = values
    }
    json.NewEncoder(w).Encode(map[string]interface{}{
        "headers": headers,
    })
})
```

Then test:
```bash
curl https://your-service.run.app/debug/headers
```

## Common Issues to Check

Based on the enhanced logging, check for these issues:

### Issue 1: No Middlewares Generated
```
✗ No middlewares found
⚠️  PROBLEM IDENTIFIED: No middlewares configured!
```

**Causes:**
- Token generation failing
- Services not labeled with `traefik_enable=true`
- Plugin not loaded by Traefik

**Check:**
```bash
# Provider logs
grep "Failed to fetch identity token" <provider-logs>

# Service labels
gcloud run services describe <service> --region=<region> --format="value(metadata.labels)"
```

### Issue 2: Token Generation Failing
```
[ConfigBuilder] ⚠️  Created auth middleware 'my-service-auth' WITHOUT token
```

**Causes:**
- Not running in Cloud Run/GCE (no metadata server)
- Missing IAM permissions
- `CLOUDRUN_PROVIDER_DEV_MODE` not set for local testing

**Solutions:**
```bash
# Local: Enable dev mode
export CLOUDRUN_PROVIDER_DEV_MODE=true

# Production: Check IAM
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:traefik-sa@project.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

### Issue 3: Headers Not Reaching Backend
```
Backend: ⚠️  X-Serverless-Authorization header NOT present
```

**Check:**
1. Traefik dashboard shows middleware configured
2. Router lists the middleware
3. No other middleware removing headers
4. Traefik version compatibility (v2.10+)

## Next Steps for Your labs-stg Deployment

1. **Run the debug script** against your labs-stg Traefik:
   ```bash
   ./debug-headers.sh https://your-traefik-labs-stg.com:8081
   ```

2. **Check provider logs** for middleware creation:
   ```bash
   gcloud run logs read traefik-service \
     --project=labs-project-stg \
     --format="table(timestamp, textPayload)" | \
     grep "ConfigBuilder"
   ```

3. **Add debug endpoint** to your backend service (temporary):
   - Deploy with `/debug/headers` endpoint
   - Test: `curl https://your-backend.run.app/debug/headers`
   - Check if `X-Serverless-Authorization` is present

4. **Compare with local test**:
   ```bash
   ./test-e2e.sh
   # Check if Test 8 passes locally
   ```

5. **Check differences**:
   - Local vs production Traefik config
   - Local vs production plugin config
   - Service labels in Cloud Run

## Files Modified

- `tests/e2e/backend/main.go` - Added header debugging
- `test-e2e.sh` - Added header validation tests
- `plugin/plugin.go` - Enhanced middleware logging
- `provider/config.go` - Enhanced auth middleware logging

## Files Created

- `debug-headers.sh` - Production debugging script
- `docs/DEBUGGING_HEADERS.md` - Comprehensive debugging guide
- `docs/CHANGES.md` - This file

## Plugin Folder Question

**Q: Should `plugin/` be committed?**

**A: YES!** The `plugin/` folder contains the Traefik plugin interface (`plugin/plugin.go`) that's essential for running as a Traefik plugin. It's not in `.gitignore` and is a core part of the codebase.

You're using Traefik's [local plugin mode](https://plugins.traefik.io/create) for development, which means:
- ✅ `plugin/` folder is required
- ✅ Should be committed to git
- ✅ Used in local mode during development
- ✅ Will be published later when stable

The folder structure follows Traefik's plugin requirements:
```
plugin/
  └── plugin.go  # Plugin interface implementation
```
