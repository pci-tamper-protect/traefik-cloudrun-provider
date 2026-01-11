package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

type Response struct {
	Message string `json:"message"`
	Service string `json:"service"`
	Version string `json:"version"`
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
