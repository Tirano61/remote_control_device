package com.example.remote_control_device

import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The transmission gate, alone and in the frame path exactly as [ScreenCapturer.onFrame] builds
 * it: gate first, then the settle frame. The helper is modelled as in the settle-frame tests: it
 * latches the last texture the capture produced, and a redelivery request hands that texture
 * back when the test says so.
 *
 * Every clock here is the test's: `elapsedRealtimeNanos` moved by hand, so a lease runs out at
 * an exact nanosecond and the edges can be tested on both sides.
 */
class ScreenCaptureTransmissionTest {

    private var now = 1_000 * S
    private val gate = ScreenCaptureTransmission { now }

    /** Opens [grant] with evidence [ageMs] old and the backend's 13 s validity. */
    private fun open(grant: Long = 1, ageMs: Long = 0, validFor: Long = VALID): TransmissionOpening? =
        gate.open(grant, now - ageMs * MS, validFor)

    private fun renew(grant: Long, evidenceAt: Long, validFor: Long = VALID) =
        gate.renew(grant, evidenceAt, validFor)

    private fun admitted() = gate.admit() == FrameAdmission.ADMITTED

    // ------------------------------------------------------------------ the gate alone

    @Test
    fun `a new capture starts closed and withholds every frame`() {
        assertFalse(gate.transmitting)
        assertEquals(FrameAdmission.WITHHELD_CLOSED, gate.admit())
        assertEquals(FrameAdmission.WITHHELD_CLOSED, gate.admit())
    }

    @Test
    fun `1 a lease with time left lets frames through`() {
        val opening = open(ageMs = 2_000)!!

        assertEquals(LeaseVerdict.LIVE, opening.verdict)
        assertEquals(2_000 * MS, opening.evidenceAgeNanos)
        assertTrue(admitted())
        assertTrue(gate.isLive())
    }

    @Test
    fun `2 a lease that ran out keeps frames back, and says so once`() {
        val evidence = now
        open()
        now = evidence + VALID - 1
        assertTrue(admitted())

        now = evidence + VALID
        assertEquals(FrameAdmission.WITHHELD_LEASE_RAN_OUT, gate.admit())
        assertEquals(FrameAdmission.WITHHELD_EXPIRED, gate.admit())
        now += 60 * S
        assertEquals(FrameAdmission.WITHHELD_EXPIRED, gate.admit())
        assertFalse(gate.isLive())
        assertTrue("still open: only Dart closes it", gate.transmitting)
    }

    @Test
    fun `3 closed explicitly, nothing goes through and no renewal reopens it`() {
        val evidence = now
        open()
        assertNotNull(gate.close())

        assertEquals(FrameAdmission.WITHHELD_CLOSED, gate.admit())
        now += S
        assertEquals(RenewalOutcome.IGNORED, renew(1, now).outcome)
        assertEquals(FrameAdmission.WITHHELD_CLOSED, gate.admit())
        assertFalse(gate.transmitting)
        assertTrue(evidence < now)
    }

    @Test
    fun `4 the lease runs out with no call at all - Dart not running`() {
        open(ageMs = 1_000)
        assertTrue(admitted())

        // Nothing is called on the gate: no renewal, no closing. Only time passes.
        now += VALID - 1_000 * MS
        assertEquals(FrameAdmission.WITHHELD_LEASE_RAN_OUT, gate.admit())
        repeat(100) {
            now += 33 * MS
            assertFalse(admitted())
        }
    }

    @Test
    fun `5 a renewal in time moves the deadline to the new evidence`() {
        val first = now
        open()
        now = first + 10 * S
        val renewal = renew(1, now)

        assertEquals(RenewalOutcome.RENEWED, renewal.outcome)
        assertTrue(renewal.live)
        assertFalse(renewal.refresh)
        assertEquals(VALID, renewal.remainingNanos)
        assertEquals(now + VALID, gate.lease!!.deadlineNanos)

        now = first + VALID + 5 * S // past the first deadline, inside the second
        assertTrue(admitted())
    }

    @Test
    fun `6a a late message of timely evidence renews from the evidence, not from its arrival`() {
        val first = now
        open()
        val evidence = first + 12 * S // before the first deadline (13 s)
        now = first + 14 * S // ...but its message arrives after it
        assertFalse(admitted())

        val renewal = renew(1, evidence)

        assertEquals(RenewalOutcome.RENEWED, renewal.outcome)
        assertTrue(renewal.live)
        assertEquals(evidence + VALID, gate.lease!!.deadlineNanos)
        assertEquals(2 * S, renewal.evidenceAgeNanos)
        assertTrue("frames were kept back meanwhile", renewal.refresh)
        assertTrue(admitted())
    }

