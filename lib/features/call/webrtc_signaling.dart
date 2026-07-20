// lib/features/call/webrtc_signaling.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import '../../constants.dart';

/// Firestore-backed signalling for the single active WebRTC call.
///
/// The app is always exactly two participants and one call at a time, so a
/// single well-known doc is enough — no per-call IDs to coordinate:
///
/// ```
/// rooms/{room}/webrtc/current
///   ├── offer:  {type, sdp}      ← written by the caller
///   ├── answer: {type, sdp}      ← written by the callee
///   ├── callerCandidates/{auto}  ← trickled ICE from the caller
///   └── calleeCandidates/{auto}  ← trickled ICE from the callee
/// ```
///
/// The caller [reset]s the doc before offering so a previous call's SDP/ICE can
/// never be mistaken for the current one.
class WebRtcSignaling {
  static final _db = FirebaseFirestore.instance;

  static DocumentReference<Map<String, dynamic>> get _doc => _db
      .collection('rooms')
      .doc(chatRoomId)
      .collection('webrtc')
      .doc('current');

  static CollectionReference<Map<String, dynamic>> candidates(bool fromCaller) =>
      _doc.collection(fromCaller ? 'callerCandidates' : 'calleeCandidates');

  /// Wipe the previous call's offer/answer and ICE. Caller-only, before offering.
  static Future<void> reset() async {
    for (final fromCaller in [true, false]) {
      final snap = await candidates(fromCaller).get();
      for (final d in snap.docs) {
        await d.reference.delete();
      }
    }
    await _doc.set({
      'offer': null,
      'answer': null,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> setOffer(Map<String, dynamic> sdp) =>
      _doc.set({'offer': sdp, 'updatedAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true));

  static Future<void> setAnswer(Map<String, dynamic> sdp) =>
      _doc.set({'answer': sdp, 'updatedAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true));

  static Future<void> addCandidate(
    bool fromCaller,
    Map<String, dynamic> candidate,
  ) =>
      candidates(fromCaller).add(candidate);

  /// Emits the offer once the caller has written it (null until then).
  static Stream<Map<String, dynamic>?> offerStream() =>
      _doc.snapshots().map((s) => s.data()?['offer'] as Map<String, dynamic>?);

  /// Emits the answer once the callee has written it (null until then).
  static Stream<Map<String, dynamic>?> answerStream() =>
      _doc.snapshots().map((s) => s.data()?['answer'] as Map<String, dynamic>?);

  /// Emits each newly-added ICE candidate from the other side.
  static Stream<Map<String, dynamic>> remoteCandidateStream(bool fromCaller) =>
      candidates(fromCaller).snapshots().expand((snap) => snap.docChanges
          .where((c) => c.type == DocumentChangeType.added)
          .map((c) => c.doc.data())
          .whereType<Map<String, dynamic>>());
}
