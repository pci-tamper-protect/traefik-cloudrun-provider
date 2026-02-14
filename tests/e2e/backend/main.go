package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

type Response struct {
	Message string `json:"message"`
	Service string `json:"service"`
	Version string `json:"version"`
}

type QueryResponse struct {
	Request  RequestDetails  `json:"request"`
	Response ResponseDetails `json:"response"`
	Service  ServiceInfo    `json:"service"`
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

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
	})

	// Debug endpoint to inspect headers
	http.HandleFunc("/debug/headers", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Backend: DEBUG - received request from %s", r.RemoteAddr)

		// Log all headers
		log.Println("Backend: All headers received:")
		for name, values := range r.Header {
			for _, value := range values {
				log.Printf("  %s: %s", name, value)
			}
		}

		// Return headers as JSON
		headers := make(map[string][]string)
		for name, values := range r.Header {
			headers[name] = values
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"headers": headers,
			"path":    r.URL.Path,
			"method":  r.Method,
			"remote":  r.RemoteAddr,
		})
	})

	// /api/query endpoint - returns all request and response details
	http.HandleFunc("/api/query", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Backend: /api/query - received request from %s", r.RemoteAddr)

		// Read request body if present
		var bodyStr string
		if r.Body != nil {
			bodyBytes, err := io.ReadAll(r.Body)
			if err == nil {
				bodyStr = string(bodyBytes)
				// Restore body for potential future reads
				r.Body = io.NopCloser(bytes.NewReader(bodyBytes))
			}
		}

		// Collect all headers
		headers := make(map[string][]string)
		for name, values := range r.Header {
			headers[name] = values
			log.Printf("Backend: Header %s = %v", name, values)
		}

		// Collect query parameters
		queryParams := make(map[string][]string)
		for key, values := range r.URL.Query() {
			queryParams[key] = values
		}

		// Build request details
		requestDetails := RequestDetails{
			Method:      r.Method,
			Path:        r.URL.Path,
			QueryParams: queryParams,
			Headers:     headers,
			RemoteAddr:  r.RemoteAddr,
			Host:        r.Host,
			URL:         r.URL.String(),
			Body:        bodyStr,
		}

		// Prepare response headers
		responseHeaders := map[string]string{
			"Content-Type": "application/json",
			"X-Service":    "backend-api",
		}
		if requestID := r.Header.Get("X-Request-ID"); requestID != "" {
			responseHeaders["X-Request-ID"] = requestID
		}

		// Set response headers
		for name, value := range responseHeaders {
			w.Header().Set(name, value)
		}

		// Prepare response
		responseData := QueryResponse{
			Request: requestDetails,
			Response: ResponseDetails{
				Status:     http.StatusOK,
				StatusCode: "200 OK",
				Headers:    responseHeaders,
			},
			Service: ServiceInfo{
				Name:    "backend",
				Version: "1.0.0",
				Port:    port,
			},
			Timestamp: time.Now().UTC().Format(time.RFC3339),
		}

		// Marshal response to get size
		responseJSON, err := json.Marshal(responseData)
		if err != nil {
			log.Printf("Backend: failed to marshal response: %v", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		responseData.Response.Size = len(responseJSON)

		// Write response
		w.WriteHeader(http.StatusOK)
		if _, err := w.Write(responseJSON); err != nil {
			log.Printf("Backend: failed to write response: %v", err)
		}

		log.Printf("Backend: /api/query - responded with %d bytes", len(responseJSON))
	})

	// Keep /api/hello for backward compatibility
	http.HandleFunc("/api/hello", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Backend: received request from %s", r.RemoteAddr)

		// Log auth headers specifically
		if authHeader := r.Header.Get("Authorization"); authHeader != "" {
			log.Printf("Backend: Authorization header present (length: %d)", len(authHeader))
		}
		if serverlessAuth := r.Header.Get("X-Serverless-Authorization"); serverlessAuth != "" {
			log.Printf("Backend: X-Serverless-Authorization header present (length: %d)", len(serverlessAuth))
		} else {
			log.Printf("Backend: ⚠️  X-Serverless-Authorization header NOT present")
		}

		response := Response{
			Message: "Hello from Backend!",
			Service: "backend",
			Version: "1.0.0",
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
	})

	log.Printf("Backend service listening on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
