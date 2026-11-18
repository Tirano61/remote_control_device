package com.example.remote_control_device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MediaProjection's `onStop`, as the bookkeeping sees it: only a platform stop of the capture
 * that is running is released and reported to Dart, and only once.
 */
class RunningScreenCaptureTest {

    private data class Capture(val trackId: String)

    private val released = mutableListOf<String>()
    private val running = RunningScreenCapture<Capture>(
        trackIdOf = { it.trackId },
        release = { released += it.trackId },
    )

    @Test
    fun `a platform stop of the running capture releases it and is reported`() {
        running.started(Capture("a"))

        assertTrue(running.stoppedByPlatform("a"))

        assertEquals(listOf("a"), released)
        assertNull(running.current)
    }

    @Test
    fun `a second platform stop of the same capture is not reported again`() {
        running.started(Capture("a"))
        running.stoppedByPlatform("a")

        assertFalse(running.stoppedByPlatform("a"))
        assertEquals(listOf("a"), released)
    }

    @Test
    fun `a late platform stop of a replaced capture leaves the new one alone`() {
        running.started(Capture("old"))
        val current = Capture("new")
        running.started(current)

        assertFalse(running.stoppedByPlatform("old"))

        assertSame(current, running.current)
        assertEquals(listOf("old"), released)
    }

    @Test
    fun `a platform stop after the application stopped it is not news`() {
        running.started(Capture("a"))
        running.stop("a")

        assertFalse(running.stoppedByPlatform("a"))
        assertEquals(listOf("a"), released)
    }

    @Test
    fun `a keyed stop never takes down a capture that replaced it`() {
        running.started(Capture("old"))
        val current = Capture("new")
        running.started(current)

        running.stop("old")

        assertSame(current, running.current)
    }

    @Test
    fun `nothing running means nothing to report`() {
        assertFalse(running.stoppedByPlatform("a"))
        running.stop()
        assertTrue(released.isEmpty())
    }
}
