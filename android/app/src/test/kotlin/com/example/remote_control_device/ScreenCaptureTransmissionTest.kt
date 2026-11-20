package com.example.remote_control_device

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
 */
class ScreenCaptureTransmissionTest {

    // ------------------------------------------------------------------ the gate alone

    @Test
    fun `a new capture starts closed and withholds every frame`() {
        val gate = ScreenCaptureTransmission()

        assertFalse(gate.transmitting)
        assertFalse(gate.admit())
        assertFalse(gate.admit())
    }

    @Test
    fun `open, frames go through, closed again, none does`() {
        val gate = ScreenCaptureTransmission()
        gate.resume()

        assertTrue(gate.admit())
        assertTrue(gate.admit())

        gate.suspend()
        assertFalse(gate.admit())
    }

    @Test
    fun `each switch reports what happened since the previous one`() {
        val gate = ScreenCaptureTransmission()
        gate.admit()
        val opened = gate.resume()!!
        assertEquals(TransmissionChange(true, 0, 1, refresh = true), opened)

        repeat(3) { gate.admit() }
        val closed = gate.suspend()!!
        assertEquals(TransmissionChange(false, 3, 0, refresh = false), closed)

        repeat(5) { gate.admit() }
        assertEquals(TransmissionChange(true, 0, 5, refresh = true), gate.resume())
    }

    @Test
    fun `switching to the state it is already in changes nothing`() {
        val gate = ScreenCaptureTransmission()

        assertNull(gate.suspend())
        assertNotNull(gate.resume())
        assertNull(gate.resume())
    }

    @Test
    fun `opening before any frame asks for no refresh`() {
        val gate = ScreenCaptureTransmission()

        assertFalse(gate.resume()!!.refresh)
    }

    @Test
    fun `a stopped capture is closed for good`() {
        val gate = ScreenCaptureTransmission()
        gate.resume()

        gate.stop()

        assertFalse(gate.transmitting)
        assertFalse(gate.admit())
        assertNull(gate.resume())
        assertFalse(gate.admit())
    }

    @Test
    fun `two suspensions and two resumptions in a row, the second of each is nothing`() {
        val gate = ScreenCaptureTransmission()
        gate.resume()

        assertNotNull(gate.suspend())
        assertNull(gate.suspend())
        assertFalse(gate.admit())
        assertNotNull(gate.resume())
        assertNull(gate.resume())
        assertTrue(gate.admit())
    }

    // ----------------------------------------------------------- the whole frame path

    private class Pipeline {
        var nowMs = 0L
        private val scheduled = mutableListOf<Pair<Long, Runnable>>()
        var redeliveryRequests = 0
        private var latchedNs: Long? = null
        val sent = mutableListOf<SettleFrameOutgoing>()

        val gate = ScreenCaptureTransmission()
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
            if (!gate.admit()) return
            settle.onFrame(ns, CROP)?.let { sent += it }
        }

        /** What ScreenCapturer.setTransmitting does on the helper's thread. */
        fun setTransmitting(open: Boolean) {
            val change = (if (open) gate.resume() else gate.suspend()) ?: return
            if (change.refresh) settle.redeliverNow()
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

    private companion object {
        const val NS_PER_MS = 1_000_000L
        const val OFFSET_NS = 123_456_789L
        val CROP = CaptureRect(left = 0, top = 360, width = 1200, height = 1920)
    }
}
