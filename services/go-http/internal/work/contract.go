package work

const (
	// BodyLimitBytes is the maximum decoded request body accepted by POST /work.
	// DecodeAndValidate enforces this by reading at most BodyLimitBytes+1 bytes
	// before attempting JSON decoding.
	BodyLimitBytes = 4096

	MaxRequestIDLength = 128
	MaxPayloadSize     = 131072
	MaxSeed            = 2147483647
	MaxExtraWork       = 100
)

type Request struct {
	RequestID   string
	PayloadSize int
	Seed        int
	ExtraWork   int
}

type Response struct {
	RequestID   string `json:"requestId"`
	PayloadSize int    `json:"payloadSize"`
	ExtraWork   int    `json:"extraWork"`
	Checksum    string `json:"checksum"`
	OK          bool   `json:"ok"`
}
