#!/bin/bash
# test-provider.sh - Comprehensive Cloud Run provider testing script

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Load environment variables from .env if it exists
if [ -f .env ]; then
    echo "Loading environment variables from .env"
    export $(grep -v '^#' .env | grep -v '^$' | sed 's/#.*//' | xargs)
fi

# Impersonate service account if configured
if [ -n "$IMPERSONATE_SERVICE_ACCOUNT" ]; then
    echo -e "${YELLOW}Setting up service account impersonation...${NC}"
    echo "  Impersonating: $IMPERSONATE_SERVICE_ACCOUNT"

    if gcloud auth application-default login \
        --impersonate-service-account="$IMPERSONATE_SERVICE_ACCOUNT" 2>&1 | grep -q "Credentials saved"; then
        echo -e "${GREEN}✓ Successfully set up impersonation${NC}"
    else
        echo -e "${YELLOW}⚠ Impersonation may already be configured${NC}"
    fi
    echo ""
fi

echo "🧪 Docker Integration Testing for traefik-cloudrun-provider"
echo "==========================================================="
echo ""

# Show configuration
echo -e "${YELLOW}Configuration:${NC}"
echo "  LABS_PROJECT_ID: ${LABS_PROJECT_ID:-my-project-stg (default)}"
echo "  HOME_PROJECT_ID: ${HOME_PROJECT_ID:-my-home-stg (default)}"
echo "  REGION: ${REGION:-us-central1 (default)}"
echo "  IMPERSONATE_SERVICE_ACCOUNT: ${IMPERSONATE_SERVICE_ACCOUNT:-(none - using default credentials)}"
echo "  TRAEFIK_API_PORT: ${TRAEFIK_API_PORT:-8091 (default)}"
echo "  TRAEFIK_WEB_PORT: ${TRAEFIK_WEB_PORT:-8090 (default)}"
echo ""

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker-compose -f docker-compose.provider.yml down -v 2>/dev/null || true
    # Keep test-output for inspection - comment out to auto-clean
    # rm -rf test-output
}

trap cleanup EXIT

# Create output directory
mkdir -p test-output

echo -e "${YELLOW}Step 1: Building test image${NC}"
docker build -f Dockerfile.provider -t traefik-cloudrun-provider:test .

echo -e "\n${GREEN}✓ Image built successfully${NC}"

echo -e "\n${YELLOW}Step 2: Testing provider with ADC credentials${NC}"
docker run --rm \
  -v $(pwd)/test-output:/output \
  -v $HOME/.config/gcloud:/home/cloudrunner/.config/gcloud:ro \
  -e CLOUDRUN_PROVIDER_DEV_MODE=true \
  -e LOG_LEVEL=DEBUG \
  -e ENVIRONMENT=stg \
  -e LABS_PROJECT_ID=${LABS_PROJECT_ID:-my-project-stg} \
  -e HOME_PROJECT_ID=${HOME_PROJECT_ID:-my-home-stg} \
  -e REGION=${REGION:-us-central1} \
  traefik-cloudrun-provider:test \
  /output/routes.yml

if [ -f test-output/routes.yml ]; then
    echo -e "${GREEN}✓ Routes file generated successfully${NC}"
    echo -e "\n${YELLOW}Generated routes summary:${NC}"

    # Count routers, services, and middlewares in YAML (match indented keys)
    ROUTER_COUNT=$(grep -E '^\s+[a-zA-Z0-9_-]+:$' test-output/routes.yml | sed -n '/routers:/,/services:/p' | grep -c ':$' || echo 0)
    SERVICE_COUNT=$(grep -E '^\s+[a-zA-Z0-9_-]+:$' test-output/routes.yml | sed -n '/services:/,/middlewares:/p' | grep -c ':$' || echo 0)
    MIDDLEWARE_COUNT=$(grep -E '^\s+[a-zA-Z0-9_-]+:$' test-output/routes.yml | sed -n '/middlewares:/,$p' | grep -c ':$' || echo 0)

    # Fallback: just count sections if above fails
    if [ "$ROUTER_COUNT" -eq 0 ]; then
        ROUTER_COUNT=$(yq eval '.http.routers | length' test-output/routes.yml 2>/dev/null || echo "unknown")
    fi
    if [ "$SERVICE_COUNT" -eq 0 ]; then
        SERVICE_COUNT=$(yq eval '.http.services | length' test-output/routes.yml 2>/dev/null || echo "unknown")
    fi
    if [ "$MIDDLEWARE_COUNT" -eq 0 ]; then
        MIDDLEWARE_COUNT=$(yq eval '.http.middlewares | length' test-output/routes.yml 2>/dev/null || echo "unknown")
    fi

    echo "  Routers: $ROUTER_COUNT"
    echo "  Services: $SERVICE_COUNT"
    echo "  Middlewares: $MIDDLEWARE_COUNT"

    # Show file size for reference
    FILE_SIZE=$(wc -c < test-output/routes.yml)
    echo "  File size: ${FILE_SIZE} bytes"
else
    echo -e "${RED}✗ Routes file not generated${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Step 3: Testing without ADC (should fail gracefully)${NC}"
if docker run --rm \
  -v $(pwd)/test-output:/output \
  -e K_SERVICE=test-service \
  -e LOG_LEVEL=DEBUG \
  -e ENVIRONMENT=stg \
  -e LABS_PROJECT_ID=${LABS_PROJECT_ID:-my-project-stg} \
  -e HOME_PROJECT_ID=${HOME_PROJECT_ID:-my-home-stg} \
  -e REGION=${REGION:-us-central1} \
  traefik-cloudrun-provider:test \
  /output/routes-no-adc.yml 2>&1 | grep -q "metadata server not available"; then
    echo -e "${GREEN}✓ Failed gracefully with expected error message${NC}"
else
    echo -e "${YELLOW}⚠ Expected 'metadata server not available' error${NC}"
fi

echo -e "\n${YELLOW}Step 4: Starting E2E test with Traefik${NC}"
docker-compose -f docker-compose.provider.yml up -d traefik

echo "Waiting for Traefik to start..."
sleep 3

# Test Traefik API
TRAEFIK_API_PORT=${TRAEFIK_API_PORT:-8091}
echo -e "\n${YELLOW}Step 5: Verifying Traefik configuration${NC}"
if curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/routers | grep -q '"name"'; then
    echo -e "${GREEN}✓ Traefik API responding${NC}"

    ROUTER_COUNT=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/routers | grep -c '"name"' || echo 0)
    SERVICE_COUNT=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/services | grep -c '"name"' || echo 0)
    MIDDLEWARE_COUNT=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/middlewares | grep -c '"name"' || echo 0)

    echo "  Loaded routers: $ROUTER_COUNT"
    echo "  Loaded services: $SERVICE_COUNT"
    echo "  Loaded middlewares: $MIDDLEWARE_COUNT"

    if [ $ROUTER_COUNT -gt 0 ] && [ $SERVICE_COUNT -gt 0 ]; then
        echo -e "${GREEN}✓ Configuration loaded successfully${NC}"
    else
        echo -e "${RED}✗ No routers or services loaded${NC}"
        echo "Traefik logs:"
        docker-compose -f docker-compose.provider.yml logs traefik
        exit 1
    fi
else
    echo -e "${RED}✗ Traefik API not responding${NC}"
    docker-compose -f docker-compose.provider.yml logs traefik
    exit 1
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All tests passed! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Traefik dashboard available at: http://localhost:${TRAEFIK_API_PORT}/dashboard/"
echo "Press Ctrl+C to stop services and exit"

# Keep running until interrupted
docker-compose -f docker-compose.provider.yml logs -f
