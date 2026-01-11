package provider

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/kestenbroughton/traefik-cloudrun-provider/internal/gcp"
	"github.com/kestenbroughton/traefik-cloudrun-provider/internal/logging"
	run "google.golang.org/api/run/v1"
)

// Config represents the provider configuration
type Config struct {
	// GCP Configuration
	ProjectIDs   []string      // List of GCP project IDs to monitor
	Region       string        // GCP region (e.g., "us-central1")
	PollInterval time.Duration // How often to poll Cloud Run API

	// Optional: Eventarc configuration (future)
	EventarcEnabled bool
	EventarcTopic   string

	// Token cache settings
	TokenRefreshBefore time.Duration // Refresh tokens this long before expiry
}

// Provider implements the Traefik provider interface for Cloud Run
type Provider struct {
	config       *Config
	runService   *run.APIService
	tokenManager *gcp.TokenManager
	logger       *logging.Logger
	stopChan     chan struct{}
}

// New creates a new Cloud Run provider
func New(config *Config) (*Provider, error) {
	if config == nil {
		return nil, fmt.Errorf("config cannot be nil")
	}

	// Validate configuration
	if len(config.ProjectIDs) == 0 {
		return nil, fmt.Errorf("at least one project ID must be specified")
	}
	if config.Region == "" {
		return nil, fmt.Errorf("region must be specified")
	}
	if config.PollInterval == 0 {
		config.PollInterval = 30 * time.Second
	}

	// Setup logger
	logLevel := logging.LevelInfo
	if level := os.Getenv("LOG_LEVEL"); level != "" {
		if parsed, err := logging.ParseLevel(level); err == nil {
			logLevel = parsed
		}
	}

	logFormat := logging.FormatText
	if format := os.Getenv("LOG_FORMAT"); format != "" {
		if parsed, err := logging.ParseFormat(format); err == nil {
			logFormat = parsed
		}
	}

	logger := logging.New(&logging.Config{
		Level:  logLevel,
		Format: logFormat,
		Output: os.Stdout,
	}).WithPrefix("CloudRunProvider")

	logger.Info("Initializing Cloud Run provider",
		logging.Any("projects", config.ProjectIDs),
		logging.String("region", config.Region),
		logging.Duration("pollInterval", config.PollInterval),
	)

	// Initialize Cloud Run client
	ctx := context.Background()
	runService, err := run.NewService(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to create Cloud Run service: %w", err)
	}

	logger.Debug("Cloud Run API client initialized")

	tokenManager := gcp.NewTokenManager()
	if tokenManager.IsDevMode() {
		logger.Warn("Running in development mode - will use ADC for tokens if metadata server unavailable")
	}

	return &Provider{
		config:       config,
		runService:   runService,
		tokenManager: tokenManager,
		logger:       logger,
		stopChan:     make(chan struct{}),
	}, nil
}

// Start begins polling for Cloud Run services and generating configurations
func (p *Provider) Start(configChan chan<- *DynamicConfig) error {
	p.logger.Info("Starting provider", logging.Duration("pollInterval", p.config.PollInterval))

	// Generate initial configuration
	p.logger.Debug("Generating initial configuration")
	if err := p.updateConfig(configChan); err != nil {
		return fmt.Errorf("failed to generate initial config: %w", err)
	}

	p.logger.Info("Initial configuration generated successfully")

	// Start polling loop
	go p.pollLoop(configChan)

	return nil
}

// Stop stops the provider
func (p *Provider) Stop() error {
	close(p.stopChan)
	p.logger.Info("Provider stopped")
	return nil
}

// pollLoop polls Cloud Run API at configured intervals
func (p *Provider) pollLoop(configChan chan<- *DynamicConfig) {
	ticker := time.NewTicker(p.config.PollInterval)
	defer ticker.Stop()

	pollCount := 0
	for {
		select {
		case <-ticker.C:
			pollCount++
			p.logger.Debug("Polling for configuration updates", logging.Int("pollCount", pollCount))

			if err := p.updateConfig(configChan); err != nil {
				p.logger.Error("Failed to update configuration", logging.Error(err))
			}
		case <-p.stopChan:
			p.logger.Debug("Stopping poll loop")
			return
		}
	}
}

