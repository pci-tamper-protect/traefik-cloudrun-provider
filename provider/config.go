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
func (c *DynamicConfig) AddAuthMiddleware(name, token string) {
	mw := MiddlewareConfig{
		Headers: &HeadersConfig{
			CustomRequestHeaders: make(map[string]string),
		},
	}

	if token != "" {
		mw.Headers.CustomRequestHeaders["Authorization"] = fmt.Sprintf("Bearer %s", token)
	} else {
		mw.Headers.CustomRequestHeaders["Authorization"] = "Bearer TOKEN_FETCH_FAILED"
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
