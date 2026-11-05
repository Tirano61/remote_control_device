package com.example.remote_control_device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The settle frame against a virtual clock: time moves only when a test moves it, so "no frame
 * for 700 ms" is exact, and "several seconds later" takes none.
 *
 * The helper is modelled too. A redelivery request is queued, as `forceFrame` posts it, and the
 * test decides when it comes back and what is latched by then.
 */
class ScreenCaptureSettleFrameTest {

    private class FakeTimer : SettleFrameTimer {
        var nowMs = 0L
        private val pending = mutableListOf<Pair<Long, Runnable>>()

        val pendingCount: Int get() = pending.size

        override fun schedule(action: Runnable, delayMs: Long) {
            pending += (nowMs + delayMs) to action
        }

        override fun cancel(action: Runnable) {
            pending.removeAll { it.second === action }
        }

        fun advance(ms: Long) {
            val until = nowMs + ms
            while (true) {
                val next = pending.filter { it.first <= until }.minByOrNull { it.first } ?: break
                pending.remove(next)
                nowMs = next.first
                next.second.run()
            }
            nowMs = until
        }
    }

    private val portrait = CaptureRect(left = 240, top = 0, width = 800, height = 1280)
    private val landscape = CaptureRect(left = 0, top = 240, width = 1280, height = 800)

    private val timer = FakeTimer()
    private val requests = mutableListOf<Long>()

    private val settle = ScreenCaptureSettleFrame(
        timer = timer,
        nanoTime = { timer.nowMs * NS_PER_MS },
        requestRedelivery = { requests += timer.nowMs },
    )

    /** A real frame: its timestamp is the current virtual time on the frame's own clock. */
    private fun real(crop: CaptureRect? = portrait): SettleFrameOutgoing? =
        settle.onFrame(capturedNowNs(), crop)

    private fun capturedNowNs() = timer.nowMs * NS_PER_MS + CLOCK_OFFSET_NS

    @Test
    fun `a real frame goes out unchanged`() {
        val timestampNs = capturedNowNs()

        val out = real()!!

        assertEquals(portrait, out.crop)
        assertEquals(timestampNs, out.timestampNs)
        assertFalse(out.isSettle)
    }

    @Test
    fun `nothing before 700 ms, exactly one request at 700 ms`() {
        real()

        timer.advance(699)
        assertEquals(emptyList<Long>(), requests)

        timer.advance(1)
        assertEquals(listOf(700L), requests)
    }

    @Test
    fun `the wait is counted from the last frame of a burst`() {
        real()
        timer.advance(50)
        real()
        timer.advance(50)
        real()

        timer.advance(699)
        assertEquals("not 700 ms from the first, nor the second", emptyList<Long>(), requests)

        timer.advance(1)
        assertEquals(listOf(800L), requests)
    }

    @Test
    fun `a real frame before the timeout restarts the wait`() {
        real()
        timer.advance(500)
        real()

        timer.advance(200) // 700 ms after the first
        assertEquals("the first wait was cancelled", emptyList<Long>(), requests)

        timer.advance(499)
        assertEquals(emptyList<Long>(), requests)

        timer.advance(1) // 700 ms after the second
        assertEquals(listOf(1200L), requests)
    }

    @Test
    fun `the redelivery is the settle frame, and it is not taken for a real one`() {
        val capturedNs = capturedNowNs()
        real()
        timer.advance(700)

        val out = settle.onFrame(capturedNs, portrait)!!

        assertTrue(out.isSettle)
        assertEquals("the settle frame starts no new wait", 0, timer.pendingCount)
    }

    @Test
    fun `it does not loop`() {
        val capturedNs = capturedNowNs()
        real()
        timer.advance(700)
        settle.onFrame(capturedNs, portrait)

        timer.advance(30_000)

        assertEquals(listOf(700L), requests)
        assertEquals(0, timer.pendingCount)
    }

    @Test
    fun `one settle frame per quiet period`() {
        val firstNs = capturedNowNs()
        real()
        timer.advance(700)
        assertTrue(settle.onFrame(firstNs, portrait)!!.isSettle)

        timer.advance(5_000)
        val secondNs = capturedNowNs()
        assertFalse(real()!!.isSettle)
        timer.advance(699)
        assertEquals(listOf(700L), requests)

        timer.advance(1)
        assertTrue(settle.onFrame(secondNs, portrait)!!.isSettle)
        timer.advance(5_000)

        assertEquals(listOf(700L, 6_400L), requests)
    }

    @Test
    fun `stop before the timeout requests nothing`() {
        real()
        timer.advance(500)

        settle.stop()
        timer.advance(30_000)

        assertEquals(emptyList<Long>(), requests)
        assertEquals(0, timer.pendingCount)
    }

    @Test
    fun `a redelivery still on its way when stop arrives sends nothing`() {
        val capturedNs = capturedNowNs()
        real()
        timer.advance(700)
        assertEquals(1, requests.size)

        settle.stop()

        assertNull(settle.onFrame(capturedNs, portrait))
    }

