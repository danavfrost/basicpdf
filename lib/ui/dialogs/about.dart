import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

Future<void> showAbout(BuildContext context) async {
  var version = '';
  try {
    final info = await PackageInfo.fromPlatform();
    version = info.version;
  } catch (_) {}
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.picture_as_pdf_outlined, size: 40),
      title: const Text('Basic PDF'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (version.isNotEmpty) Text('Version $version'),
          const SizedBox(height: 12),
          const Text(
            'Free. No ads. No tracking. No network.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'Basic PDF',
            applicationVersion: version,
          ),
          child: const Text('Licenses'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
