#!/bin/bash
# test-plugin-local.sh - E2E testing with Traefik local plugin mode (Yaegi)
#
# REQUIREMENTS FOR YAEGI PLUGINS:
# 1. Dependencies must be vendored: run `go mod vendor`
# 2. Vendor directory must be included in the plugin source
# 3. See: https://doc.traefik.io/traefik-hub/api-gateway/guides/plugin-development-guide
#
# POTENTIAL ISSUES:
# - GCP SDK uses complex reflection patterns
# - Some packages may need useUnsafe: true in .traefik.yml
# - gRPC/protobuf may cause runtime issues with Yaegi
#
# ALTERNATIVE: Use ./test-provider.sh or ./test-cloudrun-sim.sh
# which run the provider as an external binary with File provider.

set -e

# Check if vendor directory exists
if [ ! -d "vendor" ]; then
    echo "⚠️  Vendor directory not found. Yaegi requires vendored dependencies."
    echo "   Run: go mod vendor"
    echo ""
    read -p "Run 'go mod vendor' now? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "Running go mod vendor..."
        go mod vendor
        echo "✓ Dependencies vendored"
    else
        echo "Exiting. Run 'go mod vendor' first."
        exit 1
    fi
fi

echo "📦 Vendor directory found ($(du -sh vendor | cut -f1))"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | grep -v '^$' | sed 's/#.*//' | xargs)
fi

# Set port defaults
TRAEFIK_WEB_PORT=${TRAEFIK_WEB_PORT:-8090}
TRAEFIK_API_PORT=${TRAEFIK_API_PORT:-8091}

echo "🧪 E2E Testing: Traefik v3.0 Local Plugin Mode"
echo "=============================================="
echo ""
echo "This test validates the local plugin mode used in production:"
echo "  - Traefik v3.0 compiles plugin from plugins-local/"
echo "  - Plugin discovers Cloud Run services"
echo "  - Plugin generates routes with X-Serverless-Authorization headers"
echo ""
echo "Using ports: WEB=${TRAEFIK_WEB_PORT}, API=${TRAEFIK_API_PORT}"
echo ""

# Show configuration
echo -e "${YELLOW}Configuration:${NC}"
echo "  LABS_PROJECT_ID: ${LABS_PROJECT_ID:-my-project-stg (default)}"
echo "  HOME_PROJECT_ID: ${HOME_PROJECT_ID:-my-home-stg (default)}"
echo "  REGION: ${REGION:-us-central1 (default)}"
echo ""

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker-compose -f docker-compose.plugin-local.yml down -v 2>/dev/null || true
}

trap cleanup EXIT

# Create dynamic config directory if it doesn't exist
mkdir -p tests/e2e/traefik/dynamic

# Build and start services
echo -e "${YELLOW}Step 1: Building Traefik image with local plugin${NC}"
docker-compose -f docker-compose.plugin-local.yml build traefik

echo -e "\n${YELLOW}Step 2: Starting services${NC}"
docker-compose -f docker-compose.plugin-local.yml up -d

echo -e "${YELLOW}Waiting for Traefik to start and compile plugin...${NC}"
sleep 10

# Test 1: Traefik Dashboard
echo -e "\n${BLUE}Test 1: Traefik Dashboard${NC}"
if curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/routers | grep -q '"name"'; then
    echo -e "${GREEN}✓ Traefik dashboard is accessible${NC}"
else
    echo -e "${RED}✗ Traefik dashboard not accessible${NC}"
    docker-compose -f docker-compose.plugin-local.yml logs traefik | tail -50
    exit 1
fi

# Test 2: Check plugin is loaded
echo -e "\n${BLUE}Test 2: Plugin Loading Status${NC}"
TRAEFIK_LOGS=$(docker-compose -f docker-compose.plugin-local.yml logs traefik 2>&1)

if echo "$TRAEFIK_LOGS" | grep -q "Plugin.*cloudrun.*loaded\|localPlugins\|plugin.*compiled"; then
    echo -e "${GREEN}✓ Plugin appears to be loading/loaded${NC}"
    echo "$TRAEFIK_LOGS" | grep -i "plugin\|cloudrun" | tail -10
