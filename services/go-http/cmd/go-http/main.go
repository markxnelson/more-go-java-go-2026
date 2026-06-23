package main

import (
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"example.com/more-go-java-go/services/go-http/internal/work"
)

func main() {
	host := getenv("GO_HOST", "127.0.0.1")
	port := getenv("GO_PORT", "18081")

	if _, err := strconv.Atoi(port); err != nil {
		log.Fatalf("invalid GO_PORT %q: %v", port, err)
	}

	addr := net.JoinHostPort(host, port)
	server := &http.Server{
		Addr:              addr,
		Handler:           work.NewHandler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("go-http listening on http://%s", addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func getenv(name string, fallback string) string {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	return value
}
