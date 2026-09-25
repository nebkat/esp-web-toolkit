import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../session/device_session.dart';
import '../session/relay_host.dart';
import '../session/relay_socket.dart';
import '../widgets/app_title.dart';
import '../widgets/dropdown.dart';
import '../widgets/log_panel.dart';
import '../widgets/port_picker.dart';

/// Owns the session and relay host for `/relay`. `?relay=<ws url>` presets
/// the relay server.
class RelayShell extends StatefulWidget {
  const RelayShell({super.key});

  @override
  State<RelayShell> createState() => _RelayShellState();
}

class _RelayShellState extends State<RelayShell> {
  final _session = DeviceSession();
  late final _host = RelayHost(_session, relayUrl: switch (Uri.base.queryParameters['relay']) {
    final relay? => parseRelayUrl(relay),
    null => null,
  });

  @override
  void dispose() {
    _host.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([_session, _host]),
        builder: (context, _) => RelayPage(session: _session, host: _host),
      );
}

/// `/relay`: share a device on this computer with someone else's browser.
/// Pick the port and the relay, Share, and hand out the link; the other end
/// opens the full tool with this device as its port.
class RelayPage extends StatefulWidget {
  const RelayPage({super.key, required this.session, required this.host});
  final DeviceSession session;
  final RelayHost host;

  @override
  State<RelayPage> createState() => _RelayPageState();
}

class _RelayPageState extends State<RelayPage> {
  late final _relay = TextEditingController(text: '${widget.host.relayUrl}');
  String? _relayProblem;

  RelayHost get host => widget.host;
  DeviceSession get session => widget.session;

  @override
  void dispose() {
    _relay.dispose();
    super.dispose();
  }

  void _share() {
    final url = parseRelayUrl(_relay.text);
    if (url == null) {
      setState(() => _relayProblem = 'A wss:// address, like wss://relay.example.com');
      return;
    }
    if (url.scheme == 'ws' && Uri.base.scheme == 'https') {
      setState(() => _relayProblem = 'This page is on https, so the relay must be wss://');
      return;
    }
    _relay.text = '$url';
    setState(() => _relayProblem = null);
    host.setRelayUrl(url);
    host.start();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final idle = host.state == RelayState.idle;
    return Scaffold(
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(padding: const EdgeInsets.all(32), shrinkWrap: true, children: [
                const Align(alignment: Alignment.centerLeft, child: AppTitle()),
                const SizedBox(height: 16),
                Text('Share a device', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Let someone use a device plugged into this computer from their own browser. '
                  'Anyone with the link can read and flash it while it is shared. '
                  'Keep this tab open and in view until you stop sharing.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  PortPicker(session: session, enabled: idle, allowRemote: false),
                  AppDropdown<ResetChoice>(
                    value: session.reset,
                    label: 'Reset',
                    width: 240,
                    entries: [for (final r in ResetChoice.values) DropdownMenuEntry(value: r, label: r.label)],
                    enabled: idle,
                    onSelected: (v) {
                      if (v != null) session.setReset(v);
                    },
                  ),
                  SizedBox(
                    width: 420,
                    child: TextField(
                      controller: _relay,
                      enabled: idle,
                      decoration: InputDecoration(labelText: 'Relay server', errorText: _relayProblem),
                      onSubmitted: (_) => _share(),
                    ),
                  ),
                  if (idle)
                    FilledButton.icon(
                      onPressed: session.selectedPort == null ? null : _share,
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                    )
                  else
                    FilledButton.tonalIcon(
                      onPressed: host.state == RelayState.sharing ? host.stop : null,
                      icon: host.state == RelayState.starting
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.stop),
                      label: Text(host.state == RelayState.starting ? 'Starting…' : 'Stop sharing'),
                    ),
                ]),
                if (host.state == RelayState.sharing) ...[
                  const SizedBox(height: 24),
                  _status(theme),
                ],
              ]),
            ),
          ),
        ),
        const Divider(height: 1),
        SizedBox(height: 200, child: LogPanel(session: session)),
      ]),
    );
  }

  Widget _status(ThemeData theme) {
    final link = host.shareLink;
    final server = host.server;
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'RobotoMono');
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Link', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          if (link == null)
            const Text('Waiting for the relay…')
          else
            Row(children: [
              Expanded(child: SelectableText('$link', style: mono)),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '$link'));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                },
              ),
            ]),
          const SizedBox(height: 12),
          _line(Icons.person_outline, host.peer == null ? 'No one connected' : 'Connected from ${host.peer}'),
          if (host.waitingForPort)
            _line(Icons.usb_off, 'Waiting for the device to come back', color: theme.colorScheme.error)
          else if (server != null)
            _line(Icons.usb, '${server.baudRate} baud  ·  DTR ${server.dtr ? 1 : 0}  ·  RTS ${server.rts ? 1 : 0}'),
          if (server != null) _line(Icons.swap_vert, '${server.bytesToDevice.bytesString} to the device  ·  ${server.bytesFromDevice.bytesString} from it'),
        ]),
      ),
    );
  }

  Widget _line(IconData icon, String text, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color))),
        ]),
      );
}
