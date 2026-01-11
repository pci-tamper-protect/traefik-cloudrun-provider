#!/bin/bash
# test-e2e.sh - End-to-End testing with Traefik Gateway + Frontend + Backend
# Simulates Cloud Run architecture with public gateway and private services

set -e

echo "🧪 E2E Testing: Traefik Gateway + Frontend + Backend"
echo "====================================================="
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
if curl -s http://traefik.localhost:8081/api/http/routers | grep -q '"name"'; then
    echo -e "${GREEN}✓ Traefik dashboard is accessible${NC}"

    ROUTER_COUNT=$(curl -s http://traefik.localhost:8081/api/http/routers | grep -c '"name"' || echo 0)
    SERVICE_COUNT=$(curl -s http://traefik.localhost:8081/api/http/services | grep -c '"name"' || echo 0)

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
BACKEND_RESPONSE=$(curl -s -H "Host: api.localhost" http://localhost/api/hello)
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
FRONTEND_RESPONSE=$(curl -s -H "Host: app.localhost" http://localhost/)
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
FRONTEND_HEALTH=$(curl -s -H "Host: app.localhost" http://localhost/health)
if echo "$FRONTEND_HEALTH" | grep -q "healthy"; then
    echo -e "${GREEN}✓ Frontend health check passed${NC}"
else
    echo -e "${RED}✗ Frontend health check failed${NC}"
    exit 1
fi

# Backend health (through Traefik)
BACKEND_HEALTH=$(curl -s -H "Host: api.localhost" http://localhost/health)
if echo "$BACKEND_HEALTH" | grep -q "healthy"; then
    echo -e "${GREEN}✓ Backend health check passed${NC}"
else
    echo -e "${RED}✗ Backend health check failed${NC}"
    exit 1
fi

# Test 6: Verify routing configuration
echo -e "\n${BLUE}Test 6: Routing Configuration${NC}"
ROUTERS=$(curl -s http://traefik.localhost:8081/api/http/routers)

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
echo "  Frontend:  http://app.localhost/"
echo "  Backend:   http://api.localhost/api/hello"
echo "  Dashboard: http://traefik.localhost:8081/dashboard/"
echo ""
echo "Press Ctrl+C to stop services and exit"
echo ""

# Show logs in follow mode
docker-compose -f docker-compose.e2e.yml logs -f
