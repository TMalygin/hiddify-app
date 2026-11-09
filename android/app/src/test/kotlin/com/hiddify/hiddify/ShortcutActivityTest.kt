package com.hiddify.hiddify

import android.content.Context
import com.hiddify.hiddify.constant.Action
import com.hiddify.hiddify.constant.ServiceMode
import com.hiddify.hiddify.constant.Status
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = android.app.Application::class)
class ShortcutActivityTest {
    @Before
    fun setUp() {
        // Attach the real app context without onCreate loading the native Go core.
        val app = Application()
        ReflectionHelpers.callInstanceMethod<Void>(
            app, "attach", ClassParameter.from(Context::class.java, RuntimeEnvironment.getApplication())
        )
        Settings.serviceMode = ServiceMode.NORMAL
        // This is the persisted value left by a normal in-app connection.
        Settings.startCoreAfterStartingService = false
    }

    @Test
    fun stoppedShortcutRequestsTheCoreAsWellAsTheForegroundService() {
        val activity = Robolectric.buildActivity(ShortcutActivity::class.java).get()
        activity.onServiceStatusChanged(Status.Stopped)

        assertTrue("The shortcut must request Mobile.start after service setup", Settings.startCoreAfterStartingService)
        val started = shadowOf(RuntimeEnvironment.getApplication()).nextStartedService
        assertNotNull("The shortcut must still start its foreground service", started)
        assertEquals(Settings.serviceClass().name, started.component?.className)
        assertTrue(activity.isFinishing)
    }

    @Test
    fun runningShortcutStopsWithoutRequestingAnotherStart() {
        val activity = Robolectric.buildActivity(ShortcutActivity::class.java).get()
        activity.onServiceStatusChanged(Status.Started)

        assertFalse(Settings.startCoreAfterStartingService)
        val application = shadowOf(RuntimeEnvironment.getApplication())
        assertNull(application.nextStartedService)
        assertTrue(application.broadcastIntents.any { it.action == Action.SERVICE_CLOSE })
        assertTrue(activity.isFinishing)
    }

    @Test
    fun transitionalStatesDoNotStartASecondService() {
        for (status in listOf(Status.Starting, Status.Stopping)) {
            val activity = Robolectric.buildActivity(ShortcutActivity::class.java).get()
            activity.onServiceStatusChanged(status)

            assertFalse(Settings.startCoreAfterStartingService)
            assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedService)
            assertTrue(activity.isFinishing)
        }
    }
}
