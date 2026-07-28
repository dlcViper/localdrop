import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_settings_plus/open_settings_plus.dart';

import 'server_screen.dart';

/// On first launch, triggers the real Android permission dialog.
/// If denied, shows an explanatory screen with settings button.
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  bool _checking = true;
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final status = await Permission.storage.status;
    if (status.isGranted) {
      setState(() {
        _granted = true;
        _checking = false;
      });
      return;
    }
    final result = await Permission.storage.request();
    setState(() {
      _granted = result.isGranted;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_granted) {
      return Scaffold(
        appBar: AppBar(title: const Text('Storage Permission')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_off, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                const Text(
                  'LocalDrop needs storage access\nto read and write files on your device.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {},
                  /* TODO: open Android settings via platform channel — placeholder */
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const ServerScreen();
  }
}
