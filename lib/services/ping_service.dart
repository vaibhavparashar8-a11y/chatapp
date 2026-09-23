import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/ping.dart';
import 'log_service.dart';

/// "Is the app still alive on the other phone?"
///
/// The room doc already records that a phone *once* installed the app
/// (`roleAssignments`, `appLastOpened`), but those entries survive an
/// uninstall or an OEM battery-killer forever. The only honest proof is a
/// round trip: this phone writes a ping doc, the `onPingCreated` Cloud
/// Function pushes it to the other role as a silent data message, and the
/// other phone writes the reply back. A reply means the app is installed,
/// has a live FCM token, and the OS is still delivering to it.
///
/// Deliberately invisible on the receiving side: no notification is shown, in
/// line with the discreteness requirement.
class PingService {
  static bool testMode = false;
  static const _tag = 'PingService';

  /// How long the sender waits before calling it a no-show. Generous, because
  /// a dozing phone can take ten-odd seconds to act on a high-priority push.
  static const replyTimeout = Duration(seconds: 25);

  /// Test seam: when set, [ping] returns this instead of touching Firestore.
  @visibleForTesting
  static PingResult? pingOverride;

  /// Test seam: when set, [readRoom] returns this instead of reading Firestore.
  @visibleForTesting
  static DeviceCheck? roomOverride;

  // ── Pure parsers (unit-tested; no Firebase types) ─────────────────────────

  /// Builds the passive both-phones view from the raw room document.
  static DeviceCheck parseRoom(Map<String, dynamic> data,
      {required String me}) {
    final them = me == 'A' ? 'B' : 'A';
    return DeviceCheck(
      me: _recordFor(data, me),
      them: _recordFor(data, them),
    );
  }

  static DeviceRecord _recordFor(Map<String, dynamic> data, String role) {
    Map<String, dynamic> mapAt(String field) =>
        Map<String, dynamic>.from(data[field] as Map? ?? const {});

    final assignment = mapAt('roleAssignments')[role];
    final token = mapAt('fcmTokens')[role];
    return DeviceRecord(
      claimed: assignment is String && assignment.isNotEmpty,
      hasFcmToken: token is String && token.isNotEmpty,
      appLastOpened: _asDate(mapAt('appLastOpened')[role]),
      todoLastOpened: _asDate(mapAt('todoLastOpened')[role]),
    );
  }

  /// Timestamps arrive as a Firestore [Timestamp] from the wire and as a
  /// [DateTime] from tests — accept either, ignore anything else.
  static DateTime? _asDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  /// Turns the ping doc as it stands when the wait ended into a result.
  static PingResult parseReply(Map<String, dynamic>? doc, Duration elapsed) {
    final repliedBy = doc?['repliedBy'];
    if (repliedBy is! String || repliedBy.isEmpty) {
      return const PingResult(outcome: PingOutcome.timedOut);
    }
    return PingResult(
      outcome: PingOutcome.replied,
      roundTrip: elapsed,
      repliedBy: repliedBy,
      via: _viaFromStorage(doc?['replyVia']),
    );
  }

  static PingReplyVia _viaFromStorage(Object? value) {
    switch (value) {
      case 'foreground':
        return PingReplyVia.foreground;
      case 'background':
        return PingReplyVia.background;
      default:
        return PingReplyVia.unknown;
    }
  }

  static String _viaToStorage(PingReplyVia via) {
    switch (via) {
      case PingReplyVia.foreground:
        return 'foreground';
      case PingReplyVia.background:
        return 'background';
      case PingReplyVia.unknown:
        return 'unknown';
    }
  }

  // ── Firestore ─────────────────────────────────────────────────────────────

  static CollectionReference<Map<String, dynamic>> _pings(String roomId) =>
      FirebaseFirestore.instance
          .collection('rooms')
          .doc(roomId)
          .collection('pings');

  /// Reads the room doc once for the passive view. Returns null when the doc
  /// cannot be read — the caller still offers the ping button.
  static Future<DeviceCheck?> readRoom() async {
    final override = roomOverride;
    if (override != null) return override;
    if (testMode) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('rooms')
          .doc(chatRoomId)
          .get();
      return parseRoom(snap.data() ?? const {}, me: mySenderId);
    } catch (e) {
      LogService.w(_tag, 'room read failed: $e');
      return null;
    }
  }

  /// Sends one ping and waits for the other phone to answer.
  ///
  /// Never throws: every failure comes back as a [PingResult] the dialog can
  /// show, with the technical detail logged.
  static Future<PingResult> ping() async {
    final override = pingOverride;
    if (override != null) return override;
    if (testMode) {
      return const PingResult(outcome: PingOutcome.failed, error: 'testMode');
    }

    final doc = _pings(chatRoomId).doc();
    final stopwatch = Stopwatch()..start();
    try {
      await doc.set({
        'from': mySenderId,
        'sentAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      LogService.e(_tag, 'ping write failed: $e');
      return PingResult(outcome: PingOutcome.failed, error: '$e');
    }

    try {
      final snap = await doc
          .snapshots()
          .firstWhere((s) => s.data()?['repliedBy'] != null)
          .timeout(replyTimeout);
      stopwatch.stop();
      final result = parseReply(snap.data(), stopwatch.elapsed);
      LogService.i(_tag, 'ping answered by ${result.repliedBy} '
          'in ${stopwatch.elapsedMilliseconds}ms');
      return result;
    } on TimeoutException {
      LogService.w(_tag, 'ping timed out after ${replyTimeout.inSeconds}s');
      return const PingResult(outcome: PingOutcome.timedOut);
    } catch (e) {
      LogService.e(_tag, 'ping wait failed: $e');
      return PingResult(outcome: PingOutcome.failed, error: '$e');
    } finally {
      // Diagnostic traffic only — don't let it pile up in the room.
      unawaited(doc.delete().catchError(
            (Object e) => LogService.w(_tag, 'ping cleanup failed: $e'),
          ));
    }
  }

  /// Answers a ping that arrived as an FCM data push.
  ///
  /// Runs in the UI isolate (foreground push) *and* in the background isolate,
  /// where the [mySenderId] / [chatRoomId] globals were never set — hence the
  /// SharedPreferences fallback, the same keys `callbackDispatcher` uses.
  static Future<void> replyToPush(
    Map<String, dynamic> data, {
    required PingReplyVia via,
  }) async {
    if (testMode) return;
    final pingId = data['pingId'];
    if (pingId is! String || pingId.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final role = mySenderId.isNotEmpty
        ? mySenderId
        : prefs.getString('sender_role') ?? '';
    final roomId = prefs.getString('_bgChatRoomId') ?? chatRoomId;
    if (role.isEmpty) {
      LogService.w(_tag, 'ping $pingId ignored — no role on this device');
      return;
    }

    try {
      await _pings(roomId).doc(pingId).update({
        'repliedBy': role,
        'repliedAt': FieldValue.serverTimestamp(),
        'replyVia': _viaToStorage(via),
      });
      LogService.i(_tag, 'answered ping $pingId as $role');
    } catch (e) {
      // Not fatal: the sender may have given up and deleted the doc, or we are
      // offline. The sender then reports a timeout, which is the honest answer.
      LogService.w(_tag, 'ping reply failed: $e');
    }
  }
}
