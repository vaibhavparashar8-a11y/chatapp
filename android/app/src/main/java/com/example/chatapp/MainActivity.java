package com.example.chatapp;

import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.view.WindowManager;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String PROXIMITY_CHANNEL    = "com.example.chatapp/proximity";
    private static final String CALL_CHANNEL         = "com.example.chatapp/call";
    private PowerManager.WakeLock proximityWakeLock;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Prevent OS from capturing a screenshot for the recents thumbnail
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), PROXIMITY_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if (call.method.equals("acquire")) {
                    acquireProximityWakeLock();
                    result.success(null);
                } else if (call.method.equals("release")) {
                    releaseProximityWakeLock();
                    result.success(null);
                } else {
                    result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CALL_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if (call.method.equals("startForeground")) {
                    startCallForegroundService();
                    result.success(null);
                } else if (call.method.equals("stopForeground")) {
                    stopCallForegroundService();
                    result.success(null);
                } else {
                    result.notImplemented();
                }
            });
    }

    @SuppressWarnings("WakelockTimeout")
    private void acquireProximityWakeLock() {
        if (proximityWakeLock == null) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            proximityWakeLock = pm.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "chatapp:proximity"
            );
            proximityWakeLock.setReferenceCounted(false);
        }
        if (!proximityWakeLock.isHeld()) {
            // 2-hour max; always released explicitly when call ends
            proximityWakeLock.acquire(2 * 60 * 60 * 1000L);
        }
    }

    private void releaseProximityWakeLock() {
        if (proximityWakeLock != null && proximityWakeLock.isHeld()) {
            proximityWakeLock.release();
        }
    }

    private void startCallForegroundService() {
        Intent i = new Intent(this, CallForegroundService.class);
        i.setAction(CallForegroundService.ACTION_START);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(i);
        } else {
            startService(i);
        }
    }

    private void stopCallForegroundService() {
        Intent i = new Intent(this, CallForegroundService.class);
        i.setAction(CallForegroundService.ACTION_STOP);
        startService(i);
    }
}