    @Test
    fun `6b a message late enough buys nothing - its evidence is as old as it is`() {
        val first = now
        open()
        val evidence = first + 12 * S
        now = evidence + VALID + S // Dart was held between the PING and its message

        val renewal = renew(1, evidence)

        assertEquals(RenewalOutcome.RENEWED, renewal.outcome)
        assertFalse(renewal.live)
        assertFalse(renewal.refresh)
        assertEquals(-S, renewal.remainingNanos)
        assertFalse(admitted())
    }

    @Test
    fun `6c evidence after the lease ran out lapses it for good`() {
        val first = now
        open()
        now = first + 20 * S // Dart blocked: the next PING is handled 20 s later
        val renewal = renew(1, now)

        assertEquals(RenewalOutcome.LAPSED, renewal.outcome)
        assertFalse(renewal.live)
        assertFalse(admitted())
        // Every later evidence is later still: the grant cannot be revived by any of them.
        repeat(5) {
            now += 10 * S
            assertEquals(RenewalOutcome.LAPSED, renew(1, now).outcome)
            assertFalse(admitted())
        }
        // Only a new opening, which Dart makes after confirming the authority again.
        assertEquals(LeaseVerdict.LIVE, open(grant = 2)!!.verdict)
        assertTrue(admitted())
    }

    @Test
    fun `6d evidence not newer than the lease's changes nothing`() {
        val first = now
        open()
        now += 5 * S
        assertEquals(RenewalOutcome.RENEWED, renew(1, now).outcome)
        val deadline = gate.lease!!.deadlineNanos

        assertEquals(RenewalOutcome.IGNORED, renew(1, now).outcome) // a repeat
        assertEquals(RenewalOutcome.IGNORED, renew(1, first + S).outcome) // older
        assertEquals(deadline, gate.lease!!.deadlineNanos)
    }

    @Test
    fun `7 an older grant neither renews the current one nor reopens after a newer one`() {
        open(grant = 3)
        now += S
        assertEquals(RenewalOutcome.IGNORED, renew(2, now).outcome)

        gate.close()
        assertNull("an opening older than one already seen", open(grant = 2))
        assertNull("the same grant again", open(grant = 3))
        assertEquals(FrameAdmission.WITHHELD_CLOSED, gate.admit())
        assertNotNull(open(grant = 4))
    }

    @Test
    fun `7b a renewal of the previous grant never reaches the opening that replaced it`() {
        val first = now
        open(grant = 1)
        gate.close()
        open(grant = 2)
        val deadline = gate.lease!!.deadlineNanos

        assertEquals(RenewalOutcome.IGNORED, renew(1, first + 5 * S).outcome)
        assertEquals(deadline, gate.lease!!.deadlineNanos)
        assertEquals(2L, gate.lease!!.grant)
    }

    @Test
    fun `9 10 11 a stopped capture is over - FINALIZAR, SYSTEM or Android's own stop`() {
        open()
        gate.stop()

        assertFalse(gate.transmitting)
        assertNull(gate.lease)
        assertEquals(FrameAdmission.STOPPED, gate.admit())
        now += S
        assertEquals(RenewalOutcome.IGNORED, renew(1, now).outcome)
        assertNull(open(grant = 2))
        assertNull(gate.close())
        assertEquals(FrameAdmission.STOPPED, gate.admit())
        gate.stop() // idempotent
    }

    @Test
    fun `an opening whose evidence is already too old opens nothing that sends`() {
        val opening = open(ageMs = 13_000)!!

        assertEquals(LeaseVerdict.EXPIRED, opening.verdict)
        assertEquals(FrameAdmission.WITHHELD_LEASE_RAN_OUT, gate.admit())
    }

    @Test
    fun `evidence from this clock's future is refused - the two clocks do not agree`() {
        val opening = gate.open(1, now + MS, VALID)!!
        assertEquals(LeaseVerdict.REJECTED, opening.verdict)
        assertFalse(gate.transmitting)
        assertEquals(FrameAdmission.WITHHELD_CLOSED, gate.admit())

        open(grant = 2)
        val deadline = gate.lease!!.deadlineNanos
        assertEquals(RenewalOutcome.REJECTED, renew(2, now + MS).outcome)
        assertEquals(deadline, gate.lease!!.deadlineNanos)
    }

