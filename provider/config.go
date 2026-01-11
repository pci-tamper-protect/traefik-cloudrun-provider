package provider

import (
	"fmt"
)

// DynamicConfig represents the Traefik dynamic configuration
type DynamicConfig struct {
	HTTP HTTPConfig `yaml:"http"`
}

// HTTPConfig represents HTTP-level configuration
type HTTPConfig struct {
	Routers     map[string]RouterConfig     `yaml:"routers"`
	Services    map[string]ServiceConfig    `yaml:"services"`
	Middlewares map[string]MiddlewareConfig `yaml:"middlewares"`
}

// MiddlewareConfig represents a Traefik middleware configuration
type MiddlewareConfig struct {
	Headers *HeadersConfig `yaml:"headers,omitempty"`
}

// HeadersConfig represents headers middleware configuration
type HeadersConfig struct {
	CustomRequestHeaders map[string]string `yaml:"customRequestHeaders,omitempty"`
}

// NewDynamicConfig creates a new dynamic configuration
func NewDynamicConfig() *DynamicConfig {
	return &DynamicConfig{
		HTTP: HTTPConfig{
			Routers:     make(map[string]RouterConfig),
			Services:    make(map[string]ServiceConfig),
			Middlewares: make(map[string]MiddlewareConfig),
		},
	}
}

// AddRouter adds a router to the configuration
func (c *DynamicConfig) AddRouter(name string, config RouterConfig) {
	c.HTTP.Routers[name] = config
}

// AddService adds a service to the configuration
func (c *DynamicConfig) AddService(name string, config ServiceConfig) {
	c.HTTP.Services[name] = config
}

// AddAuthMiddleware adds an authentication middleware with token
// Uses X-Serverless-Authorization header for service-to-service auth to avoid conflicts
// with user's Authorization header (Firebase token).
//
// According to Cloud Run docs:
// https://docs.cloud.google.com/run/docs/authenticating/service-to-service
// Cloud Run accepts identity tokens in either:
// - Authorization: Bearer ID_TOKEN header, OR
// - X-Serverless-Authorization: Bearer ID_TOKEN header
//
// Using X-Serverless-Authorization allows:
// - User's Authorization header (Firebase token) to pass through unchanged
// - Service-to-service auth via X-Serverless-Authorization
// - No header conflicts or middleware ordering concerns
func (c *DynamicConfig) AddAuthMiddleware(name, token string) {
	mw := MiddlewareConfig{
		Headers: &HeadersConfig{
			CustomRequestHeaders: make(map[string]string),
		},
	}

	if token != "" {
		// Use X-Serverless-Authorization to avoid conflicts with user's Authorization header
		// Cloud Run will check this header for service-to-service authentication
		// If both Authorization and X-Serverless-Authorization are present, Cloud Run
		// only checks X-Serverless-Authorization (per Cloud Run docs)
		mw.Headers.CustomRequestHeaders["X-Serverless-Authorization"] = fmt.Sprintf("Bearer %s", token)

		// Log successful middleware creation with token info
		tokenLen := len(token)
		tokenPreview := "empty"
		if tokenLen > 10 {
			tokenPreview = token[:10] + "..."
		} else if tokenLen > 0 {
			tokenPreview = token[:tokenLen]
		}
		fmt.Printf("[ConfigBuilder] ✅ Created auth middleware '%s' with X-Serverless-Authorization header (token length: %d, preview: %s)\n",
			name, tokenLen, tokenPreview)
	} else {
		// Don't set invalid token - let service return 401 naturally
		// This allows proper error handling
		fmt.Printf("[ConfigBuilder] ⚠️  Created auth middleware '%s' WITHOUT token (will not set X-Serverless-Authorization header)\n", name)
	}

	c.HTTP.Middlewares[name] = mw
}

// AddTraefikInternalRouters adds Traefik API and Dashboard routers
func (c *DynamicConfig) AddTraefikInternalRouters() {
	// Traefik API
	c.HTTP.Routers["traefik-api"] = RouterConfig{
		Rule:        "PathPrefix(`/api/http`) || PathPrefix(`/api/rawdata`) || PathPrefix(`/api/overview`) || Path(`/api/version`)",
		Service:     "api@internal",
		Priority:    1000,
		EntryPoints: []string{"web"},
	}

	// Traefik Dashboard
	c.HTTP.Routers["traefik-dashboard"] = RouterConfig{
		Rule:        "PathPrefix(`/dashboard`)",
		Service:     "api@internal",
		Priority:    1000,
		EntryPoints: []string{"web"},
	}
}
