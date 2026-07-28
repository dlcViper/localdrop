import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/server_controller.dart';
import '../services/app_logger.dart';
import 'settings_screen.dart';
import 'log_screen.dart';
import '../models/transfer.dart';

class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  final _ctrl = ServerController();

  @override
  void initState() {
    super.initState();
    _ctrl.init();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalDrop'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Logs',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LogScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => Future.sync(() {}),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildServerCard(),
              const SizedBox(height: 12),
              _buildQrCard(),
              const SizedBox(height: 12),
              _buildPinCard(),
              const SizedBox(height: 12),
              _buildTransfersCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServerCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _ctrl.running ? Icons.cloud_done : Icons.cloud_off,
                  color: _ctrl.running ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  _ctrl.running ? 'Server running' : 'Server stopped',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_ctrl.running && _ctrl.url != null)
              SelectableText(
                _ctrl.url!,
                style: const TextStyle(fontSize: 1.1, fontFamily: 'monospace'),
              ),
            const SizedBox(height: 4),
            Text('Shared: ${_ctrl.sharedPath}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _ctrl.running ? _ctrl.stop : _ctrl.start,
                  icon: Icon(_ctrl.running ? Icons.stop : Icons.play_arrow),
                  label: Text(_ctrl.running ? 'Stop' : 'Start'),
                ),
                if (_ctrl.error != null)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        _ctrl.error!,
                        style: const TextStyle(color: Colors.red, fontSize: 0.8),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
            if (_ctrl.starting)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrCard() {
    if (!_ctrl.running || _ctrl.url == null) {
      return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Start the server to see the QR code.')));
    }
    final url = _ctrl.url!;
    final displayUrl = url.length > 50 ? '${url.substring(0, 50)}…' : url;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            const Text('Connect from other devices:', style: TextStyle(fontSize: 0.85)),
            const SizedBox(height: 8),
            QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 200,
            ),
            const SizedBox(height: 8),
            SelectableText(displayUrl, style: const TextStyle(fontSize: 0.8, fontFamily: 'monospace')),
          ],
        ),
      ),
    );
  }

  Widget _buildPinCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PIN for browser clients', style: TextStyle(fontSize: 0.85)),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  _ctrl.pin,
                  style: const TextStyle(fontSize: 2, fontFamily: 'monospace', letterSpacing: 0.5),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy PIN',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _ctrl.pin));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('PIN copied')),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Regenerate PIN',
                  onPressed: _ctrl.regeneratePinNow,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransfersCard() {
    final transfers = _ctrl.transferViews;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Transfers (${transfers.length})', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (transfers.isEmpty)
              const Text('No active transfers.', style: TextStyle(color: Colors.grey)),
            ...transfers.take(20).map((t) => _transferRow(t)),
          ],
        ),
      ),
    );
  }

  Widget _transferRow(TransferInfoView t) {
    final pct = t.bytesTotal > 0
        ? ((t.bytesDone / t.bytesTotal) * 100).toStringAsFixed(1) + '%'
        : (t.status == 'completed' ? '100%' : '—');
    StatusColor color;
    switch (t.status) {
      case 'completed': color = Colors.green; break;
      case 'failed': color = Colors.red; break;
      case 'active': color = Colors.blue; break;
      default: color = Colors.orange; break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(t.direction == 'upload' ? Icons.upload : t.direction == 'zip' ? Icons.archive : Icons.download, size: 18, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              t.name.length > 30 ? '${t.name.substring(0, 30)}…' : t.name,
              style: const TextStyle(fontSize: 0.85),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(pct, style: TextStyle(fontSize: 0.8, color: color)),
          const SizedBox(width: 4),
          Text('${_fmtBytes(t.bytesDone)}/${_fmtBytes(t.bytesTotal)}', style: const TextStyle(fontSize: 0.75, color: Colors.grey)),
        ],
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
