// sample-app is a minimal HTTP server used to demonstrate a Cloud Foundry /
// BOSH deployment running natively on ARM64 (Apple Silicon / AWS Graviton).
//
// It reports its own architecture and OS at runtime so that a caller can
// confirm the workload is running on arm64 Linux without emulation.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"
)

// response is the JSON payload returned from the root endpoint.
type response struct {
	App     string `json:"app"`
	Arch    string `json:"arch"`
	Message string `json:"message"`
	OS      string `json:"os"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// APP_NAME is injected by the BOSH job control script (ctl.sh) so the
	// deployed name is visible in the response.
	appName := os.Getenv("APP_NAME")
	if appName == "" {
		appName = "bosh-deployed-arm64-app"
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(response{
			App:     appName,
			Arch:    runtime.GOARCH,
			Message: "Hello from Cloud Foundry on ARM64!",
			OS:      runtime.GOOS,
		})
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	})

	// Use an explicit http.Server with timeouts rather than http.ListenAndServe,
	// which cannot configure them. Without timeouts the server is exposed to
	// slow-client / slowloris resource-exhaustion attacks (CWE-770): a client
	// can hold connections open indefinitely and eventually starve the server.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("sample-app starting on port %s (arch: %s, os: %s)", port, runtime.GOARCH, runtime.GOOS)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