    @Test
    fun `a validity that is not the grant's, or no validity at all, is refused`() {
        assertEquals(LeaseVerdict.REJECTED, gate.open(1, now, 0)!!.verdict)
        assertEquals(
            LeaseVerdict.REJECTED,
            gate.open(2, now, ScreenCaptureTransmission.MAX_VALIDITY_NANOS + 1)!!.verdict,
        )
        open(grant = 3)
        now += S
        assertEquals(RenewalOutcome.REJECTED, renew(3, now, validFor = 60 * S).outcome)
    }

    @Test
    fun `a newer opening of a gate already open replaces its lease`() {
        open(grant = 1, ageMs = 12_000)
        val opening = open(grant = 2)!!

        assertNull("no switch: it was open", opening.change)
        assertEquals(2L, gate.lease!!.grant)
        now += 12 * S
        assertTrue(admitted())
    }

    @Test
    fun `14 a renewal at the very nanosecond the lease runs out is a lapse`() {
        val first = now
        open()
        now = first + VALID
        assertEquals(RenewalOutcome.LAPSED, renew(1, first + VALID).outcome)

        val other = ScreenCaptureTransmission { now }
        other.open(1, first, VALID)
        assertEquals(RenewalOutcome.RENEWED, other.renew(1, first + VALID - 1, VALID).outcome)
        assertEquals(FrameAdmission.ADMITTED, other.admit())
    }

    @Test
    fun `15 a new capture is a new gate - closed, and the old grants mean nothing to it`() {
        open(grant = 7)
        gate.stop()

        val next = ScreenCaptureTransmission { now }
        assertEquals(FrameAdmission.WITHHELD_CLOSED, next.admit())
        assertEquals(RenewalOutcome.IGNORED, next.renew(7, now, VALID).outcome)
        assertEquals(LeaseVerdict.LIVE, next.open(1, now, VALID)!!.verdict)
    }

    @Test
    fun `each switch reports what happened since the previous one`() {
        val first = now
        gate.admit()
        val opened = open()!!.change!!
        assertEquals(TransmissionChange(true, 0, 1, refresh = true), opened)

        repeat(3) { gate.admit() }
        now = first + VALID
        repeat(2) { gate.admit() }
        val closed = gate.close()!!
        assertEquals(TransmissionChange(false, 3, 0, refresh = false, expiredBefore = 2), closed)

        repeat(5) { gate.admit() }
        assertEquals(TransmissionChange(true, 0, 5, refresh = true), open(grant = 2)!!.change)
    }

    @Test
    fun `closing a gate already closed changes nothing`() {
        assertNull(gate.close())
        assertNotNull(open()!!.change)
        gate.close()
        assertNull(gate.close())
    }

    @Test
    fun `opening before any frame asks for no refresh`() {
        assertFalse(open()!!.change!!.refresh)
    }

    @Test
    fun `two suspensions and two resumptions in a row, the second of each is nothing`() {
        open(grant = 1)
        assertNotNull(gate.close())
        assertNull(gate.close())
        assertFalse(admitted())
        assertNotNull(open(grant = 2)!!.change)
        assertNull(open(grant = 3)!!.change)
        assertTrue(admitted())
    }

    @Test
    fun `12 13 two consecutive cuts and two recoveries, each with its own grant`() {
        val start = now
        open(grant = 1)
        now = start + 10 * S
        renew(1, now)
        // First cut: no PING for 15 s.
        now = start + 25 * S
        assertFalse(admitted())
        gate.close() // Dart's suspension, when it runs
        now = start + 30 * S
        assertEquals(LeaseVerdict.LIVE, open(grant = 2)!!.verdict) // recovery confirmed
        assertTrue(admitted())
        // Second cut.
        now = start + 45 * S
        assertFalse(admitted())
        assertEquals(RenewalOutcome.LAPSED, renew(2, now).outcome)
        gate.close()
        assertEquals(RenewalOutcome.IGNORED, renew(1, now).outcome)
        assertEquals(LeaseVerdict.LIVE, open(grant = 3)!!.verdict)
        assertTrue(admitted())
    }

    // ---------------------------------------------------------------------- threads

