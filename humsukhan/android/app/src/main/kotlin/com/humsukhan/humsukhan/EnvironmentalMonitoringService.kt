package com.humsukhan.humsukhan

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import org.json.JSONObject

class EnvironmentalMonitoringService : Service() {
    companion object {
        const val CHANNEL_ID = "environmental_monitoring"
        const val NOTIFICATION_ID = 4107
        private const val METHOD_CHANNEL = "com.humsukhan/environmental_monitor"
        /** SharedPreferences file name — matches Flutter's default_shared_prefs. */
        private const val PREFS_NAME = "FlutterSharedPreferences"
    }

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var stopping = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            EnvironmentalMonitoringState.ACTION_STOP -> stopMonitoring()
            EnvironmentalMonitoringState.ACTION_START -> startMonitoring()
            null -> if (EnvironmentalMonitoringState.get(this) == EnvironmentalMonitoringState.ACTIVE) startMonitoring() else stopSelf()
        }
        return START_STICKY
    }

    private fun startMonitoring() {
        if (EnvironmentalMonitoringState.get(this) == EnvironmentalMonitoringState.ACTIVE && engine != null) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            EnvironmentalMonitoringState.set(this, EnvironmentalMonitoringState.ERROR)
            stopSelf()
            return
        }
        EnvironmentalMonitoringState.set(this, EnvironmentalMonitoringState.STARTING)
        try {
            val notification = buildMonitoringNotification("Environmental monitoring: starting")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            EnvironmentalMonitoringState.set(this, EnvironmentalMonitoringState.ERROR)
            stopSelf()
            return
        }
        startFlutterBackgroundEngine()
    }

    private fun startFlutterBackgroundEngine() {
        if (engine != null) return
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, emptyArray())
            val flutterEngine = FlutterEngine(applicationContext)
            GeneratedPluginRegistrant.registerWith(flutterEngine)
            engine = flutterEngine
            channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            channel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "pipelineState" -> {
                        val state = call.argument<String>("state") ?: EnvironmentalMonitoringState.ERROR
                        EnvironmentalMonitoringState.set(this, state)
                        updateMonitoringNotification(state)
                        result.success(true)
                    }
                    "event" -> {
                        val type = call.argument<String>("type") ?: "Environmental sound"
                        val confidence = call.argument<Double>("confidence") ?: 0.0
                        val severity = call.argument<String>("severity") ?: "warning"
                        handleSoundEvent(type, confidence, severity)
                        result.success(true)
                    }
                    "policy" -> {
                        // Dart pushed a new alert policy — persist so
                        // handleSoundEvent reads the latest values.
                        persistPolicyFromDart(call.arguments)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
            val entrypoint = DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "environmentalMonitoringBackgroundMain")
            flutterEngine.dartExecutor.executeDartEntrypoint(entrypoint)
        } catch (e: Exception) {
            EnvironmentalMonitoringState.set(this, EnvironmentalMonitoringState.ERROR)
            cleanupAndStop()
        }
    }

    private fun stopMonitoring() {
        if (stopping) return
        stopping = true
        EnvironmentalMonitoringState.set(this, EnvironmentalMonitoringState.STOPPING)
        try { channel?.invokeMethod("stop", null) } catch (_: Exception) {}
        mainHandler.postDelayed({ cleanupAndStop() }, 400L)
    }

    private fun cleanupAndStop() {
        mainHandler.removeCallbacksAndMessages(null)
        channel = null
        engine?.destroy()
        engine = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }
        EnvironmentalMonitoringState.set(this, EnvironmentalMonitoringState.OFF)
        stopping = false
        stopSelf()
    }

    /**
     * Handle a detected sound event.
     *
     * This method intentionally does NOT trigger any feedback (vibration,
     * flashlight, etc.).  All presentation feedback is owned by the Flutter
     * layer ([AlertService]) to prevent duplicate vibration when both the
     * native service and the Flutter pipeline fire simultaneously.
     *
     * Responsibilities here are limited to:
     *   - Updating the ongoing notification text with the latest event.
     *   - Broadcasting the event to the main-isolate EventChannel listener.
     */
    private fun handleSoundEvent(type: String, confidence: Double, severity: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildMonitoringNotification("$type detected \u2022 local/offline"))
    
        sendBroadcast(Intent(EnvironmentalMonitoringState.ACTION_STATE).setPackage(packageName)
            .putExtra(EnvironmentalMonitoringState.EXTRA_STATE, EnvironmentalMonitoringState.ACTIVE)
            .putExtra(EnvironmentalMonitoringState.EXTRA_EVENT, JSONObject()
                .put("type", type).put("confidence", confidence).put("severity", severity).toString()))
    }

    /**
     * Persist an alert policy received from Dart into the same
     * SharedPreferences file that Flutter uses, so [handleSoundEvent]
     * always reads the latest values.
     */
    @Suppress("UNCHECKED_CAST")
    private fun persistPolicyFromDart(arguments: Any?) {
        if (arguments !is Map<*, *>) return
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().apply {
            (arguments["haptic"] as? Boolean)?.let { putBoolean("flutter.hapticAlerts", it) }
            (arguments["visual"] as? Boolean)?.let { putBoolean("flutter.visualAlerts", it) }
            (arguments["screenFlash"] as? Boolean)?.let { putBoolean("flutter.screenFlashAlerts", it) }
            (arguments["flashlight"] as? Boolean)?.let { putBoolean("flutter.flashAlerts", it) }
            apply()
        }
    }

    private fun buildMonitoringNotification(text: String): Notification {
        val stopIntent = Intent(this, EnvironmentalMonitoringService::class.java).setAction(EnvironmentalMonitoringState.ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(this, 4108, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val openIntent = Intent(this, MainActivity::class.java)
        val openPendingIntent = PendingIntent.getActivity(this, 4109, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("HumSukhan Environmental Monitoring")
            .setContentText(text)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openPendingIntent)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopPendingIntent)
            .build()
    }

    private fun updateMonitoringNotification(state: String) {
        val text = when (state) {
            EnvironmentalMonitoringState.ACTIVE -> "Environmental monitoring: Offline / Local"
            EnvironmentalMonitoringState.ERROR -> "Environmental monitoring: unavailable"
            EnvironmentalMonitoringState.STARTING -> "Environmental monitoring: starting"
            else -> "Environmental monitoring: $state"
        }
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildMonitoringNotification(text))
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Environmental Monitoring", NotificationManager.IMPORTANCE_LOW)
            channel.description = "Shows when HumSukhan is actively monitoring environmental sounds."
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        channel = null
        engine?.destroy()
        engine = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
