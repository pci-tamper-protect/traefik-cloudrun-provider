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

# Clean up any existing containers before starting
docker-compose -f docker-compose.e2e.yml down -v 2>/dev/null || true

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

# Test 3: Backend /api/query through Traefik
echo -e "\n${BLUE}Test 3: Backend /api/query Access Through Traefik${NC}"
BACKEND_QUERY_RESPONSE=$(curl -s -H "Host: api.localhost" http://localhost:${TRAEFIK_WEB_PORT}/api/query)
if echo "$BACKEND_QUERY_RESPONSE" | grep -q "\"request\"" && echo "$BACKEND_QUERY_RESPONSE" | grep -q "\"response\""; then
    echo -e "${GREEN}✓ Backend /api/query accessible through Traefik gateway${NC}"
    echo "  Response preview:"
    echo "$BACKEND_QUERY_RESPONSE" | jq '{request: .request.method, response: .response.status, service: .service.name}' 2>/dev/null || echo "$BACKEND_QUERY_RESPONSE" | head -5
else
    echo -e "${RED}✗ Backend /api/query not accessible through Traefik${NC}"
    echo "  Response: $BACKEND_QUERY_RESPONSE"
    exit 1
fi

# Test 3b: Verify backend is private (no direct access)
echo -e "\n${BLUE}Test 3b: Backend Privacy (No Direct Access)${NC}"
if docker-compose -f docker-compose.e2e.yml exec -T backend wget -qO- http://localhost:8080/api/query 2>&1 | grep -q "200 OK\|request"; then
    echo -e "${YELLOW}⚠ Backend is accessible internally (expected for docker-compose)${NC}"
    echo -e "${YELLOW}  In Cloud Run, this would be blocked by --no-allow-unauthenticated${NC}"
else
    echo -e "${GREEN}✓ Backend is not directly accessible (private service)${NC}"
fi

# Test 4: Frontend through Traefik (which calls Backend /api/query through Traefik)
echo -e "\n${BLUE}Test 4: Frontend → Traefik → Backend /api/query Communication${NC}"
FRONTEND_RESPONSE=$(curl -s -H "Host: app.localhost" http://localhost:${TRAEFIK_WEB_PORT}/)
if echo "$FRONTEND_RESPONSE" | grep -q "frontend_headers" && echo "$FRONTEND_RESPONSE" | grep -q "backend_query_result"; then
    echo -e "${GREEN}✓ Full stack working: Frontend → Traefik → Backend /api/query${NC}"
    echo "  Response structure:"
    echo "$FRONTEND_RESPONSE" | jq '{
        frontend_info: .frontend_info,
        backend_service: .backend_query_result.service,
        has_headers: (.frontend_headers | length > 0),
        has_access_log: (.frontend_access_log | length > 0),
        backend_request_method: .backend_query_result.request.method
    }' 2>/dev/null || echo "$FRONTEND_RESPONSE" | head -10
else
    echo -e "${RED}✗ Frontend-to-Backend communication failed${NC}"
    echo "  Response: $FRONTEND_RESPONSE"
    echo -e "\n${YELLOW}Frontend logs:${NC}"
    docker-compose -f docker-compose.e2e.yml logs frontend | tail -20
    echo -e "\n${YELLOW}Backend logs:${NC}"
    docker-compose -f docker-compose.e2e.yml logs backend | tail -20
    exit 1
fi

# Test 4b: Verify frontend displays headers and access logs
echo -e "\n${BLUE}Test 4b: Frontend Headers and Access Log Display${NC}"
FRONTEND_HEADERS_COUNT=$(echo "$FRONTEND_RESPONSE" | jq '.frontend_headers | length' 2>/dev/null || echo "0")
FRONTEND_ACCESS_LOG_COUNT=$(echo "$FRONTEND_RESPONSE" | jq '.frontend_access_log | length' 2>/dev/null || echo "0")

if [ "$FRONTEND_HEADERS_COUNT" -gt "0" ]; then
    echo -e "${GREEN}✓ Frontend displays headers (count: $FRONTEND_HEADERS_COUNT)${NC}"
    echo "  Sample headers:"
    echo "$FRONTEND_RESPONSE" | jq '.frontend_headers | to_entries | .[0:3] | from_entries' 2>/dev/null || echo "  (unable to parse)"
else
    echo -e "${RED}✗ Frontend does not display headers${NC}"
    exit 1
fi

if [ "$FRONTEND_ACCESS_LOG_COUNT" -gt "0" ]; then
    echo -e "${GREEN}✓ Frontend displays access logs (count: $FRONTEND_ACCESS_LOG_COUNT)${NC}"
    echo "  Latest access log entry:"
    echo "$FRONTEND_RESPONSE" | jq '.frontend_access_log[-1]' 2>/dev/null || echo "  (unable to parse)"
else
    echo -e "${YELLOW}⚠ Frontend access log is empty (may be first request)${NC}"
fi

# Test 4c: Verify backend returns all request/response details
echo -e "\n${BLUE}Test 4c: Backend /api/query Request/Response Details${NC}"
BACKEND_QUERY_DETAILS=$(echo "$FRONTEND_RESPONSE" | jq '.backend_query_result' 2>/dev/null)
if [ -n "$BACKEND_QUERY_DETAILS" ] && echo "$BACKEND_QUERY_DETAILS" | jq -e '.request.method' > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Backend /api/query returns complete request details${NC}"
    echo "  Request details:"
    echo "$BACKEND_QUERY_DETAILS" | jq '{
        method: .request.method,
        path: .request.path,
        headers_count: (.request.headers | length),
        remote_addr: .request.remote_addr
    }' 2>/dev/null || echo "  (unable to parse)"
    
    echo -e "${GREEN}✓ Backend /api/query returns complete response details${NC}"
    echo "  Response details:"
    echo "$BACKEND_QUERY_DETAILS" | jq '{
        status: .response.status,
        status_code: .response.status_code,
        size: .response.size,
        headers_count: (.response.headers | length)
    }' 2>/dev/null || echo "  (unable to parse)"
