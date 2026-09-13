part of 'settings_page.dart';

class NasSettingsView extends StatefulWidget {
  const NasSettingsView({super.key});

  @override
  State<NasSettingsView> createState() => _NasSettingsViewState();
}

class _NasSettingsViewState extends State<NasSettingsView> {
  final manager = NasManager.instance;
  String? _message;

  @override
  void initState() {
    super.initState();
    manager.addListener(_changed);
  }

  @override
  void dispose() {
    manager.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _edit([NasConnection? existing]) async {
    await context.to(() => NasConnectionEditor(existing: existing));
    if (mounted) setState(() {});
  }

  Future<void> _sync(NasConnection connection) async {
    setState(() => _message = null);
    try {
      final result = await manager.syncAll(connection.id);
      if (mounted) {
        setState(() {
          _message = 'Uploaded @a file(s), skipped @b unchanged file(s), @c.'
              .tlParams({
                'a': result.uploadedFiles.toString(),
                'b': result.skippedFiles.toString(),
                'c': bytesToReadableString(result.totalBytes),
              });
        });
      }
    } catch (e, s) {
      Log.error('NAS', 'NAS sync failed: $e', s);
      if (mounted) setState(() => _message = 'NAS sync failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final connections = manager.connections;
    final progress = manager.progress;
    return PopUpWidgetScaffold(
      title: 'NAS Storage'.tl,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Connect a NAS with WebDAV, FTP/FTPS, or SMB 2/3. Sync uploads '
                    'downloaded comics and an app-data backup without deleting remote files.'
                .tl,
          ),
          const SizedBox(height: 16),
          if (connections.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                'No NAS connections yet'.tl,
                textAlign: TextAlign.center,
              ),
            ),
          for (final connection in connections)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Use as default'.tl,
                          onPressed: manager.isSyncing
                              ? null
                              : () =>
                                    manager.setDefaultConnection(connection.id),
                          icon: Icon(
                            manager.defaultConnectionId == connection.id
                                ? Icons.star
                                : Icons.star_border,
                          ),
                        ),
                        Expanded(
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(connection.name),
                            subtitle: Text(
                              '${connection.protocol.name.toUpperCase()} · '
                              '${connection.host} · /${normalizeRemotePath(connection.remotePath)}',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Edit'.tl,
                          onPressed: manager.isSyncing
                              ? null
                              : () => _edit(connection),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: 'Delete'.tl,
                          onPressed: manager.isSyncing
                              ? null
                              : () => manager.deleteConnection(connection.id),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: manager.isSyncing
                            ? null
                            : () => _sync(connection),
                        icon: const Icon(Icons.sync),
                        label: Text('Sync now'.tl),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (manager.isSyncing && progress != null) ...[
            NasSyncProgressPanel(progress: progress),
          ],
          if (_message != null) ...[
            const SizedBox(height: 12),
            SelectableText(_message!),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('nas-add'),
            onPressed: manager.isSyncing ? null : () => _edit(),
            icon: const Icon(Icons.add),
            label: Text('Add NAS connection'.tl),
          ),
        ],
      ),
    );
  }
}

class NasConnectionEditor extends StatefulWidget {
  const NasConnectionEditor({this.existing, super.key});

  final NasConnection? existing;

  @override
  State<NasConnectionEditor> createState() => _NasConnectionEditorState();
}

class _NasConnectionEditorState extends State<NasConnectionEditor> {
  final _formKey = GlobalKey<FormState>();
  late NasProtocol _protocol;
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _password;
  late final TextEditingController _remotePath;
  late final TextEditingController _share;
  late final TextEditingController _domain;
  bool _smbEncryption = true;
  bool _testing = false;
  String? _testMessage;

