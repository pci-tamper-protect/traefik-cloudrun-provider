package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sort"
	"time"
)

type HeaderInspection struct {
	Timestamp   string              `json:"timestamp"`
	Method      string              `json:"method"`
	Path        string              `json:"path"`
	RemoteAddr  string              `json:"remote_addr"`
	Headers     map[string][]string `json:"headers"`
	AuthHeaders AuthHeaders         `json:"auth_headers"`
}

type AuthHeaders struct {
	Authorization              string `json:"authorization,omitempty"`
	XServerlessAuthorization   string `json:"x_serverless_authorization,omitempty"`
	XForwardedFor              string `json:"x_forwarded_for,omitempty"`
	XForwardedHost             string `json:"x_forwarded_host,omitempty"`
	XForwardedProto            string `json:"x_forwarded_proto,omitempty"`
	XRealIP                    string `json:"x_real_ip,omitempty"`
}

func main() {
	port := getEnv("PORT", "8080")

	http.HandleFunc("/", handleInspect)
	http.HandleFunc("/health", handleHealth)

	log.Printf("🔍 Header Inspector Service starting on port %s", port)
	log.Printf("📍 Endpoints:")
	log.Printf("   GET/POST  /       - Inspect all headers")
	log.Printf("   GET       /health - Health check")
	log.Printf("")

	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func handleInspect(w http.ResponseWriter, r *http.Request) {
	inspection := HeaderInspection{
		Timestamp:  time.Now().Format(time.RFC3339),
		Method:     r.Method,
		Path:       r.URL.Path,
		RemoteAddr: r.RemoteAddr,
		Headers:    r.Header,
		AuthHeaders: AuthHeaders{
			Authorization:            r.Header.Get("Authorization"),
			XServerlessAuthorization: r.Header.Get("X-Serverless-Authorization"),
			XForwardedFor:            r.Header.Get("X-Forwarded-For"),
			XForwardedHost:           r.Header.Get("X-Forwarded-Host"),
			XForwardedProto:          r.Header.Get("X-Forwarded-Proto"),
			XRealIP:                  r.Header.Get("X-Real-Ip"),
		},
	}

	// Log to console
	logInspection(inspection)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(inspection)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":    "healthy",
		"timestamp": time.Now().Format(time.RFC3339),
	})
}

func logInspection(inspection HeaderInspection) {
	log.Printf("========================================")
	log.Printf("📨 Request: %s %s", inspection.Method, inspection.Path)
	log.Printf("🌐 Remote: %s", inspection.RemoteAddr)
	log.Printf("")
	log.Printf("🔐 Auth Headers:")
	if inspection.AuthHeaders.XServerlessAuthorization != "" {
		log.Printf("   X-Serverless-Authorization: %s", truncate(inspection.AuthHeaders.XServerlessAuthorization, 60))
	}
	if inspection.AuthHeaders.Authorization != "" {
		log.Printf("   Authorization: %s", truncate(inspection.AuthHeaders.Authorization, 60))
	}
	if inspection.AuthHeaders.XForwardedFor != "" {
		log.Printf("   X-Forwarded-For: %s", inspection.AuthHeaders.XForwardedFor)
	}
	if inspection.AuthHeaders.XForwardedHost != "" {
		log.Printf("   X-Forwarded-Host: %s", inspection.AuthHeaders.XForwardedHost)
	}
	log.Printf("")
	log.Printf("📋 All Headers:")

	// Sort headers for consistent output
	headers := make([]string, 0, len(inspection.Headers))
	for k := range inspection.Headers {
		headers = append(headers, k)
	}
	sort.Strings(headers)

	for _, k := range headers {
		values := inspection.Headers[k]
		for _, v := range values {
			// Truncate long values
			displayValue := v
			if len(v) > 80 {
				displayValue = v[:40] + "..." + v[len(v)-37:]
			}
			log.Printf("   %s: %s", k, displayValue)
		}
	}
	log.Printf("========================================")
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	half := maxLen / 2
	return s[:half-2] + "..." + s[len(s)-(half-1):]
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
