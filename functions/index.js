const functions = require('firebase-functions');
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
exports.onReminderCreated = functions.firestore
  .document('rooms/{roomId}/reminders/{reminderId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    const forUser = data.forUser;
    const roomId = context.params.roomId;
    const reminderId = context.params.reminderId;

    // Look up the recipient's FCM token stored under rooms/{roomId}/fcmTokens.
    const roomDoc = await getFirestore().collection('rooms').doc(roomId).get();
    const fcmTokens = (roomDoc.data() || {}).fcmTokens || {};
    const token = fcmTokens[forUser];

    // Token is absent if the recipient has never opened the app on this device.
    if (!token) return null;

    const scheduledAt = data.scheduledAt && data.scheduledAt.toDate
      ? data.scheduledAt.toDate().toISOString()
      : null;
    if (!scheduledAt) return null;

    return getMessaging().send({
      token,
      // Notification payload: shown automatically by Android when the app is
      // backgrounded/killed. The data payload lets the Flutter handler also
      // schedule the future local notification.
      notification: {
        title: 'Task Reminder',
        body: data.title || 'You have a reminder',
      },
      data: {
        type: 'reminder',
        reminderId,
        title: data.title || 'Reminder',
        scheduledAt,
        addToList: String(data.addToList || false),
      },
      android: {
        priority: 'high',
        notification: { channelId: 'task_reminders' },
      },
    });
  });
