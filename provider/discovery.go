package provider

import (
	"fmt"

	run "google.golang.org/api/run/v1"
)

// CloudRunService represents a discovered Cloud Run service with Traefik labels
type CloudRunService struct {
	Name      string
	URL       string
	ProjectID string
	Region    string
	Labels    map[string]string
}

// listServices lists Cloud Run services with traefik_enable=true label
// Extracted from cmd/generate-routes/main.go:237-275
func (p *Provider) listServices(runService *run.APIService, projectID, region string) ([]CloudRunService, error) {
	parent := fmt.Sprintf("projects/%s/locations/%s", projectID, region)

	var services []CloudRunService
	pageToken := ""

	for {
		call := runService.Projects.Locations.Services.List(parent)
		if pageToken != "" {
			call = call.Continue(pageToken)
		}

		resp, err := call.Do()
		if err != nil {
			return nil, fmt.Errorf("failed to list services in %s/%s: %w", projectID, region, err)
		}

		if resp.Items != nil {
			for _, svc := range resp.Items {
				// Check if service has traefik_enable=true label
				if svc.Spec != nil && svc.Spec.Template != nil && svc.Spec.Template.Metadata != nil {
					if svc.Spec.Template.Metadata.Labels != nil {
						if enabled, ok := svc.Spec.Template.Metadata.Labels["traefik_enable"]; ok && enabled == "true" {
							services = append(services, CloudRunService{
								Name:      svc.Metadata.Name,
								URL:       svc.Status.Url,
								ProjectID: projectID,
								Region:    region,
								Labels:    svc.Spec.Template.Metadata.Labels,
							})
						}
					}
				}
			}
		}

		// Check for next page token in metadata
		if resp.Metadata == nil || resp.Metadata.Continue == "" {
			break
		}
		pageToken = resp.Metadata.Continue
	}

	return services, nil
}

// getServiceDetails gets detailed information about a single Cloud Run service
func (p *Provider) getServiceDetails(runService *run.APIService, projectID, region, serviceName string) (*run.Service, error) {
	parent := fmt.Sprintf("projects/%s/locations/%s/services/%s", projectID, region, serviceName)
	service, err := runService.Projects.Locations.Services.Get(parent).Do()
	if err != nil {
		return nil, fmt.Errorf("failed to get service %s: %w", serviceName, err)
	}
	return service, nil
}
