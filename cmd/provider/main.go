package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/pci-tamper-protect/traefik-cloudrun-provider/provider"
	"gopkg.in/yaml.v3"
)

const (
	defaultEnvironment   = "stg"
	defaultRegion        = "us-central1"
	defaultOutputFile    = "/etc/traefik/dynamic/routes.yml"
	defaultPollInterval  = 30 * time.Second
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	fmt.Fprintf(os.Stderr, "🚀 Starting traefik-cloudrun-provider at %s\n", time.Now().UTC().Format(time.RFC3339))

	// Load .env file if it exists (optional, silently ignore if not found)
	if err := godotenv.Load(); err != nil {
		// Ignore file not found errors - .env is optional
		// Environment variables can be set directly in Cloud Run
		if !os.IsNotExist(err) {
			log.Printf("Warning: Error loading .env file: %v", err)
		}
	}

	// Load configuration from environment
	config := loadConfig()

	fmt.Fprintf(os.Stderr, "🔍 Generating Traefik routes from Cloud Run service labels...\n")
	fmt.Fprintf(os.Stderr, "   Environment: %s\n", config.Environment)
	fmt.Fprintf(os.Stderr, "   Projects: %v\n", config.ProjectIDs)
	fmt.Fprintf(os.Stderr, "   Region: %s\n", config.Region)
	fmt.Fprintf(os.Stderr, "   Output: %s\n", config.OutputFile)
	fmt.Fprintf(os.Stderr, "   Mode: %s\n", config.Mode)
	if config.Mode == "daemon" {
		fmt.Fprintf(os.Stderr, "   Poll Interval: %s\n", config.PollInterval)
	}
	fmt.Fprintf(os.Stderr, "\n")

	// Create output directory
	if err := os.MkdirAll(getDir(config.OutputFile), 0755); err != nil {
		log.Fatalf("Failed to create output directory: %v", err)
	}

	// Create provider
	providerConfig := &provider.Config{
		ProjectIDs:   config.ProjectIDs,
		Region:       config.Region,
		PollInterval: config.PollInterval,
	}

	p, err := provider.New(providerConfig)
	if err != nil {
		log.Fatalf("Failed to create provider: %v", err)
	}

	if config.Mode == "daemon" {
		runDaemon(p, config)
	} else {
		runOnce(p, config)
	}
}

// runOnce generates configuration once and exits
func runOnce(p *provider.Provider, config *AppConfig) {
	configChan := make(chan *provider.DynamicConfig, 1)
	if err := p.Start(configChan); err != nil {
		log.Fatalf("Failed to start provider: %v", err)
	}

	// Wait for first configuration
	select {
	case dynamicConfig := <-configChan:
		if err := writeRoutes(config.OutputFile, dynamicConfig); err != nil {
			log.Fatalf("Failed to write routes file: %v", err)
		}
		printSummary(config.OutputFile, dynamicConfig)

	case <-time.After(60 * time.Second):
		log.Fatalf("Timeout waiting for configuration")
	}

	if err := p.Stop(); err != nil {
		log.Printf("Warning: Failed to stop provider: %v", err)
	}
}

// runDaemon runs continuously, regenerating routes on interval
func runDaemon(p *provider.Provider, config *AppConfig) {
	fmt.Fprintf(os.Stderr, "🔄 Running in daemon mode (poll every %s)\n", config.PollInterval)

	// Handle graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	configChan := make(chan *provider.DynamicConfig, 1)
	ticker := time.NewTicker(config.PollInterval)
	defer ticker.Stop()

	// Generate initial configuration
	generateAndWrite(p, config, configChan)

	generation := 1
	for {
		select {
		case <-ticker.C:
			generation++
			fmt.Fprintf(os.Stderr, "\n🔄 [Gen %d] Regenerating routes at %s\n", generation, time.Now().Format(time.RFC3339))
			generateAndWrite(p, config, configChan)

		case sig := <-sigChan:
			fmt.Fprintf(os.Stderr, "\n⏹️  Received %s, shutting down...\n", sig)
			if err := p.Stop(); err != nil {
				log.Printf("Warning: Failed to stop provider: %v", err)
			}
			return
		}
	}
}

