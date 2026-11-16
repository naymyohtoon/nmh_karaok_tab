package com.nmh.karaoke

import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaPlayer
import android.os.Bundle
import android.view.Display
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.nmh.karaoke/player"
    private var mediaPlayer: MediaPlayer? = null
    private var tvPresentation: TvPresentation? = null
    private var tabletSurface: SurfaceView? = null
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "nmh_tablet_video",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val sv = SurfaceView(context)
                    tabletSurface = sv
                    sv.holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            if (tvPresentation == null) mediaPlayer?.setDisplay(holder)
                        }
                        override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, h2: Int) {}
                        override fun surfaceDestroyed(h: SurfaceHolder) {
                            if (tvPresentation == null) mediaPlayer?.setDisplay(null)
                        }
                    })
                    return object : PlatformView {
                        override fun getView(): View = sv
                        override fun dispose() { tabletSurface = null }
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
                "playVideo" -> { playVideo(call.argument<String>("path") ?: ""); result.success(true) }
                "pauseResume" -> {
                    val mp = mediaPlayer
                    if (mp != null) {
                        if (mp.isPlaying) mp.pause() else mp.start()
                        result.success(mp.isPlaying)
                    } else result.success(false)
                }
                "stop" -> { mediaPlayer?.stop(); mediaPlayer?.reset(); result.success(true) }
                "replay" -> { mediaPlayer?.seekTo(0); mediaPlayer?.start(); result.success(true) }
                "setVoiceMode" -> { setVoice(call.argument<String>("mode") ?: "STEREO"); result.success(true) }
                else -> result.notImplemented()
            }
        }
    }

    private fun updateDisplay() {
        val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val displays = dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
        if (displays.isNotEmpty()) {
            if (tvPresentation == null) {
                tvPresentation = TvPresentation(this, displays[0]) { holder -> mediaPlayer?.setDisplay(holder) }
                tvPresentation?.show()
            }
            methodChannel?.invokeMethod("onDisplayChanged", true)
        } else {
            tvPresentation?.dismiss()
            tvPresentation = null
            tabletSurface?.holder?.let { if (it.surface.isValid) mediaPlayer?.setDisplay(it) }
            methodChannel?.invokeMethod("onDisplayChanged", false)
        }
    }

    private fun playVideo(path: String) {
        mediaPlayer?.release()
        mediaPlayer = MediaPlayer().apply {
            setDataSource(path)
            if (tvPresentation != null) tvPresentation?.surfaceHolder?.let { setDisplay(it) }
            else tabletSurface?.holder?.let { if (it.surface.isValid) setDisplay(it) }
            setOnPreparedListener { start() }
            setOnCompletionListener { methodChannel?.invokeMethod("onSongCompleted", null) }
            prepareAsync()
        }
    }

    private fun setVoice(mode: String) {
        val mp = mediaPlayer ?: return
        when (mode) {
            "LEFT" -> mp.setVolume(1.0f, 0.0f)
            "RIGHT" -> mp.setVolume(0.0f, 1.0f)
            else -> mp.setVolume(1.0f, 1.0f)
        }
    }

    class TvPresentation(ctx: Context, d: Display, val onReady: (SurfaceHolder) -> Unit) : Presentation(ctx, d) {
        var surfaceHolder: SurfaceHolder? = null
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            val sv = SurfaceView(context)
            setContentView(sv)
            sv.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(h: SurfaceHolder) { surfaceHolder = h; onReady(h) }
                override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, h2: Int) {}
                override fun surfaceDestroyed(h: SurfaceHolder) { surfaceHolder = null }
            })
        }
    }
}
