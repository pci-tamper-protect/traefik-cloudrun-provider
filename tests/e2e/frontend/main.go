package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
)

type BackendResponse struct {
	Message string `json:"message"`
	Service string `json:"service"`
	Version string `json:"version"`
}

type FrontendResponse struct {
	Frontend string          `json:"frontend"`
	Backend  BackendResponse `json:"backend"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	backendURL := os.Getenv("BACKEND_URL")
	if backendURL == "" {
		backendURL = "http://backend:8080"
	}

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
	})

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Frontend: received request from %s", r.RemoteAddr)

		// Call backend service
		resp, err := http.Get(backendURL + "/api/hello")
		if err != nil {
			log.Printf("Frontend: failed to call backend: %v", err)
			http.Error(w, "Failed to reach backend", http.StatusServiceUnavailable)
			return
		}
		defer resp.Body.Close()

		body, err := io.ReadAll(resp.Body)
		if err != nil {
			log.Printf("Frontend: failed to read backend response: %v", err)
			http.Error(w, "Failed to read backend response", http.StatusInternalServerError)
			return
		}

		var backendResp BackendResponse
		if err := json.Unmarshal(body, &backendResp); err != nil {
			log.Printf("Frontend: failed to parse backend response: %v", err)
			http.Error(w, "Failed to parse backend response", http.StatusInternalServerError)
			return
		}

		response := FrontendResponse{
			Frontend: "Hello from Frontend!",
			Backend:  backendResp,
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
	})

	log.Printf("Frontend service listening on port %s", port)
	log.Printf("Backend URL: %s", backendURL)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}
