import 'package:flutter/material.dart';
import 'package:venera_netmatic/foundation/context.dart';
import 'package:venera_netmatic/foundation/nas/nas_manager.dart';
import 'package:venera_netmatic/utils/translations.dart';

class DownloadDestination {
  const DownloadDestination.local() : nasConnectionId = null;
  const DownloadDestination.nas(this.nasConnectionId);

  final String? nasConnectionId;
}

Future<DownloadDestination?> selectDownloadDestination(
  BuildContext context,
) async {
  final manager = NasManager.instance;
  final connections = manager.connections;
  if (connections.isEmpty) return const DownloadDestination.local();

  String? selected = manager.defaultConnectionId;
  return showDialog<DownloadDestination>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Download destination'.tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'NAS downloads keep a local copy for reading and recovery.'.tl,
            ),
            const SizedBox(height: 8),
            RadioGroup<String?>(
              groupValue: selected,
              onChanged: (value) => setState(() => selected = value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<String?>(
                    value: null,
                    title: Text('Local storage'.tl),
                  ),
                  for (final connection in connections)
                    RadioListTile<String?>(
                      value: connection.id,
                      title: Text(connection.name),
                      subtitle: Text(
                        '${connection.protocol.name.toUpperCase()} · '
                        '${connection.host}',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              selected == null
                  ? const DownloadDestination.local()
                  : DownloadDestination.nas(selected),
            ),
            child: Text('Confirm'.tl),
          ),
        ],
      ),
    ),
  );
}

Future<String?> selectNasConnection(BuildContext context) async {
  final manager = NasManager.instance;
  final connections = manager.connections;
  if (connections.isEmpty) {
    if (context.mounted) {
      context.showMessage(message: 'No NAS connections yet'.tl);
    }
    return null;
  }
  var selected = manager.defaultConnectionId;
  if (selected == null || !connections.any((item) => item.id == selected)) {
    selected = connections.first.id;
  }
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text('Select NAS connection'.tl),
        content: RadioGroup<String>(
          groupValue: selected,
          onChanged: (value) {
            if (value != null) setState(() => selected = value);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final connection in connections)
                RadioListTile<String>(
                  value: connection.id,
                  title: Text(connection.name),
                  subtitle: Text(
                    '${connection.protocol.name.toUpperCase()} · ${connection.host}',
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, selected),
            child: Text('Confirm'.tl),
          ),
        ],
      ),
    ),
  );
}
