import 'package:flutter/material.dart';
import 'package:venera_netmatic/foundation/nas/nas_manager.dart';
import 'package:venera_netmatic/utils/io.dart';
import 'package:venera_netmatic/utils/translations.dart';

class NasSyncProgressPanel extends StatelessWidget {
  const NasSyncProgressPanel({required this.progress, super.key});

  final NasSyncProgress progress;

  String _duration(Duration? value) {
    if (value == null) return '--';
    final seconds = value.inSeconds;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remaining = seconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final fraction = progress.fraction.clamp(0.0, 1.0).toDouble();
    final hasFiles = progress.totalFiles > 0;
    final speed = bytesToReadableString(progress.bytesPerSecond);
    final transferred = bytesToReadableString(progress.transferredBytes);
    final total = bytesToReadableString(progress.totalBytes);
    final details = hasFiles
        ? 'NAS progress: @a/@b files · @c uploaded · @d skipped'.tlParams({
            'a': progress.scannedFiles.toString(),
            'b': progress.totalFiles.toString(),
            'c': progress.uploadedFiles.toString(),
            'd': progress.skippedFiles.toString(),
          })
        : 'Connecting to NAS...'.tl;
    final transfer = hasFiles
        ? 'NAS transfer: @a / @b · @c/s · ETA @d'.tlParams({
            'a': transferred,
            'b': total,
            'c': speed,
            'd': _duration(progress.estimatedRemaining),
          })
        : '';

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_upload_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(details)),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: hasFiles ? fraction : null,
              minHeight: 6,
            ),
            if (transfer.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(transfer),
            ],
            if (progress.currentPath.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Uploading: @a'.tlParams({'a': progress.currentPath}),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
