package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// sensitiveHeaders lists headers whose values must be sanitized in logs.
// This is test-only code; full values are still returned in JSON responses.
var sensitiveHeaders = map[string]bool{
	"Authorization":              true,
	"X-Serverless-Authorization": true,
}

// sanitizeForLog strips the JWT signature (third segment) from Bearer tokens.
func sanitizeForLog(value string) string {
	v := value
	prefix := ""
	if strings.HasPrefix(v, "Bearer ") {
		prefix = "Bearer "
		v = v[len(prefix):]
	}
	parts := strings.SplitN(v, ".", 3)
	if len(parts) == 3 {
		return prefix + parts[0] + "." + parts[1] + ".<sig-redacted>"
	}
	if len(value) > 40 {
		return value[:20] + "..." + value[len(value)-20:]
	}
	return value
}

// sanitizeHeaderValue returns a log-safe version of a header value.
func sanitizeHeaderValue(name, value string) string {
	if sensitiveHeaders[http.CanonicalHeaderKey(name)] {
		return sanitizeForLog(value)
	}
	return value
}

type QueryResponse struct {
	Request  RequestDetails  `json:"request"`
	Response ResponseDetails `json:"response"`
	Service  ServiceInfo     `json:"service"`
	Timestamp string         `json:"timestamp"`
}

type RequestDetails struct {
	Method      string              `json:"method"`
	Path        string              `json:"path"`
	QueryParams map[string][]string `json:"query_params"`
	Headers     map[string][]string `json:"headers"`
	RemoteAddr  string              `json:"remote_addr"`
	Host        string              `json:"host"`
	URL         string              `json:"url"`
	Body        string              `json:"body,omitempty"`
}

type ResponseDetails struct {
	Status     int               `json:"status"`
	Headers    map[string]string `json:"headers"`
	Size       int               `json:"size"`
	StatusCode string            `json:"status_code"`
}

type ServiceInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Port    string `json:"port"`
}

type FrontendResponse struct {
	FrontendHeaders    map[string][]string `json:"frontend_headers"`
	FrontendAccessLog  []AccessLogEntry    `json:"frontend_access_log"`
	BackendQueryResult QueryResponse        `json:"backend_query_result"`
	FrontendInfo       ServiceInfo          `json:"frontend_info"`
	Timestamp          string               `json:"timestamp"`
}

type AccessLogEntry struct {
	Timestamp   string `json:"timestamp"`
	Method      string `json:"method"`
	Path        string `json:"path"`
	RemoteAddr  string `json:"remote_addr"`
	UserAgent   string `json:"user_agent"`
	Status      int    `json:"status"`
	ResponseTime string `json:"response_time"`
}

// In-memory access log (in production, use proper logging)
var accessLog []AccessLogEntry

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	backendURL := os.Getenv("BACKEND_URL")
	if backendURL == "" {
		backendURL = "http://traefik:80"
	}
	
	backendHost := os.Getenv("BACKEND_HOST")
	if backendHost == "" {
		backendHost = "api.localhost"
	}

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
	})

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		startTime := time.Now()
		log.Printf("Frontend: received request from %s", r.RemoteAddr)

		// Collect all frontend headers (sensitive values sanitized in logs)
		frontendHeaders := make(map[string][]string)
		for name, values := range r.Header {
			frontendHeaders[name] = values
			for _, v := range values {
				log.Printf("Frontend: Header %s = %s", name, sanitizeHeaderValue(name, v))
			}
		}

		// Call backend service via /api/query through Traefik
		backendQueryURL := backendURL + "/api/query"
		log.Printf("Frontend: calling backend at %s with Host: %s", backendQueryURL, backendHost)
		
		req, err := http.NewRequest("GET", backendQueryURL, nil)
		if err != nil {
			log.Printf("Frontend: failed to create request: %v", err)
			http.Error(w, "Failed to create backend request", http.StatusInternalServerError)
			return
		}

		// Set Host header for Traefik routing
		req.Host = backendHost
		req.Header.Set("Host", backendHost)

		// Forward relevant headers to backend
		if requestID := r.Header.Get("X-Request-ID"); requestID != "" {
			req.Header.Set("X-Request-ID", requestID)
		}
		if forwardedFor := r.Header.Get("X-Forwarded-For"); forwardedFor != "" {
			req.Header.Set("X-Forwarded-For", forwardedFor)
		} else {
			req.Header.Set("X-Forwarded-For", r.RemoteAddr)
		}

		client := &http.Client{
			Timeout: 10 * time.Second,
		}
		
		resp, err := client.Do(req)
		if err != nil {
			log.Printf("Frontend: failed to call backend: %v", err)
			http.Error(w, fmt.Sprintf("Failed to reach backend: %v", err), http.StatusServiceUnavailable)
			return
		}
		defer resp.Body.Close()

		body, err := io.ReadAll(resp.Body)
		if err != nil {
			log.Printf("Frontend: failed to read backend response: %v", err)
			http.Error(w, "Failed to read backend response", http.StatusInternalServerError)
			return
		}

		var backendQueryResp QueryResponse
		if err := json.Unmarshal(body, &backendQueryResp); err != nil {
			log.Printf("Frontend: failed to parse backend response: %v", err)
			log.Printf("Frontend: response body: %s", string(body))
			http.Error(w, "Failed to parse backend response", http.StatusInternalServerError)
			return
		}

		// Calculate response time
		responseTime := time.Since(startTime)

		// Add to access log
		accessLogEntry := AccessLogEntry{
			Timestamp:    time.Now().UTC().Format(time.RFC3339),
			Method:        r.Method,
			Path:          r.URL.Path,
			RemoteAddr:    r.RemoteAddr,
			UserAgent:     r.Header.Get("User-Agent"),
			Status:        http.StatusOK,
			ResponseTime:  responseTime.String(),
		}
		accessLog = append(accessLog, accessLogEntry)
		
		// Keep only last 100 entries
		if len(accessLog) > 100 {
			accessLog = accessLog[len(accessLog)-100:]
		}

		// Build response
		response := FrontendResponse{
			FrontendHeaders:   frontendHeaders,
			FrontendAccessLog: accessLog,
			BackendQueryResult: backendQueryResp,
			FrontendInfo: ServiceInfo{
				Name:    "frontend",
				Version: "1.0.0",
				Port:    port,
			},
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if err := json.NewEncoder(w).Encode(response); err != nil {
			log.Printf("Frontend: failed to encode response: %v", err)
		}

		log.Printf("Frontend: request completed in %v", responseTime)
	})

	log.Printf("Frontend service listening on port %s", port)
	log.Printf("Backend URL: %s", backendURL)
	log.Printf("Backend Host: %s", backendHost)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
