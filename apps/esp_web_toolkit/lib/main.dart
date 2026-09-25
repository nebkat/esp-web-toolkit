import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:idftool/idftool.dart' show PartitionTable;

import 'pages/data_page.dart';
import 'pages/flash_page.dart';
import 'pages/inspect_page.dart';
import 'pages/monitor_page.dart';
import 'pages/oneclick_page.dart';
import 'pages/partitions_page.dart';
import 'pages/relay_page.dart';
import 'session/device_session.dart';
import 'session/relay_socket.dart';
import 'util/files.dart';
import 'theme.dart';
import 'widgets/connection_bar.dart';
import 'widgets/empty_state.dart';
import 'widgets/log_panel.dart';

/// Routes live in the fragment (`#/flash?remote=…`, the default URL
/// strategy): every link is then served by a version's index.html as is,
/// and what follows the `#` — a relay session id, a bundle's address —
/// never reaches the server. Links from before, with the route in the path,
/// are moved into the fragment by web/index.html.
void main() => runApp(const IdfToolApp());

class IdfToolApp extends StatelessWidget {
  const IdfToolApp({super.key});

  /// The one-click flasher's route. `#/oneclick?bundle=<url>` is the link to
  /// hand out, with the bundle's absolute URL.
  static const oneClickPath = '/oneclick';

  /// The page that shares a device through a relay; it hands out links to
  /// the full tool with `?remote=<relay>/c/<id>`.
  static const relayPath = '/relay';

  /// Which page a route (the URL's fragment) opens: [oneClickPath] is the
  /// one-click flasher, `/<tool>` (`/flash`, say) the full tool on that
  /// page, anything else the full tool on its first page. [relayPath] shares
  /// a device; `?remote=<ws url>` on the full tool uses one shared that way.
  static Widget _entry(String name) {
    final route = Uri.tryParse(name) ?? Uri(path: '/');
    final path = route.path.replaceAll(RegExp(r'/+$'), '');
    final params = route.queryParameters;
    final remote = switch (params['remote']) {
      final r? => parseRemoteAddress(r),
      null => null,
    };
    // A remote device needs no Web Serial on this end.
    if (!DeviceSession.supported && (remote == null || path == oneClickPath || path == relayPath)) return const UnsupportedBrowserPage();
    if (path == relayPath) return RelayShell(relayUrl: switch (params['relay']) { final r? => parseRelayUrl(r), null => null });
    if (path == oneClickPath) {
      final bundle = params['bundle'];
      return OneClickShell(bundleUrl: bundle == null ? null : Uri.tryParse(bundle));
    }
    return HomeShell(initialTool: Tool.values.where((t) => '/${t.name}' == path).firstOrNull ?? Tool.partitions, remoteUrl: remote);
  }

  static Route<void> _route(RouteSettings settings) =>
      MaterialPageRoute<void>(settings: settings, builder: (_) => _entry(settings.name ?? '/'));

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP Web Toolkit',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      onGenerateRoute: _route,
      onGenerateInitialRoutes: (name) => [_route(RouteSettings(name: name))],
    );
  }
}

/// The tools, as navigation destinations. Pages that need the idftool
/// library light up as it lands.
enum Tool {
  partitions('Partitions', Icons.table_chart_outlined),
  flash('Flash', Icons.flash_on),
  data('Data', Icons.storage),
  monitor('Monitor', Icons.terminal),
  inspect('Inspect', Icons.search);

