# Quick Debug Reference Card

## TL;DR - Headers Not Working?

### 1️⃣ Run Debug Script (30 seconds)
```bash
./debug-headers.sh https://your-traefik:8081
```

**Look for:** `✗ No middlewares found` or `✗ X-Serverless-Authorization header NOT configured`

### 2️⃣ Check Provider Logs (1 minute)
```bash
# Docker
docker logs <container> 2>&1 | grep "ConfigBuilder"

# Cloud Run
gcloud run logs read <service> --project=<project> | grep "ConfigBuilder"
```

**Look for:**
- ✅ `Created auth middleware 'X' with X-Serverless-Authorization header`
- ❌ `Created auth middleware 'X' WITHOUT token`

### 3️⃣ Test Backend Headers (30 seconds)
Add this to your backend temporarily:
```go
http.HandleFunc("/debug/headers", func(w http.ResponseWriter, r *http.Request) {
    json.NewEncoder(w).Encode(r.Header)
})
```

Test: `curl https://your-service.run.app/debug/headers`

**Look for:** `"X-Serverless-Authorization": ["Bearer eyJ..."]`

---

## Common Problems & Quick Fixes

### Problem: "No middlewares found"

**Quick fix:**
```bash
# Local testing - set dev mode
export CLOUDRUN_PROVIDER_DEV_MODE=true

# Cloud Run - check IAM permissions
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:YOUR_SA@project.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

### Problem: "Token generation failing"

**Quick fix:**
```bash
# Local: Login to gcloud
gcloud auth application-default login

# Production: Check service account
gcloud run services describe YOUR_SERVICE --format="value(spec.serviceAccountName)"
```

### Problem: "Headers not reaching backend"

**Quick checks:**
1. ✅ Traefik dashboard shows middleware? → `http://traefik:8081/dashboard/`
2. ✅ Router lists middleware? → Check router in dashboard
3. ✅ Token has content? → Check provider logs for token length
4. ✅ Traefik v2.10+? → `curl http://traefik:8081/api/version`

---

## Debug Commands Cheatsheet

### Local Testing
```bash
# Run e2e tests with header validation
./test-e2e.sh

# Check backend logs for headers
docker-compose -f docker-compose.e2e.yml logs backend | grep "Authorization"

# Check what middlewares were created
docker-compose -f docker-compose.provider.yml logs provider | grep "ConfigBuilder"
```

### Production Debugging
```bash
# Full diagnosis
./debug-headers.sh https://traefik.example.com:8081

# Check middlewares exist
curl -s http://traefik:8081/api/http/middlewares | jq -r '.[].name'

# Check specific middleware details
curl -s http://traefik:8081/api/http/middlewares/NAME | jq '.headers.customRequestHeaders'

# Check router middlewares
curl -s http://traefik:8081/api/http/routers/NAME | jq '.middlewares'
```

### Provider Logs
```bash
# Docker - see middleware creation
docker logs CONTAINER 2>&1 | grep -E "(ConfigBuilder|middleware|token)"

# Cloud Run - see middleware creation
gcloud run logs read SERVICE --project=PROJECT \
  --format="value(textPayload)" | grep "ConfigBuilder"

# Look for token fetch
gcloud run logs read SERVICE --project=PROJECT \
  --format="value(textPayload)" | grep "identity token"
```

### Backend Testing
```bash
# Test debug endpoint
curl https://your-service.run.app/debug/headers | jq '.["X-Serverless-Authorization"]'

# Test with specific header
curl -H "Authorization: Bearer test" https://your-service.run.app/debug/headers
```

---

## What Logs Should Show

### ✅ Good Logs
```
[CloudRunPlugin] ✅ Plugin instantiated by Traefik - New() called
[CloudRunPlugin] ✅ Cloud Run API client initialized successfully
[CloudRunPlugin] ✅ Token manager initialized (production mode)
[CloudRunProvider] 🔧 Processing service name=my-service
[CloudRunProvider] ✅ Successfully fetched identity token (tokenLength: 842)
[ConfigBuilder] ✅ Created auth middleware 'my-service-auth' with X-Serverless-Authorization header (token length: 842)
[CloudRunPlugin] ✅ Auth middleware converted name=my-service-auth
```

### ❌ Problem Logs
```
[CloudRunProvider] ❌ Failed to fetch identity token for service
[ConfigBuilder] ⚠️  Created auth middleware 'my-service-auth' WITHOUT token
```

---

## Quick Traefik Dashboard Checks

1. **Go to:** `http://your-traefik:8081/dashboard/`

2. **Click:** HTTP → Middlewares

3. **Check:**
   - See middlewares ending in `-auth`?
   - Click middleware → See `customRequestHeaders`?
   - See `X-Serverless-Authorization`?

4. **Click:** HTTP → Routers

5. **Check:**
   - Your router exists?
   - Click router → See middlewares listed?
   - Auth middleware included?

---

## Emergency Debug Steps

If nothing works, run these in order:

```bash
# 1. Verify Traefik is running
curl http://traefik:8081/api/version

# 2. Check if ANY middlewares exist
curl -s http://traefik:8081/api/http/middlewares | jq -r '.[].name'

# 3. Check if provider is generating config
docker logs PROVIDER_CONTAINER 2>&1 | tail -50

# 4. Check if plugin is loaded
docker logs TRAEFIK_CONTAINER 2>&1 | grep -i plugin

# 5. Test token generation locally
export CLOUDRUN_PROVIDER_DEV_MODE=true
gcloud auth application-default login
./test-provider.sh

# 6. Check Cloud Run service labels
gcloud run services describe SERVICE \
  --region=REGION \
  --format="value(metadata.labels)" | grep traefik
```

---

## When to Use Each Tool

| Tool | When to Use |
|------|-------------|
| `./test-e2e.sh` | Testing changes locally |
| `./debug-headers.sh` | Diagnosing production issues |
| `docker logs \| grep ConfigBuilder` | Check if middlewares being created |
| Traefik Dashboard | Verify config loaded correctly |
| Backend `/debug/headers` | Confirm headers reach service |

---

## Getting Help

When asking for help, provide:

1. Output of `./debug-headers.sh`
2. Provider logs with `grep ConfigBuilder`
3. Output of backend `/debug/headers` endpoint
4. Traefik version: `curl http://traefik:8081/api/version`
5. Deployment method (Docker, Cloud Run, K8s)

---

## Most Common Fix

**90% of the time, it's one of these:**

1. **Token generation failing:**
   ```bash
   # Local
   export CLOUDRUN_PROVIDER_DEV_MODE=true
   gcloud auth application-default login

   # Production
   # Add IAM role: roles/iam.serviceAccountTokenCreator
   ```

2. **Service not labeled:**
   ```yaml
   # Cloud Run service needs:
   metadata:
     labels:
       traefik_enable: "true"
   ```

3. **Plugin not loaded:**
   ```yaml
   # Check Traefik static config includes plugin
   experimental:
     localPlugins:
       cloudrun:
         moduleName: github.com/YOUR_ORG/traefik-cloudrun-provider
   ```
