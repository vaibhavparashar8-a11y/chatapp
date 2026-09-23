/// Plain data for the two-phone "is the app alive over there?" check.
/// No Firebase imports — [PingService] does the Firestore/FCM work and hands
/// the raw maps to the pure parsers that build these.

/// How a ping ended.
enum PingOutcome {
  /// The other phone answered the push and wrote its reply back.
  replied,

  /// Nothing came back inside the timeout — the app is uninstalled, has no
  /// FCM token, or the OS never delivered the push.
  timedOut,

  /// The ping could not even be written (no network, Firestore rejected it).
  failed,
}

/// Which side of the other app answered — a real diagnostic, not decoration:
/// `foreground` means its UI was running, `background` means a killed or
/// backgrounded process was woken by the push alone.
enum PingReplyVia { foreground, background, unknown }

/// The result of one round trip.
class PingResult {
  final PingOutcome outcome;

  /// Send → reply, measured on this phone. Null unless [outcome] is
  /// [PingOutcome.replied].
  final Duration? roundTrip;

  /// Which role answered ('A' / 'B'), when one did.
  final String? repliedBy;

  final PingReplyVia via;

  /// Technical detail for [PingOutcome.failed] — shown in logs, not in the UI.
  final String? error;

  const PingResult({
    required this.outcome,
    this.roundTrip,
    this.repliedBy,
    this.via = PingReplyVia.unknown,
    this.error,
  });

  bool get replied => outcome == PingOutcome.replied;
}

/// What the room doc already knows about one role, without pinging anything.
class DeviceRecord {
  /// The role claimed a device id, so the app has been installed and launched
  /// at least once on that phone.
  final bool claimed;

  /// Last time that phone opened the chat screen / the todo list.
  final DateTime? appLastOpened;
  final DateTime? todoLastOpened;

  /// An FCM token is on file, so a push has somewhere to go.
  final bool hasFcmToken;

  const DeviceRecord({
    required this.claimed,
    required this.hasFcmToken,
    this.appLastOpened,
    this.todoLastOpened,
  });

  /// The most recent sign of life from either surface.
  DateTime? get lastSeen {
    final a = appLastOpened;
    final t = todoLastOpened;
    if (a == null) return t;
    if (t == null) return a;
    return a.isAfter(t) ? a : t;
  }
}

/// Passive snapshot of both phones, read from the room doc in one go.
class DeviceCheck {
  final DeviceRecord me;
  final DeviceRecord them;

  const DeviceCheck({required this.me, required this.them});

  /// Both roles have claimed a device — the closest thing the room doc has to
  /// "installed on both phones". Says nothing about whether either still is:
  /// a claim survives an uninstall, which is exactly why the ping exists.
  bool get bothClaimed => me.claimed && them.claimed;
}
