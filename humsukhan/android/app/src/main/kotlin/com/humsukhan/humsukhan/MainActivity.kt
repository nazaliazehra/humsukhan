package com.humsukhan.humsukhan

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
        const val EXTRA_REQUEST_ENVIRONMENTAL_PERMISSION = "request_environmental_permission"
        private const val ENV_CHANNEL = "com.humsukhan/environmental_monitor"
        private const val ENV_EVENTS = "com.humsukhan/environmental_monitor/events"
        private const val ENV_PERMISSION_REQUEST = 8401
    }

    private val FLASH_CHANNEL = "com.humsukhan.flashlight"
    private var cameraManager: CameraManager? = null
    /** Camera ID that actually supports a torch — not just cameraIdList.first(). */
    private var torchCameraId: String? = null
    private var isTorchOn = false
    /** When true, any in-progress flash pattern is aborted. */
    private var torchCancelled = false
    private var torchFlashActive = false
    private var eventSink: EventChannel.EventSink? = null
    private var receiverRegistered = false

    private val environmentalReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != EnvironmentalMonitoringState.ACTION_STATE) return
            val payload = mutableMapOf<String, Any?>()
            payload["state"] = intent.getStringExtra(EnvironmentalMonitoringState.EXTRA_STATE)
            payload["event"] = intent.getStringExtra(EnvironmentalMonitoringState.EXTRA_EVENT)
            runOnUiThread { eventSink?.success(payload) }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        maybeRequestEnvironmentalPermission(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        maybeRequestEnvironmentalPermission(intent)
    }

    private fun maybeRequestEnvironmentalPermission(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_REQUEST_ENVIRONMENTAL_PERMISSION, false) == true) {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), ENV_PERMISSION_REQUEST)
            } else {
                EnvironmentalMonitoringState.requestStart(this)
            }
            intent.removeExtra(EXTRA_REQUEST_ENVIRONMENTAL_PERMISSION)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == ENV_PERMISSION_REQUEST) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                EnvironmentalMonitoringState.requestStart(this)
            } else {
                EnvironmentalMonitoringState.set(this, EnvironmentalMonitoringState.ERROR)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        try {
            cameraManager = getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            torchCameraId = findTorchCamera(cameraManager)
        } catch (e: Exception) {
            e.printStackTrace()
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FLASH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "turnOn" -> { turnOnTorch(); result.success(true) }
                    "turnOff" -> { turnOffTorch(); result.success(true) }
                    "isAvailable" -> result.success(torchCameraId != null)
                    "flashPattern" -> {
                        val count = call.argument<Int>("count") ?: 2
                        val onMs = call.argument<Int>("onMs") ?: 200
                        val offMs = call.argument<Int>("offMs") ?: 150
                        runFlashPattern(count, onMs, offMs)
                        result.success(true)
                    }
                    "cancelFlash" -> {
                        torchCancelled = true
                        turnOffTorch()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENV_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getState" -> result.success(EnvironmentalMonitoringState.get(this))
                    "start" -> {
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            result.error("MIC_PERMISSION", "Microphone permission is required", null)
                        } else {
                            EnvironmentalMonitoringState.requestStart(this)
                            result.success(true)
                        }
                    }
                    "stop" -> {
                        EnvironmentalMonitoringState.requestStop(this)
                        result.success(true)
                    }
                    "isSupported" -> result.success(true)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, ENV_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    registerEnvironmentalReceiver()
                    eventSink?.success(mapOf("state" to EnvironmentalMonitoringState.get(this@MainActivity)))
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    unregisterEnvironmentalReceiver()
                }
            })
    }

    private fun registerEnvironmentalReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(EnvironmentalMonitoringState.ACTION_STATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(environmentalReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION") registerReceiver(environmentalReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun unregisterEnvironmentalReceiver() {
        if (!receiverRegistered) return
        try { unregisterReceiver(environmentalReceiver) } catch (_: Exception) {}
        receiverRegistered = false
    }

    /**
     * Iterate cameraIdList and return the first camera that reports
     * FLASH_INFO_AVAILABLE = true.  This avoids assuming the first camera
     * is the rear-facing flash camera.
     */
    private fun findTorchCamera(cm: CameraManager?): String? {
        cm ?: return null
        for (id in cm.cameraIdList) {
            try {
                val chars = cm.getCameraCharacteristics(id)
                val available = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false
                if (available) return id
            } catch (e: CameraAccessException) {
                // Skip this camera and try the next.
            }
        }
        return null
    }

    private fun turnOnTorch() {
        try {
            val id = torchCameraId ?: return
            if (!isTorchOn) {
                cameraManager?.setTorchMode(id, true)
                isTorchOn = true
            }
        } catch (e: Exception) {
            Log.w(TAG, "Flashlight turnOn failed", e)
            isTorchOn = false
        }
    }

    private fun turnOffTorch() {
        try {
            val id = torchCameraId ?: return
            if (isTorchOn) {
                cameraManager?.setTorchMode(id, false)
                isTorchOn = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "Flashlight turnOff failed", e)
        }
    }

    /**
     * Run a serialized flash pattern on a background thread.  A previous
     * pattern is cancelled before starting a new one so that overlapping
     * alerts cannot fight each other.
     */
    private fun runFlashPattern(count: Int, onMs: Int, offMs: Int) {
        // Cancel any in-progress pattern first.
        torchCancelled = true
        turnOffTorch()
        torchCancelled = false
        torchFlashActive = true

        Thread {
            try {
                for (i in 0 until count) {
                    if (torchCancelled) break
                    runOnUiThread { turnOnTorch() }
                    Thread.sleep(onMs.toLong())
                    if (torchCancelled) break
                    runOnUiThread { turnOffTorch() }
                    if (i < count - 1) Thread.sleep(offMs.toLong())
                }
            } catch (_: InterruptedException) {
                // Pattern was cancelled; turn off and exit.
                runOnUiThread { turnOffTorch() }
            } finally {
                torchFlashActive = false
            }
        }.start()
    }

    override fun onDestroy() {
        unregisterEnvironmentalReceiver()
        turnOffTorch()
        super.onDestroy()
    }
}
