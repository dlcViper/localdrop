import 'package:flutter/material.dart';

import '../services/server_controller.dart';
import '../services/auth_service.dart';
import '../services/app_logger.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ctrl = ServerController();
  final _folderCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  late bool _regenPin;

  @override
  void initState() {
    super.initState();
    _ctrl.init().then((_) {
      _folderCtrl.text = _ctrl.sharedPath;
      _portCtrl.text = _ctrl.portOverride.toString();
      _regenPin = _ctrl.regenPinOnStart;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('Shared Folder'),
          TextField(
            controller: _folderCtrl,
            readOnly: true,
            decoration: InputDecoration(
              suffixIcon: IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: 'Change folder',
                onPressed: () async {
                  // SAF picker — placeholder, calls path_provider for now
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('SAF picker: use this in the final implementation')),
                  );
                },
              ),
              hintText: 'Shared folder path',
            ),
          ),
          const SizedBox(height: 12),
          _section('Server'),
          TextField(
            controller: _portCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Port'),
          ),
          const SizedBox(height: 12),
          _section('PIN'),
          SwitchListTile(
            title: const Text('Regenerate PIN on every server start'),
            value: _regenPin,
            onChanged: (v) {
              setState(() => _regenPin = v);
              _ctrl.setRegenPin(v);
            },
          ),
          const SizedBox(height: 8),
          _section('Debug'),
          ListTile(
            leading: const Icon(Icons.delete_sweep),
            title: const Text('Clear logs'),
            onTap: () async {
              await AppLogger.instance.clear();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Logs cleared')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_all),
            title: const Text('Copy current PIN'),
            onTap: () {
              // handled in server screen
              Navigator.pop(context);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          final port = int.tryParse(_portCtrl.text);
          if (port != null && port > 0 && port < 65536) {
            _ctrl.setPort(port);
          }
          _ctrl.setSharedPath(_folderCtrl.text.trim());
          Navigator.pop(context);
        },
        icon: const Icon(Icons.save),
        label: const Text('Save'),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}
