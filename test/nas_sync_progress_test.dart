import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/nas/nas_manager.dart';

void main() {
  test('NAS progress combines completed and current file bytes', () {
    const progress = NasSyncProgress(
      scannedFiles: 2,
      totalFiles: 4,
      uploadedFiles: 1,
      skippedFiles: 1,
      currentPath: 'cover.webp',
      sentBytes: 25,
      currentFileTotalBytes: 50,
      completedBytes: 75,
      totalBytes: 200,
      uploadedBytes: 50,
      bytesPerSecond: 25,
    );

    expect(progress.fraction, 0.5);
    expect(progress.transferredBytes, 75);
    expect(progress.estimatedRemaining, const Duration(seconds: 4));
  });

  test('NAS progress has no ETA before the first bytes are sent', () {
    const progress = NasSyncProgress(
      scannedFiles: 0,
      totalFiles: 3,
      uploadedFiles: 0,
      skippedFiles: 0,
      currentPath: '',
      sentBytes: 0,
      currentFileTotalBytes: 0,
      completedBytes: 0,
      totalBytes: 100,
      uploadedBytes: 0,
      bytesPerSecond: 0,
    );

    expect(progress.estimatedRemaining, isNull);
    expect(progress.fraction, 0);
  });
}
