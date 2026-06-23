package load

import (
	"errors"
	"fmt"
	"math"
	"net/url"
	"strings"
	"time"
	"unicode"
)

const (
	MaxConcurrency = 1024
	MaxLabelLength = 128
)

type Config struct {
	URL              string
	Fixture          string
	Output           string
	Duration         time.Duration
	Concurrency      int
	Warmup           time.Duration
	Rate             float64
	Service          string
	Variant          string
	Cell             string
	Repeat           int
	RunID            string
	SummaryOutput    string
	ManifestOutput   string
	ProfileArtifacts []ProfileArtifact
}

func (c Config) Validate() error {
	if strings.TrimSpace(c.URL) == "" {
		return errors.New("url is required")
	}
	if err := validateWorkURL(c.URL); err != nil {
		return err
	}
	if strings.TrimSpace(c.Fixture) == "" {
		return errors.New("fixture is required")
	}
	if strings.TrimSpace(c.Output) == "" {
		return errors.New("out is required")
	}
	if c.Duration <= 0 {
		return errors.New("duration must be positive")
	}
	if c.Warmup < 0 {
		return errors.New("warmup must be non-negative")
	}
	if c.Concurrency < 1 || c.Concurrency > MaxConcurrency {
		return fmt.Errorf("concurrency must be between 1 and %d", MaxConcurrency)
	}
	if math.IsNaN(c.Rate) || math.IsInf(c.Rate, 0) {
		return errors.New("rate must be finite")
	}
	if c.Rate < 0 {
		return errors.New("rate must be non-negative")
	}
	if c.Repeat < 0 {
		return errors.New("repeat must be non-negative")
	}
	if err := validateLabel("service", c.Service); err != nil {
		return err
	}
	if err := validateLabel("variant", c.Variant); err != nil {
		return err
	}
	if err := validateLabel("cell", c.Cell); err != nil {
		return err
	}
	if err := validateLabel("run-id", c.RunID); err != nil {
		return err
	}

	if len(c.ProfileArtifacts) > 0 && strings.TrimSpace(c.ManifestOutput) == "" {
		return errors.New("manifest-out is required when profile artifacts are provided")
	}
	for i, artifact := range c.ProfileArtifacts {
		if err := artifact.Validate(); err != nil {
			return fmt.Errorf("profile artifact %d: %w", i, err)
		}
	}

	return nil
}

func validateWorkURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("url is invalid: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return errors.New("url scheme must be http or https")
	}
	if u.Host == "" {
		return errors.New("url host is required")
	}
	if u.Path != "/work" {
		return errors.New("url path must be /work")
	}
	return nil
}

func validateLabel(name string, value string) error {
	if value == "" {
		return nil
	}
	if len(value) > MaxLabelLength {
		return fmt.Errorf("%s must be at most %d bytes", name, MaxLabelLength)
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return fmt.Errorf("%s must not contain control characters", name)
		}
	}
	return nil
}
