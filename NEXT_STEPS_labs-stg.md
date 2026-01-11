# Next Steps to Debug labs-stg Headers

You ran the **e2e architecture test** which validates Traefik routing but **doesn't test the Cloud Run provider** or `X-Serverless-Authorization` headers.

## What You Just Ran (E2E Test)

```bash
docker-compose -f docker-compose.e2e.yml up -d
./debug-headers.sh
```

**Result:**
- ✅ Tests Traefik gateway architecture
- ✅ Sets `X-Forwarded-By` header
- ❌ Doesn't test Cloud Run provider plugin
- ❌ Doesn't test `X-Serverless-Authorization`
- ❌ Doesn't test GCP token generation

This is why you saw:
```
✗ No authentication middlewares found
  Expected middlewares with '-auth' suffix
```

**This is expected!** The e2e test doesn't create `-auth` middlewares.

---

## What You Need to Do for labs-stg

### Step 1: Test the Actual Provider (Local)

Stop the e2e test and run the provider test:

```bash
# Stop e2e test
docker-compose -f docker-compose.e2e.yml down

# Set up environment
export CLOUDRUN_PROVIDER_DEV_MODE=true
export LABS_PROJECT_ID=your-labs-project-stg
export HOME_PROJECT_ID=your-home-project  # if you have one
export REGION=us-central1

# Make sure you're logged in
gcloud auth application-default login

# Run the provider test
./test-provider.sh
```

**What to look for:**
```
[ConfigBuilder] ✅ Created auth middleware 'my-service-auth' with X-Serverless-Authorization header (token length: 842, preview: eyJhbGciOi...)
```

**OR errors like:**
```
[ConfigBuilder] ⚠️  Created auth middleware 'my-service-auth' WITHOUT token
[CloudRunProvider] ❌ Failed to fetch identity token for service
```

If you see errors, that's your problem! The provider can't generate tokens.

### Step 2: Run Debug Script (Local)

After the provider test is running:

```bash
./debug-headers.sh http://localhost:8081
```

**You should now see:**
```
Test 4: Authentication Middlewares
✓ Found authentication middlewares:
  - my-service-auth@file

Test 5: Middleware Header Configuration
✓ X-Serverless-Authorization header is configured
  Token preview: Bearer eyJhbGciOi...
```

### Step 3: Debug labs-stg Deployment

Now run the debug script against your actual labs-stg deployment:

```bash
./debug-headers.sh https://your-traefik-labs-stg.example.com:8081
```

**Compare the output with your local test.**

#### If labs-stg shows "No middlewares found":

**Problem:** Provider not running or token generation failing

**Check provider logs:**
```bash
# If using Docker deployment
docker logs <traefik-container> 2>&1 | grep -E "(ConfigBuilder|token|middleware)"

# If using Cloud Run
gcloud run logs read <traefik-service-name> \
  --project=<labs-project-stg> \
  --format="value(textPayload)" \
  --limit=500 | grep -E "(ConfigBuilder|token|middleware)"
```

**Look for:**
```
[ConfigBuilder] ⚠️  Created auth middleware WITHOUT token
[CloudRunProvider] ❌ Failed to fetch identity token
```

#### If labs-stg shows "No authentication middlewares":

**Problem:** Middlewares created but don't have `-auth` suffix

**Check:**
```bash
curl -s https://your-traefik:8081/api/http/middlewares | jq -r '.[].name'
```

See what middlewares exist.

#### If labs-stg shows auth middlewares but no X-Serverless-Authorization:

**Problem:** Middleware exists but doesn't have the header

**Check middleware details:**
```bash
curl -s https://your-traefik:8081/api/http/middlewares/<middleware-name> | jq '.headers.customRequestHeaders'
```

### Step 4: Common Fixes

#### Problem: Token generation failing in labs-stg

**Cause:** No access to GCP metadata server or missing IAM permissions

