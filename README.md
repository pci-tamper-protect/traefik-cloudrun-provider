# Traefik Cloud Run Provider

[![CI](https://github.com/kestenbroughton/traefik-cloudrun-provider/actions/workflows/ci.yml/badge.svg)](https://github.com/kestenbroughton/traefik-cloudrun-provider/actions/workflows/ci.yml)
[![Go Report Card](https://goreportcard.com/badge/github.com/kestenbroughton/traefik-cloudrun-provider)](https://goreportcard.com/report/github.com/kestenbroughton/traefik-cloudrun-provider)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A standalone provider that dynamically discovers Google Cloud Run services and generates Traefik routing configuration with automatic GCP identity token injection for service-to-service authentication.

## Overview

This provider continuously polls the Cloud Run Admin API to discover services with Traefik labels and generates a dynamic Traefik configuration file. It handles service-to-service authentication by fetching and caching GCP identity tokens.

**Architecture:**
```
Cloud Run Services (with traefik_* labels)
         ↓
   Cloud Run Admin API
         ↓
  Provider (polls every 30s)
         ↓
  routes.yml (Traefik file provider)
         ↓
    Traefik Gateway
```

## Features

✅ **Automatic Service Discovery** - Polls Cloud Run API for services with `traefik_enable=true` label
✅ **Label-based Configuration** - Generates routers, services, and middlewares from Cloud Run labels
✅ **Identity Token Management** - Fetches and caches GCP identity tokens with automatic refresh
✅ **Development Mode** - ADC (Application Default Credentials) fallback for local development
✅ **Structured Logging** - JSON and text formats with configurable log levels
✅ **Multi-Project Support** - Discover services across multiple GCP projects
✅ **Health Checks** - Graceful error handling with service-level health status

## Quick Start

### Prerequisites

- Go 1.21 or later
- GCP project with Cloud Run services
- IAM permissions: `run.services.list`, `run.services.get`
- For service-to-service auth: `iam.serviceAccounts.getAccessToken`

### Installation

```bash
# Clone the repository
git clone https://github.com/kestenbroughton/traefik-cloudrun-provider
cd traefik-cloudrun-provider

# Build the provider
make build

# Or install directly
go install github.com/kestenbroughton/traefik-cloudrun-provider/cmd/provider@latest
```

### Configuration

The provider is configured via environment variables:

```bash
# Required
export ENVIRONMENT=stg                    # Environment name
export LABS_PROJECT_ID=labs-stg           # Primary GCP project
export HOME_PROJECT_ID=labs-home-stg      # Secondary GCP project (optional)
export REGION=us-central1                 # GCP region

# Optional
export LOG_LEVEL=INFO                     # DEBUG, INFO, WARN, ERROR
export LOG_FORMAT=text                    # text or json
export CLOUDRUN_PROVIDER_DEV_MODE=true    # Enable ADC fallback for local dev
```

### Label Your Cloud Run Services

Add Traefik labels to your Cloud Run services:

```bash
gcloud run services update my-service \
  --region=us-central1 \
  --update-labels="\
traefik_enable=true,\
traefik_http_routers_myapp_rule=Host(\`app.example.com\`),\
traefik_http_routers_myapp_priority=200,\
traefik_http_services_myapp_lb_port=8080"
```

### Run the Provider

```bash
# Generate routes once and exit
./bin/traefik-cloudrun-provider /path/to/routes.yml

# Or use make
make run
```

The provider will:
1. Discover services with `traefik_enable=true` in configured projects
2. Fetch identity tokens for each service
3. Generate Traefik configuration in `/path/to/routes.yml`
4. Exit (in Cloud Run, this is triggered by cron every 30s)

### Configure Traefik

Update your `traefik.yml` to use the generated routes:

```yaml
providers:
  file:
    filename: /path/to/routes.yml
    watch: true
```

## Example Configurations

Comprehensive configuration examples are available in the [examples/](examples/) directory:

- **[traefik-static-config.yml](examples/traefik-static-config.yml)** - Traefik static configuration with all options
- **[cloud-run-service-labels.yml](examples/cloud-run-service-labels.yml)** - Cloud Run service label patterns and examples
- **[docker-compose-deployment.yml](examples/docker-compose-deployment.yml)** - Docker Compose deployment with provider
- **[kubernetes-deployment.yml](examples/kubernetes-deployment.yml)** - Kubernetes/GKE deployment manifests

## Development

### Setup

```bash
# Install development tools
make install-tools

# Install pre-commit hooks
make pre-commit-install

# Run all checks
make check
```

### Common Tasks

```bash
# Format and lint
make fmt
make lint

# Run tests
make test
make coverage

# Build
make build
make build-static  # For containers

# Run locally (requires GCP auth)
gcloud auth application-default login
make run

# Docker tests
make docker-test

# E2E tests
make e2e-test
```

### Pre-commit Hooks

The project uses pre-commit hooks for code quality:

```bash
# Install hooks
make pre-commit-install

# Run manually
make pre-commit-run
```

Hooks include:
- Go formatting (gofmt, goimports)
- Go linting (golangci-lint)
- Go vet
- YAML linting
- Markdown linting
- Shell script linting

## Testing

See [TESTING.md](TESTING.md) for comprehensive testing documentation.

### Quick Test Commands

```bash
# Unit tests
make test

# Coverage report
make coverage
make coverage-html  # Opens in browser

# Docker integration tests
make docker-test

# E2E tests (Traefik + Frontend + Backend)
make e2e-test
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Cloud Run Provider                                     │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────┐ │
│  │   Discovery  │→ │ Token Manager │→ │   Config     │ │
│  │   (API)      │  │  (Caching)    │  │  Generator   │ │
│  └──────────────┘  └───────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────┘
                           ↓
                    routes.yml (file)
                           ↓
┌─────────────────────────────────────────────────────────┐
│  Traefik                                                │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────┐ │
│  │ File Provider│→ │   Routers     │→ │  Middlewares │ │
│  │   (Watch)    │  │  (Routing)    │  │  (Auth)      │ │
│  └──────────────┘  └───────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────┘
                           ↓
              Cloud Run Services (private)
```

### Key Components

- **Discovery**: Polls Cloud Run Admin API for labeled services
- **Token Manager**: Fetches and caches GCP identity tokens (55-minute TTL)
- **Config Generator**: Converts service metadata + labels into Traefik config
- **Logging**: Structured logging with configurable formats and levels

## Documentation

- **[TESTING.md](TESTING.md)** - Comprehensive testing guide (unit, Docker, E2E)
- **[DESIGN.md](DESIGN.md)** - Architecture and design decisions
- **[MIGRATION.md](MIGRATION.md)** - Migrating from shell script approach
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - Contribution guidelines

## Production Deployment

### Cloud Run Deployment

Deploy the provider as a Cloud Run service with Cloud Scheduler:

```bash
# Deploy provider service
gcloud run deploy traefik-cloudrun-provider \
  --source . \
  --region=us-central1 \
  --set-env-vars="ENVIRONMENT=prod,LABS_PROJECT_ID=labs-prod,REGION=us-central1" \
  --no-allow-unauthenticated

# Create Cloud Scheduler job (runs every 30s)
gcloud scheduler jobs create http refresh-routes \
  --location=us-central1 \
  --schedule="*/30 * * * * *" \
  --uri="https://traefik-cloudrun-provider-xyz.run.app/refresh" \
  --oidc-service-account-email=scheduler@project.iam.gserviceaccount.com
```

### Environment Variables

**Required:**
- `ENVIRONMENT` - Environment name (stg, prod)
- `LABS_PROJECT_ID` - Primary GCP project ID
- `REGION` - GCP region for Cloud Run services

**Optional:**
- `HOME_PROJECT_ID` - Additional GCP project ID
- `LOG_LEVEL` - Logging level (DEBUG, INFO, WARN, ERROR)
- `LOG_FORMAT` - Log format (text, json)
- `CLOUDRUN_PROVIDER_DEV_MODE` - Enable ADC fallback (auto-detected in Cloud Run)

## Troubleshooting

### Common Issues

**"metadata server not available"**
- Running locally without dev mode enabled
- Solution: Set `CLOUDRUN_PROVIDER_DEV_MODE=true` and run `gcloud auth application-default login`

**"failed to create token source with ADC"**
- ADC credentials not configured
- Solution: Run `gcloud auth application-default login`

**"no services found"**
- No services have `traefik_enable=true` label
- Check project IDs and region are correct
- Verify IAM permissions

### Debug Logging

Enable debug logging for detailed output:

```bash
export LOG_LEVEL=DEBUG
export LOG_FORMAT=text  # Easier to read during debugging
./bin/traefik-cloudrun-provider /tmp/routes.yml
```

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for:
- Code of conduct
- Development workflow
- Pull request process
- Coding standards

## License

MIT License - see [LICENSE](LICENSE) file for details

## Acknowledgments

This provider was created to solve Cloud Run + Traefik integration challenges for the [e-skimming-labs](https://github.com/kestenbroughton/e-skimming-labs) project.

## Support

- **Issues**: [GitHub Issues](https://github.com/kestenbroughton/traefik-cloudrun-provider/issues)
- **Discussions**: [GitHub Discussions](https://github.com/kestenbroughton/traefik-cloudrun-provider/discussions)
