const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

/**
 * Triggers when A writes a new reminder doc for B.
 * Reads B's FCM token from the room doc and sends an immediate push so B's
 * device wakes up and schedules the local notification — regardless of whether
 * the app is open, backgrounded, or completely killed.
 */
exports.onReminderCreated = onDocumentCreated(
  'rooms/{roomId}/reminders/{reminderId}',
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const data = snap.data();
    const forUser = data.forUser;
    const roomId = event.params.roomId;

    // Look up the recipient's FCM token stored under rooms/{roomId}/fcmTokens.
    const roomDoc = await getFirestore().collection('rooms').doc(roomId).get();
    const fcmTokens = roomDoc.data()?.fcmTokens ?? {};
    const token = fcmTokens[forUser];

    // Token is absent if the recipient has never opened the app on this device.
    if (!token) return;

    const scheduledAt = data.scheduledAt?.toDate()?.toISOString();
    if (!scheduledAt) return;

    await getMessaging().send({
      token,
      // Notification payload: shown automatically by Android when the app is
      // backgrounded/killed (system tray). The data payload is processed by
      // the Flutter FCM handler to also schedule the future local notification.
      notification: {
        title: 'Task Reminder',
        body: data.title || 'You have a reminder',
      },
      data: {
        type: 'reminder',
        reminderId: event.params.reminderId,
        title: data.title || 'Reminder',
        scheduledAt,
        addToList: String(data.addToList ?? false),
      },
      android: {
        priority: 'high',
        notification: { channelId: 'task_reminders' },
      },
    });
  },
);
