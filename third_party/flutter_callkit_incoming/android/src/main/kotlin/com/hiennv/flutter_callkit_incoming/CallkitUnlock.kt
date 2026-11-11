package com.hiennv.flutter_callkit_incoming

import android.os.Bundle

/**
 * doorbell-call patch: a third button, "Unlock", between Decline and Accept
 * on the incoming call screen and in the call notification.
 *
 * Unlock is Accept with `extra["action"] = "unlock"`: the app comes up the
 * same way and reads the action from the accept event (or from the stored
 * active call on a cold start) to open the door at once. The button shows
 * only when the call's extra has `show_unlock: true`.
 */
object CallkitUnlock {
    private const val SHOW = "show_unlock"
    private const val ACTION = "action"

    fun isShown(data: Bundle?): Boolean = extraOf(data)?.get(SHOW) == true

    /** A copy of [data] whose extra says "unlock". */
    fun withUnlock(data: Bundle?): Bundle {
        val copy = Bundle(data ?: Bundle())
        val extra = HashMap(extraOf(data) ?: hashMapOf())
        extra[ACTION] = "unlock"
        copy.putSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA, extra)
        return copy
    }

    @Suppress("UNCHECKED_CAST", "DEPRECATION")
    private fun extraOf(data: Bundle?): HashMap<String, Any?>? =
        data?.getSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA) as? HashMap<String, Any?>
}
