package work

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

var ErrBodyTooLarge = errors.New("body too large")

// DecodeAndValidate reads at most BodyLimitBytes+1 bytes, rejects bodies larger
// than BodyLimitBytes, and validates the exact POST /work request contract.
func DecodeAndValidate(body io.Reader) (Request, error) {
	raw, err := io.ReadAll(io.LimitReader(body, BodyLimitBytes+1))
	if err != nil {
		return Request{}, fmt.Errorf("read body: %w", err)
	}
	if len(raw) > BodyLimitBytes {
		return Request{}, ErrBodyTooLarge
	}

	if err := rejectDuplicateTopLevelFields(raw); err != nil {
		return Request{}, err
	}

	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()

	var obj map[string]json.RawMessage
	if err := dec.Decode(&obj); err != nil {
		return Request{}, fmt.Errorf("invalid json: %w", err)
	}

	if dec.Decode(&struct{}{}) != io.EOF {
		return Request{}, errors.New("multiple json documents")
	}

	if obj == nil {
		return Request{}, errors.New("body must be a json object")
	}

	allowed := map[string]bool{
		"requestId":   true,
		"payloadSize": true,
		"seed":        true,
		"extraWork":   true,
	}
	for key := range obj {
		if !allowed[key] {
			return Request{}, fmt.Errorf("unknown field: %s", key)
		}
	}

	requestID, err := requiredString(obj, "requestId")
	if err != nil {
		return Request{}, err
	}
	if len(requestID) < 1 || len(requestID) > MaxRequestIDLength {
		return Request{}, errors.New("requestId length out of range")
	}

	payloadSize, err := requiredInt(obj, "payloadSize", 0, MaxPayloadSize)
	if err != nil {
		return Request{}, err
	}

	seed, err := requiredInt(obj, "seed", 0, MaxSeed)
	if err != nil {
		return Request{}, err
	}

	extraWork, err := requiredInt(obj, "extraWork", 0, MaxExtraWork)
	if err != nil {
		return Request{}, err
	}

	return Request{
		RequestID:   requestID,
		PayloadSize: payloadSize,
		Seed:        seed,
		ExtraWork:   extraWork,
	}, nil
}

func requiredString(obj map[string]json.RawMessage, name string) (string, error) {
	raw, ok := obj[name]
	if !ok {
		return "", fmt.Errorf("missing field: %s", name)
	}

	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] != '"' {
		return "", fmt.Errorf("%s must be a string", name)
	}

	var value string
	if err := json.Unmarshal(trimmed, &value); err != nil {
		return "", fmt.Errorf("%s must be a string", name)
	}

	return value, nil
}

func requiredInt(obj map[string]json.RawMessage, name string, min int, max int) (int, error) {
	raw, ok := obj[name]
	if !ok {
		return 0, fmt.Errorf("missing field: %s", name)
	}

	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] == '"' {
		return 0, fmt.Errorf("%s must be a json integer number", name)
	}

	var number json.Number
	if err := json.Unmarshal(trimmed, &number); err != nil {
		return 0, fmt.Errorf("%s must be a json integer number", name)
	}

	text := number.String()
	if strings.ContainsAny(text, ".eE") {
		return 0, fmt.Errorf("%s must be an integer", name)
	}

	value, err := number.Int64()
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", name)
	}
	if value < int64(min) || value > int64(max) {
		return 0, fmt.Errorf("%s out of range", name)
	}

	return int(value), nil
}

func rejectDuplicateTopLevelFields(raw []byte) error {
	dec := json.NewDecoder(bytes.NewReader(raw))

	tok, err := dec.Token()
	if err != nil {
		return fmt.Errorf("invalid json: %w", err)
	}

	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return errors.New("body must be a json object")
	}

	seen := map[string]bool{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return fmt.Errorf("invalid json: %w", err)
		}

		key, ok := tok.(string)
		if !ok {
			return errors.New("object key must be a string")
		}
		if seen[key] {
			return fmt.Errorf("duplicate field: %s", key)
		}
		seen[key] = true

		var value any
		if err := dec.Decode(&value); err != nil {
			return fmt.Errorf("invalid json: %w", err)
		}
	}

	if _, err := dec.Token(); err != nil {
		return fmt.Errorf("invalid json: %w", err)
	}

	return nil
}
