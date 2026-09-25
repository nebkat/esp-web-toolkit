import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:idftool/idftool.dart';

import '../session/device_session.dart';
import '../session/flash_plan.dart';
import '../util/files.dart';
import '../widgets/op_tile.dart';
import '../widgets/port_picker.dart';

/// The one-click flasher at `#/oneclick`: a bundle (from `?bundle=<url>` or a picked file),
/// an outline of what it will do, Connect, Flash, done. Any bundle works —
/// one by the filename convention, with or without a manifest of extras.
/// The bundle's name and description are the
/// page's only heading. None of the tool's machinery is shown; the log
/// stays behind a disclosure.
class OneClickPage extends StatefulWidget {
  const OneClickPage({super.key, required this.session, this.bundleUrl, this.bundle, this.onBack});
  final DeviceSession session;

  /// The bundle to fetch on arrival, from the link's `?bundle=`.
  final Uri? bundleUrl;

  /// A bundle already in hand (the Flash page previewing its plan).
  final FlashBundle? bundle;

  /// Shown as a way back when this page was pushed over the full tool.
  final VoidCallback? onBack;

  @override
  State<OneClickPage> createState() => _OneClickPageState();
}

/// [empty] is the opener (URL row and file button), also where a load is
/// in flight or has failed — the row itself says so.
enum _Phase { empty, ready, flashing, done, failed }

class _OneClickPageState extends State<OneClickPage> {
  _Phase _phase = _Phase.empty;
  FlashBundle? _bundle;
  String? _problem;

  late final _url = TextEditingController(text: widget.bundleUrl?.toString() ?? '');
  bool _fetching = false;
  String? _urlProblem;
  String? _fileProblem;
  int _currentStep = -1;
  final _completed = <int>{};
  /// The log appears once a device has been connected and stays for good.
  bool _logShown = false;

  /// The bundle checked against the connected device's table, once read.
  BundleCheck? _check;
  bool _checkStarted = false;

  /// What the person flashing chose for a differing table ([TablePolicy.ask]).
  TableChoice? _tableChoice;

  DeviceSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    final url = widget.bundleUrl;
    if (widget.bundle case final bundle?) {
      _bundle = bundle;
      _phase = _Phase.ready;
    } else if (url != null) {
      _fetch(url);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  /// Load the URL in the field, and put it in the address bar so the page
  /// can be shared as a link.
  void _load() {
    final text = _url.text.trim();
    if (text.isEmpty) return setState(() => _urlProblem = 'Enter the URL of a bundle');
    final url = Uri.tryParse(text);
    if (url == null || !url.hasScheme || !url.hasAuthority) return setState(() => _urlProblem = 'Enter a full URL, starting with https://');
    SystemNavigator.routeInformationUpdated(uri: Uri(path: '/oneclick', queryParameters: {'bundle': text}));
    _fetch(url);
  }

  Future<void> _fetch(Uri url) async {
    setState(() {
      _fetching = true;
      _urlProblem = null;
      _fileProblem = null;
    });
    try {
      // The bundle host only needs CORS; the browser sends its cookies for
      // same-site hosts (Cloudflare Access) as usual.
      final response = await http.get(url);
      if (response.statusCode != 200) throw IdfToolException('HTTP ${response.statusCode}');
      _use(response.bodyBytes, url.pathSegments.lastOrNull ?? 'bundle', fromUrl: true);
    } catch (e) {
      if (mounted) setState(() => _urlProblem = 'Could not load bundle: ${e is IdfToolException ? e.message : e}');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _pick() async {
    final file = await pickFile(extensions: ['zip']);
    if (file == null) return;
    _use(file.bytes, file.name, fromUrl: false);
  }

  void _use(Uint8List bytes, String name, {required bool fromUrl}) {
    try {
      final bundle = FlashBundle.fromZip(bytes, source: name);
      setState(() {
        _bundle = bundle;
        _phase = _Phase.ready;
        _problem = null;
        _urlProblem = null;
        _fileProblem = null;
        _completed.clear();
        _currentStep = -1;
        _forgetCheck();
      });
    } catch (e) {
      final problem = '$name is not a usable bundle: ${e is IdfToolException ? e.message : e}';
      setState(() => fromUrl ? _urlProblem = problem : _fileProblem = problem);
    }
  }

  /// Drop the bundle and go back to the opener.
  void _close() => setState(() {
        _bundle = null;
        _phase = _Phase.empty;
        _problem = null;
        _completed.clear();
        _currentStep = -1;
        _forgetCheck();
      });

  void _forgetCheck() {
    _check = null;
    _checkStarted = false;
    _tableChoice = null;
  }

  /// Read the device's table and check the bundle against it: nothing is
  /// written, and the outline then says what the flash will really do.
  Future<void> _checkDevice() async {
    final bundle = _bundle;
    if (bundle == null) return;
    _checkStarted = true;
    final check = await session.runDevice(
        'Check the device',
        (device) async => checkBundle(bundle, await readDeviceTable(device)));
    if (mounted && identical(bundle, _bundle)) setState(() => _check = check);
  }

  Future<void> _flash() async {
    final bundle = _bundle!;
    setState(() {
      _phase = _Phase.flashing;
      _completed.clear();
      _currentStep = -1;
      _problem = null;
    });
    Object? failure;
    await session.runDevice('Flash ${bundle.name}', (device) async {
      try {
        await runFlashBundle(
          device,
          bundle,
          onStep: (i, _) => setState(() {
            if (_currentStep >= 0) _completed.add(_currentStep);
            _currentStep = i;
          }),
          onProgress: session.reportProgress,
          nvsKeys: session.nvsKeys,
          log: session.addLog,
          chooseTable: (_) async => _tableChoice,
        );
        _completed.add(_currentStep);
      } catch (e) {
        failure = e;
        rethrow;
      }
    });
    if (!mounted) return;
    if (failure == null && session.connected) {
      await session.disconnect(hardReset: true);
      setState(() => _phase = _Phase.done);
    } else {
      setState(() {
        _phase = _Phase.failed;
        _problem = failure == null ? 'The device disconnected during flashing' : '$failure';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bundle = _bundle;
    if (session.connected) _logShown = true;
    if (!session.connected && _checkStarted) _forgetCheck();
    if (session.connected && !session.busy && !_checkStarted && bundle != null && _phase == _Phase.ready) {
      _checkStarted = true;
      Future<void>.microtask(_checkDevice);
    }
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.all(32), shrinkWrap: true, children: [
            if (widget.onBack case final onBack?)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextButton.icon(onPressed: onBack, icon: const Icon(Icons.arrow_back, size: 18), label: const Text('Back to the plan')),
                ),
              ),
            switch (_phase) {
              _Phase.empty => _opener(theme),
              _ => _bundleCard(bundle!, theme),
            },
            if (_logShown) ...[
              const SizedBox(height: 16),
              _log(theme),
            ],
          ]),
        ),
      ),
    );
  }

