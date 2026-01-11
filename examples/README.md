# Configuration Examples

This directory contains examples showing how to configure Traefik with the Cloud Run provider.

## Two Example Approaches

### 1. Generic Self-Contained Examples (`basic-*.yml`)

These examples use simple, generic names perfect for getting started or adapting to your own project:
- `basic-service-labels.yml` - Cloud Run service label patterns
- `basic-deployment.yml` - Simple deployment setup

**Use these when:**
- Learning how the provider works
- Starting a new project
- Need a template to customize

### 2. Real-World e-skimming-labs Examples (`e-skimming-labs-*.yml`)

These examples show actual production usage from the [e-skimming-labs](https://github.com/kestenbroughton/e-skimming-labs) project:
- `e-skimming-labs-labels.yml` - Real service label configurations
- `e-skimming-labs-deployment.yml` - Production deployment setup

**Use these when:**
- Want to see real-world usage patterns
- Working with similar multi-lab architecture
- Need inspiration for complex routing scenarios

### 3. Platform Examples (Applies to Both)

These examples work with both approaches:
- `traefik-static-config.yml` - Traefik static configuration
- `docker-compose-deployment.yml` - Docker Compose setup
- `kubernetes-deployment.yml` - Kubernetes/GKE deployment

## Quick Start

### Basic Generic Setup

```bash
# 1. Set environment variables
export ENVIRONMENT=prod
export LABS_PROJECT_ID=my-project-prod
export REGION=us-central1

# 2. Label your Cloud Run services (see basic-service-labels.yml)
gcloud run services update frontend-service \
  --region=us-central1 \
  --update-labels="traefik_enable=true,..."

# 3. Deploy Traefik with provider
./bin/traefik-cloudrun-provider /etc/traefik/dynamic/routes.yml
```

### e-skimming-labs Setup

```bash
# 1. Set environment variables for multi-project setup
export ENVIRONMENT=stg
export LABS_PROJECT_ID=labs-stg
export HOME_PROJECT_ID=labs-home-stg
export REGION=us-central1

# 2. Label your services (see e-skimming-labs-labels.yml)
gcloud run services update home-index-service \
  --region=us-central1 \
  --update-labels="traefik_enable=true,..."

# 3. Deploy provider
./bin/traefik-cloudrun-provider /etc/traefik/dynamic/routes.yml
```

## Files in This Directory

| File | Type | Description |
|------|------|-------------|
| `README.md` | Documentation | This file |
| `basic-service-labels.yml` | Generic | Simple service label examples |
| `e-skimming-labs-labels.yml` | Real-world | Actual e-skimming-labs labels |
| `traefik-static-config.yml` | Both | Traefik static configuration |
| `docker-compose-deployment.yml` | Both | Docker deployment |
| `kubernetes-deployment.yml` | Both | Kubernetes deployment |

## Key Differences

| Aspect | Generic Examples | e-skimming-labs Examples |
|--------|------------------|--------------------------|
| **Project Names** | `my-project-prod` | `labs-stg`, `labs-home-stg` |
| **Service Names** | `frontend-service`, `backend-api` | `home-index-service`, `lab1-service` |
| **Domains** | `example.com`, `app.example.com` | `stg.labs.pcioasis.com` (real) |
| **Routing** | Simple `/api`, `/static` paths | Custom rule IDs: `lab1`, `lab1-c2` |
| **Architecture** | Single project | Multi-project (labs + home) |

## Environment Variables

### Generic Setup (Minimum)
```bash
ENVIRONMENT=prod           # Environment name
LABS_PROJECT_ID=my-project # GCP project ID (required)
REGION=us-central1         # GCP region (required)
```

### e-skimming-labs Setup (Full)
```bash
ENVIRONMENT=stg                  # stg or prod
LABS_PROJECT_ID=labs-stg         # Labs services project
HOME_PROJECT_ID=labs-home-stg    # Home/landing page project
REGION=us-central1               # GCP region
```

## Next Steps

1. **Read the basic examples** to understand the fundamentals
2. **Review e-skimming-labs examples** for advanced patterns
3. **Adapt to your needs** - use the patterns that fit your architecture
4. **Check the main README** for deployment instructions

## Additional Resources

- [Main README](../README.md) - Provider documentation
- [TESTING.md](../TESTING.md) - Testing guide
- [MIGRATION.md](../MIGRATION.md) - Migration from shell scripts
- [e-skimming-labs repo](https://github.com/kestenbroughton/e-skimming-labs) - Original use case
