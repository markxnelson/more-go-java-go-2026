package demo.benchmark;

import java.util.Locale;

public final class WorkComputer {
    private static final long FNV_OFFSET_64 = 1469598103934665603L;
    private static final long FNV_PRIME_64 = 1099511628211L;

    private WorkComputer() {
    }

    public static String computeChecksum(WorkRequest request) {
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
}
