package com.example.remote_control_device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * The rotation as it actually happened on the SKY_PAD10MAX: `onDisplayChanged` first, still
 * reading the display as it was, and `onConfigurationChanged` after, reading it as it is.
 *
 * The display is a fake whose reading the test moves by hand, exactly when Android would.
 */
class ScreenCaptureGeometryRefreshTest {

    private val landscape = ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1)
    private val portrait = ScreenCaptureGeometry(width = 800, height = 1280, densityDpi = 160, rotation = 0)

    private val landscapeCrop = CaptureRect(left = 0, top = 240, width = 1280, height = 800)
    private val portraitCrop = CaptureRect(left = 240, top = 0, width = 800, height = 1280)

    /** What `Display.getRealMetrics` / `getRotation` answer right now. */
    private var display: ScreenCaptureGeometry = landscape
    private var reads = 0

    private fun refreshStartingIn(initial: ScreenCaptureGeometry): ScreenCaptureGeometryRefresh {
        display = initial
        return ScreenCaptureGeometryRefresh(ScreenCaptureFraming(initial)) {
            reads++
            display
        }
    }

    @Test
    fun `landscape to portrait completes on the configuration change, not before`() {
        val refresh = refreshStartingIn(landscape)
        val framing = refresh.framing

        // The tablet is turned. onDisplayChanged arrives while the reading is still 1280x800.
        assertNull("a stale reading is not a rotation", refresh.refresh())
        assertEquals(landscape, framing.geometry)
        assertEquals(landscapeCrop, framing.content)

        // The configuration catches up, and onConfigurationChanged reads the new display.
        display = portrait
        val moved = refresh.refresh()

        assertEquals(portrait, moved)
        assertEquals(portraitCrop, framing.content)
    }

    @Test
    fun `portrait to landscape completes on the configuration change, not before`() {
        val refresh = refreshStartingIn(portrait)
        val framing = refresh.framing

        assertNull(refresh.refresh()) // onDisplayChanged, still portrait
        assertEquals(portraitCrop, framing.content)

        display = landscape
        assertEquals(landscape, refresh.refresh()) // onConfigurationChanged

        assertEquals(landscapeCrop, framing.content)
    }

    @Test
    fun `the old one-signal behaviour is what lagged by one rotation`() {
        // Replays 14:28 and 14:30 with only onDisplayChanged, to pin down what the extra signal
        // is for: each display change read the orientation before it.
        val refresh = refreshStartingIn(landscape)

        assertNull(refresh.refresh()) // 14:28:05 rotated to portrait, read landscape
        display = portrait            // ...configuration updated, nobody looked again

        // 14:30:07 rotated to landscape; onDisplayChanged reads portrait — one behind.
        assertEquals(portrait, refresh.refresh())
        display = landscape

        // With the configuration signal, the next read is the right one and the crop catches up.
        assertEquals(landscape, refresh.refresh())
        assertEquals(landscapeCrop, refresh.framing.content)
    }

    @Test
    fun `duplicate signals are idempotent`() {
        val refresh = refreshStartingIn(landscape)
        display = portrait

        // onDisplayChanged after the configuration already caught up, then
        // onConfigurationChanged, then another display change: one move, not three.
        assertNotNull(refresh.refresh())
        assertNull(refresh.refresh())
        assertNull(refresh.refresh())

        assertEquals(portraitCrop, refresh.framing.content)
        assertEquals(3, reads)
    }

    @Test
    fun `a reading that arrives before the configuration never sticks`() {
        // Even a half-updated reading — rotation already new, size still old — leaves the crop
        // where the size says, and the configuration change finishes the job.
        val refresh = refreshStartingIn(landscape)

        display = landscape.copy(rotation = 0)
        refresh.refresh()
        assertEquals(landscapeCrop, refresh.framing.content)

        display = portrait
        assertEquals(portrait, refresh.refresh())
        assertEquals(portraitCrop, refresh.framing.content)
    }

    @Test
    fun `many rotations keep one framing and one virtual display`() {
        val refresh = refreshStartingIn(portrait)
        val framing = refresh.framing
        val side = framing.virtualDisplaySide

        for (next in listOf(landscape, portrait, landscape, portrait, landscape)) {
            assertNull(refresh.refresh()) // onDisplayChanged: still the old reading
            display = next
            assertEquals(next, refresh.refresh()) // onConfigurationChanged
            assertNull(refresh.refresh()) // a late duplicate
        }

        // The same framing object and the same square throughout: a rotation moves the crop of
        // the one capture that exists, it never asks for another virtual display or track.
        assertSame(framing, refresh.framing)
        assertEquals(side, framing.virtualDisplaySide)
        assertEquals(landscapeCrop, framing.content)
    }
}
