import 'package:flutter/material.dart';

import '../session/relay_socket.dart';

/// Ask for a shared device's address: the link someone's relay page gave
/// them, or the `wss://<relay>/c/<id>` address in it. `null` if cancelled.
Future<Uri?> askRemoteDevice(BuildContext context, {Uri? initial}) =>
    showDialog<Uri>(context: context, builder: (context) => _RemoteDialog(initial: initial));

class _RemoteDialog extends StatefulWidget {
  const _RemoteDialog({this.initial});
  final Uri? initial;

  @override
  State<_RemoteDialog> createState() => _RemoteDialogState();
}

class _RemoteDialogState extends State<_RemoteDialog> {
  late final _controller = TextEditingController(text: widget.initial?.toString() ?? '');
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final url = parseRemoteAddress(_controller.text);
    if (url == null) {
      setState(() => _problem = 'Paste the link from the sharing page, or a wss://…/c/<id> address');
      return;
    }
    if (url.scheme == 'ws' && Uri.base.scheme == 'https') {
      setState(() => _problem = 'This page is on https, so the address must be wss://');
      return;
    }
    Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Connect to a remote device'),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'A device someone is sharing from their own computer, through a relay. '
            'Paste the link they sent you.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Link or address',
              hintText: 'wss://relay.example.com/c/…',
              errorText: _problem,
              errorMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
            style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Use this device')),
      ],
    );
  }
}
