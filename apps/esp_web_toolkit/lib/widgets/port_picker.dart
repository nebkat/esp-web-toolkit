import 'package:esptool/web.dart' show serial;
import 'package:flutter/material.dart';

import '../session/device_session.dart';
import 'dropdown.dart';
import 'port_item.dart';
import 'remote_dialog.dart';

/// The granted serial ports as a dropdown, with a last entry that asks the
/// browser for access to another one (Web Serial only exposes ports the
/// user has explicitly granted), the remote device if there is one, and an
/// entry that asks for a remote device's address.
///
/// [allowRemote] is off where a remote device makes no sense (the page that
/// shares a local one).
class PortPicker extends StatefulWidget {
  const PortPicker({super.key, required this.session, this.width = 420, this.enabled = true, this.allowRemote = true});
  final DeviceSession session;
  final double width;
  final bool enabled;
  final bool allowRemote;

  @override
  State<PortPicker> createState() => _PortPickerState();
}

/// The "grant another" entry's value; ports are their index in the list
/// (a JS interop type can't be the entry value without runtime checks).
const _grant = -1;
const _remote = -2;
const _askRemote = -3;

class _PortPickerState extends State<PortPicker> {
  /// Bumped when the grant or remote-address entry is chosen so the field's
  /// text goes back to the selected port if the user cancels.
  int _nonce = 0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final selected = session.selectedPort;
    final remote = session.remoteUrl;
    final index = session.remoteSelected ? _remote : (selected == null ? null : session.ports.indexOf(selected));
    return AppDropdown<int>(
      key: ValueKey((selected == null ? null : session.labelFor(selected), session.remoteSelected, _nonce)),
      value: index == null || index == -1 ? null : index,
      label: 'Port',
      hint: session.ports.isEmpty ? 'No port granted' : 'Select…',
      width: widget.width,
      enabled: widget.enabled,
      entries: [
        for (final (i, p) in session.ports.indexed)
          DropdownMenuEntry(value: i, label: session.labelFor(p), labelWidget: PortItem(session: session, port: p)),
        if (widget.allowRemote && remote != null)
          DropdownMenuEntry(value: _remote, label: 'Remote device via ${remote.host}', leadingIcon: const Icon(Icons.cloud_outlined)),
        if (widget.allowRemote) const DropdownMenuEntry(value: _askRemote, label: 'Connect to a remote device…', leadingIcon: Icon(Icons.add_link)),
        if (serial != null) const DropdownMenuEntry(value: _grant, label: 'Grant access to another port…', leadingIcon: Icon(Icons.usb)),
      ],
      onSelected: (v) {
        if (v == null) return;
        if (v == _remote) {
          session.selectRemote();
        } else if (v == _askRemote) {
          setState(() => _nonce++);
          askRemoteDevice(context, initial: session.remoteUrl).then((url) {
            if (url != null) session.setRemote(url);
          });
        } else if (v == _grant) {
          setState(() => _nonce++);
          session.requestPort();
        } else if (v < session.ports.length) {
          session.selectPort(session.ports[v]);
        }
      },
    );
  }
}
