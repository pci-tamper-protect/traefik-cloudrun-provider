#!/bin/bash
# test-cloudrun-sim.sh - Local Cloud Run simulation with full debugging
# Simulates production Cloud Run environment with real service account authentication

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables from .env if it exists
if [ -f .env ]; then
    echo "Loading environment variables from .env"
    export $(grep -v '^#' .env | grep -v '^$' | sed 's/#.*//' | xargs)
fi

# Set port defaults
TRAEFIK_WEB_PORT=${TRAEFIK_WEB_PORT:-8090}
TRAEFIK_API_PORT=${TRAEFIK_API_PORT:-8091}

echo -e "${BLUE}🧪 Cloud Run Local Simulation${NC}"
echo "=================================================="
echo ""
echo "This test simulates the production Cloud Run environment:"
echo "  • Traefik gateway with real GCP authentication"
echo "  • Mock Cloud Run services with auth validation"
echo "  • Header inspector for debugging"
echo "  • Full instrumentation and logging"
echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  LABS_PROJECT_ID: ${LABS_PROJECT_ID:-labs-stg}"
echo "  HOME_PROJECT_ID: ${HOME_PROJECT_ID:-labs-home-stg}"
echo "  REGION: ${REGION:-us-central1}"
echo "  IMPERSONATE_SERVICE_ACCOUNT: ${IMPERSONATE_SERVICE_ACCOUNT:-(none)}"
echo "  TRAEFIK_API_PORT: ${TRAEFIK_API_PORT}"
echo "  TRAEFIK_WEB_PORT: ${TRAEFIK_WEB_PORT}"
echo ""

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker-compose -f docker-compose.cloudrun-sim.yml down -v 2>/dev/null || true
}

trap cleanup EXIT

# Clean up any existing containers before starting
echo -e "${YELLOW}Cleaning up any existing test containers...${NC}"
docker-compose -f docker-compose.cloudrun-sim.yml down -v 2>/dev/null || true
echo ""

# Setup service account impersonation if configured
if [ -n "$IMPERSONATE_SERVICE_ACCOUNT" ]; then
    echo -e "${YELLOW}Checking service account impersonation...${NC}"
    echo "  Target service account: $IMPERSONATE_SERVICE_ACCOUNT"

    CURRENT_IMPERSONATE=$(gcloud config get-value auth/impersonate_service_account 2>/dev/null || echo "")

    if [ "$CURRENT_IMPERSONATE" = "$IMPERSONATE_SERVICE_ACCOUNT" ]; then
        echo -e "${GREEN}✓ Impersonation already configured${NC}"
    else
        echo -e "${YELLOW}Configuring impersonation...${NC}"
        gcloud config set auth/impersonate_service_account "$IMPERSONATE_SERVICE_ACCOUNT" --quiet
        echo -e "${GREEN}✓ Impersonation configured${NC}"
    fi
    echo ""
fi

# Step 1: Generate provider configuration with real tokens
echo -e "${YELLOW}Step 1: Generating Traefik configuration from Cloud Run${NC}"
echo "This will fetch real services and generate auth tokens..."
echo ""

mkdir -p test-output

# Run provider to generate routes.yml
docker run --rm \
  -v $(pwd)/test-output:/output \
  -v $HOME/.config/gcloud:/home/cloudrunner/.config/gcloud:ro \
  -e CLOUDRUN_PROVIDER_DEV_MODE=true \
  -e LOG_LEVEL=INFO \
  -e ENVIRONMENT=${ENVIRONMENT:-stg} \
  -e LABS_PROJECT_ID=${LABS_PROJECT_ID:-labs-stg} \
  -e HOME_PROJECT_ID=${HOME_PROJECT_ID:-labs-home-stg} \
  -e REGION=${REGION:-us-central1} \
  traefik-cloudrun-provider:test \
  /output/routes.yml

if [ ! -f test-output/routes.yml ]; then
    echo -e "${RED}✗ Failed to generate routes.yml${NC}"
    exit 1
fi

# Copy static middleware configuration to test-output
echo "Copying static middleware configuration..."
cp traefik-static-middleware.yml test-output/middleware.yml

echo -e "${GREEN}✓ Configuration generated${NC}"
echo ""

# Show configuration summary
ROUTER_COUNT=$(yq eval '.http.routers | length' test-output/routes.yml 2>/dev/null || echo "unknown")
SERVICE_COUNT=$(yq eval '.http.services | length' test-output/routes.yml 2>/dev/null || echo "unknown")
MIDDLEWARE_COUNT=$(yq eval '.http.middlewares | length' test-output/routes.yml 2>/dev/null || echo "unknown")

echo -e "${BLUE}Generated Configuration:${NC}"
echo "  Routers: $ROUTER_COUNT"
echo "  Services: $SERVICE_COUNT"
echo "  Middlewares: $MIDDLEWARE_COUNT"
echo ""

# Step 2: Build mock services
echo -e "${YELLOW}Step 2: Building mock Cloud Run services${NC}"
docker-compose -f docker-compose.cloudrun-sim.yml build --quiet

echo -e "${GREEN}✓ Services built${NC}"
echo ""