**Fix for Cloud Run deployment:**
```bash
# 1. Check service account
gcloud run services describe <traefik-service> \
  --region=<region> \
  --format="value(spec.serviceAccountName)"

# 2. Add IAM permission
gcloud projects add-iam-policy-binding <labs-project-stg> \
  --member="serviceAccount:<service-account>@<project>.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

#### Problem: Services not discovered

**Cause:** Cloud Run services don't have required labels

**Fix:**
```bash
# Check service labels
gcloud run services describe <your-service> \
  --region=<region> \
  --format="value(metadata.labels)"

# Should show:
# traefik_enable=true
# traefik_http_routers_<name>_rule=Host(`example.com`)
```

#### Problem: Plugin not loaded

**Cause:** Traefik static config doesn't include plugin

**Check Traefik logs:**
```bash
gcloud run logs read <traefik-service> | grep -i "plugin\|cloudrun" | head -20
```

**Should see:**
```
[CloudRunPlugin] ✅ Plugin discovered by Traefik - CreateConfig() called
[CloudRunPlugin] 🔧 INFO: New() called by Traefik
[CloudRunPlugin] ✅ Plugin instantiated by Traefik
```

---

## Summary Checklist

### Local Testing
- [ ] Stop e2e test: `docker-compose -f docker-compose.e2e.yml down`
- [ ] Set environment variables (CLOUDRUN_PROVIDER_DEV_MODE, LABS_PROJECT_ID, etc.)
- [ ] Run provider test: `./test-provider.sh`
- [ ] Check for "Created auth middleware with X-Serverless-Authorization" logs
- [ ] Run debug script: `./debug-headers.sh http://localhost:8081`
- [ ] Verify middlewares with `-auth` suffix exist
- [ ] Verify X-Serverless-Authorization header configured

### labs-stg Debugging
- [ ] Run debug script: `./debug-headers.sh https://traefik-labs-stg:8081`
- [ ] Check provider logs for token generation
- [ ] Verify middlewares exist in Traefik
- [ ] Check X-Serverless-Authorization header is set
- [ ] Verify service account has IAM permissions
- [ ] Check Cloud Run services have correct labels

### If Still Not Working
- [ ] Compare local vs labs-stg debug output
- [ ] Check local works: `./test-provider.sh` passes
- [ ] Get labs-stg provider logs: `grep ConfigBuilder`
- [ ] Get labs-stg Traefik logs: `grep plugin`
- [ ] Add `/debug/headers` endpoint to backend service
- [ ] Test backend: `curl https://backend.run.app/debug/headers`

---

## Quick Reference

**Run the RIGHT test for labs-stg debugging:**
```bash
# NOT THIS (architecture test only)
./test-e2e.sh

# THIS (provider plugin test)
./test-provider.sh
```

**Debug the RIGHT endpoint:**
```bash
# NOT THIS (e2e test)
./debug-headers.sh http://localhost:8081

# THIS (labs-stg deployment)
./debug-headers.sh https://your-traefik-labs-stg.com:8081
```

---

## Documentation

- **TEST_MODES.md** - Understand the difference between e2e and provider tests
- **DEBUGGING_HEADERS.md** - Comprehensive debugging guide
- **QUICK_DEBUG_REFERENCE.md** - Quick command reference
- **CHANGES.md** - What was added to help debug

---

## Example: Full Debug Session

```bash
# 1. Test locally first
export CLOUDRUN_PROVIDER_DEV_MODE=true
export LABS_PROJECT_ID=my-labs-stg
gcloud auth application-default login
./test-provider.sh

# Look for: "Created auth middleware 'X-auth' with X-Serverless-Authorization"

# 2. Debug local
./debug-headers.sh http://localhost:8081

# Should show:
# ✓ Found 3 middlewares
# ✓ Found authentication middlewares: my-service-auth@file
# ✓ X-Serverless-Authorization header is configured

# 3. If local works, debug production
./debug-headers.sh https://traefik.labs-stg.example.com:8081

# 4. Compare outputs - find the difference

# 5. Check logs
gcloud run logs read traefik-service \
  --project=labs-project-stg | \
  grep "ConfigBuilder\|token\|middleware"

# 6. Look for errors like:
# "Failed to fetch identity token"
# "Created auth middleware WITHOUT token"

# 7. Fix and redeploy
```