  const Tool(this.label, this.icon);
  final String label;
  final IconData icon;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialTool = Tool.partitions, this.remoteUrl});
  final Tool initialTool;

  /// A shared device to offer, and select, in place of a local port.
  final Uri? remoteUrl;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final _session = DeviceSession()
    ..remoteUrl = widget.remoteUrl
    ..remoteSelected = widget.remoteUrl != null;
  late Tool _tool = widget.initialTool;
  String? _dataPartition;
  PickedFile? _dataFile;

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  /// Switch page and put it in the address bar (`#/flash`), so a reload or
  /// a shared link lands on the same page.
  void _select(Tool tool) {
    _tool = tool;
    final remote = _session.remoteUrl;
    SystemNavigator.routeInformationUpdated(uri: Uri(path: '/${tool.name}', queryParameters: remote == null ? null : {'remote': '$remote'}));
    setState(() {});
  }

  void _planTable(PartitionTable table, String source) {
    for (final note in _session.plan.stageTable(table, source: source)) {
      _session.addLog(note, error: true);
    }
    _select(Tool.flash);
  }

  void _planBundle(Uint8List zip, String name) {
    try {
      for (final note in _session.plan.loadBundle(zip, source: name)) {
        _session.addLog(note, error: true);
      }
    } on FormatException catch (e) {
      _session.addLog(e.message, error: true);
      return;
    }
    _select(Tool.flash);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final page = switch (_tool) {
          Tool.partitions => PartitionsPage(
              session: _session,
              onBrowse: (name) => setState(() {
                _dataPartition = name;
                _dataFile = null;
                _select(Tool.data);
              }),
              onOpenFlash: () => _select(Tool.flash),
              onPlanTable: _planTable,
            ),
          Tool.flash => FlashPage(session: _session),
          Tool.data => DataPage(key: ValueKey((_dataPartition, _dataFile)), session: _session, initialPartition: _dataPartition, initialFile: _dataFile),
          Tool.monitor => MonitorPage(session: _session),
          Tool.inspect => InspectPage(
              session: _session,
              onPlanTable: _planTable,
              onPlanBundle: _planBundle,
              onOpenData: (file) => setState(() {
                _dataFile = file;
                _dataPartition = null;
                _select(Tool.data);
              }),
            ),
        };
        return Scaffold(
          body: Column(children: [
            ConnectionBar(session: _session),
            const Divider(height: 1),
            Expanded(
              flex: 3,
              child: Row(children: [
                NavigationRail(
                  groupAlignment: 0,
                  selectedIndex: _tool.index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => _select(Tool.values[i]),
                  destinations: [
                    for (final t in Tool.values) NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (_session.monitoring && _tool != Tool.monitor && _tool != Tool.inspect)
                      MaterialBanner(
                        leading: const Icon(Icons.terminal),
                        content: const Text('The device is being monitored: it is running its app, so reading and flashing are unavailable until it is back in the bootloader.'),
                        actions: [
                          TextButton(onPressed: () => _select(Tool.monitor), child: const Text('Open monitor')),
                          FilledButton.tonal(
                            onPressed: _session.busy ? null : () => _session.stopMonitor(enterBootloader: true),
                            child: const Text('Enter bootloader'),
                          ),
                        ],
                      ),
                    Expanded(child: page),
                  ]),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(flex: 1, child: LogPanel(session: _session)),
          ]),
        );
      },
    );
  }
}

/// Owns a session for the one-click page, which has no rail, bar or log.
class OneClickShell extends StatefulWidget {
  const OneClickShell({super.key, this.bundleUrl});
  final Uri? bundleUrl;

  @override
  State<OneClickShell> createState() => _OneClickShellState();
}

class _OneClickShellState extends State<OneClickShell> {
  final _session = DeviceSession();

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _session, builder: (context, _) => OneClickPage(session: _session, bundleUrl: widget.bundleUrl));
}

/// The whole page when the browser has no Web Serial: nothing here can work
/// without it.
class UnsupportedBrowserPage extends StatelessWidget {
  const UnsupportedBrowserPage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: EmptyState(
          icon: Icons.usb_off,
          title: 'This browser cannot connect to devices',
          message: 'Talking to a device over USB needs Web Serial, which only Chrome, Edge and Opera on a desktop computer provide. '
              'Open this page in one of those.',
        ),
      );
}
