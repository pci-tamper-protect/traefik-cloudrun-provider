package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// Response structure for JSON responses
type Response struct {
	Message   string            `json:"message"`
	Service   string            `json:"service"`
	Timestamp string            `json:"timestamp"`
	Headers   map[string]string `json:"headers,omitempty"`
	Auth      *AuthInfo         `json:"auth,omitempty"`
}

// AuthInfo contains authentication details
type AuthInfo struct {
	Authenticated bool   `json:"authenticated"`
	Method        string `json:"method"`
	TokenPreview  string `json:"token_preview,omitempty"`
	Error         string `json:"error,omitempty"`
}

func main() {
	serviceName := getEnv("SERVICE_NAME", "mock-cloudrun-service")
	port := getEnv("PORT", "8080")

	http.HandleFunc("/", handleRoot)
	http.HandleFunc("/health", handleHealth)
	http.HandleFunc("/debug/headers", handleHeaderDebug)
	http.HandleFunc("/api/", handleAPI)

	log.Printf("🚀 Mock Cloud Run Service '%s' starting on port %s", serviceName, port)
	log.Printf("📍 Endpoints:")
	log.Printf("   GET  /              - Main endpoint")
	log.Printf("   GET  /health        - Health check")
	log.Printf("   GET  /debug/headers - Show all headers")
	log.Printf("   GET  /api/*         - API endpoints")
	log.Printf("")
	log.Printf("🔐 Authentication: Validates X-Serverless-Authorization header")
	log.Printf("")

	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	serviceName := getEnv("SERVICE_NAME", "mock-cloudrun-service")

	// Log the request
	logRequest(r, "ROOT")

	// Check authentication
	authInfo := validateAuth(r)

	response := Response{
		Message:   fmt.Sprintf("Hello from %s", serviceName),
		Service:   serviceName,
		Timestamp: time.Now().Format(time.RFC3339),
		Auth:      authInfo,
	}

	w.Header().Set("Content-Type", "application/json")
	if !authInfo.Authenticated {
		w.WriteHeader(http.StatusUnauthorized)
	}
	json.NewEncoder(w).Encode(response)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	response := Response{
		Message:   "healthy",
		Service:   getEnv("SERVICE_NAME", "mock-cloudrun-service"),
		Timestamp: time.Now().Format(time.RFC3339),
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func handleHeaderDebug(w http.ResponseWriter, r *http.Request) {
	logRequest(r, "HEADER_DEBUG")

	headers := make(map[string]string)
	for name, values := range r.Header {
		headers[name] = strings.Join(values, ", ")
	}

	authInfo := validateAuth(r)

	response := Response{
		Message:   "Header inspection",
		Service:   getEnv("SERVICE_NAME", "mock-cloudrun-service"),
		Timestamp: time.Now().Format(time.RFC3339),
		Headers:   headers,
		Auth:      authInfo,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func handleAPI(w http.ResponseWriter, r *http.Request) {
	logRequest(r, "API")

	authInfo := validateAuth(r)

	response := Response{
		Message:   fmt.Sprintf("API endpoint: %s", r.URL.Path),
		Service:   getEnv("SERVICE_NAME", "mock-cloudrun-service"),
		Timestamp: time.Now().Format(time.RFC3339),
		Auth:      authInfo,
	}

	w.Header().Set("Content-Type", "application/json")
	if !authInfo.Authenticated {
		w.WriteHeader(http.StatusUnauthorized)
	}
	json.NewEncoder(w).Encode(response)
}

// validateAuth checks for X-Serverless-Authorization or Authorization header
func validateAuth(r *http.Request) *AuthInfo {
	info := &AuthInfo{
		Authenticated: false,
	}

	// Check X-Serverless-Authorization first (Cloud Run service-to-service)
	if token := r.Header.Get("X-Serverless-Authorization"); token != "" {
		info.Method = "X-Serverless-Authorization"
		if strings.HasPrefix(token, "Bearer ") {
			tokenValue := strings.TrimPrefix(token, "Bearer ")
			info.TokenPreview = truncateToken(tokenValue)

			// In a real service, you would validate the JWT token here
			// For simulation, we just check it looks like a JWT
			if strings.Count(tokenValue, ".") == 2 {
				info.Authenticated = true
			} else {
				info.Error = "Invalid token format (not a JWT)"
			}
		} else {
			info.Error = "Token must start with 'Bearer '"
		}
		return info
	}

	// Check Authorization header (user authentication)
	if token := r.Header.Get("Authorization"); token != "" {
		info.Method = "Authorization"
		if strings.HasPrefix(token, "Bearer ") {
			tokenValue := strings.TrimPrefix(token, "Bearer ")
			info.TokenPreview = truncateToken(tokenValue)
			info.Authenticated = true // Accept for testing
		} else {
			info.Error = "Token must start with 'Bearer '"
		}
		return info
	}

	info.Error = "No authentication header present"
	return info
}

// truncateToken shows first 20 and last 20 characters of a token
func truncateToken(token string) string {
	if len(token) <= 40 {
		return token
	}
	return token[:20] + "..." + token[len(token)-20:]
}

// logRequest logs incoming requests with authentication details
func logRequest(r *http.Request, endpoint string) {
	authHeader := r.Header.Get("X-Serverless-Authorization")
	userAuthHeader := r.Header.Get("Authorization")

	authStatus := "❌ No Auth"
	if authHeader != "" {
		authStatus = "✅ X-Serverless-Authorization"
	} else if userAuthHeader != "" {
		authStatus = "👤 Authorization (user)"
	}

	log.Printf("[%s] %s %s | %s | From: %s",
		endpoint,
		r.Method,
		r.URL.Path,
		authStatus,
		r.RemoteAddr,
	)
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
