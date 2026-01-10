package gcp

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// TokenManager manages GCP identity tokens with caching and refresh
type TokenManager struct {
	cache map[string]*CachedToken
	mu    sync.RWMutex
}

// CachedToken represents a cached identity token with expiry
type CachedToken struct {
	Token     string
	ExpiresAt time.Time
}

// NewTokenManager creates a new token manager
func NewTokenManager() *TokenManager {
	return &TokenManager{
		cache: make(map[string]*CachedToken),
	}
}

// GetToken gets an identity token for the given audience (service URL)
// Returns cached token if valid, otherwise fetches new token from metadata server
func (tm *TokenManager) GetToken(audience string) (string, error) {
	// Check cache first
	tm.mu.RLock()
	cached, ok := tm.cache[audience]
	tm.mu.RUnlock()

	if ok && time.Now().Before(cached.ExpiresAt) {
		return cached.Token, nil
	}

	// Fetch new token
	token, err := tm.fetchFromMetadata(audience)
	if err != nil {
		return "", err
	}

	// Cache token (GCP tokens expire after 1 hour)
	// Refresh 5 minutes before expiry to avoid edge cases
	tm.mu.Lock()
	tm.cache[audience] = &CachedToken{
		Token:     token,
		ExpiresAt: time.Now().Add(55 * time.Minute),
	}
	tm.mu.Unlock()

	return token, nil
}

// fetchFromMetadata fetches an identity token from the GCP metadata server
// Extracted from cmd/generate-routes/main.go:509-543
func (tm *TokenManager) fetchFromMetadata(audience string) (string, error) {
	// URL-encode the audience
	encodedAudience := strings.ReplaceAll(strings.ReplaceAll(audience, ":", "%3A"), "/", "%2F")
	url := fmt.Sprintf(
		"http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=%s",
		encodedAudience,
	)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Metadata-Flavor", "Google")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to fetch token from metadata server: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("metadata server returned %d: %s", resp.StatusCode, string(body))
	}

	token, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read token: %w", err)
	}

	tokenStr := strings.TrimSpace(string(token))
	if !strings.HasPrefix(tokenStr, "eyJ") {
		return "", fmt.Errorf("token doesn't look valid (doesn't start with eyJ)")
	}

	return tokenStr, nil
}

// ClearCache clears all cached tokens
func (tm *TokenManager) ClearCache() {
	tm.mu.Lock()
	defer tm.mu.Unlock()
	tm.cache = make(map[string]*CachedToken)
}

// CacheStats returns cache statistics for monitoring
func (tm *TokenManager) CacheStats() (total int, expired int) {
	tm.mu.RLock()
	defer tm.mu.RUnlock()

	total = len(tm.cache)
	now := time.Now()
	for _, cached := range tm.cache {
		if now.After(cached.ExpiresAt) {
			expired++
		}
	}
	return total, expired
}
