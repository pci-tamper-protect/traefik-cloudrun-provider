#!/bin/bash
# test-e2e.sh - End-to-End testing with Traefik Gateway + Frontend + Backend
# Simulates Cloud Run architecture with public gateway and private services

set -e

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | grep -v '^$' | sed 's/#.*//' | xargs)
fi

# Set port defaults
TRAEFIK_WEB_PORT=${TRAEFIK_WEB_PORT:-8090}
TRAEFIK_API_PORT=${TRAEFIK_API_PORT:-8091}

echo "🧪 E2E Testing: Traefik Gateway + Frontend + Backend"
echo "====================================================="
echo ""
echo "Using ports: WEB=${TRAEFIK_WEB_PORT}, API=${TRAEFIK_API_PORT}"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker-compose -f docker-compose.e2e.yml down -v 2>/dev/null || true
}

trap cleanup EXIT

# Build and start services
echo -e "${YELLOW}Step 1: Building and starting services${NC}"
docker-compose -f docker-compose.e2e.yml up -d --build

echo -e "${YELLOW}Waiting for services to be ready...${NC}"
sleep 5

# Test 1: Traefik Dashboard
echo -e "\n${BLUE}Test 1: Traefik Dashboard${NC}"
if curl -s http://traefik.localhost:${TRAEFIK_API_PORT}/api/http/routers | grep -q '"name"'; then
    echo -e "${GREEN}✓ Traefik dashboard is accessible${NC}"

    ROUTER_COUNT=$(curl -s http://traefik.localhost:${TRAEFIK_API_PORT}/api/http/routers | grep -c '"name"' || echo 0)
    SERVICE_COUNT=$(curl -s http://traefik.localhost:${TRAEFIK_API_PORT}/api/http/services | grep -c '"name"' || echo 0)

    echo "  Routers configured: $ROUTER_COUNT"
    echo "  Services configured: $SERVICE_COUNT"
else
    echo -e "${RED}✗ Traefik dashboard not accessible${NC}"
    docker-compose -f docker-compose.e2e.yml logs traefik
    exit 1
fi

# Test 2: Verify Backend is Running
echo -e "\n${BLUE}Test 2: Backend Service Health${NC}"
if docker-compose -f docker-compose.e2e.yml ps backend | grep -q "Up"; then
    echo -e "${GREEN}✓ Backend service is running${NC}"
else
    echo -e "${RED}✗ Backend service is not running${NC}"
    exit 1
fi

# Test 3: Backend through Traefik
echo -e "\n${BLUE}Test 3: Backend Access Through Traefik${NC}"
BACKEND_RESPONSE=$(curl -s -H "Host: api.localhost" http://localhost:${TRAEFIK_WEB_PORT}/api/hello)
if echo "$BACKEND_RESPONSE" | grep -q "Hello from Backend"; then
    echo -e "${GREEN}✓ Backend accessible through Traefik gateway${NC}"
    echo "  Response: $BACKEND_RESPONSE"
else
    echo -e "${RED}✗ Backend not accessible through Traefik${NC}"
    echo "  Response: $BACKEND_RESPONSE"
    exit 1
fi

# Test 4: Frontend through Traefik (which calls Backend through Traefik)
echo -e "\n${BLUE}Test 4: Frontend → Traefik → Backend Communication${NC}"
FRONTEND_RESPONSE=$(curl -s -H "Host: app.localhost" http://localhost:${TRAEFIK_WEB_PORT}/)
if echo "$FRONTEND_RESPONSE" | grep -q "Hello from Frontend" && echo "$FRONTEND_RESPONSE" | grep -q "Hello from Backend"; then
    echo -e "${GREEN}✓ Full stack working: Frontend → Traefik → Backend${NC}"
    echo "  Response:"
    echo "$FRONTEND_RESPONSE" | jq . || echo "$FRONTEND_RESPONSE"
else
    echo -e "${RED}✗ Frontend-to-Backend communication failed${NC}"
    echo "  Response: $FRONTEND_RESPONSE"
    echo -e "\n${YELLOW}Frontend logs:${NC}"
    docker-compose -f docker-compose.e2e.yml logs frontend
    echo -e "\n${YELLOW}Backend logs:${NC}"
    docker-compose -f docker-compose.e2e.yml logs backend
    exit 1
fi

# Test 5: Health checks
echo -e "\n${BLUE}Test 5: Service Health Checks${NC}"

# Frontend health
FRONTEND_HEALTH=$(curl -s -H "Host: app.localhost" http://localhost:${TRAEFIK_WEB_PORT}/health)
if echo "$FRONTEND_HEALTH" | grep -q "healthy"; then
    echo -e "${GREEN}✓ Frontend health check passed${NC}"
else
    echo -e "${RED}✗ Frontend health check failed${NC}"
    exit 1
fi

# Backend health (through Traefik)
BACKEND_HEALTH=$(curl -s -H "Host: api.localhost" http://localhost:${TRAEFIK_WEB_PORT}/health)
if echo "$BACKEND_HEALTH" | grep -q "healthy"; then
    echo -e "${GREEN}✓ Backend health check passed${NC}"
else
    echo -e "${RED}✗ Backend health check failed${NC}"
    exit 1
fi

# Test 6: Verify routing configuration
echo -e "\n${BLUE}Test 6: Routing Configuration${NC}"
ROUTERS=$(curl -s http://traefik.localhost:${TRAEFIK_API_PORT}/api/http/routers)

if echo "$ROUTERS" | grep -q "frontend@docker"; then
    echo -e "${GREEN}✓ Frontend router configured${NC}"
else
    echo -e "${RED}✗ Frontend router not found${NC}"
    exit 1
fi

if echo "$ROUTERS" | grep -q "backend@docker"; then
    echo -e "${GREEN}✓ Backend router configured${NC}"
else
    echo -e "${RED}✗ Backend router not found${NC}"
    exit 1
fi

# Test 7: Check middleware configuration (headers)
echo -e "\n${BLUE}Test 7: Middleware Configuration (Docker Provider)${NC}"
MIDDLEWARES=$(curl -s http://traefik.localhost:${TRAEFIK_API_PORT}/api/http/middlewares)

echo -e "${YELLOW}Note: This test uses Docker provider, not Cloud Run provider${NC}"
echo -e "${YELLOW}      It sets X-Forwarded-By header, not X-Serverless-Authorization${NC}"
echo ""

# Check if backend-headers middleware exists
if echo "$MIDDLEWARES" | grep -q "backend-headers@docker"; then
    echo -e "${GREEN}✓ Backend headers middleware configured${NC}"

    # Check middleware details
    MW_DETAILS=$(curl -s http://traefik.localhost:${TRAEFIK_API_PORT}/api/http/middlewares/backend-headers@docker)
    if echo "$MW_DETAILS" | grep -q "X-Forwarded-By"; then
        echo -e "${GREEN}✓ X-Forwarded-By header configured in middleware${NC}"
    else
        echo -e "${YELLOW}⚠ X-Forwarded-By header not found in middleware details${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Backend headers middleware not found${NC}"
fi

# Test 8: Verify headers are actually sent to backend
echo -e "\n${BLUE}Test 8: Header Propagation to Backend${NC}"
HEADER_DEBUG=$(curl -s -H "Host: api.localhost" http://localhost:${TRAEFIK_WEB_PORT}/debug/headers)

if echo "$HEADER_DEBUG" | grep -q "X-Forwarded-By"; then
    echo -e "${GREEN}✓ X-Forwarded-By header reaches backend${NC}"
    HEADER_VALUE=$(echo "$HEADER_DEBUG" | jq -r '.headers["X-Forwarded-By"][0]' 2>/dev/null || echo 'parsing failed')
    echo "  Header value: $HEADER_VALUE"

    if [ "$HEADER_VALUE" == "traefik" ]; then
        echo -e "${GREEN}✓ Header has expected value 'traefik'${NC}"
    else
        echo -e "${YELLOW}⚠ Unexpected header value: $HEADER_VALUE${NC}"
    fi
else
    echo -e "${RED}✗ X-Forwarded-By header NOT reaching backend${NC}"
    echo "  All headers received by backend:"
    echo "$HEADER_DEBUG" | jq '.headers' 2>/dev/null || echo "$HEADER_DEBUG"
    exit 1
fi

# Show what headers the backend actually receives
echo -e "\n${YELLOW}Backend headers inspection (last 10 requests):${NC}"
docker-compose -f docker-compose.e2e.yml logs backend | tail -20 | grep -E "(X-Forwarded-By|headers received)" | tail -10 || echo "No relevant header logs found"

# Important note about provider testing
echo -e "\n${YELLOW}================================================${NC}"
echo -e "${YELLOW}NOTE: E2E Architecture Test Complete${NC}"
echo -e "${YELLOW}================================================${NC}"
echo -e "This test validates Traefik gateway architecture using Docker provider."
echo -e "It sets ${GREEN}X-Forwarded-By${NC} header, not ${YELLOW}X-Serverless-Authorization${NC}."
echo -e ""
echo -e "To test the actual Cloud Run provider with X-Serverless-Authorization:"
echo -e "  ${GREEN}./test-provider.sh${NC}"
echo -e ""

# Summary
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All E2E tests passed! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Architecture verified:"
echo -e "  ${GREEN}✓${NC} Traefik Gateway (Public)"
echo -e "  ${GREEN}✓${NC} Frontend Service (Private, accessible via Traefik)"
echo -e "  ${GREEN}✓${NC} Backend Service (Private, accessible via Traefik)"
echo -e "  ${GREEN}✓${NC} Frontend → Traefik → Backend communication"
echo ""
echo "Access points:"
echo "  Frontend:  http://app.localhost:${TRAEFIK_WEB_PORT}/"
echo "  Backend:   http://api.localhost:${TRAEFIK_WEB_PORT}/api/hello"
echo "  Dashboard: http://traefik.localhost:${TRAEFIK_API_PORT}/dashboard/"
echo ""
echo "Press Ctrl+C to stop services and exit"
echo ""

# Show logs in follow mode
docker-compose -f docker-compose.e2e.yml logs -f
