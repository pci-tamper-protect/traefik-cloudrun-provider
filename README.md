# Traefik Cloud Run Provider

A Traefik provider plugin that automatically discovers Google Cloud Run services and configures routing based on labels, with built-in GCP service-to-service authentication.

## Quick Start

```yaml
# traefik.yml
providers:
  cloudrun:
    projectID: "my-gcp-project"
    region: "us-central1"
    pollInterval: 30s
```

```bash
# Label your Cloud Run service
gcloud run services update my-service \
  --region=us-central1 \
  --update-labels="\
traefik_enable=true,\
traefik_http_routers_myapp_rule_id=myapp,\
traefik_http_routers_myapp_priority=200,\
traefik_http_routers_myapp_service=myapp,\
traefik_http_services_myapp_lb_port=8080"
```

Traefik will automatically:
- Discover the service via Cloud Run Admin API
- Generate path-based route: `/myapp` → `my-service:8080`
- Inject GCP identity token for service-to-service auth

## Features

✅ **Automatic Service Discovery** - Polls Cloud Run API for services with Traefik labels
✅ **Label-based Routing** - Generates routes from `traefik_*` labels on Cloud Run services
✅ **Service-to-Service Auth** - Injects GCP identity tokens automatically
🚧 **Event-driven Updates** - Eventarc support (planned)
🚧 **Permission Auto-detection** - Detects and uses best available method (planned)

## Why This Provider?

**Problem**: Connecting Traefik to Cloud Run requires:
1. Discovering services and their URLs
2. Generating routing rules
3. Handling GCP service-to-service authentication
4. Updating routes when services change

**Traditional Approach** (complex shell scripts):
- Run only at startup
- No dynamic updates without restart
- Mix concerns in entrypoint.sh
- Difficult to test and maintain

**This Provider** (native Traefik integration):
- Continuous polling for changes
- Dynamic route updates
- Proper error handling
- Automatic token management

## Documentation

- [Design Document](DESIGN.md) - Architecture and implementation details
- [Configuration](docs/configuration.md) - Complete configuration reference (TODO)
- [Migration Guide](docs/migration.md) - Migrating from entrypoint.sh (TODO)

## Project Status

🚧 **Under Active Development**

See [DESIGN.md](DESIGN.md) for the complete roadmap.

Current phase: Extracting core logic from [e-skimming-labs](https://github.com/kestenbroughton/e-skimming-labs) into proper provider plugin.

## Development

```bash
# Build
go build -o bin/traefik-cloudrun-provider ./cmd/provider

# Test
go test ./...

# Integration tests (requires GCP credentials)
go test ./tests/integration/...
```

## License

MIT

## Contributing

This provider was created to solve Cloud Run + Traefik integration challenges for the [e-skimming-labs](https://github.com/kestenbroughton/e-skimming-labs) project. Contributions welcome!
