import 'package:uuid/uuid.dart';

enum NasProtocol { webdav, ftp, ftps, smb }

class NasConnection {
  const NasConnection({
    required this.id,
    required this.name,
    required this.protocol,
    required this.host,
    required this.username,
    required this.password,
    this.port,
    this.remotePath = 'Venera',
    this.share = '',
    this.domain = '',
    this.smbEncryption = true,
  });

  final String id;
  final String name;
  final NasProtocol protocol;
  final String host;
  final String username;
  final String password;
  final int? port;
  final String remotePath;
  final String share;
  final String domain;
  final bool smbEncryption;

  factory NasConnection.create({
    required String name,
    required NasProtocol protocol,
    required String host,
    required String username,
    required String password,
    int? port,
    String remotePath = 'Venera',
    String share = '',
    String domain = '',
    bool smbEncryption = true,
  }) => NasConnection(
    id: const Uuid().v4(),
    name: name,
    protocol: protocol,
    host: host,
    username: username,
    password: password,
    port: port,
    remotePath: remotePath,
    share: share,
    domain: domain,
    smbEncryption: smbEncryption,
  );

  factory NasConnection.fromJson(Map<String, dynamic> json) => NasConnection(
    id: json['id'] as String,
    name: json['name'] as String,
    protocol: NasProtocol.values.firstWhere(
      (value) => value.name == json['protocol'],
    ),
    host: json['host'] as String,
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
    port: (json['port'] as num?)?.toInt(),
    remotePath: json['remotePath'] as String? ?? 'Venera',
    share: json['share'] as String? ?? '',
    domain: json['domain'] as String? ?? '',
    smbEncryption: json['smbEncryption'] as bool? ?? true,
  );

  int get effectivePort =>
      port ??
      switch (protocol) {
        NasProtocol.webdav =>
          host.toLowerCase().startsWith('https://') ? 443 : 80,
        NasProtocol.ftp => 21,
        NasProtocol.ftps => 21,
        NasProtocol.smb => 445,
      };

  String? validationError() {
    if (name.trim().isEmpty) return 'Name cannot be empty';
    if (host.trim().isEmpty) return 'Host cannot be empty';
    if (port != null && (port! < 1 || port! > 65535)) return 'Invalid port';
    if (protocol == NasProtocol.webdav &&
        !(host.startsWith('http://') || host.startsWith('https://'))) {
      return 'WebDAV address must start with http:// or https://';
    }
    if (protocol == NasProtocol.smb && share.trim().isEmpty) {
      return 'SMB share cannot be empty';
    }
    try {
      normalizeRemotePath(remotePath);
    } catch (e) {
      return e.toString();
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'host': host,
    'username': username,
    'password': password,
    if (port != null) 'port': port,
    'remotePath': remotePath,
    if (share.isNotEmpty) 'share': share,
    if (domain.isNotEmpty) 'domain': domain,
    'smbEncryption': smbEncryption,
  };
}

String normalizeRemotePath(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList();
  if (parts.any((part) => part == '..')) {
    throw const FormatException('Remote path cannot contain ..');
  }
  return parts.join('/');
}

String joinRemotePath(Iterable<String> parts) =>
    normalizeRemotePath(parts.where((part) => part.isNotEmpty).join('/'));