func generateAndWrite(p *provider.Provider, config *AppConfig, configChan chan *provider.DynamicConfig) {
	if err := p.Start(configChan); err != nil {
		log.Printf("Error starting provider: %v", err)
		return
	}

	select {
	case dynamicConfig := <-configChan:
		if err := writeRoutes(config.OutputFile, dynamicConfig); err != nil {
			log.Printf("Error writing routes file: %v", err)
		} else {
			printSummary(config.OutputFile, dynamicConfig)
		}
	case <-time.After(60 * time.Second):
		log.Printf("Timeout waiting for configuration")
	}

	// Note: Don't stop provider in daemon mode between polls
}

func printSummary(outputFile string, dynamicConfig *provider.DynamicConfig) {
	fmt.Fprintf(os.Stderr, "✅ Routes file generated at %s\n", outputFile)
	fmt.Fprintf(os.Stderr, "📊 Summary: Routers=%d Services=%d Middlewares=%d\n",
		len(dynamicConfig.HTTP.Routers),
		len(dynamicConfig.HTTP.Services),
		len(dynamicConfig.HTTP.Middlewares))
}

type AppConfig struct {
	Environment  string
	ProjectIDs   []string
	Region       string
	OutputFile   string
	Mode         string        // "once" or "daemon"
	PollInterval time.Duration
}

func loadConfig() *AppConfig {
	env := os.Getenv("ENVIRONMENT")
	if env == "" {
		env = defaultEnvironment
	}

	var projectIDs []string

	// Primary project (required)
	primaryProject := os.Getenv("LABS_PROJECT_ID")
	if primaryProject == "" {
		log.Fatalf("LABS_PROJECT_ID environment variable is required")
	}
	projectIDs = append(projectIDs, primaryProject)

	// Secondary project (optional)
	secondaryProject := os.Getenv("HOME_PROJECT_ID")
	if secondaryProject != "" {
		projectIDs = append(projectIDs, secondaryProject)
	}

	region := os.Getenv("REGION")
	if region == "" {
		region = defaultRegion
	}

	outputFile := defaultOutputFile
	if len(os.Args) > 1 {
		outputFile = os.Args[1]
	}

	// Mode: "once" (default) or "daemon"
	mode := os.Getenv("MODE")
	if mode == "" {
		mode = "once"
	}

	// Poll interval for daemon mode
	pollInterval := defaultPollInterval
	if intervalStr := os.Getenv("POLL_INTERVAL"); intervalStr != "" {
		if seconds, err := strconv.Atoi(intervalStr); err == nil {
			pollInterval = time.Duration(seconds) * time.Second
		} else if parsed, err := time.ParseDuration(intervalStr); err == nil {
			pollInterval = parsed
		}
	}

	return &AppConfig{
		Environment:  env,
		ProjectIDs:   projectIDs,
		Region:       region,
		OutputFile:   outputFile,
		Mode:         mode,
		PollInterval: pollInterval,
	}
}

func getDir(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return "."
}

func writeRoutes(outputFile string, config *provider.DynamicConfig) error {
	file, err := os.Create(outputFile)
	if err != nil {
		return fmt.Errorf("failed to create file: %w", err)
	}
	defer file.Close()

	// Write header comment
	fmt.Fprintf(file, "# Auto-generated Traefik routes from Cloud Run service labels\n")
	fmt.Fprintf(file, "# Generated at: %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(file, "# Environment: %s\n", os.Getenv("ENVIRONMENT"))
	fmt.Fprintf(file, "#\n")
	fmt.Fprintf(file, "# This file is generated by traefik-cloudrun-provider\n")
	fmt.Fprintf(file, "# Labels follow the same format as docker-compose.yml\n\n")

	// Write YAML
	encoder := yaml.NewEncoder(file)
	encoder.SetIndent(2)
	if err := encoder.Encode(config); err != nil {
		return fmt.Errorf("failed to encode YAML: %w", err)
	}

	return encoder.Close()
}