  @override
  void initState() {
    super.initState();
    final value = widget.existing;
    _protocol = value?.protocol ?? NasProtocol.smb;
    _name = TextEditingController(text: value?.name ?? '');
    _host = TextEditingController(text: value?.host ?? '');
    _port = TextEditingController(text: value?.port?.toString() ?? '');
    _user = TextEditingController(text: value?.username ?? '');
    _password = TextEditingController(text: value?.password ?? '');
    _remotePath = TextEditingController(text: value?.remotePath ?? 'Venera');
    _share = TextEditingController(text: value?.share ?? '');
    _domain = TextEditingController(text: value?.domain ?? '');
    _smbEncryption = value?.smbEncryption ?? true;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _host,
      _port,
      _user,
      _password,
      _remotePath,
      _share,
      _domain,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  NasConnection _value() => NasConnection(
    id: widget.existing?.id ?? const Uuid().v4(),
    name: _name.text.trim(),
    protocol: _protocol,
    host: _host.text.trim(),
    username: _user.text,
    password: _password.text,
    port: _port.text.trim().isEmpty ? null : int.tryParse(_port.text.trim()),
    remotePath: _remotePath.text.trim(),
    share: _share.text.trim(),
    domain: _domain.text.trim(),
    smbEncryption: _smbEncryption,
  );

  Future<void> _test() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final error = _value().validationError();
    if (error != null) {
      setState(() => _testMessage = error.tl);
      return;
    }
    setState(() {
      _testing = true;
      _testMessage = 'Connecting...'.tl;
    });
    try {
      await NasManager.instance.testConnection(_value());
      if (mounted) setState(() => _testMessage = 'Connection successful'.tl);
    } catch (e) {
      if (mounted) setState(() => _testMessage = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final error = _value().validationError();
    if (error != null) {
      setState(() => _testMessage = error.tl);
      return;
    }
    await NasManager.instance.saveConnection(_value());
    if (mounted) context.pop();
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    String? hint,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: label.tl,
          hintText: hint,
        ),
        validator: validator,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null
              ? 'Add NAS connection'.tl
              : 'Edit NAS connection'.tl,
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<NasProtocol>(
              initialValue: _protocol,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Protocol'.tl,
              ),
              items: NasProtocol.values
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(value.name.toUpperCase()),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _protocol = value ?? _protocol),
            ),
            const SizedBox(height: 10),
            _field(
              _name,
              'Name',
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Name cannot be empty'.tl
                  : null,
            ),
            _field(
              _host,
              _protocol == NasProtocol.webdav ? 'WebDAV URL' : 'Host',
              hint: _protocol == NasProtocol.webdav
                  ? 'https://nas.example.com/dav'
                  : '192.168.1.10',
              validator: (value) {
                final host = value?.trim() ?? '';
                if (host.isEmpty) return 'Host cannot be empty'.tl;
                if (_protocol == NasProtocol.webdav &&
                    !(host.startsWith('http://') ||
                        host.startsWith('https://'))) {
                  return 'WebDAV address must start with http:// or https://'
                      .tl;
                }
                return null;
              },
            ),
            _field(
              _port,
              'Port',
              keyboardType: TextInputType.number,
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return null;
                final port = int.tryParse(text);
                return port == null || port < 1 || port > 65535
                    ? 'Invalid port'.tl
                    : null;
              },
            ),
            if (_protocol == NasProtocol.smb) ...[
              _field(
                _share,
                'SMB share',
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'SMB share cannot be empty'.tl
                    : null,
              ),
              _field(_domain, 'Domain (optional)'),
            ],
            _field(_user, 'Username'),
            _field(_password, 'Password', obscure: true),
            _field(
              _remotePath,
              'Remote folder',
              validator: (value) {
                try {
                  normalizeRemotePath(value ?? '');
                  return null;
                } catch (_) {
                  return 'Remote path cannot contain ..'.tl;
                }
              },
            ),
            if (_protocol == NasProtocol.smb)
              SwitchListTile(
                title: Text('Require SMB 3 encryption'.tl),
                subtitle: Text(
                  'Disable only when the NAS supports SMB 2 but not SMB 3.'.tl,
                ),
                value: _smbEncryption,
                onChanged: (value) => setState(() => _smbEncryption = value),
              ),
            if (_protocol == NasProtocol.ftp)
              ListTile(
                leading: const Icon(Icons.warning_amber_outlined),
                title: Text(
                  'FTP sends credentials without encryption. Prefer FTPS or SMB 3.'
                      .tl,
                ),
              ),
            if (_testMessage != null) SelectableText(_testMessage!),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('nas-test'),
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.cable),
                  label: Text('Test connection'.tl),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('nas-save'),
                  onPressed: _testing ? null : _save,
                  child: Text('Save'.tl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