// updateConfig discovers services and generates Traefik configuration
func (p *Provider) updateConfig(configChan chan<- *DynamicConfig) error {
	startTime := time.Now()
	config := NewDynamicConfig()

	totalServices := 0

	// Discover services from all configured projects
	for _, projectID := range p.config.ProjectIDs {
		p.logger.Debug("Listing services in project", logging.String("project", projectID))

		services, err := p.listServices(p.runService, projectID, p.config.Region)
		if err != nil {
			p.logger.Warn("Failed to list services in project",
				logging.String("project", projectID),
				logging.Error(err),
			)
			continue
		}

		totalServices += len(services)
		p.logger.Info("Discovered services",
			logging.String("project", projectID),
			logging.Int("count", len(services)),
		)

		for _, service := range services {
			if err := p.processService(service, config); err != nil {
				p.logger.Warn("Failed to process service",
					logging.String("service", service.Name),
					logging.String("project", projectID),
					logging.Error(err),
				)
				continue
			}
		}
	}

	// Add Traefik API/Dashboard routers
	config.AddTraefikInternalRouters()

	duration := time.Since(startTime)
	p.logger.Info("Configuration generation complete",
		logging.Int("totalServices", totalServices),
		logging.Int("routers", len(config.HTTP.Routers)),
		logging.Int("services", len(config.HTTP.Services)),
		logging.Int("middlewares", len(config.HTTP.Middlewares)),
		logging.Duration("duration", duration),
	)

	// Send configuration to Traefik
	configChan <- config

	return nil
}

// processService processes a single Cloud Run service and adds it to the configuration
func (p *Provider) processService(service CloudRunService, config *DynamicConfig) error {
	p.logger.Debug("Processing service",
		logging.String("name", service.Name),
		logging.String("project", service.ProjectID),
		logging.String("url", service.URL),
	)

	// Extract router configs from labels
	routerConfigs := extractRouterConfigs(service.Labels, service.Name)
	if len(routerConfigs) == 0 {
		return fmt.Errorf("no router labels found")
	}

	p.logger.Debug("Extracted router configurations",
		logging.String("service", service.Name),
		logging.Int("routerCount", len(routerConfigs)),
	)

	// Determine service name from labels
	serviceNameFromLabel := service.Name
	for _, router := range routerConfigs {
		if router.Service != "" {
			serviceNameFromLabel = router.Service
			break
		}
	}

	// Get identity token for service
	serviceToken, err := p.tokenManager.GetToken(service.URL)
	if err != nil {
		p.logger.Warn("Failed to fetch identity token for service",
			logging.String("service", service.Name),
			logging.Error(err),
		)
		// Continue without token - middleware will have error marker
	} else {
		p.logger.Debug("Fetched identity token",
			logging.String("service", service.Name),
			logging.Int("tokenLength", len(serviceToken)),
		)
	}

	// Create auth middleware
	authMiddlewareName := fmt.Sprintf("%s-auth", serviceNameFromLabel)
	config.AddAuthMiddleware(authMiddlewareName, serviceToken)

	// Add routers (with auth middleware and retry middleware)
	for routerName, routerConfig := range routerConfigs {
		// Add auth middleware if not already present
		hasAuth := false
		for _, mw := range routerConfig.Middlewares {
			if mw == authMiddlewareName || mw == fmt.Sprintf("%s@file", authMiddlewareName) {
				hasAuth = true
				break
			}
		}
		if !hasAuth {
			routerConfig.Middlewares = append(routerConfig.Middlewares, authMiddlewareName)
		}

		// Always add retry middleware for cold starts
		hasRetry := false
		for _, mw := range routerConfig.Middlewares {
			if mw == "retry-cold-start@file" {
				hasRetry = true
				break
			}
		}
		if !hasRetry {
			routerConfig.Middlewares = append(routerConfig.Middlewares, "retry-cold-start@file")
		}

		config.AddRouter(routerName, routerConfig)
	}

	// Add service definition
	serviceConfig := ServiceConfig{
		LoadBalancer: LoadBalancerConfig{
			Servers:        []ServerConfig{{URL: service.URL}},
			PassHostHeader: false,
		},
	}
	config.AddService(serviceNameFromLabel, serviceConfig)

	p.logger.Debug("Service processed successfully",
		logging.String("service", service.Name),
		logging.String("serviceName", serviceNameFromLabel),
	)

	return nil
}
