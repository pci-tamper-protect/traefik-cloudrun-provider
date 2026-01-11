# Debugging Header Propagation

This guide helps you debug why the `X-Serverless-Authorization` header might not be reaching your Cloud Run services in production.

## Quick Start

### 1. Run the E2E Tests (Local)

The enhanced e2e tests now validate header propagation:

```bash
./test-e2e.sh
```

**New tests added:**
- **Test 7**: Checks if middlewares with custom headers are configured
- **Test 8**: Verifies headers actually reach the backend service

The backend service now logs all headers, so you'll see:
```
Backend: X-Serverless-Authorization header present (length: 842)
```

Or the warning:
```
Backend: ⚠️  X-Serverless-Authorization header NOT present
```

### 2. Debug Production Deployment

Use the new debug script to inspect your labs-stg deployment:

```bash
./debug-headers.sh https://your-traefik-url.com:8081
```

This script checks:
- ✅ Traefik API accessibility
- ✅ Configured routers
- ✅ Configured middlewares (especially auth middlewares)
- ✅ Middleware header configuration
- ✅ Router-middleware associations
- ✅ Provider sources

## What to Look For

### 1. In Provider Logs

With the enhanced logging, you should see:

```
[CloudRunPlugin] ✅ Plugin instantiated by Traefik - New() called
[CloudRunPlugin] 🔧 Initializing Cloud Run API client...
[CloudRunPlugin] ✅ Cloud Run API client initialized successfully
[CloudRunPlugin] 🔧 Initializing token manager...
[CloudRunPlugin] ✅ Token manager initialized (production mode - using metadata server)
```

When processing services:
```
[CloudRunProvider] 🔧 Processing service name=my-service
[CloudRunProvider] ✅ Successfully fetched identity token for service (tokenLength: 842)
[ConfigBuilder] ✅ Created auth middleware 'my-service-auth' with X-Serverless-Authorization header (token length: 842, preview: eyJhbGciOi...)
```

**Red flags:**
```
[CloudRunProvider] ❌ Failed to fetch identity token for service
[ConfigBuilder] ⚠️  Created auth middleware 'my-service-auth' WITHOUT token
```

### 2. In Traefik Dashboard

Access your Traefik dashboard at `http://your-traefik:8081/dashboard/`

Check **HTTP > Middlewares**:
- Should see middlewares with `-auth` suffix (e.g., `my-service-auth@file`)
- Click on the middleware to see details
- Should contain `customRequestHeaders` with `X-Serverless-Authorization`

Check **HTTP > Routers**:
- Your service routers should list the auth middleware
- Example: `my-service@file` router should have middleware `my-service-auth@file`

### 3. Using the Debug Script

```bash
./debug-headers.sh https://your-traefik.example.com:8081
```

**Good output:**
```
✓ Traefik API is accessible
✓ Found 5 routers
✓ Found 3 middlewares
✓ Found authentication middlewares:
  - my-service-auth@file
✓ Custom request headers configured
✓ X-Serverless-Authorization header is configured
  Token preview: Bearer eyJhbGciOiJSUzI1Ni...
```

**Problem output:**
```
✗ No middlewares found
⚠️  PROBLEM IDENTIFIED: No middlewares configured!

Likely causes:
  1. Provider plugin not running or not generating config
  2. Plugin not being loaded by Traefik
  3. Token generation failing (check provider logs)
```

## Common Issues and Solutions

### Issue 1: No Middlewares Generated

**Symptoms:**
- `./debug-headers.sh` shows 0 middlewares
- Traefik dashboard shows no custom middlewares
- Provider logs show token fetch failures

**Causes:**
1. **Token generation failing** - Check if running on Cloud Run/GCE with metadata server access
2. **Services not labeled** - Ensure Cloud Run services have `traefik_enable=true` label
3. **Plugin not loaded** - Check Traefik static config for plugin configuration

**Solutions:**

For local development:
```bash
export CLOUDRUN_PROVIDER_DEV_MODE=true
# Uses Application Default Credentials instead of metadata server
```

For production (Cloud Run):
```yaml
# Your Cloud Run service needs:
labels:
  traefik_enable: "true"
  traefik_http_routers_myservice_rule: "Host(`api.example.com`)"
```

