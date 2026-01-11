#!/bin/bash
# debug-headers.sh - Debug header propagation in deployed Traefik
# Usage: ./debug-headers.sh [traefik-url]
#   Example: ./debug-headers.sh https://your-traefik.example.com:8081

set -e

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | grep -v '^$' | sed 's/#.*//' | xargs)
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TRAEFIK_API_PORT=${TRAEFIK_API_PORT:-8091}
TRAEFIK_URL="${1:-http://localhost:${TRAEFIK_API_PORT}}"

echo -e "${BLUE}🔍 Traefik Header Debugging Tool${NC}"
echo "=================================================="
echo ""
echo "Target: $TRAEFIK_URL"
echo ""

# Function to check if URL is accessible
check_url() {
    local url=$1
    if curl -s -f -o /dev/null "$url"; then
        return 0
    else
        return 1
    fi
}

# Test 1: Check Traefik API is accessible
echo -e "${BLUE}Test 1: Traefik API Accessibility${NC}"
if check_url "$TRAEFIK_URL/api/version"; then
    VERSION=$(curl -s "$TRAEFIK_URL/api/version")
    echo -e "${GREEN}✓ Traefik API is accessible${NC}"
    echo "  Version: $(echo "$VERSION" | jq -r '.Version' 2>/dev/null || echo 'unknown')"
else
    echo -e "${RED}✗ Traefik API not accessible at $TRAEFIK_URL${NC}"
    echo "  Make sure Traefik API is enabled and accessible"
    echo "  Try: --api.insecure=true (for debugging only)"
    exit 1
fi

# Test 2: List all routers
echo -e "\n${BLUE}Test 2: Configured Routers${NC}"
ROUTERS=$(curl -s "$TRAEFIK_URL/api/http/routers" | jq -r '.[].name' 2>/dev/null || echo "")
if [ -z "$ROUTERS" ]; then
    echo -e "${RED}✗ No routers found or unable to parse${NC}"
else
    echo -e "${GREEN}✓ Found $(echo "$ROUTERS" | wc -l | tr -d ' ') routers${NC}"
    echo "$ROUTERS" | while read -r router; do
        echo "  - $router"
    done
fi

# Test 3: List all middlewares
echo -e "\n${BLUE}Test 3: Configured Middlewares${NC}"
MIDDLEWARES=$(curl -s "$TRAEFIK_URL/api/http/middlewares")
MW_COUNT=$(echo "$MIDDLEWARES" | jq -r '.[].name' 2>/dev/null | wc -l | tr -d ' ')

if [ "$MW_COUNT" -eq 0 ]; then
    echo -e "${RED}✗ No middlewares found${NC}"
    echo -e "${YELLOW}  This is the problem! The provider should create middlewares.${NC}"
else
    echo -e "${GREEN}✓ Found $MW_COUNT middlewares${NC}"
    echo "$MIDDLEWARES" | jq -r '.[].name' 2>/dev/null | while read -r mw; do
        echo "  - $mw"
    done
fi

# Test 4: Check for auth middlewares specifically
echo -e "\n${BLUE}Test 4: Authentication Middlewares${NC}"
AUTH_MIDDLEWARES=$(echo "$MIDDLEWARES" | jq -r '.[] | select(.name | contains("-auth")) | .name' 2>/dev/null || echo "")
if [ -z "$AUTH_MIDDLEWARES" ]; then
    echo -e "${RED}✗ No authentication middlewares found${NC}"
    echo -e "${YELLOW}  Expected middlewares with '-auth' suffix${NC}"
    echo -e "${YELLOW}  These should contain X-Serverless-Authorization headers${NC}"
else
    echo -e "${GREEN}✓ Found authentication middlewares:${NC}"
    echo "$AUTH_MIDDLEWARES" | while read -r mw; do
        echo "  - $mw"
    done
fi

# Test 5: Inspect middleware details
echo -e "\n${BLUE}Test 5: Middleware Header Configuration${NC}"
if [ -n "$AUTH_MIDDLEWARES" ]; then
    echo "$AUTH_MIDDLEWARES" | head -1 | while read -r mw; do
        echo -e "${YELLOW}Inspecting: $mw${NC}"
        MW_DETAIL=$(curl -s "$TRAEFIK_URL/api/http/middlewares/$mw")

        # Check for custom headers
        if echo "$MW_DETAIL" | jq -e '.headers.customRequestHeaders' > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Custom request headers configured${NC}"
            echo "$MW_DETAIL" | jq '.headers.customRequestHeaders' 2>/dev/null

            # Check specifically for X-Serverless-Authorization
            if echo "$MW_DETAIL" | jq -e '.headers.customRequestHeaders["X-Serverless-Authorization"]' > /dev/null 2>&1; then
                echo -e "${GREEN}✓ X-Serverless-Authorization header is configured${NC}"
                TOKEN_PREVIEW=$(echo "$MW_DETAIL" | jq -r '.headers.customRequestHeaders["X-Serverless-Authorization"]' | head -c 30)
                echo "  Token preview: ${TOKEN_PREVIEW}..."
            else
                echo -e "${RED}✗ X-Serverless-Authorization header NOT configured${NC}"
            fi
        else
            echo -e "${RED}✗ No custom request headers found in middleware${NC}"
        fi
    done