    @Test
    fun `12 frames on one thread, renewals on another - a frame never passes after the closing`() {
        val clock = AtomicLong(now)
        val gate = ScreenCaptureTransmission { clock.get() }
        gate.open(1, clock.get(), VALID)
        val closed = AtomicBoolean(false)
        val passedAfterClose = AtomicLong(0)
        val stopFrames = AtomicBoolean(false)
        val ready = CountDownLatch(2)

        val frames = Thread {
            ready.countDown()
            while (!stopFrames.get()) {
                val wasClosed = closed.get()
                if (gate.admit() == FrameAdmission.ADMITTED && wasClosed) passedAfterClose.incrementAndGet()
            }
        }
        val renewals = Thread {
            ready.countDown()
            var i = 0L
            while (!stopFrames.get()) {
                gate.renew(1, clock.addAndGet(MS), VALID)
                i++
            }
        }
        frames.start()
        renewals.start()
        ready.await()
        Thread.sleep(50)
        gate.close()
        closed.set(true)
        Thread.sleep(50)
        stopFrames.set(true)
        frames.join()
        renewals.join()

        assertEquals(0, passedAfterClose.get())
        assertFalse(gate.transmitting)
    }

    @Test
    fun `13 concurrent renewals - the lease only ever moves forward, to the newest evidence`() {
        val clock = AtomicLong(now)
        val gate = ScreenCaptureTransmission { clock.get() }
        val base = clock.get()
        gate.open(1, base, VALID)
        clock.set(base + 5 * S)
        val threads = 8
        val perThread = 500
        val barrier = CyclicBarrier(threads)
        val workers = (0 until threads).map { t ->
            Thread {
                barrier.await()
                for (i in 0 until perThread) {
                    // Interleaved instants 1 ms apart, all in the clock's past and all inside
                    // the first lease, so none of them can lapse whatever order they land in.
                    val evidence = base + (i * threads + t + 1) * MS
                    gate.renew(1, evidence, VALID)
                }
            }
        }
        workers.forEach { it.start() }
        workers.forEach { it.join(TimeUnit.SECONDS.toMillis(10)) }

        val newest = base + (perThread * threads) * MS
        assertEquals(newest, gate.lease!!.evidenceAtNanos)
        assertEquals(newest + VALID, gate.lease!!.deadlineNanos)
    }

    @Test
    fun `revocation always wins - a closing racing renewals leaves the gate closed`() {
        repeat(200) { round ->
            val clock = AtomicLong(now)
            val gate = ScreenCaptureTransmission { clock.get() }
            gate.open(round + 1L, clock.get(), VALID)
            val barrier = CyclicBarrier(2)
            val renewer = Thread {
                barrier.await()
                repeat(20) { gate.renew(round + 1L, clock.incrementAndGet(), VALID) }
            }
            renewer.start()
            barrier.await()
            gate.close()
            renewer.join()
            assertFalse(gate.transmitting)
            assertEquals(FrameAdmission.WITHHELD_CLOSED, gate.admit())
        }
    }

    // ----------------------------------------------------------- the whole frame path

    private class Pipeline {
        var nowMs = 0L
        private val scheduled = mutableListOf<Pair<Long, Runnable>>()
        var redeliveryRequests = 0
        private var latchedNs: Long? = null
        val sent = mutableListOf<SettleFrameOutgoing>()
        var grants = 0L

        /** The elapsed-realtime clock, on the same time line as the frames' own. */
        val gate = ScreenCaptureTransmission { nowMs * NS_PER_MS }
        val settle = ScreenCaptureSettleFrame(
            timer = object : SettleFrameTimer {
                override fun schedule(action: Runnable, delayMs: Long) {
                    scheduled += (nowMs + delayMs) to action
                }

                override fun cancel(action: Runnable) {
                    scheduled.removeAll { it.second === action }
                }
            },
            nanoTime = { nowMs * NS_PER_MS },
            requestRedelivery = { redeliveryRequests++ },
        )

        /** The screen changed: the capture produces a frame, latched by the helper. */
        fun screenChanges() {
            val ns = nowMs * NS_PER_MS + OFFSET_NS
            latchedNs = ns
            deliver(ns)
        }

        /** The helper honours a pending redelivery with what it has latched. */
        fun helperRedelivers() {
            val ns = latchedNs ?: return
            deliver(ns)
        }

        private fun deliver(ns: Long) {
            if (gate.admit() != FrameAdmission.ADMITTED) return
            settle.onFrame(ns, CROP)?.let { sent += it }
        }