  /// Two ways in: a bundle at a URL (the row a `?bundle=` link lands on,
  /// loading or failing in place) or a bundle file.
  Widget _opener(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.unarchive_outlined, size: 40, color: scheme.outline),
        const SizedBox(height: 12),
        Text('Open a firmware bundle', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('Review its steps, then connect a device and flash it.', style: TextStyle(color: scheme.outline), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: _url,
              enabled: !_fetching,
              decoration: InputDecoration(
                labelText: 'Bundle URL',
                hintText: 'https://example.com/firmware/device-v1.2.0.zip',
                errorText: _urlProblem,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _load(),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(
            onPressed: _fetching ? null : _load,
            icon: _fetching ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download),
            label: Text(_fetching ? 'Loading…' : 'Load'),
          ),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          const Expanded(child: Divider()),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('or', style: TextStyle(color: scheme.outline))),
          const Expanded(child: Divider()),
        ]),
        const SizedBox(height: 20),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
          FilledButton.tonalIcon(onPressed: _fetching ? null : _pick, icon: const Icon(Icons.folder_open), label: const Text('Open a bundle file…')),
          FilledButton.tonalIcon(
            onPressed: _fetching ? null : () => Navigator.pushReplacementNamed(context, '/flash'),
            icon: const Icon(Icons.add_box_outlined),
            label: const Text('Create a bundle…'),
          ),
        ]),
        if (_fileProblem != null) ...[
          const SizedBox(height: 8),
          Text(_fileProblem!, style: TextStyle(color: scheme.error), textAlign: TextAlign.center),
        ],
      ]),
    );
  }

  Widget _bundleCard(FlashBundle bundle, ThemeData theme) {
    final flashing = _phase == _Phase.flashing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(bundle.name, style: theme.textTheme.titleLarge)),
            if (widget.bundle == null)
              IconButton(
                tooltip: 'Close this bundle',
                icon: const Icon(Icons.close),
                onPressed: flashing ? null : _close,
              ),
          ]),
          if (bundle.description != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(bundle.description!)),
          if (bundle.chip != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('For ${bundle.chip!.name}', style: theme.textTheme.bodySmall)),
          const SizedBox(height: 16),
          Text('This update will:', style: theme.textTheme.labelLarge),
          for (var i = 0; i < bundle.steps.length; i++)
            if (_row(bundle, bundle.steps[i]) case final row) ...[
              OpTile(
                icon: row.icon,
                name: row.name,
                detail: row.detail,
                summary: row.summary,
                warning: _check?.missing[i] ?? (bundle.steps[i] is WriteTableStep && (_check?.tableChanges ?? false) ? _check!.blocker : null),
                leading: SizedBox(
                  width: 24,
                  child: Center(
                    child: _completed.contains(i)
                        ? const Icon(Icons.check_circle, size: 18, color: Colors.green)
                        : i == _currentStep && flashing
                            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : _phase == _Phase.failed && i == _currentStep
                                ? Icon(Icons.error, size: 18, color: theme.colorScheme.error)
                                : Text('${i + 1}.', style: theme.textTheme.bodyMedium),
                  ),
                ),
              ),
              if (bundle.steps[i] is WriteTableStep && (_check?.tableChanges ?? false)) _tableChanges(_check!, theme, enabled: _phase == _Phase.ready),
            ],
          const SizedBox(height: 20),
          switch (_phase) {
            _Phase.done => Row(children: [
                const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 8),
                const Expanded(child: Text('Done. The device has been reset and is running the update.')),
                TextButton(
                    onPressed: () => setState(() {
                          _phase = _Phase.ready;
                          _forgetCheck();
                        }),
                    child: const Text('Flash another')),
              ]),
            _Phase.failed => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Flashing failed: $_problem', style: TextStyle(color: theme.colorScheme.error)),
                const SizedBox(height: 8),
                Text('Reconnect the device and try again. If it keeps failing, send the log below to support.', style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                FilledButton.tonal(
                    onPressed: () => setState(() {
                          _phase = _Phase.ready;
                          _forgetCheck();
                        }),
                    child: const Text('Try again')),
              ]),
            _ => _connectAndFlash(theme),
          },
        ]),
      ),
    );
  }

  /// A step as the Flash page shows a planned operation: where it lands
  /// (named against the bundle's own table when it carries one) and what
  /// is written there.
  ({IconData icon, String name, String detail, String summary}) _row(FlashBundle bundle, FlashStep step) {
    // Offsets come from the bundle's own table, or else from the connected
    // device's, which is where names will land; with neither, only names.
    final table = bundle.contents.table ?? _check?.deviceTable;
    String size(String file) => bundle.files[file]?.length.bytesString ?? '?';
    PartitionDefinition? find(String name) => table?.findByName(name);
    String offset(String name) => find(name)?.offset.hex ?? 'by name';
    return switch (step) {
      WriteTableStep(:final file, :final policy) => (
          icon: _check?.tableMatches ?? false ? Icons.check : Icons.table_chart,
          name: 'partition_table',
          detail: PartitionTable.defaultOffset.hex,
          summary: switch ((_check, policy)) {
            (null, TablePolicy.update) => "Update the partition layout from $file, if the device's differs",
            (null, TablePolicy.ask) => 'Check the partition layout against $file; ask before updating it',
            (null, TablePolicy.require) => 'Check the device is laid out as in $file',
            (final c?, _) when c.tableMatches => 'The partition layout already matches: left as it is',
            (final c?, TablePolicy.update) => "Update the partition layout: this device's differs in ${c.differences.length} partition${c.differences.length == 1 ? '' : 's'}",
            (final c?, TablePolicy.ask) when c.canKeepLayout =>
              "This device's partition layout differs in ${c.differences.length} partition${c.differences.length == 1 ? '' : 's'}, none of them used by this update",
            (final c?, TablePolicy.ask) => "This device's partition layout differs in ${c.differences.length} partition${c.differences.length == 1 ? '' : 's'}",
            (final c?, TablePolicy.require) when c.canKeepLayout => "This device's partition layout differs, but not where this update writes: left as it is",
            (_, TablePolicy.require) => "This device's partition layout is different",
          },
        ),
      WriteBootloaderStep(:final file) => (
          icon: Icons.upload_file,
          name: 'bootloader',
          detail: bundle.chip?.bootloaderFlashOffset.hex ?? 'chip offset',
          summary: 'Write $file (${size(file)})',
        ),
      FactoryStep(:final file) => (
          icon: Icons.upload_file,
          name: FlashRole.factory.fileStem,
          detail: table == null ? FlashRole.factory.label : factoryTarget(table)?.name ?? FlashRole.factory.label,
          summary: 'Write $file (${size(file)}) to ${FlashRole.factory.description}',
        ),
      OtaStep(:final file) => (
          icon: Icons.upload_file,
          name: FlashRole.ota.fileStem,
          detail: FlashRole.ota.label,
          summary: 'Write $file (${size(file)}) to ${FlashRole.ota.description}',
        ),
      WritePartitionStep(:final partition, :final file) => (icon: Icons.upload_file, name: partition, detail: offset(partition), summary: 'Write $file (${size(file)})'),
      WriteFsStep(:final partition, :final file) => (icon: Icons.folder_outlined, name: partition, detail: offset(partition), summary: 'Write filesystem image $file (${size(file)})'),
      EraseStep(:final partition) => (
          icon: Icons.delete_outline,
          name: partition,
          detail: offset(partition),
          summary: switch (find(partition)) { final p? => 'Erase ${p.size.bytesString}', null => 'Erase' },
        ),
      SetNvsStep(:final partition, :final set, :final delete) => (
          icon: Icons.edit_note,
          name: partition ?? 'nvs',
          detail: partition == null ? 'first nvs' : offset(partition),
          summary: [for (final e in set.entries) 'Set ${e.key} = ${e.value}', for (final d in delete) 'Delete $d'].join(', '),
        ),
      EditFsStep(:final partition, :final put, :final delete) => (
          icon: Icons.folder_outlined,
          name: partition,
          detail: offset(partition),
          summary: [for (final e in put.entries) 'Put ${e.key} (${size(e.value)})', for (final d in delete) 'Delete $d'].join(', '),
        ),
      SetBootStep(:final partition) => (icon: Icons.restart_alt, name: partition, detail: offset(partition), summary: 'Boot from it next'),
      ClearBootStep() => (icon: Icons.restart_alt, name: 'otadata', detail: offset('otadata'), summary: 'Clear the OTA selection so the factory app boots'),
    };
  }

  /// Under the table step when the device's table differs: what differs,
  /// and for [TablePolicy.ask] the choice — update it, or keep the device's
  /// when nothing this update uses differs.
  Widget _tableChanges(BundleCheck check, ThemeData theme, {required bool enabled}) {
    final scheme = theme.colorScheme;
    final mono = TextStyle(fontFamily: 'RobotoMono', fontSize: 12, color: scheme.onSurfaceVariant);
    return Container(
      margin: const EdgeInsets.only(left: 64, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: check.needsApproval ? scheme.tertiaryContainer.withValues(alpha: 0.4) : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (check.deviceTable == null)
          Text('The device has no partition table yet.', style: mono)
        else
          for (final d in check.differences)
            Text('${d.name.padRight(12)} ${d.describe()}${check.match == TableMatch.used && check.used.contains(d.name) ? '   (used by this update)' : ''}',
                style: mono),
        if (check.needsApproval && check.canKeepLayout) ...[
          const SizedBox(height: 8),
          RadioGroup<TableChoice>(
            groupValue: _tableChoice,
            onChanged: (v) => enabled ? setState(() => _tableChoice = v) : null,
            child: Column(children: [
              RadioListTile<TableChoice>(
                value: TableChoice.update,
                enabled: enabled,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Update the partition layout'),
                subtitle: const Text('Only the layout is replaced; nothing stored on the device is moved or erased.'),
              ),
              RadioListTile<TableChoice>(
                value: TableChoice.keep,
                enabled: enabled,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text("Keep this device's layout"),
                subtitle: const Text('None of the partitions above are used by this update, so it can be flashed as the device is.'),
              ),
            ]),
          ),
        ] else if (check.needsApproval) ...[
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _tableChoice == TableChoice.update,
            onChanged: enabled ? (v) => setState(() => _tableChoice = v ?? false ? TableChoice.update : null) : null,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Update the partition layout on this device'),
            subtitle: const Text('Only the layout is replaced; nothing stored on the device is moved or erased. '
                "If you weren't told to expect this, stop and ask whoever sent you this update."),
          ),
        ] else if (check.automaticChoice == TableChoice.keep) ...[
          const SizedBox(height: 8),
          Text("None of these partitions are used by this update, so the device's layout is kept.", style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ]),
    );
  }

  Widget _connectAndFlash(ThemeData theme) {
    final flashing = _phase == _Phase.flashing;
    if (!session.connected) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Plug the device in over USB, then connect. Chrome will ask which port to use.'),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(
            onPressed: session.busy
                ? null
                : () async {
                    if (!session.hasDevice) await session.requestPort();
                    if (session.hasDevice) await session.connect();
                  },
            icon: session.busy ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.usb),
            label: Text(session.busy ? 'Connecting…' : 'Connect device'),
          ),
          if (session.ports.isNotEmpty) PortPicker(session: session, width: 360, enabled: !session.busy),
        ]),
        if (session.log.any((l) => l.error)) ...[
          const SizedBox(height: 8),
          Text(session.log.lastWhere((l) => l.error).message, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ]);
    }
    final chipMismatch = _bundle!.chip != null && session.chip != _bundle!.chip;
    final check = _check;
    final checking = _checkStarted && check == null && session.busy && !flashing;
    final blocker = check?.blocker;
    final awaitingApproval = (check?.needsApproval ?? false) && _tableChoice == null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.check_circle, size: 18, color: Colors.green),
        const SizedBox(width: 8),
        Text('Connected: ${session.chip?.name}, ${session.macString}'),
      ]),
      if (chipMismatch)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('This update is for ${_bundle!.chip!.name}, but the connected device is a ${session.chip?.name}.',
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      if (!chipMismatch && !flashing && blocker != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('This update cannot be flashed onto this device: $blocker.', style: TextStyle(color: theme.colorScheme.error)),
        ),
      if (!chipMismatch && !flashing && blocker == null && awaitingApproval)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(check!.canKeepLayout ? 'Choose what to do with the partition layout above to continue.' : 'Agree to the partition layout update above to continue.',
              style: TextStyle(color: theme.colorScheme.outline)),
        ),
      const SizedBox(height: 12),
      Row(children: [
        FilledButton.icon(
          onPressed: flashing || chipMismatch || checking || blocker != null || awaitingApproval ? null : _flash,
          icon: checking ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.flash_on),
          label: Text(flashing
              ? 'Flashing…'
              : checking
                  ? 'Checking the device…'
                  : 'Flash'),
        ),
        const SizedBox(width: 12),
        if (!flashing) TextButton(onPressed: () => session.disconnect(hardReset: false), child: const Text('Disconnect')),
      ]),
      if (flashing && session.progress != null) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(value: session.progress!.fraction),
        const SizedBox(height: 4),
        Text('${session.progress!.label}: ${session.progress!.done.bytesString} / ${session.progress!.total.bytesString}', style: theme.textTheme.bodySmall),
      ],
    ]);
  }

  Widget _log(ThemeData theme) => Container(
        height: 220,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(border: Border.all(color: theme.dividerColor), borderRadius: BorderRadius.circular(8)),
        child: SelectionArea(
          child: ListView(children: [
            for (final l in session.log)
              Text(l.message, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 12, color: l.error ? theme.colorScheme.error : null)),
          ]),
        ),
      );
}
