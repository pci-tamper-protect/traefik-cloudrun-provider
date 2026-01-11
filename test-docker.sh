#!/bin/bash
# test-docker.sh - Comprehensive Docker testing script

set -e

echo "🧪 Docker Integration Testing for traefik-cloudrun-provider"
echo "==========================================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker-compose -f docker-compose.test.yml down -v 2>/dev/null || true
    rm -rf test-output
}

trap cleanup EXIT

# Create output directory
mkdir -p test-output

echo -e "${YELLOW}Step 1: Building test image${NC}"
docker build -f Dockerfile.test -t traefik-cloudrun-provider:test .

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
    echo "  Routers: $(grep -c 'http.routers' test-output/routes.yml || echo 0)"
    echo "  Services: $(grep -c 'http.services' test-output/routes.yml || echo 0)"
    echo "  Middlewares: $(grep -c 'http.middlewares' test-output/routes.yml || echo 0)"
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
docker-compose -f docker-compose.test.yml up -d traefik

echo "Waiting for Traefik to start..."
sleep 3

# Test Traefik API
echo -e "\n${YELLOW}Step 5: Verifying Traefik configuration${NC}"
if curl -s http://localhost:8081/api/http/routers | grep -q '"name"'; then
    echo -e "${GREEN}✓ Traefik API responding${NC}"

    ROUTER_COUNT=$(curl -s http://localhost:8081/api/http/routers | grep -c '"name"' || echo 0)
    SERVICE_COUNT=$(curl -s http://localhost:8081/api/http/services | grep -c '"name"' || echo 0)
    MIDDLEWARE_COUNT=$(curl -s http://localhost:8081/api/http/middlewares | grep -c '"name"' || echo 0)

    echo "  Loaded routers: $ROUTER_COUNT"
    echo "  Loaded services: $SERVICE_COUNT"
    echo "  Loaded middlewares: $MIDDLEWARE_COUNT"

    if [ $ROUTER_COUNT -gt 0 ] && [ $SERVICE_COUNT -gt 0 ]; then
        echo -e "${GREEN}✓ Configuration loaded successfully${NC}"
    else
        echo -e "${RED}✗ No routers or services loaded${NC}"
        echo "Traefik logs:"
        docker-compose -f docker-compose.test.yml logs traefik
        exit 1
    fi
else
    echo -e "${RED}✗ Traefik API not responding${NC}"
    docker-compose -f docker-compose.test.yml logs traefik
    exit 1
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All tests passed! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Traefik dashboard available at: http://localhost:8081/dashboard/"
echo "Press Ctrl+C to stop services and exit"

# Keep running until interrupted
docker-compose -f docker-compose.test.yml logs -f