    @Test
    fun `a timer already firing as stop arrives requests nothing`() {
        // A Handler cannot cancel a callback already running. Modelled with a timer that ignores
        // the cancel: the check inside is what stands in the way.
        var fire: Runnable? = null
        val stubborn = object : SettleFrameTimer {
            override fun schedule(action: Runnable, delayMs: Long) {
                fire = action
            }

            override fun cancel(action: Runnable) = Unit
        }
        val late = ScreenCaptureSettleFrame(stubborn, { 0L }, { requests += 0L })
        late.onFrame(1L, portrait)

        late.stop()
        fire!!.run()

        assertEquals(emptyList<Long>(), requests)
    }

    @Test
    fun `stop is idempotent and later frames go nowhere`() {
        real()
        settle.stop()
        settle.stop()

        assertNull(real())
        timer.advance(30_000)

        assertEquals(emptyList<Long>(), requests)
        assertEquals(0, timer.pendingCount)
    }

    @Test
    fun `a real frame that beats the redelivery is real, and the redelivery is discarded`() {
        real()
        timer.advance(700)
        assertEquals(1, requests.size)

        // A new image was queued before the request ran, so what comes back is new.
        timer.advance(10)
        val newNs = capturedNowNs()
        val out = settle.onFrame(newNs, portrait)!!
        assertFalse(out.isSettle)
        assertEquals(newNs, out.timestampNs)

        // The request then runs and delivers that same image again.
        timer.advance(5)
        assertNull("not sent twice", settle.onFrame(newNs, portrait))

        // And it did not touch the new frame's wait: its settle frame is still due.
        timer.advance(694)
        assertEquals(1, requests.size)
        timer.advance(1)
        assertEquals(listOf(700L, 1_410L), requests)
        assertTrue(settle.onFrame(newNs, portrait)!!.isSettle)
    }

    @Test
    fun `a repeated timestamp nobody asked for is discarded and restarts nothing`() {
        val capturedNs = capturedNowNs()
        real()
        timer.advance(300)

        assertNull(settle.onFrame(capturedNs, portrait))

        timer.advance(400)
        assertEquals("still 700 ms from the real frame", listOf(700L), requests)
    }

    @Test
    fun `a settle frame keeps the crop of its real frame, not the current one`() {
        val capturedNs = capturedNowNs()
        real(portrait)
        timer.advance(700)

        // The configuration change moved the crop, and the rotated image has not arrived yet.
        val out = settle.onFrame(capturedNs, landscape)!!

        assertEquals(portrait, out.crop)
    }

    @Test
    fun `a frame sent uncropped is repeated uncropped`() {
        val capturedNs = capturedNowNs()
        real(crop = null)
        timer.advance(700)

        assertNull(settle.onFrame(capturedNs, portrait)!!.crop)
    }

    @Test
    fun `after a rotation only the new geometry can be repeated`() {
        real(portrait)
        timer.advance(300)
        val rotatedNs = capturedNowNs()
        real(landscape)
        timer.advance(700)

        assertEquals(listOf(1_000L), requests)
        assertEquals(landscape, settle.onFrame(rotatedNs, landscape)!!.crop)
    }

    @Test
    fun `the settle frame's timestamp is newer, and on the original's clock`() {
        val capturedNs = capturedNowNs()
        real()
        timer.advance(700)

        val settled = settle.onFrame(capturedNs, portrait)!!.timestampNs

        assertTrue("newer than the original", settled > capturedNs)
        assertEquals("as far after the original as it was sent after it", capturedNs + 700 * NS_PER_MS, settled)
    }

    @Test
    fun `a redelivery that comes back late is timestamped when it comes back`() {
        // The helper holds a request back while its texture is still in use.
        val capturedNs = capturedNowNs()
        real()
        timer.advance(700)
        timer.advance(250)

        assertEquals(capturedNs + 950 * NS_PER_MS, settle.onFrame(capturedNs, portrait)!!.timestampNs)
    }

    @Test
    fun `a later real frame is newer than the settle frame before it`() {
        val capturedNs = capturedNowNs()
        real()
        timer.advance(700)
        val settled = settle.onFrame(capturedNs, portrait)!!.timestampNs

        timer.advance(1)

        assertTrue(settled < capturedNowNs())
    }

    @Test
    fun `the timestamp moves forward whatever the clocks do`() {
        val original = 5_000L

        assertEquals(original + 700, ScreenCaptureSettleFrame.settleTimestampNs(original, 100, 800))
        assertEquals(
            "a clock that stood still",
            original + 1,
            ScreenCaptureSettleFrame.settleTimestampNs(original, 100, 100),
        )
        assertEquals(
            "a clock that went back",
            original + 1,
            ScreenCaptureSettleFrame.settleTimestampNs(original, 100, 50),
        )
    }

    private companion object {
        const val NS_PER_MS = 1_000_000L

        // Frame timestamps come from the SurfaceTexture, not from nanoTime.
        const val CLOCK_OFFSET_NS = 123_456_789_000L
    }
}
