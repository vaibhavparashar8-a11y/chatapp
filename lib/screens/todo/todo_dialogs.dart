part of '../todo_screen.dart';

// ── Reminder-related dialogs ─────────────────────────────────────────────────
// Pulled out of _TodoScreenState to keep the screen lean. These are async
// helpers that only read state / show dialogs (no setState), so an extension
// is analyzer-clean.

extension _TodoDialogs on _TodoScreenState {
  /// Configure the daily WhatsApp task summary + per-task WhatsApp pings.
  /// Writes this device's own role settings; the Cloud Functions read them and
  /// message this phone's WhatsApp number via CallMeBot.
  Future<void> _showWhatsAppSettings() async {
    final settings = await WhatsAppSettingsService.load();
    if (!mounted) return;

    bool enabled = settings.enabled;
    var time = TimeOfDay(hour: settings.hour, minute: settings.minute);
    final phoneCtrl = TextEditingController(text: settings.phone);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Daily task summary'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Send to WhatsApp'),
                  subtitle: const Text(
                      'A morning checklist of the day’s tasks, plus a ping when each timed task is due.'),
                  value: enabled,
                  onChanged: (v) => setLocal(() => enabled = v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: enabled,
                  leading: const Icon(Icons.schedule),
                  title: const Text('Summary time'),
                  trailing: Text(time.format(ctx),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  onTap: enabled
                      ? () async {
                          final picked = await showTimePicker(
                              context: ctx, initialTime: time);
                          if (picked != null) setLocal(() => time = picked);
                        }
                      : null,
                ),
                TextField(
                  controller: phoneCtrl,
                  enabled: enabled,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Your WhatsApp number',
                    hintText: 'Country code + number, e.g. 919812345678',
                    prefixText: '+',
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'One-time setup: save +34 644 66 32 62 on WhatsApp and send it '
                  '“I allow callmebot to send me messages” to activate.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) {
      phoneCtrl.dispose();
      return;
    }

    // Keep only digits — CallMeBot wants a bare country-code+number.
    final phone = phoneCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');
    phoneCtrl.dispose();

    if (enabled && phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter your WhatsApp number to enable the summary.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }

    try {
      await WhatsAppSettingsService.save(settings.copyWith(
        enabled: enabled,
        hour: time.hour,
        minute: time.minute,
        phone: phone,
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(enabled
              ? 'Daily summary on — ${time.format(context)}'
              : 'Daily summary off'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      LogService.e('todo', 'save WhatsApp settings failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save. Please try again.'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<DateTime?> _pickDateTime({DateTime? initial}) async {
    final now = DateTime.now();
    final init = initial != null && initial.isAfter(now)
        ? initial
        : now.add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Pick reminder date',
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial ?? init),
      helpText: 'Pick reminder time',
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }
}
