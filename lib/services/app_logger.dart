import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Rotating / capped file logger + in-memory ring buffer for the UI.
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const int maxFileBytes = 2 * 1024 * 1024; // 2 MB
  static const int maxMemoryLines = 500;

  final Queue<String> _memory = Queue<String>();
  final StreamController<String> _live = StreamController<String>.broadcast();
  File? _file;
  IOSink? _sink;
  bool _ready = false;

  Stream<String> get live => _live.stream;
  List<String> get lines => List.unmodifiable(_memory.toList());

  Future<void> init() async {
    if (_ready) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(dir.path, 'logs'));
      if (!await logDir.exists()) await logDir.create(recursive: true);
      _file = File(p.join(logDir.path, 'localdrop.log'));
      if (await _file!.exists() && await _file!.length() > maxFileBytes) {
        final bak = File(p.join(logDir.path, 'localdrop.log.1'));
        if (await bak.exists()) await bak.delete();
        await _file!.rename(bak.path);
        _file = File(p.join(logDir.path, 'localdrop.log'));
      }
      _sink = _file!.openWrite(mode: FileMode.append);
      _ready = true;
      info('logger', 'initialized path=${_file!.path}');
    } catch (e, st) {
      // Fallback: memory only
      _ready = true;
      error('logger', 'file init failed: $e', st);
    }
  }

  void _write(String level, String tag, String message, [StackTrace? st]) {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] [$level] [$tag] $message';
    final full = st != null ? '$line\n$st' : line;
    while (_memory.length >= maxMemoryLines) {
      _memory.removeFirst();
    }
    _memory.add(full);
    if (!_live.isClosed) _live.add(full);
    try {
      _sink?.writeln(full);
    } catch (_) {}
    // Also mirror to stdout for `flutter run` / logcat
    // ignore: avoid_print
    print(full);
  }

  void info(String tag, String message) => _write('INFO', tag, message);
  void warn(String tag, String message) => _write('WARN', tag, message);
  void error(String tag, String message, [StackTrace? st]) =>
      _write('ERROR', tag, message, st);
  void request(String method, String path, {int? status, String? extra}) {
    final parts = <String>[method, path];
    if (status != null) parts.add('status=$status');
    if (extra != null && extra.isNotEmpty) parts.add(extra);
    _write('REQ', 'http', parts.join(' '));
  }

  Future<String> readAll() async {
    final buf = StringBuffer();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final bak = File(p.join(dir.path, 'logs', 'localdrop.log.1'));
      if (await bak.exists()) buf.writeln(await bak.readAsString());
      if (_file != null && await _file!.exists()) {
        await _sink?.flush();
        buf.writeln(await _file!.readAsString());
      }
    } catch (_) {
      for (final l in _memory) {
        buf.writeln(l);
      }
    }
    return buf.toString();
  }

  Future<void> clear() async {
    _memory.clear();
    try {
      await _sink?.flush();
      await _sink?.close();
      if (_file != null && await _file!.exists()) await _file!.writeAsString('');
      _sink = _file?.openWrite(mode: FileMode.append);
    } catch (_) {}
    info('logger', 'cleared');
  }

  Future<void> dispose() async {
    await _sink?.flush();
    await _sink?.close();
    await _live.close();
  }
}