# Step 3: Start services
echo -e "${YELLOW}Step 3: Starting Cloud Run simulation${NC}"
docker-compose -f docker-compose.cloudrun-sim.yml up -d

echo "Waiting for services to be ready..."
sleep 5

# Check if services are running
if ! docker-compose -f docker-compose.cloudrun-sim.yml ps | grep -q "Up"; then
    echo -e "${RED}✗ Services failed to start${NC}"
    docker-compose -f docker-compose.cloudrun-sim.yml logs
    exit 1
fi

echo -e "${GREEN}✓ Services started${NC}"
echo ""

# Step 4: Verify Traefik is running
echo -e "${YELLOW}Step 4: Verifying Traefik configuration${NC}"

# Wait for Traefik API
MAX_RETRIES=10
RETRY=0
while [ $RETRY -lt $MAX_RETRIES ]; do
    if curl -s http://localhost:${TRAEFIK_API_PORT}/api/version >/dev/null 2>&1; then
        break
    fi
    RETRY=$((RETRY+1))
    sleep 1
done

if [ $RETRY -eq $MAX_RETRIES ]; then
    echo -e "${RED}✗ Traefik API not responding${NC}"
    docker-compose -f docker-compose.cloudrun-sim.yml logs traefik
    exit 1
fi

echo -e "${GREEN}✓ Traefik API responding${NC}"

# Check loaded configuration
LOADED_ROUTERS=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/routers | grep -c '"name"' || echo 0)
LOADED_SERVICES=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/services | grep -c '"name"' || echo 0)
LOADED_MIDDLEWARES=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/middlewares | grep -c '"name"' || echo 0)

echo "  Loaded routers: $LOADED_ROUTERS"
echo "  Loaded services: $LOADED_SERVICES"
echo "  Loaded middlewares: $LOADED_MIDDLEWARES"
echo ""

# Step 5: Test mock service
echo -e "${YELLOW}Step 5: Testing mock Cloud Run service${NC}"

MOCK_RESPONSE=$(curl -s http://localhost:${TRAEFIK_WEB_PORT}/mock 2>/dev/null || echo "{}")

if echo "$MOCK_RESPONSE" | grep -q "mock-service"; then
    echo -e "${GREEN}✓ Mock service responding${NC}"
    echo "  Response:"
    echo "$MOCK_RESPONSE" | jq . 2>/dev/null || echo "$MOCK_RESPONSE"
else
    echo -e "${YELLOW}⚠ Mock service not configured in routes${NC}"
    echo "  (This is expected if real services don't include 'mock' route)"
fi
echo ""

# Step 6: Test header inspector
echo -e "${YELLOW}Step 6: Testing header propagation${NC}"

# Direct access to header inspector (for testing)
INSPECTOR_RESPONSE=$(docker exec header-inspector wget -qO- http://localhost:8080/ 2>/dev/null || echo "{}")

if echo "$INSPECTOR_RESPONSE" | grep -q "timestamp"; then
    echo -e "${GREEN}✓ Header inspector responding${NC}"

    # Check if X-Serverless-Authorization is present
    if echo "$INSPECTOR_RESPONSE" | grep -q "X-Serverless-Authorization"; then
        echo -e "${GREEN}✓ X-Serverless-Authorization header detected${NC}"
    else
        echo -e "${YELLOW}⚠ No X-Serverless-Authorization header${NC}"
        echo "  (This is expected without routes configured for inspector)"
    fi
fi
echo ""

# Step 7: Show available services
echo -e "${YELLOW}Step 7: Available endpoints${NC}"
echo ""
echo -e "${BLUE}Real Cloud Run Services (from provider):${NC}"
curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/routers | \
  jq -r '.[] | select(.provider=="file") | "  " + .name + " -> " + .rule' 2>/dev/null | head -10

echo ""
echo -e "${BLUE}Mock Services:${NC}"
echo "  Header Inspector: docker exec -it header-inspector wget -qO- http://localhost:8080/"
echo "  Mock Service: http://localhost:${TRAEFIK_WEB_PORT}/mock (if configured)"
echo ""

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloud Run simulation running! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}🔍 Debug & Monitoring:${NC}"
echo "  Traefik Dashboard:  http://localhost:${TRAEFIK_API_PORT}/dashboard/"
echo "  API Endpoints:      http://localhost:${TRAEFIK_API_PORT}/api/http/routers"
echo "  Access Logs:        docker-compose -f docker-compose.cloudrun-sim.yml logs -f traefik"
echo ""
echo -e "${BLUE}🧪 Testing:${NC}"
echo "  Test a real service: curl -v http://localhost:${TRAEFIK_WEB_PORT}/lab1"
echo "  Check headers:       docker exec header-inspector wget -qO- http://localhost:8080/"
echo "  View all logs:       docker-compose -f docker-compose.cloudrun-sim.yml logs -f"
echo ""
echo -e "${BLUE}📚 Configuration:${NC}"
echo "  Generated routes:    cat test-output/routes.yml"
echo "  Static middleware:   cat traefik-static-middleware.yml"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"
echo ""

# Follow logs
docker-compose -f docker-compose.cloudrun-sim.yml logs -f
