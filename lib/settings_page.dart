import 'package:flutter/material.dart';

import 'server_client.dart';
import 'settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _store = SettingsStore();
  final _server = TextEditingController();
  final _cfId = TextEditingController();
  final _cfSecret = TextEditingController();
  bool _loaded = false;
  bool _showSecret = false;

  /// Result of the last connection test; null while none ran.
  ({bool ok, String text})? _status;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await _store.load();
    if (!mounted) return;
    setState(() {
      _server.text = s.serverUrl;
      _cfId.text = s.cfClientId;
      _cfSecret.text = s.cfClientSecret;
      _loaded = true;
    });
  }

  Settings _current() => Settings(
    serverUrl: _server.text,
    cfClientId: _cfId.text,
    cfClientSecret: _cfSecret.text,
  );

  Future<void> _save() async {
    await _store.save(_current());
    // Back to the door page, which reloads the settings when this one closes.
    if (mounted) Navigator.of(context).pop();
  }

  /// Reads the lock state through the server: proves the URL and the key,
  /// and the server's own Home Assistant setup, without touching the lock.
  Future<void> _test() async {
    setState(() => _testing = true);
    ({bool ok, String text}) status;
    try {
      final lock = await DoorbellServer(_current()).readLock();
      status = (ok: true, text: 'Connected. ${lock.name}: ${lock.state}.');
    } on ServerException catch (e) {
      status = (ok: false, text: e.message);
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _status = status;
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _cfId.dispose();
    _cfSecret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _Section(
                  icon: Icons.dns_outlined,
                  title: 'Doorbell server',
                  subtitle:
                      'Home Assistant, the lock and the camera are set up on '
                      'the server; this phone only needs its address and key.',
                  children: [
                    _field(
                      _server,
                      'Server URL',
                      icon: Icons.link,
                      hint: 'https://doorbell.example.com',
                      url: true,
                    ),
                    _field(
                      _cfId,
                      'Client ID',
                      icon: Icons.badge_outlined,
                      helper: 'This phone\'s Cloudflare Access service token',
                    ),
                    TextField(
                      controller: _cfSecret,
                      obscureText: !_showSecret,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Client secret',
                        prefixIcon: const Icon(Icons.key),
                        suffixIcon: IconButton(
                          tooltip: _showSecret ? 'Hide' : 'Show',
                          icon: Icon(
                            _showSecret
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () =>
                              setState(() => _showSecret = !_showSecret),
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label: const Text('Test connection'),
                    ),
                    if (_status case final s?) _StatusBanner(s.ok, s.text),
                  ],
                ),
              ],
            ),
      bottomNavigationBar: !_loaded
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _save,
                  icon: const Icon(Icons.check),
                  label: const Text('Save'),
                ),
              ),
            ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    required IconData icon,
    String? hint,
    String? helper,
    bool url = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: url ? TextInputType.url : TextInputType.text,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        prefixIcon: Icon(icon),
      ),
    );
  }
}

/// A titled card holding one group of settings, spaced evenly.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.filled(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 28),
                child: Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final child in children) ...[
              const SizedBox(height: 16),
              child,
            ],
          ],
        ),
      ),
    );
  }
}

/// Green or red line under "Test connection" saying what came back.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner(this.ok, this.text);

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ok ? Colors.green : scheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle : Icons.error_outline, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
