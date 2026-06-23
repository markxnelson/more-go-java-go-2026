package work

import "testing"

func TestComputeChecksumStable(t *testing.T) {
	req := Request{
		RequestID:   "stable",
		PayloadSize: 128,
		Seed:        42,
		ExtraWork:   1,
	}

	first := ComputeChecksum(req)
	second := ComputeChecksum(req)

	if first == "" {
		t.Fatal("checksum is empty")
	}
	if first != second {
		t.Fatalf("checksum is not stable: first=%q second=%q", first, second)
	}
}

func TestComputeChecksumChangesWithWorkInputs(t *testing.T) {
	base := Request{
		RequestID:   "same-id",
		PayloadSize: 128,
		Seed:        42,
		ExtraWork:   1,
	}

	changedPayload := base
	changedPayload.PayloadSize = 129

	changedSeed := base
	changedSeed.Seed = 43

	changedExtraWork := base
	changedExtraWork.ExtraWork = 2

	baseSum := ComputeChecksum(base)
	if baseSum == ComputeChecksum(changedPayload) {
		t.Fatal("checksum did not change when payloadSize changed")
	}
	if baseSum == ComputeChecksum(changedSeed) {
		t.Fatal("checksum did not change when seed changed")
	}
	if baseSum == ComputeChecksum(changedExtraWork) {
		t.Fatal("checksum did not change when extraWork changed")
	}
}
