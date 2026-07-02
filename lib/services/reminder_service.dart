import 'package:cloud_firestore/cloud_firestore.dart';
import '../constants.dart';

/// A reminder fetched from Firestore that hasn't been locally scheduled yet.
class PendingReminder {
  final String id;
  final String title;
  final DateTime scheduledAt;
  final bool addToList;
  const PendingReminder({
    required this.id,
    required this.title,
    required this.scheduledAt,
    required this.addToList,
  });
}

class ReminderService {
  static final _db = FirebaseFirestore.instance;

  static CollectionReference _col(String roomId) =>
      _db.collection('rooms').doc(roomId).collection('reminders');

  /// A sets a reminder for B. [forUser] is the recipient's role ('A' or 'B').
  static Future<void> createReminder({
    required String forUser,
    required String title,
    required DateTime scheduledAt,
    required bool addToList,
  }) async {
    await _col(chatRoomId).add({
      'forUser': forUser,
      'title': title,
      'scheduledAt': Timestamp.fromDate(scheduledAt),
      'addToList': addToList,
      'locallyScheduled': false,
      'createdBy': mySenderId,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Fetch reminders addressed to [forUser] that haven't been locally
  /// scheduled yet. Called from the background worker.
  static Future<List<PendingReminder>> fetchPending(
      String forUser, String roomId) async {
    final snap = await _db
        .collection('rooms')
        .doc(roomId)
        .collection('reminders')
        .where('forUser', isEqualTo: forUser)
        .where('locallyScheduled', isEqualTo: false)
        .get();
    return snap.docs.map((d) {
      final data = d.data();
      return PendingReminder(
        id: d.id,
        title: (data['title'] as String?)?.trim().isNotEmpty == true
            ? data['title'] as String
            : 'Reminder',
        scheduledAt: (data['scheduledAt'] as Timestamp).toDate(),
        addToList: (data['addToList'] as bool?) ?? false,
      );
    }).toList();
  }

  /// Mark a reminder as locally scheduled so the background worker skips it
  /// on subsequent runs.
  static Future<void> markScheduled(String docId, String roomId) async {
    await _db
        .collection('rooms')
        .doc(roomId)
        .collection('reminders')
        .doc(docId)
        .update({'locallyScheduled': true});
  }
}
