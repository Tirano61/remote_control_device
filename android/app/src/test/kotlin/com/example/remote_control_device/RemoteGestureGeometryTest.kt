package com.example.remote_control_device

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    private fun stroke(from: GesturePixel, to: GesturePixel) = GestureStroke(from, to, 300L)

    @Test
    fun `the swipe example of the protocol`() {
        assertEquals(
            stroke(GesturePixel(640, 600), GesturePixel(640, 200)),
            landscape.swipeStroke(0.5, 0.75, 0.5, 0.25, 300L),
        )
    }

    @Test
    fun `a swipe up`() {
        assertEquals(
            stroke(GesturePixel(640, 640), GesturePixel(640, 160)),
            landscape.swipeStroke(0.5, 0.8, 0.5, 0.2, 300L),
        )
        assertEquals(
            stroke(GesturePixel(400, 1024), GesturePixel(400, 256)),
            portrait.swipeStroke(0.5, 0.8, 0.5, 0.2, 300L),
        )
    }

    @Test
    fun `a swipe down`() {
        assertEquals(
            stroke(GesturePixel(640, 160), GesturePixel(640, 640)),
            landscape.swipeStroke(0.5, 0.2, 0.5, 0.8, 300L),
        )
        assertEquals(
            stroke(GesturePixel(400, 256), GesturePixel(400, 1024)),
            portrait.swipeStroke(0.5, 0.2, 0.5, 0.8, 300L),
        )
    }

    @Test
    fun `a swipe left`() {
        assertEquals(
            stroke(GesturePixel(960, 400), GesturePixel(320, 400)),
            landscape.swipeStroke(0.75, 0.5, 0.25, 0.5, 300L),
        )
        assertEquals(
            stroke(GesturePixel(600, 640), GesturePixel(200, 640)),
            portrait.swipeStroke(0.75, 0.5, 0.25, 0.5, 300L),
        )
    }

    @Test
    fun `a swipe right`() {
        assertEquals(
            stroke(GesturePixel(320, 400), GesturePixel(960, 400)),
            landscape.swipeStroke(0.25, 0.5, 0.75, 0.5, 300L),
        )
        assertEquals(
            stroke(GesturePixel(200, 640), GesturePixel(600, 640)),
            portrait.swipeStroke(0.25, 0.5, 0.75, 0.5, 300L),
        )
    }

    @Test
    fun `a diagonal swipe`() {
        assertEquals(
            stroke(GesturePixel(320, 200), GesturePixel(960, 600)),
            landscape.swipeStroke(0.25, 0.25, 0.75, 0.75, 300L),
        )
        assertEquals(
            stroke(GesturePixel(200, 320), GesturePixel(600, 960)),
            portrait.swipeStroke(0.25, 0.25, 0.75, 0.75, 300L),
        )
    }

    @Test
    fun `a swipe to the far corner ends on the last pixel, not one past it`() {
        assertEquals(
            stroke(GesturePixel(0, 0), GesturePixel(1279, 799)),
            landscape.swipeStroke(0.0, 0.0, 1.0, 1.0, 300L),
        )
        assertEquals(
            stroke(GesturePixel(799, 1279), GesturePixel(0, 0)),
            portrait.swipeStroke(1.0, 1.0, 0.0, 0.0, 300L),
        )
    }

    @Test
    fun `two positions on one pixel are no swipe, because Android would hold a touch there`() {
        assertNull(landscape.swipeStroke(0.5, 0.5, 0.5001, 0.5001, 300L))
    }

    @Test
    fun `a swipe off the screen is refused, not clamped`() {
        assertThrows(IllegalArgumentException::class.java) {
            landscape.swipeStroke(0.5, 0.5, 1.1, 0.5, 300L)
        }
        assertThrows(IllegalArgumentException::class.java) {
            landscape.swipeStroke(-0.1, 0.5, 0.5, 0.5, 300L)
        }
    }
}
