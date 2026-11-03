package com.example.remote_control_device

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Document
import org.w3c.dom.Element

/**
 * The declaration that was validated on the tablet, read from the source files. Whether Android
 * actually binds it can only be seen on a device; what can drift unnoticed is the declaration.
 */
class AccessibilityServiceDeclarationTest {

    private val manifest = parse("src/main/AndroidManifest.xml")
    private val config = parse("src/main/res/xml/accessibility_service_config.xml").documentElement

    private val service: Element = elements(manifest, "service")
        .single { it.androidAttribute("name") == ".RemoteControlAccessibilityService" }

    @Test
    fun `only the system can bind it`() {
        assertEquals(
            "android.permission.BIND_ACCESSIBILITY_SERVICE",
            service.androidAttribute("permission"),
        )
    }

    @Test
    fun `it is not exported, which is what was validated on the tablet`() {
        assertEquals("false", service.androidAttribute("exported"))
    }

    @Test
    fun `Android can find it and its configuration`() {
        val actions = elements(service, "action").map { it.androidAttribute("name") }
        assertEquals(listOf("android.accessibilityservice.AccessibilityService"), actions)

        val metaData = elements(service, "meta-data").single()
        assertEquals("android.accessibilityservice", metaData.androidAttribute("name"))
        assertEquals("@xml/accessibility_service_config", metaData.androidAttribute("resource"))
    }

    @Test
    fun `no permission was requested for it, and none it does not need`() {
        val requested = elements(manifest, "uses-permission").map { it.androidAttribute("name") }

        assertFalse(requested.contains("android.permission.BIND_ACCESSIBILITY_SERVICE"))
        assertFalse(requested.contains("android.permission.CAMERA"))
        assertFalse(requested.contains("android.permission.RECORD_AUDIO"))
        assertFalse(requested.any { it.contains("LOCATION") })
    }

    @Test
    fun `it can perform gestures and retrieve window content, and nothing else`() {
        assertEquals("true", config.androidAttribute("canPerformGestures"))
        assertEquals("true", config.androidAttribute("canRetrieveWindowContent"))

        assertFalse(config.hasAndroidAttribute("canRequestTouchExplorationMode"))
        assertFalse(config.hasAndroidAttribute("canRequestFilterKeyEvents"))
        assertFalse(config.hasAndroidAttribute("canTakeScreenshot"))
    }

    @Test
    fun `it observes no events and widens nothing with flags`() {
        // No attribute at all means no event is delivered and no flag is set, so typeAllMask,
        // flagIncludeNotImportantViews, flagReportViewIds and flagRetrieveInteractiveWindows
        // cannot be in effect.
        assertFalse(config.hasAndroidAttribute("accessibilityEventTypes"))
        assertFalse(config.hasAndroidAttribute("accessibilityFlags"))

        val source = File("src/main/res/xml/accessibility_service_config.xml").readText()
        for (excluded in listOf(
            "typeAllMask",
            "flagIncludeNotImportantViews",
            "flagReportViewIds",
            "flagRetrieveInteractiveWindows",
        )) {
            assertFalse(excluded, source.contains(excluded))
        }
    }

    @Test
    fun `Settings has something to tell the user`() {
        assertTrue(service.androidAttribute("label").startsWith("@string/"))
        assertNotNull(config.androidAttribute("description"))
        assertTrue(config.androidAttribute("description").startsWith("@string/"))
    }

    @Test
    fun `the description says what the service can do now`() {
        val description = elements(parse("src/main/res/values/strings.xml"), "string")
            .single { it.getAttribute("name") == "remote_control_accessibility_description" }
            .textContent

        assertTrue(description.contains("campo enfocado"))
        assertTrue(description.contains("ventana activa"))
        // What it said before canRetrieveWindowContent, and is no longer the whole truth.
        assertFalse(description.contains("No lee el contenido"))
    }

    private fun parse(path: String): Document =
        DocumentBuilderFactory.newInstance()
            .apply { isNamespaceAware = true }
            .newDocumentBuilder()
            .parse(File(path))

    private fun elements(document: Document, tag: String): List<Element> =
        elements(document.documentElement, tag)

    private fun elements(parent: Element, tag: String): List<Element> {
        val found = parent.getElementsByTagName(tag)
        return (0 until found.length).map { found.item(it) as Element }
    }

    private fun Element.androidAttribute(name: String): String = getAttributeNS(ANDROID, name)

    private fun Element.hasAndroidAttribute(name: String): Boolean = hasAttributeNS(ANDROID, name)

    private companion object {
        const val ANDROID = "http://schemas.android.com/apk/res/android"
    }
}
