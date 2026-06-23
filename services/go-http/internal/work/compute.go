package work

import "fmt"

const (
	fnvOffset64 = uint64(1469598103934665603)
	fnvPrime64  = uint64(1099511628211)
)

// ComputeChecksum performs deterministic CPU work for a validated request.
//
// The function intentionally avoids allocating a payload buffer. payloadSize and
// extraWork control the amount of loop work while seed controls the generated
// byte stream. The returned checksum is stable for identical inputs.
func ComputeChecksum(req Request) string {
	sum := fnvOffset64
	sum ^= uint64(req.Seed)
	sum *= fnvPrime64

	total := req.PayloadSize + req.ExtraWork*1000
	for i := 0; i < total; i++ {
		v := byte((req.Seed + i*31 + req.PayloadSize*17 + req.ExtraWork*13) & 0xff)
		sum ^= uint64(v)
		sum *= fnvPrime64
	}

	return fmt.Sprintf("%016x", sum)
}
