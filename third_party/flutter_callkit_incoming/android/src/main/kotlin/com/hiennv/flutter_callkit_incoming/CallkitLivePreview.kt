package com.hiennv.flutter_callkit_incoming

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RendererCommon
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack
import java.util.concurrent.TimeUnit

/**
 * doorbell-call patch: live video on the ringing screen, before answering.
 *
 * Opens the call's `extra["preview_url"]` (the doorbell server's go2rtc
 * signaling relay) with the call's headers, offers to receive video only, so
 * the ringtone stays the only sound, and draws into [renderer]. [onFirstFrame]
 * runs on the main thread once a frame is on screen. The WebRTC library
 * itself comes with flutter_webrtc, which the app already has.
 */
class CallkitLivePreview(
    private val context: Context,
    private val renderer: SurfaceViewRenderer,
    private val url: String,
    private val headers: Map<String, String>,
    private val onFirstFrame: () -> Unit,
) {
    companion object {
        private const val TAG = "CallkitLivePreview"
        private const val PREVIEW_URL = "preview_url"

        @Suppress("UNCHECKED_CAST", "DEPRECATION")
        fun urlFrom(data: Bundle?): String? {
            val extra = data?.getSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA)
                    as? HashMap<String, Any?>
            return (extra?.get(PREVIEW_URL) as? String)?.takeIf { it.isNotEmpty() }
        }

        @Suppress("UNCHECKED_CAST", "DEPRECATION")
        fun headersFrom(data: Bundle?): Map<String, String> {
            val h = data?.getSerializable(CallkitConstants.EXTRA_CALLKIT_HEADERS)
                    as? HashMap<String, Any?> ?: return emptyMap()
            return h.mapNotNull { (k, v) -> v?.let { k to it.toString() } }.toMap()
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val egl = EglBase.create()
    private val http = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build()
    private var factory: PeerConnectionFactory? = null
    private var pc: PeerConnection? = null
    private var socket: WebSocket? = null
    private var closed = false

    /** Local candidates found before the offer went out (go2rtc needs the
     * offer first). Main thread only. */
    private var early: MutableList<String>? = mutableListOf()

    fun start() {
        renderer.init(egl.eglBaseContext, object : RendererCommon.RendererEvents {
            override fun onFirstFrameRendered() {
                main.post { if (!closed) onFirstFrame() }
            }

            override fun onFrameResolutionChanged(w: Int, h: Int, rotation: Int) {}
        })
        renderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)

        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context.applicationContext)
                .createInitializationOptions()
        )
        val f = PeerConnectionFactory.builder()
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
            .createPeerConnectionFactory()
        factory = f
        val config = PeerConnection.RTCConfiguration(
            listOf(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer())
        ).apply { sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN }
        val peer = f.createPeerConnection(config, observer) ?: return stop()
        pc = peer
        peer.addTransceiver(
            MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY)
        )

        val request = Request.Builder().url(url)
            .apply { headers.forEach { (k, v) -> addHeader(k, v) } }
            .build()
        socket = http.newWebSocket(request, listener)
    }

    fun stop() {
        if (closed) return
        closed = true
        socket?.close(1000, null)
        socket = null
        pc?.dispose()
        pc = null
        factory?.dispose()
        factory = null
        renderer.release()
        egl.release()
        http.dispatcher().executorService().shutdown()
    }

    private fun send(type: String, value: String) {
        socket?.send(JSONObject().put("type", type).put("value", value).toString())
    }

    private fun sendOffer() {
        val peer = pc ?: return
        peer.createOffer(object : SdpAdapter() {
            override fun onCreateSuccess(sdp: SessionDescription) {
                peer.setLocalDescription(object : SdpAdapter() {
                    override fun onSetSuccess() {
                        main.post {
                            if (closed) return@post
                            send("webrtc/offer", sdp.description)
                            early?.forEach { send("webrtc/candidate", it) }
                            early = null
                        }
                    }
                }, sdp)
            }
        }, MediaConstraints())
    }

    private val observer = object : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) {
            main.post {
                if (closed) return@post
                early?.add(candidate.sdp) ?: send("webrtc/candidate", candidate.sdp)
            }
        }

        override fun onTrack(transceiver: RtpTransceiver) {
            val track = transceiver.receiver.track() as? VideoTrack ?: return
            main.post { if (!closed) track.addSink(renderer) }
        }

        override fun onSignalingChange(state: PeerConnection.SignalingState) {}
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {}
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {}
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
        override fun onAddStream(stream: MediaStream) {}
        override fun onRemoveStream(stream: MediaStream) {}
        override fun onDataChannel(channel: DataChannel) {}
        override fun onRenegotiationNeeded() {}
    }

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            main.post { if (!closed) sendOffer() }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val msg = try {
                JSONObject(text)
            } catch (e: Exception) {
                return
            }
            val value = msg.optString("value")
            main.post {
                if (closed) return@post
                when (msg.optString("type")) {
                    "webrtc/answer" -> pc?.setRemoteDescription(
                        SdpAdapter(), SessionDescription(SessionDescription.Type.ANSWER, value)
                    )
                    // One video m-line in the offer: mid "0".
                    "webrtc/candidate" -> pc?.addIceCandidate(IceCandidate("0", 0, value))
                    "error" -> Log.w(TAG, "server: $value")
                }
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Log.w(TAG, "preview signaling failed: ${t.message}")
        }
    }

    private open class SdpAdapter : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) {
            Log.w(TAG, "create sdp: $error")
        }

        override fun onSetFailure(error: String?) {
            Log.w(TAG, "set sdp: $error")
        }
    }
}
