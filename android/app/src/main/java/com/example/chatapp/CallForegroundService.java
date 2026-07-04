package com.example.chatapp;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import androidx.core.app.NotificationCompat;

/**
 * Foreground service that keeps the Agora RTC engine alive when the user
 * switches to another app during a call. Without this, Android eventually
 * kills the background process and the call drops.
 *
 * Discreteness: Android REQUIRES a notification for every foreground
 * service — it cannot be removed entirely. It is made as invisible as the
 * OS allows: IMPORTANCE_MIN (no status-bar icon; collapsed at the bottom
 * of the shade), VISIBILITY_SECRET (hidden from the lock screen), and
 * neutral wording that says nothing about a call.
 */
public class CallForegroundService extends Service {

    public static final String ACTION_START = "com.example.chatapp.START_CALL";
    public static final String ACTION_STOP  = "com.example.chatapp.STOP_CALL";

    // v2: notification channels are cached by the OS once created, so the
    // old IMPORTANCE_LOW "Call in Progress" channel cannot be updated in
    // place — a new ID is required (the old channel is deleted below).
    private static final String LEGACY_CHANNEL_ID = "chatapp_call_channel";
    private static final String CHANNEL_ID        = "chatapp_bg_channel_v2";
    private static final int    NOTIF_ID          = 1002;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopForeground(true);
            stopSelf();
            return START_NOT_STICKY;
        }
        startForeground(NOTIF_ID, buildNotification());
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm == null) return;
            // Remove the old loud channel so it disappears from the app's
            // notification settings on devices that already created it.
            nm.deleteNotificationChannel(LEGACY_CHANNEL_ID);
            // Neutral name — this string is visible in system settings.
            NotificationChannel ch = new NotificationChannel(
                CHANNEL_ID,
                "Background sync",
                NotificationManager.IMPORTANCE_MIN
            );
            ch.setSound(null, null);
            ch.setShowBadge(false);
            ch.setLockscreenVisibility(Notification.VISIBILITY_SECRET);
            nm.createNotificationChannel(ch);
        }
    }

    private Notification buildNotification() {
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );
        // Deliberately bland: no mention of a call anywhere.
        return new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MyTask")
            .setContentText("Running")
            .setSmallIcon(R.drawable.ic_bg_notification)
            .setContentIntent(pi)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build();
    }
}