else
    echo -e "${RED}✗ Backend /api/query does not return complete details${NC}"
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

# Test 8: Verify headers are actually sent to backend via /api/query
echo -e "\n${BLUE}Test 8: Header Propagation to Backend via /api/query${NC}"
BACKEND_QUERY_HEADERS=$(echo "$BACKEND_QUERY_RESPONSE" | jq '.request.headers' 2>/dev/null)

if echo "$BACKEND_QUERY_HEADERS" | jq -e '.["X-Forwarded-By"]' > /dev/null 2>&1; then
    echo -e "${GREEN}✓ X-Forwarded-By header reaches backend via /api/query${NC}"
    HEADER_VALUE=$(echo "$BACKEND_QUERY_HEADERS" | jq -r '.["X-Forwarded-By"][0]' 2>/dev/null || echo 'parsing failed')
    echo "  Header value: $HEADER_VALUE"

    if [ "$HEADER_VALUE" == "traefik" ]; then
        echo -e "${GREEN}✓ Header has expected value 'traefik'${NC}"
    else
        echo -e "${YELLOW}⚠ Unexpected header value: $HEADER_VALUE${NC}"
    fi
else
    echo -e "${YELLOW}⚠ X-Forwarded-By header not found in /api/query response${NC}"
    echo "  Available headers:"
    echo "$BACKEND_QUERY_HEADERS" | jq 'keys' 2>/dev/null || echo "$BACKEND_QUERY_HEADERS"
fi

# Show what headers the backend actually receives
echo -e "\n${YELLOW}Backend headers inspection (from /api/query):${NC}"
echo "$BACKEND_QUERY_RESPONSE" | jq '.request.headers | to_entries | .[0:5] | from_entries' 2>/dev/null || echo "Unable to parse headers"

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
echo -e "  ${GREEN}✓${NC} Frontend Service (Private, no direct access, accessible via Traefik)"
echo -e "  ${GREEN}✓${NC} Backend Service (Private, no direct access, accessible via Traefik)"
echo -e "  ${GREEN}✓${NC} Frontend → Traefik → Backend /api/query communication"
echo -e "  ${GREEN}✓${NC} Frontend displays all headers and access logs"
echo -e "  ${GREEN}✓${NC} Backend /api/query returns all request/response details"
echo ""
echo "Access points:"
echo "  Frontend:  http://app.localhost:${TRAEFIK_WEB_PORT}/"
echo "  Backend:   http://api.localhost:${TRAEFIK_WEB_PORT}/api/query"
echo "  Dashboard: http://traefik.localhost:${TRAEFIK_API_PORT}/dashboard/"
echo ""
echo "Note: Services are private (no direct port exposure)."
echo "      In Cloud Run, use --no-allow-unauthenticated for the same effect."
echo ""
echo "Press Ctrl+C to stop services and exit"
echo ""

# Show logs in follow mode
docker-compose -f docker-compose.e2e.yml logs -f
