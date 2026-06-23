package work

import (
	"errors"
	"strings"
	"testing"
)

func TestValidRequest(t *testing.T) {
	req, err := DecodeAndValidate(strings.NewReader(`{"requestId":"a","payloadSize":128,"seed":42,"extraWork":1}`))
	if err != nil {
		t.Fatal(err)
	}

	if req.RequestID != "a" || req.PayloadSize != 128 || req.Seed != 42 || req.ExtraWork != 1 {
		t.Fatalf("unexpected request: %#v", req)
	}
}

func TestBoundaryValuesAccepted(t *testing.T) {
	body := `{"requestId":"max","payloadSize":131072,"seed":2147483647,"extraWork":100}`

	req, err := DecodeAndValidate(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}

	if req.PayloadSize != MaxPayloadSize || req.Seed != MaxSeed || req.ExtraWork != MaxExtraWork {
		t.Fatalf("unexpected request: %#v", req)
	}
}

func TestInvalidBoundsRejected(t *testing.T) {
	cases := []string{
		`{"requestId":"","payloadSize":1,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":-1,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":131073,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1,"seed":-1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1,"seed":2147483648,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":-1}`,
		`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":101}`,
	}

	for _, tc := range cases {
		t.Run(tc, func(t *testing.T) {
			if _, err := DecodeAndValidate(strings.NewReader(tc)); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}

func TestLongRequestIDRejected(t *testing.T) {
	longID := strings.Repeat("x", MaxRequestIDLength+1)
	body := `{"requestId":"` + longID + `","payloadSize":1,"seed":1,"extraWork":1}`

	if _, err := DecodeAndValidate(strings.NewReader(body)); err == nil {
		t.Fatal("expected requestId length error")
	}
}

func TestMissingFieldsRejected(t *testing.T) {
	cases := []string{
		`{"payloadSize":1,"seed":1,"extraWork":1}`,
		`{"requestId":"a","seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1,"seed":1}`,
	}

	for _, tc := range cases {
		t.Run(tc, func(t *testing.T) {
			if _, err := DecodeAndValidate(strings.NewReader(tc)); err == nil {
				t.Fatal("expected missing field error")
			}
		})
	}
}

func TestUnknownFieldsRejected(t *testing.T) {
	_, err := DecodeAndValidate(strings.NewReader(`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":1,"unknown":true}`))
	if err == nil {
		t.Fatal("expected unknown field error")
	}
}

func TestDuplicateFieldsRejected(t *testing.T) {
	cases := []string{
		`{"requestId":"a","requestId":"b","payloadSize":1,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1,"payloadSize":2,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1,"seed":1,"seed":2,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":1,"extraWork":2}`,
	}

	for _, tc := range cases {
		t.Run(tc, func(t *testing.T) {
			if _, err := DecodeAndValidate(strings.NewReader(tc)); err == nil {
				t.Fatal("expected duplicate field error")
			}
		})
	}
}

func TestQuotedNumericStringsRejected(t *testing.T) {
	cases := []string{
		`{"requestId":"a","payloadSize":"128","seed":42,"extraWork":1}`,
		`{"requestId":"a","payloadSize":128,"seed":"42","extraWork":1}`,
		`{"requestId":"a","payloadSize":128,"seed":42,"extraWork":"1"}`,
	}

	for _, tc := range cases {
		t.Run(tc, func(t *testing.T) {
			if _, err := DecodeAndValidate(strings.NewReader(tc)); err == nil {
				t.Fatal("expected quoted numeric string error")
			}
		})
	}
}

func TestWrongScalarTypesRejected(t *testing.T) {
	cases := []string{
		`{"requestId":1,"payloadSize":1,"seed":1,"extraWork":1}`,
		`{"requestId":true,"payloadSize":1,"seed":1,"extraWork":1}`,
		`{"requestId":null,"payloadSize":1,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":true,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":null,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":[],"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1.5,"seed":1,"extraWork":1}`,
		`{"requestId":"a","payloadSize":1e2,"seed":1,"extraWork":1}`,
	}

	for _, tc := range cases {
		t.Run(tc, func(t *testing.T) {
			if _, err := DecodeAndValidate(strings.NewReader(tc)); err == nil {
				t.Fatal("expected scalar type error")
			}
		})
	}
}

func TestInvalidJSONRejected(t *testing.T) {
	cases := []string{
		``,
		`{`,
		`[]`,
		`true`,
		`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":1`,
		`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":1} trailing`,
		`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":1}{}`,
	}

	for _, tc := range cases {
		t.Run(tc, func(t *testing.T) {
			if _, err := DecodeAndValidate(strings.NewReader(tc)); err == nil {
				t.Fatal("expected invalid json error")
			}
		})
	}
}

func TestBodyTooLarge(t *testing.T) {
	_, err := DecodeAndValidate(strings.NewReader(strings.Repeat("A", BodyLimitBytes+1)))
	if !errors.Is(err, ErrBodyTooLarge) {
		t.Fatalf("expected body too large, got %v", err)
	}
}

func TestBodyAtLimitIsReadAndDecoded(t *testing.T) {
	prefix := `{"requestId":"`
	suffix := `","payloadSize":1,"seed":1,"extraWork":1}`
	idLen := BodyLimitBytes - len(prefix) - len(suffix)
	if idLen < 1 || idLen > MaxRequestIDLength {
		t.Skip("contract constants do not allow constructing a valid body exactly at the byte limit")
	}

	body := prefix + strings.Repeat("x", idLen) + suffix
	if len(body) != BodyLimitBytes {
		t.Fatalf("test body length=%d want=%d", len(body), BodyLimitBytes)
	}

	if _, err := DecodeAndValidate(strings.NewReader(body)); err != nil {
		t.Fatalf("body at limit should be accepted when otherwise valid: %v", err)
	}
}
