import 'dart:async';
import 'dart:collection';

import '../models/transfer.dart';

/// Tracks upload/download progress for both the Flutter UI and the web client.
class TransferTracker {
  TransferTracker._();
  static final TransferTracker instance = TransferTracker._();

  final Map<String, TransferInfo> _items = LinkedHashMap();
  final StreamController<List<TransferInfo>> _ctrl =
      StreamController<List<TransferInfo>>.broadcast();

  static const int maxHistory = 100;

  Stream<List<TransferInfo>> get stream => _ctrl.stream;
  List<TransferInfo> get all => List.unmodifiable(_items.values.toList().reversed);

  TransferInfo start({
    required String id,
    required TransferDirection direction,
    required String name,
    int bytesTotal = 0,
  }) {
    final t = TransferInfo(
      id: id,
      direction: direction,
      name: name,
      status: TransferStatus.preparing,
      bytesTotal: bytesTotal,
    );
    _items[id] = t;
    _trim();
    _emit();
    return t;
  }

  void markActive(String id, {int? bytesTotal}) {
    final t = _items[id];
    if (t == null) return;
    t.status = TransferStatus.active;
    if (bytesTotal != null && bytesTotal > 0) t.bytesTotal = bytesTotal;
    _emit();
  }

  void progress(String id, int bytesDone, {int? bytesTotal}) {
    final t = _items[id];
    if (t == null) return;
    if (t.status == TransferStatus.preparing) {
      t.status = TransferStatus.active;
    }
    t.bytesDone = bytesDone;
    if (bytesTotal != null && bytesTotal > 0) t.bytesTotal = bytesTotal;
    _emit();
  }

  void complete(String id, {int? bytesDone}) {
    final t = _items[id];
    if (t == null) return;
    if (bytesDone != null) t.bytesDone = bytesDone;
    if (t.bytesTotal <= 0) t.bytesTotal = t.bytesDone;
    t.status = TransferStatus.completed;
    t.finishedAt = DateTime.now();
    _emit();
  }

  void fail(String id, String reason) {
    final t = _items[id];
    if (t == null) return;
    t.status = TransferStatus.failed;
    t.error = reason;
    t.finishedAt = DateTime.now();
    _emit();
  }

  TransferInfo? get(String id) => _items[id];

  Map<String, dynamic>? toJson(String id) => _items[id]?.toJson();

  List<Map<String, dynamic>> listJson() =>
      all.map((e) => e.toJson()).toList();

  void _trim() {
    while (_items.length > maxHistory) {
      _items.remove(_items.keys.first);
    }
  }

  void _emit() {
    if (!_ctrl.isClosed) _ctrl.add(all);
  }

  void clearFinished() {
    _items.removeWhere(
      (_, v) =>
          v.status == TransferStatus.completed ||
          v.status == TransferStatus.failed ||
          v.status == TransferStatus.cancelled,
    );
    _emit();
  }
}
