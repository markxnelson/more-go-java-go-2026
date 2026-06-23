package demo.benchmark;

import org.junit.jupiter.api.Test;

import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

final class WorkComputerTest {
    private static final long FNV_OFFSET_64 = 1469598103934665603L;
    private static final long FNV_PRIME_64 = 1099511628211L;

    @Test
    void checksumMatchesPinnedGoEquivalentValue() {
        WorkRequest request = new WorkRequest("checksum-pinned", 1, 0, 0);

        String checksum = WorkComputer.computeChecksum(request);

        assertEquals("9a690200c5489c18", checksum);
        assertNotEquals(checksumWithoutPayloadSizeAndExtraWorkInByteStream(request), checksum);
    }

    @Test
    void checksumIncludesPayloadSizeAndExtraWorkInGeneratedByteStream() {
        WorkRequest request = new WorkRequest("checksum-byte-stream-inputs", 2, 7, 1);

        String checksum = WorkComputer.computeChecksum(request);

        assertEquals(referenceChecksum(request), checksum);
        assertNotEquals(checksumWithoutPayloadSizeAndExtraWorkInByteStream(request), checksum);
    }

    @Test
    void checksumIsDeterministicAndHexFormatted() {
        WorkRequest request = new WorkRequest("checksum-1", 128, 42, 1);

        String first = WorkComputer.computeChecksum(request);
        String second = WorkComputer.computeChecksum(request);

        assertEquals(first, second);
        assertTrue(first.matches("[0-9a-f]{16}"), "checksum should be fixed-width lowercase hex");
    }

    @Test
    void checksumChangesWhenPayloadSizeChanges() {
        WorkRequest small = new WorkRequest("checksum-small", 127, 42, 1);
        WorkRequest large = new WorkRequest("checksum-large", 128, 42, 1);

        assertNotEquals(WorkComputer.computeChecksum(small), WorkComputer.computeChecksum(large));
    }

    @Test
    void checksumChangesWhenSeedChanges() {
        WorkRequest seedOne = new WorkRequest("checksum-seed-1", 128, 1, 1);
        WorkRequest seedTwo = new WorkRequest("checksum-seed-2", 128, 2, 1);

        assertNotEquals(WorkComputer.computeChecksum(seedOne), WorkComputer.computeChecksum(seedTwo));
    }

    @Test
    void checksumChangesWhenExtraWorkChanges() {
        WorkRequest lowExtraWork = new WorkRequest("checksum-extra-low", 128, 42, 0);
        WorkRequest highExtraWork = new WorkRequest("checksum-extra-high", 128, 42, 1);

        assertNotEquals(WorkComputer.computeChecksum(lowExtraWork), WorkComputer.computeChecksum(highExtraWork));
    }

    @Test
    void zeroPayloadAndZeroExtraWorkStillProducesChecksum() {
        WorkRequest request = new WorkRequest("checksum-zero", 0, 42, 0);

        String checksum = WorkComputer.computeChecksum(request);

        assertTrue(checksum.matches("[0-9a-f]{16}"), "checksum should be fixed-width lowercase hex");
    }

    private static String referenceChecksum(WorkRequest request) {
        long sum = FNV_OFFSET_64;
        sum ^= request.seed();
        sum *= FNV_PRIME_64;

        long total = request.payloadSize() + request.extraWork() * 1000L;
        for (long i = 0; i < total; i++) {
            long value = (request.seed()
                    + i * 31L
                    + request.payloadSize() * 17L
                    + request.extraWork() * 13L) & 0xffL;
            sum ^= value;
            sum *= FNV_PRIME_64;
        }

        return String.format(Locale.ROOT, "%016x", sum);
    }

    private static String checksumWithoutPayloadSizeAndExtraWorkInByteStream(WorkRequest request) {
        long sum = FNV_OFFSET_64;
        sum ^= request.seed();
        sum *= FNV_PRIME_64;

        long total = request.payloadSize() + request.extraWork() * 1000L;
        for (long i = 0; i < total; i++) {
            long value = (request.seed() + i * 31L) & 0xffL;
            sum ^= value;
            sum *= FNV_PRIME_64;
        }

        return String.format(Locale.ROOT, "%016x", sum);
    }
}
