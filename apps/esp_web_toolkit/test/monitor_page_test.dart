import 'dart:convert';

import 'package:esp_monitor/esp_monitor.dart';
import 'package:esp_web_toolkit/pages/monitor_page.dart';
import 'package:esp_web_toolkit/session/device_session.dart';
import 'package:esp_web_toolkit/theme.dart';
import 'package:esp_web_toolkit/widgets/log_overview.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DeviceSession session;

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    session = DeviceSession();
    session.monitorLog.add(utf8.encode('I (1500) wifi: connected\nW (2000) app: main up\nE (2100) app: special\nprintf\n'));
    await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.light), home: Scaffold(body: MonitorPage(session: session))));
    await tester.pump(const Duration(milliseconds: 60));
  }

  Finder richText(Pattern text) => find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains(text));

  testWidgets('timestamps are shown as chosen, and as printed under the pointer', (tester) async {
    await pumpPage(tester);
    // Readable by default.
    expect(richText('I (boot+1.500s) wifi: connected'), findsOneWidget);

    // The time since the previous line goes with any form, as printed too.
    session.monitorLog.showDelta = true;
    await tester.pump();
    expect(richText('W (boot+2.000s +0.500s) app: main up'), findsOneWidget);
    expect(richText('I (boot+1.500s) wifi'), findsOneWidget);
    session.monitorLog.timeDisplay = TimeDisplay.raw;
    await tester.pump();
    expect(richText('W (2000 +0.500s) app: main up'), findsOneWidget);
    session.monitorLog.timeDisplay = TimeDisplay.readable;
    await tester.pump();

    // Hovering the timestamp brings back the raw value, padded so it doesn't shrink from under the pointer.
    final line = tester.getTopLeft(richText('W (boot+2.000s'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: line + const Offset(40, 8));
    await tester.pump();
    expect(richText('W (2000        +0.500s) app: main up'), findsOneWidget);
    // The rebuilt span takes over the hover rather than flickering between the two.
    await tester.pumpAndSettle();
    expect(richText('W (2000        +0.500s) app: main up'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(richText('W (boot+2.000s +0.500s) app'), findsOneWidget);
  });

  testWidgets('right-clicking a line offers its tag and level', (tester) async {
    await pumpPage(tester);
    final line = tester.getCenter(richText('wifi: connected'));
    await tester.tapAt(line, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Hide tag wifi'), findsOneWidget);
    expect(find.text('Show Info and above'), findsOneWidget);
    await tester.tap(find.text('Show only tag wifi'));
    await tester.pumpAndSettle();
    expect(session.monitorLog.buffer.visible.map((l) => l.text), ['I (1500) wifi: connected', 'printf']);
    expect(find.text('Tags (1 shown)'), findsOneWidget);

    // A click elsewhere in the output closes the menu.
    await tester.tapAt(tester.getCenter(richText('wifi: connected')), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Hide tag wifi'), findsOneWidget);
    await tester.tapAt(tester.getCenter(richText('printf')) + const Offset(0, 100), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Hide tag wifi'), findsNothing);
  });

  testWidgets('the button sticks the view to the bottom, or unsticks it', (tester) async {
    await pumpPage(tester);
    session.monitorLog.add(utf8.encode([for (var i = 0; i < 200; i++) 'I ($i) t: line $i\n'].join()));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    final position = tester.state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first).position;
    expect(position.pixels, position.maxScrollExtent);

    await tester.tap(find.byTooltip('Following new output: stop'));
    await tester.pump();
    final unstuck = position.pixels;
    expect(unstuck, position.maxScrollExtent - 0.5);
    session.monitorLog.add(utf8.encode('I (999) t: more\n'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(position.pixels, unstuck);
    expect(position.maxScrollExtent, greaterThan(unstuck + 0.5));

    await tester.tap(find.byTooltip('Follow new output'));
    await tester.pump();
    await tester.pump();
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('level chips show a level and those above; the lowest again drops one', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('WARNING'));
    await tester.pump();
    expect(session.monitorLog.filter.maxLevel, LogLevel.warning);
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'ERROR')).selected, isTrue);
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'INFO')).selected, isFalse);
    await tester.tap(find.text('WARNING'));
    await tester.pump();
    expect(session.monitorLog.filter.maxLevel, LogLevel.error);
    await tester.tap(find.text('ERROR'));
    await tester.pump();
    expect(session.monitorLog.filter.maxLevel, LogLevel.error);
    await tester.tap(find.text('VERBOSE'));
    await tester.pump();
    expect(session.monitorLog.filter.maxLevel, LogLevel.verbose);
  });

  testWidgets('the overview beside the output scrolls it', (tester) async {
    await pumpPage(tester);
    session.monitorLog.add(utf8.encode([for (var i = 0; i < 300; i++) '${i == 150 ? 'E' : 'I'} ($i) t: line $i\n'].join()));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    final position = tester.state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first).position;
    expect(position.pixels, position.maxScrollExtent);

    final overview = tester.getRect(find.byType(LogOverview));
    await tester.tapAt(overview.topCenter + const Offset(0, 2));
    await tester.pump();
    expect(position.pixels, 0);
    expect(find.byTooltip('Follow new output'), findsOneWidget);

    await tester.tapAt(overview.center);
    await tester.pump();
    expect(position.pixels, closeTo(position.maxScrollExtent / 2, position.maxScrollExtent * 0.05));
  });
}
