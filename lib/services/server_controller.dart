import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../server/local_drop_server.dart';
import '../services/app_logger.dart';
import '../services/auth_service.dart';
import '../services/transfer_tracker.dart';
import '../models/transfer.dart';

/// Owns server lifecycle, PIN, IP discovery, web asset loading, foreground service.
class ServerController extends ChangeNotifier {
  ServerController();

  final _log = AppLogger.instance;
  final _auth = AuthService.instance;
  final transfers = TransferTracker.instance;

  LocalDropServer? _server;
  bool starting = false;
  bool running = false;
  String? url;
  String? localIp;
  String? error;
  String pin = '------';
  String sharedPath = '';
  List<TransferInfoView> transferViews = [];

  Future<void> init() async {
    await _log.init();
    await _auth.load();
    pin = _auth.pin;
    sharedPath = _auth.sharedFolderPath ?? await _defaultShared();
    _auth.sharedFolderPath = sharedPath;
    await _auth.save();
    _listenTransfers();
    notifyListeners();
  }

  Future<String> _defaultShared() async {
    final ext = await getExternalStorageDirectory();
    if (ext != null) {
      final d = Directory('${ext.path}/LocalDrop');
      if (!await d.exists()) await d.create(recursive: true);
      return d.path;
    }
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/LocalDrop');
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }

  void _listenTransfers() {
    transfers.stream.listen((list) {
      transferViews = list
          .map((t) => TransferInfoView(
                id: t.id,
                name: t.name,
                direction: t.direction.name,
                status: t.status.name,
                bytesDone: t.bytesDone,
                bytesTotal: t.bytesTotal,
                progress: t.progress,
                error: t.error,
              ))
          .toList();
      notifyListeners();
    });
  }

  Future<void> _loadWebAssetsInto(LocalDropServer server) async {
    const names = ['index.html', 'app.js', 'style.css'];
    for (final n in names) {
      final data = await rootBundle.load('assets/web/$n');
      final bytes = data.buffer.asUint8List();
      server.webAssets[n] = Uint8List.fromList(bytes);
    }
  }

  Future<String?> _detectIp() async {
    final info = NetworkInfo();
    try {
      final wifi = await info.getWifiIP();
      if (wifi != null && wifi.isNotEmpty && wifi != '0.0.0.0') return wifi;
    } catch (e) {
      _log.warn('net', 'wifi ip failed: $e');
    }
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      )) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (e) {
      _log.warn('net', 'iface list failed: $e');
    }
    return null;
  }

  Future<void> start() async {
    if (running || starting) return;
    starting = true;
    error = null;
    notifyListeners();
    try {
      _auth.generatePin();
      pin = _auth.pin;
      await _auth.save();

      localIp = await _detectIp();
      if (localIp == null) {
        throw StateError(
          'No local IP found. Connect to Wi-Fi and try again.',
        );
      }

      final root = Directory(sharedPath);
      if (!await root.exists()) await root.create(recursive: true);

      final server = LocalDropServer(
        sharedRoot: root,
        preferredPort: _auth.portOverride,
        onTransfersChanged: () {
          // stream already notifies
        },
      );
      await _loadWebAssetsInto(server);

      await server.start(bindAddress: localIp!);
      _server = server;
      running = true;
      url = server.baseUrl;
      await _startForeground(url!);
      _log.info('ctrl', 'server up $url pin_set=true');
    } catch (e, st) {
      error = e.toString();
      _log.error('ctrl', 'start failed: $e', st);
      running = false;
      url = null;
      await _server?.stop();
      _server = null;
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    try {
      await _server?.stop();
    } catch (e, st) {
      _log.error('ctrl', 'stop error: $e', st);
    }
    _server = null;
    running = false;
    url = null;
    await FlutterForegroundTask.stopService();
    notifyListeners();
  }

  Future<void> setSharedPath(String path) async {
    sharedPath = path;
    _auth.sharedFolderPath = path;
    await _auth.save();
    _server?.updateRoot(Directory(path));
    _log.info('ctrl', 'shared path -> $path');
    notifyListeners();
  }

  Future<void> setPort(int port) async {
    _auth.portOverride = port;
    await _auth.save();
    notifyListeners();
  }

  Future<void> setRegenPin(bool v) async {
    _auth.regeneratePinOnStart = v;
    await _auth.save();
    notifyListeners();
  }

  Future<void> regeneratePinNow() async {
    _auth.generatePin(force: true);
    pin = _auth.pin;
    await _auth.save();
    notifyListeners();
  }

  int get portOverride => _auth.portOverride;
  bool get regenPinOnStart => _auth.regeneratePinOnStart;

  Future<void> _startForeground(String serverUrl) async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'localdrop_server',
        channelName: 'LocalDrop Server',
        channelDescription: 'Keeps the local file server running',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(15000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    await FlutterForegroundTask.startService(
      notificationTitle: 'LocalDrop running',
      notificationText: serverUrl,
      callback: startLocalDropForegroundCallback,
    );
  }
}

class TransferInfoView {
  TransferInfoView({
    required this.id,
    required this.name,
    required this.direction,
    required this.status,
    required this.bytesDone,
    required this.bytesTotal,
    required this.progress,
    this.error,
  });
  final String id;
  final String name;
  final String direction;
  final String status;
  final int bytesDone;
  final int bytesTotal;
  final double progress;
  final String? error;
}

@pragma('vm:entry-point')
void startLocalDropForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_LocalDropTaskHandler());
}

class _LocalDropTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