Check provider logs:
```bash
# Docker deployment
docker logs <provider-container> 2>&1 | grep -E "(token|middleware|auth)"

# Cloud Run deployment
gcloud run logs read <traefik-service> --project=<project-id> | grep -E "(token|middleware|auth)"
```

### Issue 2: Middlewares Exist but Not Applied

**Symptoms:**
- Middlewares exist in Traefik dashboard
- But headers still not reaching backend
- Router configuration doesn't list the middleware

**Causes:**
1. Router not associated with middleware
2. Middleware order issues (unlikely with current implementation)
3. Traefik not reloading configuration

**Solutions:**

Check router configuration:
```bash
curl -s http://your-traefik:8081/api/http/routers/my-service@file | jq '.middlewares'
# Should show: ["my-service-auth@file", "retry-cold-start@file"]
```

Force Traefik reload:
- If using file provider: Wait for file watch interval
- If using plugin: Restart Traefik service

### Issue 3: Token Not Being Fetched

**Symptoms:**
```
[ConfigBuilder] ⚠️  Created auth middleware 'my-service-auth' WITHOUT token
```

**Causes:**
1. Not running in Cloud Run/GCE (no metadata server)
2. Service account lacks `roles/iam.serviceAccountTokenCreator`
3. Network issue reaching metadata server

**Solutions:**

For local testing:
```bash
# Set dev mode to use ADC
export CLOUDRUN_PROVIDER_DEV_MODE=true

# Ensure you're logged in
gcloud auth application-default login
```

For production Cloud Run:
```yaml
# In your Traefik Cloud Run service
spec:
  serviceAccountName: traefik-sa@project.iam.gserviceaccount.com
```

Ensure service account has permissions:
```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:traefik-sa@project.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

### Issue 4: Headers Stripped by Traefik

**Symptoms:**
- Middlewares configured correctly
- Headers visible in Traefik logs
- But not reaching backend

**Causes:**
1. Another middleware removing headers
2. Traefik version incompatibility
3. Header name conflicts

**Solutions:**

Check Traefik version:
```bash
curl -s http://your-traefik:8081/api/version | jq '.Version'
# Should be v2.10 or later
```

Test with backend debug endpoint:
```bash
# Using the enhanced backend with /debug/headers endpoint
curl -H "Host: api.localhost" http://localhost/debug/headers | jq '.headers'
```

Check for conflicting middlewares:
```bash
./debug-headers.sh https://your-traefik:8081 | grep -A5 "Router-Middleware"
```

## Testing Changes

After making configuration changes:

1. **Local Docker tests:**
   ```bash
   ./test-e2e.sh
   # Look for "Test 8: Header Propagation to Backend"
   ```

2. **Check backend logs:**
   ```bash
   docker-compose -f docker-compose.e2e.yml logs backend | grep -E "(Authorization|header)"
   ```

3. **Inspect generated config:**
   ```bash
   # If using file provider mode
   cat test-output/routes.yml | grep -A10 "middlewares:"
   ```

4. **Production deployment:**
   ```bash
   ./debug-headers.sh https://your-traefik.example.com:8081
   ```

## Adding Debug Logging to Your Backend

If your backend service doesn't have header debugging, add this:

```go
// Go example
http.HandleFunc("/debug/headers", func(w http.ResponseWriter, r *http.Request) {
    headers := make(map[string][]string)
    for name, values := range r.Header {
        headers[name] = values
        log.Printf("Header %s: %v", name, values)
    }
    json.NewEncoder(w).Encode(map[string]interface{}{
        "headers": headers,
    })
})
```

```python
# Python/Flask example
@app.route('/debug/headers')
def debug_headers():
    headers = dict(request.headers)
    app.logger.info(f"Received headers: {headers}")
    return jsonify({'headers': headers})
```

Then test:
```bash
curl https://your-service.run.app/debug/headers
```

## Next Steps

If headers still not working after debugging:

1. ✅ Verify all logs show middleware creation
2. ✅ Verify Traefik dashboard shows middlewares
3. ✅ Verify routers list the middleware
4. ✅ Test with `/debug/headers` endpoint
5. ✅ Check Cloud Run service IAM permissions
6. ✅ Verify network connectivity to metadata server
7. ✅ Check for Traefik version compatibility

For support, include output from:
- `./debug-headers.sh`
- Provider logs (showing middleware creation)
- Traefik dashboard screenshots
- Backend `/debug/headers` response