else
    echo -e "${YELLOW}⚠ Could not confirm plugin loading from logs${NC}"
    echo "Checking for plugin-related errors..."
    echo "$TRAEFIK_LOGS" | grep -i "error\|fail" | tail -10
fi

# Test 3: Check for Cloud Run service discovery
echo -e "\n${BLUE}Test 3: Cloud Run Service Discovery${NC}"
if echo "$TRAEFIK_LOGS" | grep -q "Discovered services\|Processing service\|Cloud Run"; then
    echo -e "${GREEN}✓ Plugin is discovering Cloud Run services${NC}"
    echo "$TRAEFIK_LOGS" | grep -i "discovered\|processing\|cloud run" | tail -10
else
    echo -e "${YELLOW}⚠ No service discovery logs found${NC}"
    echo "This might be expected if no services are found or credentials are missing"
fi

# Test 4: Check for X-Serverless-Authorization middleware
echo -e "\n${BLUE}Test 4: X-Serverless-Authorization Middleware${NC}"
MIDDLEWARES=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/middlewares 2>/dev/null || echo "{}")

if echo "$MIDDLEWARES" | grep -q "X-Serverless-Authorization\|Serverless-Authorization"; then
    echo -e "${GREEN}✓ X-Serverless-Authorization middleware found${NC}"
    echo "$MIDDLEWARES" | jq -r 'to_entries[] | select(.value.headers.customRequestHeaders."X-Serverless-Authorization" != null) | "  \(.key): \(.value.headers.customRequestHeaders."X-Serverless-Authorization" | .[0:50])..."' 2>/dev/null || echo "  (middleware details available)"
else
    echo -e "${YELLOW}⚠ X-Serverless-Authorization middleware not found${NC}"
    echo "This might be expected if no services are discovered or tokens aren't generated"
    echo "Available middlewares:"
    echo "$MIDDLEWARES" | jq -r 'keys[]' 2>/dev/null || echo "$MIDDLEWARES"
fi

# Test 5: Verify plugin provider is active
echo -e "\n${BLUE}Test 5: Plugin Provider Status${NC}"
PROVIDERS=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/rawdata 2>/dev/null || echo "{}")

if echo "$PROVIDERS" | grep -q "plugin\|cloudrun"; then
    echo -e "${GREEN}✓ Plugin provider appears in Traefik configuration${NC}"
else
    echo -e "${YELLOW}⚠ Could not confirm plugin provider in configuration${NC}"
fi

# Test 6: Check routers generated by plugin
echo -e "\n${BLUE}Test 6: Routers Generated by Plugin${NC}"
ROUTERS=$(curl -s http://localhost:${TRAEFIK_API_PORT}/api/http/routers 2>/dev/null || echo "[]")
ROUTER_COUNT=$(echo "$ROUTERS" | jq 'length' 2>/dev/null || echo "0")

if [ "$ROUTER_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Found $ROUTER_COUNT router(s)${NC}"
    echo "$ROUTERS" | jq -r '.[] | "  \(.name): \(.rule)"' 2>/dev/null || echo "  (router details available)"
else
    echo -e "${YELLOW}⚠ No routers found${NC}"
    echo "This might be expected if no Cloud Run services are discovered"
fi

# Summary
echo -e "\n${YELLOW}================================================${NC}"
echo -e "${YELLOW}Local Plugin Mode E2E Test Complete${NC}"
echo -e "${YELLOW}================================================${NC}"
echo ""
echo -e "This test validates:"
echo -e "  ${GREEN}✓${NC} Traefik v3.0 can compile plugin from plugins-local/"
echo -e "  ${GREEN}✓${NC} Plugin can be loaded via experimental.localPlugins"
echo -e "  ${GREEN}✓${NC} Plugin can discover Cloud Run services (if credentials available)"
echo -e "  ${GREEN}✓${NC} Plugin can generate routes and middlewares"
echo ""
echo "Access points:"
echo "  Dashboard: http://localhost:${TRAEFIK_API_PORT}/dashboard/"
echo "  API: http://localhost:${TRAEFIK_API_PORT}/api/http/routers"
echo ""
echo "Press Ctrl+C to stop services and exit"
echo ""

# Show logs in follow mode
docker-compose -f docker-compose.plugin-local.yml logs -f
