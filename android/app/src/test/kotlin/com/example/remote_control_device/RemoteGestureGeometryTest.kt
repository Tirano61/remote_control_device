package com.example.remote_control_device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * From a normalized position to a pixel, on the SKY_PAD10MAX's two orientations. `1.0` is the
 * case that matters: `width` itself is one past the last pixel.
 */
class RemoteGestureGeometryTest {

    private val landscape = ScreenCaptureGeometry(width = 1280, height = 800, densityDpi = 160, rotation = 1)
    private val portrait = ScreenCaptureGeometry(width = 800, height = 1280, densityDpi = 160, rotation = 0)

    @Test
    fun `the top-left corner`() {
        assertEquals(GesturePixel(0, 0), landscape.gesturePixel(0.0, 0.0))
        assertEquals(GesturePixel(0, 0), portrait.gesturePixel(0.0, 0.0))
    }

    @Test
    fun `the centre`() {
        assertEquals(GesturePixel(640, 400), landscape.gesturePixel(0.5, 0.5))
        assertEquals(GesturePixel(400, 640), portrait.gesturePixel(0.5, 0.5))
    }

    @Test
    fun `the bottom-right corner is the last pixel, not one past it`() {
        assertEquals(GesturePixel(1279, 799), landscape.gesturePixel(1.0, 1.0))
        assertEquals(GesturePixel(799, 1279), portrait.gesturePixel(1.0, 1.0))
    }

    @Test
    fun `the example of the protocol`() {
        assertEquals(GesturePixel(640, 200), landscape.gesturePixel(0.5, 0.25))
    }

    @Test
    fun `the axes are not swapped on a screen taller than it is wide`() {
        assertEquals(GesturePixel(200, 960), portrait.gesturePixel(0.25, 0.75))
    }

    @Test
    fun `a position off the screen is refused, not clamped`() {
        assertThrows(IllegalArgumentException::class.java) { landscape.gesturePixel(1.1, 0.0) }
        assertThrows(IllegalArgumentException::class.java) { landscape.gesturePixel(0.0, -0.1) }
        assertThrows(IllegalArgumentException::class.java) { landscape.gesturePixel(Double.NaN, 0.0) }
        assertThrows(IllegalArgumentException::class.java) {
            landscape.gesturePixel(0.0, Double.POSITIVE_INFINITY)
        }
    }
}
