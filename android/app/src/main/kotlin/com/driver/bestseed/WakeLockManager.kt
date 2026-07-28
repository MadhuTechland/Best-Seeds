package com.driver.bestseed

import android.content.Context
import android.os.PowerManager
import android.util.Log

/**
 * Holds a native Android PARTIAL_WAKE_LOCK for the entire driver journey.
 *
 * WHY (root cause): the previous `wakelock_plus` implementation only kept the
 * Dart isolate awake. Android Doze deep-sleep suspends the CPU regardless of
 * Dart-level flags — GPS callbacks pile up in the OS queue, the Dart isolate
 * freezes, and no location POSTs go out until the user unlocks the phone.
 *
 * A PARTIAL_WAKE_LOCK acquired at the PowerManager (OS) level survives Doze:
 * Doze's whole point is deciding when to allow the CPU to sleep, and it
 * explicitly honours held wake locks. This keeps the CPU running so the
 * flutter_background_service isolate keeps ticking, GPS stream keeps
 * delivering, and http.post keeps firing.
 *
 * Held in a process-static reference so once acquired from any surface
 * (MainActivity, foreground-service isolate, etc.) it survives Activity
 * destruction and only releases when explicitly released or when the process
 * dies (at which point Android auto-releases the lock — no leak risk).
 */
object WakeLockManager {
    private const val TAG = "WakeLockManager"
    private const val WAKE_LOCK_TAG = "Bestseeds::DriverTracking"

    @Volatile
    private var wakeLock: PowerManager.WakeLock? = null

    /**
     * Acquire the CPU wake lock. Idempotent — a second acquire is a no-op.
     */
    @Synchronized
    fun acquire(context: Context): Boolean {
        try {
            val existing = wakeLock
            if (existing != null && existing.isHeld) {
                Log.i(TAG, "acquire(): already held — no-op")
                return true
            }

            val pm = context.applicationContext
                .getSystemService(Context.POWER_SERVICE) as PowerManager
            // No timeout — we want to hold it for the whole journey (up to
            // multi-hour). We MUST release explicitly when the trip ends.
            val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            // setReferenceCounted(false): a single release() unlocks it fully
            // regardless of how many acquires happened. Cleaner semantics for
            // our idempotent acquire/release from Dart.
            lock.setReferenceCounted(false)
            lock.acquire()
            wakeLock = lock
            Log.i(TAG, "acquire(): PARTIAL_WAKE_LOCK held")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "acquire(): failed", e)
            return false
        }
    }

    /**
     * Release the wake lock. Safe to call even if not held.
     */
    @Synchronized
    fun release(): Boolean {
        try {
            val lock = wakeLock
            if (lock == null) {
                Log.i(TAG, "release(): nothing held — no-op")
                return true
            }
            if (lock.isHeld) {
                lock.release()
                Log.i(TAG, "release(): PARTIAL_WAKE_LOCK released")
            }
            wakeLock = null
            return true
        } catch (e: Exception) {
            Log.e(TAG, "release(): failed", e)
            return false
        }
    }

    /**
     * True iff the wake lock is currently held.
     */
    fun isHeld(): Boolean {
        return wakeLock?.isHeld == true
    }
}
