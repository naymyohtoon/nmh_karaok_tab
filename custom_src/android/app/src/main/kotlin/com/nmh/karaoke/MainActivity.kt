package com.nmh.karaoke

import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaPlayer
import android.os.Bundle
import android.view.Display
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.nmh.karaoke/player"
    private var displayManager: DisplayManager? = null
    private var presentation: KaraokePresentation? = null
    private var mediaPlayer: MediaPlayer? = null
    private var currentVoiceMode = "STEREO" // STEREO, LEFT, RIGHT, TRACK2
    private var methodChannel: MethodChannel? = null

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {
            setupSecondaryDisplay()
        }

        override fun onDisplayRemoved(displayId: Int) {
            presentation?.dismiss()
            presentation = null
            notifyDisplayStatus(false)
        }

        override fun onDisplayChanged(displayId: Int) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        displayManager?.registerDisplayListener(displayListener, null)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkDisplay" -> {
                    val connected = setupSecondaryDisplay()
                    result.success(connected)
                }
                "playVideo" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        playVideoOnTv(path)
                        result.success(true)
                    } else {
                        result.error("INVALID_PATH", "Video path is null", null)
                    }
                }
                "pauseResume" -> {
                    val isPlaying = togglePauseResume()
                    result.success(isPlaying)
                }
                "replay" -> {
                    mediaPlayer?.seekTo(0)
                    mediaPlayer?.start()
                    result.success(true)
                }
                "stop" -> {
                    stopPlayback()
                    result.success(true)
                }
                "setVoiceMode" -> {
                    val mode = call.argument<String>("mode") ?: "STEREO"
                    applyVoiceMode(mode)
                    result.success(currentVoiceMode)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun notifyDisplayStatus(isConnected: Boolean) {
        runOnUiThread {
            methodChannel?.invokeMethod("onDisplayChanged", isConnected)
        }
    }

    private fun setupSecondaryDisplay(): Boolean {
        val displays = displayManager?.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
        if (!displays.isNullOrEmpty()) {
            val tvDisplay = displays[0]
            if (presentation == null || presentation?.display?.displayId != tvDisplay.displayId) {
                presentation?.dismiss()
                presentation = KaraokePresentation(this, tvDisplay)
                presentation?.show()
            }
            notifyDisplayStatus(true)
            return true
        }
        notifyDisplayStatus(false)
        return false
    }

    private fun playVideoOnTv(filePath: String) {
        setupSecondaryDisplay()
        val file = File(filePath)
        if (!file.exists()) return

        try {
            mediaPlayer?.release()
            mediaPlayer = MediaPlayer().apply {
                setDataSource(filePath)
                presentation?.surfaceView?.holder?.let { holder ->
                    if (holder.surface.isValid) {
                        setDisplay(holder)
                    }
                }
                setOnPreparedListener { mp ->
                    applyVoiceMode(currentVoiceMode)
                    mp.start()
                }
                setOnCompletionListener {
                    runOnUiThread {
                        methodChannel?.invokeMethod("onSongCompleted", null)
                    }
                }
                prepareAsync()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun togglePauseResume(): Boolean {
        val mp = mediaPlayer ?: return false
        return if (mp.isPlaying) {
            mp.pause()
            false
        } else {
            mp.start()
            true
        }
    }

    private fun stopPlayback() {
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
            mediaPlayer = null
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun applyVoiceMode(mode: String) {
        currentVoiceMode = mode
        val mp = mediaPlayer ?: return
        try {
            val tracks = mp.trackInfo
            val audioTracks = mutableListOf<Int>()
            for (i in tracks.indices) {
                if (tracks[i].trackType == MediaPlayer.TrackInfo.MEDIA_TRACK_TYPE_AUDIO) {
                    audioTracks.add(i)
                }
            }

            when (mode) {
                "STEREO" -> {
                    if (audioTracks.isNotEmpty()) mp.selectTrack(audioTracks[0])
                    mp.setVolume(1.0f, 1.0f)
                }
                "LEFT" -> {
                    if (audioTracks.isNotEmpty()) mp.selectTrack(audioTracks[0])
                    mp.setVolume(1.0f, 0.0f)
                }
                "RIGHT" -> {
                    if (audioTracks.isNotEmpty()) mp.selectTrack(audioTracks[0])
                    mp.setVolume(0.0f, 1.0f)
                }
                "TRACK2" -> {
                    if (audioTracks.size > 1) {
                        mp.selectTrack(audioTracks[1])
                    } else if (audioTracks.isNotEmpty()) {
                        mp.selectTrack(audioTracks[0])
                    }
                    mp.setVolume(1.0f, 1.0f)
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onDestroy() {
        displayManager?.unregisterDisplayListener(displayListener)
        stopPlayback()
        presentation?.dismiss()
        super.onDestroy()
    }

    inner class KaraokePresentation(context: Context, display: Display) : Presentation(context, display) {
        lateinit var surfaceView: SurfaceView

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            val layout = FrameLayout(context).apply {
                setBackgroundColor(android.graphics.Color.BLACK)
            }
            surfaceView = SurfaceView(context)
            surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    mediaPlayer?.setDisplay(holder)
                }
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    mediaPlayer?.setDisplay(null)
                }
            })
            layout.addView(surfaceView, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
            setContentView(layout)
        }
    }
}
