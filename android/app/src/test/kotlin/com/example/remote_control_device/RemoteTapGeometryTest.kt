package com.example.remote_control_device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * From a normalized position to a pixel, on the SKY_PAD10MAX's two orientations. `1.0` is the
 * case that matters: `width` itself is one past the last pixel.
 */
class RemoteTapGeometryTest {

    private val landscape = ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1)
    private val portrait = ScreenCaptureGeometry(width = 800, height = 1280, densityDpi = 160, rotation = 0)

    @Test
    fun `the top-left corner`() {
        assertEquals(TapPixel(0, 0), landscape.tapPixel(0.0, 0.0))
        assertEquals(TapPixel(0, 0), portrait.tapPixel(0.0, 0.0))
    }

    @Test
    fun `the centre`() {
        assertEquals(TapPixel(640, 400), landscape.tapPixel(0.5, 0.5))
        assertEquals(TapPixel(400, 640), portrait.tapPixel(0.5, 0.5))
    }

    @Test
    fun `the bottom-right corner is the last pixel, not one past it`() {
        assertEquals(TapPixel(1279, 799), landscape.tapPixel(1.0, 1.0))
        assertEquals(TapPixel(799, 1279), portrait.tapPixel(1.0, 1.0))
    }

    @Test
    fun `the example of the protocol`() {
        assertEquals(TapPixel(640, 200), landscape.tapPixel(0.5, 0.25))
    }

    @Test
    fun `the axes are not swapped on a screen taller than it is wide`() {
        assertEquals(TapPixel(200, 960), portrait.tapPixel(0.25, 0.75))
    }

    @Test
    fun `a position off the screen is refused, not clamped`() {
        assertThrows(IllegalArgumentException::class.java) { landscape.tapPixel(1.1, 0.0) }
        assertThrows(IllegalArgumentException::class.java) { landscape.tapPixel(0.0, -0.1) }
        assertThrows(IllegalArgumentException::class.java) { landscape.tapPixel(Double.NaN, 0.0) }
        assertThrows(IllegalArgumentException::class.java) {
            landscape.tapPixel(0.0, Double.POSITIVE_INFINITY)
        }
    }
}
