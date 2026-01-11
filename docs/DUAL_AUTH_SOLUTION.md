# Dual Authentication Solution: Service-to-Service + User Auth

## Problem

We need both:
1. **Service-to-service authentication**: Traefik must authenticate to private Cloud Run services using GCP identity tokens
2. **User authentication**: Users must authenticate via Firebase tokens

Both want to use the `Authorization` header, but HTTP only allows one `Authorization` header per request.

## Solution: X-Serverless-Authorization Header

**Cloud Run supports two headers for service-to-service authentication:**
- `Authorization: Bearer ID_TOKEN` (standard)
- `X-Serverless-Authorization: Bearer ID_TOKEN` (alternative)

According to the [Cloud Run documentation](https://docs.cloud.google.com/run/docs/authenticating/service-to-service):
> "You can use this header if your application already uses the Authorization header for custom authorization. If both headers are provided, only the X-Serverless-Authorization header is checked."

**We use `X-Serverless-Authorization` for service-to-service auth, allowing `Authorization` to be used for user authentication.**

## Solution: Separate Headers

The solution uses separate headers for each authentication type:

1. **User authentication** uses `Authorization: Bearer <firebase-token>`
   - Set by user/client
   - Validated by forwardAuth middleware
   - Passed through to backend services

2. **Service-to-service authentication** uses `X-Serverless-Authorization: Bearer <gcp-identity-token>`
   - Set by service auth middleware
   - Validated by Cloud Run platform
   - Does not conflict with user's Authorization header

3. **Backend service receives:**
   - `Authorization: Bearer <firebase-token>` - User's original token (preserved)
   - `X-Serverless-Authorization: Bearer <gcp-identity-token>` - Service-to-service auth (validated by Cloud Run)
   - `X-User-Id: <user-id>` - User information from forwardAuth
   - `X-User-Email: <user-email>` - User information from forwardAuth
   - `X-Authorization: Bearer <firebase-token>` - Original user JWT (also preserved for convenience)

## Implementation

### Router Middleware Order

Middleware order is flexible since headers don't conflict:

```yaml
http:
  routers:
    lab1:
      rule: "PathPrefix(`/lab1`)"
      service: lab1
      middlewares:
        - lab1-auth-check-file  # forwardAuth - validates user token
        - lab1-auth             # Service auth - adds X-Serverless-Authorization
        - retry-cold-start@file
```

**Note:** Middleware order doesn't matter for header conflicts since we use separate headers, but forwardAuth should run first to validate user authentication before the request reaches the backend.

### How It Works

#### Scenario 1: Staging with User Auth (via gcloud proxy)

1. **User runs** `gcloud run services proxy traefik-stg --port=8082`
2. **gcloud sets** `Authorization: Bearer <gcp-token>` (for proxy access to Traefik)
3. **User makes request** with Firebase token in Cookie (browser sets this)
4. **forwardAuth middleware** (`lab1-auth-check-file`):
   - Reads Firebase token from `Cookie` header (not Authorization, since gcloud set that)
   - Forwards to `home-index-service/api/auth/check` with Cookie header
   - Auth service validates Firebase token from Cookie
   - Auth service returns `X-User-Id`, `X-User-Email`, and `X-Authorization` headers
   - `X-Authorization` contains the original Firebase JWT token (preserved for backend use)
   - forwardAuth adds these headers to the original request
5. **Service auth middleware** (`lab1-auth`):
   - Fetches GCP identity token for target service (correct audience)
   - Sets `X-Serverless-Authorization: Bearer <gcp-identity-token>` (does NOT overwrite user's Authorization)
6. **Backend service receives:**
   - `Authorization: Bearer <firebase-token>` - User's original token (preserved)
   - `X-Serverless-Authorization: Bearer <gcp-identity-token>` - Service-to-service auth (validated by Cloud Run)
   - `X-User-Id: <user-id>` - User context
   - `X-User-Email: <user-email>` - User context
   - `X-Authorization: Bearer <firebase-token>` - Original user JWT token (also preserved)

#### Scenario 2: Staging without User Auth (via gcloud proxy)

1. **User runs** `gcloud run services proxy traefik-stg --port=8082`
2. **gcloud sets** `Authorization: Bearer <gcp-token>`
3. **Service auth middleware** (`lab1-auth`):
   - Fetches GCP identity token for target service (correct audience)
   - Sets `X-Serverless-Authorization: Bearer <gcp-identity-token>`
4. **Backend service receives:**
   - `Authorization: Bearer <gcp-token>` - gcloud proxy token (if present)
   - `X-Serverless-Authorization: Bearer <gcp-identity-token>` - Service-to-service auth (validated by Cloud Run)

#### Scenario 3: Production (Direct Access)

1. **User makes request** with `Authorization: Bearer <firebase-token>`
2. **forwardAuth middleware** (`lab1-auth-check-file`):
   - Reads Firebase token from `Authorization` header
   - Forwards to `home-index-service/api/auth/check`
   - Auth service validates Firebase token
   - Auth service returns `X-User-Id`, `X-User-Email`, and `X-Authorization` headers
   - `X-Authorization` contains the original Firebase JWT token (preserved for backend use)
3. **Service auth middleware** (`lab1-auth`):
   - Fetches GCP identity token for target service
   - Sets `X-Serverless-Authorization: Bearer <gcp-identity-token>` (does NOT overwrite user's Authorization)
4. **Backend service receives:**
   - `Authorization: Bearer <firebase-token>` - User's original token (preserved)
   - `X-Serverless-Authorization: Bearer <gcp-identity-token>` - Service-to-service auth (validated by Cloud Run)
   - `X-User-Id: <user-id>` - User context
   - `X-User-Email: <user-email>` - User context
   - `X-Authorization: Bearer <firebase-token>` - Original user JWT token (also preserved)

## Backend Service Implementation

Backend services should:

1. **Validate service-to-service auth** using `Authorization` header (Cloud Run does this automatically)
2. **Extract user context** from `X-User-Id` and `X-User-Email` headers (set by forwardAuth)

Example Go code:

```go
// Cloud Run validates X-Serverless-Authorization header automatically for service-to-service auth
// User's Authorization header is preserved and available for your application

// Extract user info from forwardAuth headers
userID := r.Header.Get("X-User-Id")
userEmail := r.Header.Get("X-User-Email")

// Get user's Firebase token from Authorization header (preserved, not overwritten)
authHeader := r.Header.Get("Authorization")
var userToken string
if authHeader != "" {
    parts := strings.SplitN(authHeader, " ", 2)
    if len(parts) == 2 && strings.ToLower(parts[0]) == "bearer" {
        userToken = parts[1]
        // Now you have the raw Firebase JWT token
    }
}

// Alternative: Get from X-Authorization (also preserved by forwardAuth)
if userToken == "" {
    xAuth := r.Header.Get("X-Authorization")
    if xAuth != "" {
        if strings.HasPrefix(xAuth, "Bearer ") {
            userToken = strings.TrimPrefix(xAuth, "Bearer ")
        } else {
            userToken = xAuth
        }
    }
}

if userID == "" {
    // No user context (public request or forwardAuth didn't run)
    // Handle accordingly
}
```

## Debugging

If you see 401 errors:

1. **Check token fetching logs:**
   ```bash
   gcloud run services logs read traefik-stg --limit=100 | grep -i "token\|auth"
   ```

2. **Verify middleware order:**
   - forwardAuth should be listed BEFORE service auth in router middlewares
   - Check generated routes: `gcloud run services describe traefik-stg --format="yaml"`

3. **Check token format:**
   - Service tokens should start with `eyJ` (JWT format)
   - Look for "Successfully fetched identity token" in logs

4. **Verify service account permissions:**
   - Traefik's service account needs `iam.serviceAccounts.getAccessToken` permission
   - Check: `gcloud projects get-iam-policy <project> --flatten="bindings[].members" --filter="bindings.members:serviceAccount:traefik-stg@*"`

## Alternative: Custom Header for User Auth

If you need to preserve user's Authorization token for backend services:

1. **Create a middleware** that copies `Authorization` to `X-User-Authorization` BEFORE service auth runs
2. **Update forwardAuth** to read from `X-User-Authorization` instead of `Authorization`
3. **Backend services** check `X-User-Authorization` for user token

This is more complex and not recommended unless backend services need the raw Firebase token.
