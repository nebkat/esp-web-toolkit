import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// The app's name, `@nebkat / esp-web-toolkit ▾`, opening a menu of links to
/// this repository and its sibling `idftool`.
class AppTitle extends StatelessWidget {
  const AppTitle({super.key});

  static const owner = 'nebkat';
  static const name = 'esp-web-toolkit';
  static const repository = 'https://github.com/nebkat/esp-web-toolkit';

  static const _links = [
    (name: name, description: 'This app, in the browser', url: repository),
    (name: 'idftool', description: 'The same from the command line', url: 'https://github.com/nebkat/idftool'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final link in _links)
          MenuItemButton(
            leadingIcon: const Icon(Icons.open_in_new, size: 18),
            onPressed: () => web.window.open(link.url, '_blank'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('@$owner/${link.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(link.description, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
          ),
      ],
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(text: '@$owner', style: TextStyle(color: scheme.outline)),
                TextSpan(text: ' / ', style: TextStyle(color: scheme.outlineVariant)),
                TextSpan(text: name, style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600)),
              ]),
              style: theme.textTheme.titleMedium,
            ),
            Icon(Icons.arrow_drop_down, color: scheme.outline),
          ]),
        ),
      ),
    );
  }
}
