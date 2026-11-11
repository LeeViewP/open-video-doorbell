import 'package:flutter/material.dart';

import 'server_client.dart';
import 'settings.dart';
import 'settings_page.dart';

/// Who rang and when, with the picture taken at the ring, who answered and
/// who opened. Settings is reached from here: it is needed once, at setup or
/// when a phone's key changes.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.settings});

  final Settings settings;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<HistoryEntry>> _entries = _load();

  Future<List<HistoryEntry>> _load() =>
      DoorbellServer(widget.settings).history();

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _entries = next);
    await next.catchError((_) => <HistoryEntry>[]);
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<HistoryEntry>>(
          future: _entries,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _Message('${snap.error}');
            }
            final entries = snap.data!;
            if (entries.isEmpty) return const _Message('Nobody rang yet.');
            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 112),
              itemBuilder: (_, i) =>
                  _EntryTile(entry: entries[i], settings: widget.settings),
            );
          },
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.settings});

  final HistoryEntry entry;
  final Settings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final picture = entry.hasPicture
        ? DoorbellServer(settings).pictureUri(entry.id).toString()
        : null;
    final (title, color) = entry.isRing
        ? (
            entry.missed ? 'Missed ring' : 'Rang',
            entry.missed ? scheme.error : null,
          )
        : ('Door opened', null);
    final details = [
      if (entry.answeredBy != null) 'Answered by ${entry.answeredBy}',
      if (entry.openedBy != null) 'Opened by ${entry.openedBy}',
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 80,
          height: 60,
          child: picture == null
              ? ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    entry.isRing ? Icons.doorbell_outlined : Icons.lock_open,
                    color: scheme.onSurfaceVariant,
                  ),
                )
              : Image.network(
                  picture,
                  headers: settings.authHeaders,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
        ),
      ),
      title: Text(
        title,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          formatWhen(entry.time, DateTime.now()),
          details,
        ].where((s) => s.isNotEmpty).join('\n'),
      ),
      isThreeLine: details.isNotEmpty,
      onTap: picture == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _PictureView(url: picture, settings: settings),
              ),
            ),
    );
  }
}

/// The ring's picture, full screen and zoomable.
class _PictureView extends StatelessWidget {
  const _PictureView({required this.url, required this.settings});

  final String url;
  final Settings settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(child: Image.network(url, headers: settings.authHeaders)),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    // A ListView, so pull-to-refresh works on it too.
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, textAlign: TextAlign.center),
        ),
      ],
    );
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "14:05" today, "Yesterday 14:05", else "3 Nov 14:05".
String formatWhen(DateTime t, DateTime now) {
  final hm =
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(day).inDays;
  if (days == 0) return hm;
  if (days == 1) return 'Yesterday $hm';
  return '${t.day} ${_months[t.month - 1]} $hm';
}
