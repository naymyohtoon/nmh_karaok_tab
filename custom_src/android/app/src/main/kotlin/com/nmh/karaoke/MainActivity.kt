package com.nmh.karaoke

import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Bundle
import android.view.Display
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.nmh.karaoke/player"
    private var exoPlayer: ExoPlayer? = null
    private var tvPresentation: TvPresentation? = null
    private var tabletSurface: SurfaceView? = null
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        exoPlayer = ExoPlayer.Builder(this).build().apply {
            addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    if (state == Player.STATE_ENDED) {
                        methodChannel?.invokeMethod("onSongCompleted", null)
                    }
                }
            })
        }

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "nmh_tablet_video",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val sv = SurfaceView(context)
                    sv.setZOrderMediaOverlay(true)
                    tabletSurface = sv
                    if (tvPresentation == null) exoPlayer?.setVideoSurfaceView(sv)
                    return object : PlatformView {
                        override fun getView(): View = sv
                        override fun dispose() {
                            if (tvPresentation == null) exoPlayer?.clearVideoSurfaceView(sv)
                            tabletSurface = null
                        }
                    }
                }
            }
        )

        val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        dm.registerDisplayListener(object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(id: Int) = updateDisplay()
            override fun onDisplayRemoved(id: Int) = updateDisplay()
            override fun onDisplayChanged(id: Int) = updateDisplay()
        }, null)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkDisplay" -> { updateDisplay(); result.success(tvPresentation != null) }
                "playVideo" -> {
                    val path = call.argument<String>("path") ?: ""
                    val file = File(path)
                    if (file.exists()) {
                        exoPlayer?.apply {
                            setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
                            if (tvPresentation != null) tvPresentation?.surfaceView?.let { setVideoSurfaceView(it) }
                            else tabletSurface?.let { setVideoSurfaceView(it) }
                            prepare()
                            play()
                        }
                    }
                    result.success(true)
                }
                "pauseResume" -> {
                    val p = exoPlayer
                    if (p != null) {
                        if (p.isPlaying) p.pause() else p.play()
                        result.success(p.isPlaying)
                    } else result.success(false)
                }
                "stop" -> { exoPlayer?.stop(); exoPlayer?.clearMediaItems(); result.success(true) }
                "replay" -> { exoPlayer?.seekTo(0); exoPlayer?.play(); result.success(true) }
                "setVoiceMode" -> {
                    val mode = call.argument<String>("mode") ?: "STEREO"
                    exoPlayer?.volume = if (mode == "MUTE") 0f else 1f
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun updateDisplay() {
        val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val displays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
        if (displays.isNotEmpty()) {
            if (tvPresentation == null) {
                tvPresentation = TvPresentation(this, displays) { sv -> exoPlayer?.setVideoSurfaceView(sv) }
                tvPresentation?.show()
            }
            methodChannel?.invokeMethod("onDisplayChanged", true)
        } else {
            tvPresentation?.dismiss()
            tvPresentation = null
            tabletSurface?.let { exoPlayer?.setVideoSurfaceView(it) }
            methodChannel?.invokeMethod("onDisplayChanged", false)
        }
    }

    override fun onDestroy() {
        exoPlayer?.release()
        super.onDestroy()
    }

    class TvPresentation(ctx: Context, d: Display, val onReady: (SurfaceView) -> Unit) : Presentation(ctx, d) {
        var surfaceView: SurfaceView? = null
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            val sv = SurfaceView(context)
            surfaceView = sv
            setContentView(sv)
            sv.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(h: SurfaceHolder) = onReady(sv)
                override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, h2: Int) {}
                override fun surfaceDestroyed(h: SurfaceHolder) {}
            })
        }
    }
}