        /** What ScreenCapturer.openTransmission / closeTransmission do on the helper's thread. */
        fun setTransmitting(open: Boolean, evidenceAgeMs: Long = 0) {
            if (open) {
                val opening = gate.open(++grants, (nowMs - evidenceAgeMs) * NS_PER_MS, VALID) ?: return
                if (opening.change?.refresh == true && opening.verdict == LeaseVerdict.LIVE) {
                    settle.redeliverNow()
                }
            } else {
                gate.close()
            }
        }

        /** What ScreenCapturer.renewTransmission does: renew, and post a refresh if it asks. */
        fun renew(evidenceAtMs: Long = nowMs): TransmissionRenewal {
            val renewal = gate.renew(grants, evidenceAtMs * NS_PER_MS, VALID)
            if (renewal.refresh) settle.redeliverNow()
            return renewal
        }

        fun advance(ms: Long) {
            val until = nowMs + ms
            while (true) {
                val next = scheduled.filter { it.first <= until }.minByOrNull { it.first } ?: break
                scheduled.remove(next)
                nowMs = next.first
                next.second.run()
            }
            nowMs = until
        }
    }

    @Test
    fun `while suspended the capture keeps producing and nothing is sent`() {
        val p = Pipeline()
        p.setTransmitting(true)
        p.screenChanges()
        assertEquals(1, p.sent.size)

        p.setTransmitting(false)
        repeat(10) {
            p.advance(100)
            p.screenChanges()
        }
        // A settle frame asked for meanwhile comes back through the gate too.
        p.advance(2_000)
        p.helperRedelivers()

        assertEquals(1, p.sent.size)
    }

    @Test
    fun `16 after the lease runs out nothing is sent - not a change, not a settle frame`() {
        val p = Pipeline()
        p.setTransmitting(true)
        p.screenChanges()
        p.advance(800) // the settle frame of the first one fires
        p.helperRedelivers()
        val before = p.sent.size

        // No renewal ever comes: Dart is not running. The capture goes on.
        p.advance(13_000)
        repeat(50) {
            p.advance(100)
            p.screenChanges()
        }
        p.advance(2_000)
        p.helperRedelivers()

        assertEquals(before, p.sent.size)
        assertTrue(p.gate.transmitting)
    }

    @Test
    fun `a heartbeat every 10 s keeps a still screen and a busy one flowing`() {
        val p = Pipeline()
        p.setTransmitting(true)
        repeat(40) { second ->
            repeat(10) {
                p.advance(100)
                p.screenChanges()
            }
            if (second % 10 == 9) p.renew()
        }
        // 400 changes in 40 s, a renewal every 10 s: every one of them sent.
        assertEquals(400, p.sent.count { !it.isSettle })
    }

    @Test
    fun `a late renewal of timely evidence sends the screen as it is now`() {
        val p = Pipeline()
        p.setTransmitting(true)
        p.screenChanges()
        p.advance(12_000)
        val evidenceAt = p.nowMs // the PING, as Dart read it
        p.advance(1_500) // its message is late: the lease ran out at 13 s
        p.screenChanges() // withheld
        val withheldAtNs = p.nowMs * NS_PER_MS + OFFSET_NS
        val before = p.sent.size

        val renewal = p.renew(evidenceAt)
        assertTrue(renewal.refresh)
        p.helperRedelivers()

        assertEquals(before + 1, p.sent.size)
        assertEquals(withheldAtNs, p.sent.last().timestampNs)
    }

    @Test
    fun `resuming sends the screen as it is now, once, as a real frame`() {
        val p = Pipeline()
        p.setTransmitting(true)
        p.screenChanges()
        p.advance(800)
        p.helperRedelivers() // the settle frame of the first one
        val before = p.sent.size

        p.setTransmitting(false)
        p.advance(100)
        p.screenChanges() // withheld: the technician never got this image
        val withheldAtNs = p.nowMs * NS_PER_MS + OFFSET_NS
        p.advance(5_000)

        val requests = p.redeliveryRequests
        p.setTransmitting(true)
        assertEquals(requests + 1, p.redeliveryRequests)
        p.helperRedelivers()

        assertEquals(before + 1, p.sent.size)
        val refresh = p.sent.last()
        // The newest image, with its own timestamp, newer than anything sent before.
        assertEquals(withheldAtNs, refresh.timestampNs)
        assertFalse(refresh.isSettle)
    }

