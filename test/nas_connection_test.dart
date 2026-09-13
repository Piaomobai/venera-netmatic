import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/nas/nas_connection.dart';

void main() {
  group('NAS connection model', () {
    test('round trips every SMB setting', () {
      const connection = NasConnection(
        id: 'nas-1',
        name: 'Home NAS',
        protocol: NasProtocol.smb,
        host: '192.168.1.20',
        username: 'reader',
        password: 'secret',
        port: 445,
        remotePath: r'Comics\Venera',
        share: 'media',
        domain: 'WORKGROUP',
        smbEncryption: true,
      );

      final restored = NasConnection.fromJson(connection.toJson());
      expect(restored.id, connection.id);
      expect(restored.protocol, NasProtocol.smb);
      expect(restored.share, 'media');
      expect(restored.domain, 'WORKGROUP');
      expect(restored.smbEncryption, isTrue);
      expect(restored.validationError(), isNull);
    });

    test('normalizes separators and rejects parent traversal', () {
      expect(
        normalizeRemotePath(r'/Comics\Venera/./Title/'),
        'Comics/Venera/Title',
      );
      expect(
        () => normalizeRemotePath('Comics/../private'),
        throwsFormatException,
      );
    });

    test('requires an absolute WebDAV URL and an SMB share', () {
      const webdav = NasConnection(
        id: '1',
        name: 'DAV',
        protocol: NasProtocol.webdav,
        host: 'nas.local/dav',
        username: '',
        password: '',
      );
      const smb = NasConnection(
        id: '2',
        name: 'SMB',
        protocol: NasProtocol.smb,
        host: 'nas.local',
        username: '',
        password: '',
      );

      expect(webdav.validationError(), contains('http'));
      expect(smb.validationError(), contains('share'));
    });

    test('joins remote paths without creating absolute or traversal paths', () {
      expect(
        joinRemotePath(['Venera/', r'library\Source', '/Author/Title']),
        'Venera/library/Source/Author/Title',
      );
    });
  });
}
