package com.example.remote_control_device

/**
 * What crosses the channel about the transmission gate, both ways, and nothing else.
 *
 * ```text
 * Dart -> Android   setScreenCaptureTransmission    { trackId, transmitting: false }
 *                                                   { trackId, transmitting: true,
 *                                                     grant, evidenceAtNanos, validForMs }
 *                   renewScreenCaptureTransmission  { trackId, grant, evidenceAtNanos, validForMs }
 *
 * Android -> Dart   { applied, live }                          for setScreenCaptureTransmission
 *                   { result: renewed|lapsed|ignored|rejected,
 *                     live }                                   for renewScreenCaptureTransmission
 * ```
 *
 * `evidenceAtNanos` is an instant of `CLOCK_BOOTTIME` as Dart read it when the heartbeat
 * evidence arrived — never the time the message was sent. A Dart `int` crosses the standard
 * codec as an `Integer` or a `Long` depending on its size, so every number is read as a
 * [Number].
 *
 * Pure, so the JVM tests reach it.
 */
internal object ScreenTransmissionMessages {

    data class Lease(val grant: Long, val evidenceAtNanos: Long, val validForNanos: Long)

    /** The lease of an opening or a renewal, or null when an argument is missing or malformed. */
    fun leaseOf(argument: (String) -> Any?): Lease? {
        val grant = (argument(GRANT) as? Number)?.toLong() ?: return null
        val evidenceAt = (argument(EVIDENCE_AT_NANOS) as? Number)?.toLong() ?: return null
        val validForMs = (argument(VALID_FOR_MS) as? Number)?.toLong() ?: return null
        if (grant <= 0 || validForMs <= 0) return null
        if (validForMs > Long.MAX_VALUE / NANOS_PER_MS) return null
        return Lease(grant, evidenceAt, validForMs * NANOS_PER_MS)
    }

    /** The answer to an opening; null when nothing was applied. */
    fun openingAnswer(opening: TransmissionOpening?): Map<String, Any> = mapOf(
        APPLIED to (opening != null),
        LIVE to (opening?.verdict == LeaseVerdict.LIVE),
    )

    /** The answer to a closing. */
    fun closingAnswer(applied: Boolean): Map<String, Any> = mapOf(APPLIED to applied, LIVE to false)

    /** The answer to a renewal; null when there is no such capture. */
    fun renewalAnswer(renewal: TransmissionRenewal?): Map<String, Any> = mapOf(
        RESULT to when (renewal?.outcome) {
            RenewalOutcome.RENEWED -> "renewed"
            RenewalOutcome.LAPSED -> "lapsed"
            RenewalOutcome.REJECTED -> "rejected"
            RenewalOutcome.IGNORED, null -> "ignored"
        },
        LIVE to (renewal?.live ?: false),
    )

    const val GRANT = "grant"
    const val EVIDENCE_AT_NANOS = "evidenceAtNanos"
    const val VALID_FOR_MS = "validForMs"
    const val APPLIED = "applied"
    const val LIVE = "live"
    const val RESULT = "result"

    private const val NANOS_PER_MS = 1_000_000L
}
