import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_logger.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  List<String> _lines = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // Auto-refresh every 2s while on this screen
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  Timer? _timer;

  Future<void> _load() async {
    setState(() => _loading = true);
    final text = await AppLogger.instance.readAll();
    _lines = text.isEmpty ? [] : text.split('\n');
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Copy logs',
            onPressed: () async {
              final text = _lines.join('\n');
              await Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied')),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _lines.length,
              itemBuilder: (context, i) {
                final line = _lines[i];
                Color color = Colors.grey;
                if (line.contains('[ERROR]')) color = Colors.red;
                if (line.contains('[WARN]')) color = Colors.orange;
                if (line.contains('[INFO]')) color = Colors.blue;
                if (line.contains('[REQ]')) color = Colors.purple;
                if (line.contains('[transfer]')) color = Colors.teal;
                return SelectableText(
                  line,
                  style: TextStyle(fontSize: 0.8, fontFamily: 'monospace', color: color),
                  maxLines: 2,
                );
              },
            ),
    );
  }
}