else
    echo -e "${YELLOW}⚠ Skipping - no auth middlewares to inspect${NC}"
fi

# Test 6: Check router-middleware associations
echo -e "\n${BLUE}Test 6: Router-Middleware Associations${NC}"
ROUTER_DETAILS=$(curl -s "$TRAEFIK_URL/api/http/routers")
echo "$ROUTER_DETAILS" | jq -r '.[] | select(.middlewares != null) | "\(.name): \(.middlewares | join(", "))"' 2>/dev/null | head -5 | while read -r line; do
    echo "  $line"
done

# Test 7: Check provider source
echo -e "\n${BLUE}Test 7: Provider Sources${NC}"
PROVIDERS=$(echo "$ROUTER_DETAILS" | jq -r '.[].provider' 2>/dev/null | sort -u)
if [ -z "$PROVIDERS" ]; then
    echo -e "${YELLOW}⚠ Unable to determine providers${NC}"
else
    echo -e "${GREEN}✓ Active providers:${NC}"
    echo "$PROVIDERS" | while read -r provider; do
        echo "  - $provider"
    done

    # Check if using Docker provider (e2e test) vs File/Plugin provider (actual provider)
    if echo "$PROVIDERS" | grep -q "docker"; then
        echo ""
        echo -e "${YELLOW}📝 NOTE: Using Docker provider (@docker)${NC}"
        echo "   This is the e2e architecture test (docker-compose.e2e.yml)"
        echo "   It tests Traefik routing but NOT the Cloud Run provider plugin"
        echo "   Auth middlewares are named 'backend-headers@docker' not 'X-auth@file'"
        echo ""
        echo "   To test the actual Cloud Run provider, run:"
        echo "   ./test-docker.sh"
    elif echo "$PROVIDERS" | grep -q "file"; then
        echo ""
        echo -e "${GREEN}✓ Using File provider (@file)${NC}"
        echo "   This is the actual Cloud Run provider generating configuration"
    fi
fi

# Summary
echo -e "\n${BLUE}================================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}================================================${NC}"

# Check if this is Docker provider (e2e test)
if echo "$PROVIDERS" | grep -q "docker"; then
    echo -e "${YELLOW}ℹ️  Docker Provider Mode Detected${NC}"
    echo ""
    echo "You're running the e2e architecture test (docker-compose.e2e.yml)"
    echo "This test validates Traefik routing but uses Docker labels, not the Cloud Run provider."
    echo ""
    echo -e "${GREEN}To test the actual Cloud Run provider:${NC}"
    echo "  1. Stop this test: docker-compose -f docker-compose.e2e.yml down"
    echo "  2. Run provider test: ./test-docker.sh"
    echo "  3. Run debug script again: ./debug-headers.sh http://localhost:8091"
    echo ""
    echo "The provider test will:"
    echo "  - Generate routes.yml from real Cloud Run services"
    echo "  - Create auth middlewares with X-Serverless-Authorization"
    echo "  - Show token generation in logs"
elif [ "$MW_COUNT" -eq 0 ]; then
    echo -e "${RED}⚠️  PROBLEM IDENTIFIED: No middlewares configured!${NC}"
    echo ""
    echo "Likely causes:"
    echo "  1. Provider plugin not running or not generating config"
    echo "  2. Plugin not being loaded by Traefik"
    echo "  3. Token generation failing (check provider logs)"
    echo ""
    echo "Next steps:"
    echo "  - Check Traefik logs for plugin loading messages"
    echo "  - Check provider logs for token generation errors"
    echo "  - Verify plugin configuration in traefik static config"
elif [ -z "$AUTH_MIDDLEWARES" ]; then
    echo -e "${YELLOW}⚠️  Middlewares exist but no auth middlewares found${NC}"
    echo ""
    echo "Next steps:"
    echo "  - Check if services have 'traefik_enable=true' label"
    echo "  - Check provider logs for service discovery"
else
    echo -e "${GREEN}✓ Configuration looks good${NC}"
    echo ""
    echo "If headers still not working in production:"
    echo "  - Check backend logs to see what headers are received"
    echo "  - Verify Cloud Run service is using the correct middleware"
    echo "  - Check Traefik access logs for request flow"
fi

echo ""