    @Test
    fun `resuming with a lease already run out asks for nothing and sends nothing`() {
        val p = Pipeline()
        p.setTransmitting(true)
        p.screenChanges()
        p.setTransmitting(false)
        p.advance(3_000)
        val requests = p.redeliveryRequests

        p.setTransmitting(true, evidenceAgeMs = 14_000)
        p.helperRedelivers()

        assertEquals(requests, p.redeliveryRequests)
        assertEquals(1, p.sent.size)
    }

    @Test
    fun `resuming with nothing new repeats the last frame sent, once`() {
        val p = Pipeline()
        p.setTransmitting(true)
        p.screenChanges()
        val last = p.sent.last()

        p.setTransmitting(false)
        p.advance(3_000)
        p.setTransmitting(true)
        p.helperRedelivers()
        // A second delivery of the same texture is not asked for and goes nowhere.
        p.helperRedelivers()

        assertEquals(2, p.sent.size)
        val repeat = p.sent.last()
        assertTrue(repeat.isSettle)
        assertTrue(repeat.timestampNs > last.timestampNs)
    }

    @Test
    fun `a capture opened only after its frames began sends the latest of them`() {
        val p = Pipeline()
        p.screenChanges()
        p.advance(50)
        p.screenChanges()

        p.setTransmitting(true)
        p.helperRedelivers()

        assertEquals(1, p.sent.size)
        assertFalse(p.sent.single().isSettle)
    }

    @Test
    fun `nothing at all is asked of the helper when no frame ever arrived`() {
        val p = Pipeline()

        p.setTransmitting(true)

        assertEquals(0, p.redeliveryRequests)
    }

    // ------------------------------------------------------------------- the channel

    @Test
    fun `a lease crosses the channel as Integer or Long and is read in nanoseconds`() {
        val args = mapOf<String, Any>("grant" to 3, "evidenceAtNanos" to 123_456_789_012_345L, "validForMs" to 13_000)
        val lease = ScreenTransmissionMessages.leaseOf { args[it] }!!

        assertEquals(3L, lease.grant)
        assertEquals(123_456_789_012_345L, lease.evidenceAtNanos)
        assertEquals(VALID, lease.validForNanos)
    }

    @Test
    fun `an incomplete or malformed lease is not a lease`() {
        val full = mapOf<String, Any>("grant" to 1, "evidenceAtNanos" to 5L, "validForMs" to 13_000)
        for (missing in full.keys) {
            assertNull(ScreenTransmissionMessages.leaseOf { if (it == missing) null else full[it] })
        }
        assertNull(ScreenTransmissionMessages.leaseOf { if (it == "grant") 0 else full[it] })
        assertNull(ScreenTransmissionMessages.leaseOf { if (it == "validForMs") -1 else full[it] })
        assertNull(ScreenTransmissionMessages.leaseOf { if (it == "grant") "1" else full[it] })
    }

    @Test
    fun `answers say what was applied and whether frames go through`() {
        assertEquals(mapOf("applied" to false, "live" to false), ScreenTransmissionMessages.openingAnswer(null))
        assertEquals(
            mapOf("applied" to true, "live" to true),
            ScreenTransmissionMessages.openingAnswer(TransmissionOpening(null, LeaseVerdict.LIVE, 0)),
        )
        assertEquals(
            mapOf("applied" to true, "live" to false),
            ScreenTransmissionMessages.openingAnswer(TransmissionOpening(null, LeaseVerdict.EXPIRED, 0)),
        )
        assertEquals(
            mapOf("result" to "ignored", "live" to false),
            ScreenTransmissionMessages.renewalAnswer(null),
        )
        assertEquals(
            mapOf("result" to "lapsed", "live" to false),
            ScreenTransmissionMessages.renewalAnswer(TransmissionRenewal(RenewalOutcome.LAPSED, false)),
        )
        assertEquals(
            mapOf("result" to "renewed", "live" to true),
            ScreenTransmissionMessages.renewalAnswer(TransmissionRenewal(RenewalOutcome.RENEWED, true)),
        )
    }

    private companion object {
        const val NS_PER_MS = 1_000_000L
        const val MS = NS_PER_MS
        const val S = 1_000 * MS
        const val VALID = 13 * S
        const val OFFSET_NS = 123_456_789L
        val CROP = CaptureRect(left = 0, top = 360, width = 1200, height = 1920)
    }
}
