enum TransferDirection { upload, download, zip }

enum TransferStatus { preparing, active, completed, failed, cancelled }

class TransferInfo {
  final String id;
  final TransferDirection direction;
  final String name;
  TransferStatus status;
  int bytesTotal;
  int bytesDone;
  String? error;
  final DateTime startedAt;
  DateTime? finishedAt;

  TransferInfo({
    required this.id,
    required this.direction,
    required this.name,
    this.status = TransferStatus.preparing,
    this.bytesTotal = 0,
    this.bytesDone = 0,
    this.error,
    DateTime? startedAt,
    this.finishedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  double get progress {
    if (bytesTotal <= 0) return status == TransferStatus.completed ? 1.0 : 0.0;
    return (bytesDone / bytesTotal).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'direction': direction.name,
        'name': name,
        'status': status.name,
        'bytes_total': bytesTotal,
        'bytes_done': bytesDone,
        'progress': progress,
        'error': error,
        'started_at': startedAt.toUtc().toIso8601String(),
        'finished_at': finishedAt?.toUtc().toIso8601String(),
      };
}
