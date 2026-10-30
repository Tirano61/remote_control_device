package com.example.remote_control_device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The capture geometry, without a tablet.
 *
 * The numbers are the SKY_PAD10MAX the bug was found on — an 800×1280 panel — but nothing in
 * the code under test knows them: they arrive as a display reading, as they do on a device.
 */
class ScreenCaptureGeometryTest {

    private val portrait = ScreenCaptureGeometry(width = 800, height = 1280, densityDpi = 160, rotation = 0)
    private val landscape = ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1)

    @Test
    fun `portrait is sent at the display's own size, centred in the square`() {
        val framing = ScreenCaptureFraming(portrait)

        assertEquals(1280, framing.virtualDisplaySide)
        assertEquals(CaptureRect(left = 240, top = 0, width = 800, height = 1280), framing.content)
        assertEquals("portrait", portrait.orientation)
    }

    @Test
    fun `landscape is sent 1280x800, never the natural size turned the wrong way`() {
        val framing = ScreenCaptureFraming(landscape)

        // The plugin produced 800x1280 here and resized it: the left 62.5 % of the screen,
        // stretched 1.6x. All 1280 columns and all 800 rows, at 1:1.
        assertEquals(1280, framing.virtualDisplaySide)
        assertEquals(CaptureRect(left = 0, top = 240, width = 1280, height = 800), framing.content)
        assertTrue(landscape.isLandscape)
    }

    @Test
    fun `the picture is never scaled when the square is the long side`() {
        for (geometry in listOf(portrait, landscape)) {
            val content = geometry.contentIn(geometry.squareSide)
            assertEquals(geometry.width, content.width)
            assertEquals(geometry.height, content.height)
        }
    }

    @Test
    fun `rotating moves the picture inside the same virtual display`() {
        val framing = ScreenCaptureFraming(portrait)
        val side = framing.virtualDisplaySide

        assertTrue(framing.update(landscape))
        assertEquals(CaptureRect(0, 240, 1280, 800), framing.content)

        assertTrue(framing.update(portrait))
        assertEquals(CaptureRect(240, 0, 800, 1280), framing.content)

        assertTrue(framing.update(landscape))
        assertEquals(CaptureRect(0, 240, 1280, 800), framing.content)

        // One virtual display for the whole capture: rotation never resizes it, and so never
        // needs a second one, a new track or a renegotiation.
        assertEquals(side, framing.virtualDisplaySide)
    }

    @Test
    fun `a capture started in landscape rotates to portrait correctly`() {
        val framing = ScreenCaptureFraming(landscape)

        framing.update(portrait)

        assertEquals(1280, framing.virtualDisplaySide)
        assertEquals(CaptureRect(240, 0, 800, 1280), framing.content)
    }

    @Test
    fun `an unchanged display is not a change`() {
        val framing = ScreenCaptureFraming(portrait)

        assertFalse(framing.update(portrait.copy()))
    }

    @Test
    fun `reverse landscape is still landscape`() {
        val reverse = landscape.copy(rotation = 3)
        val framing = ScreenCaptureFraming(landscape)

        // Changed (for the log) but framed identically.
        assertTrue(framing.update(reverse))
        assertEquals(CaptureRect(0, 240, 1280, 800), framing.content)
        assertEquals(270, reverse.rotationDegrees)
    }

    @Test
    fun `a display larger than the square is fitted, as the platform fits it`() {
        // A resolution change mid-capture: the square cannot grow, so Android scales the
        // mirror down to fit, keeping its aspect. The crop follows the same arithmetic.
        val bigger = ScreenCaptureGeometry(width = 1600, height = 2560, densityDpi = 320, rotation = 0)

        val content = bigger.contentIn(1280)

        assertEquals(CaptureRect(left = 240, top = 0, width = 800, height = 1280), content)
    }

    @Test
    fun `a square display fills the square`() {
        val square = ScreenCaptureGeometry(width = 1000, height = 1000, densityDpi = 160, rotation = 0)

        assertEquals(CaptureRect(0, 0, 1000, 1000), square.contentIn(square.squareSide))
    }

    @Test
    fun `odd leftovers round down on the leading edge, as the platform does`() {
        val odd = ScreenCaptureGeometry(width = 801, height = 1280, densityDpi = 160, rotation = 0)

        // (1280 - 801) / 2 = 239 in integer arithmetic, like ContentRecorder's shift.
        assertEquals(CaptureRect(239, 0, 801, 1280), odd.contentIn(1280))
    }
}
