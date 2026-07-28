import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../models/file_entry.dart';
import '../services/app_logger.dart';
import '../services/auth_service.dart';
import '../services/transfer_tracker.dart';
import '../models/transfer.dart';

typedef TransferListener = void Function();

/// Embedded local-network file hub.
class LocalDropServer {
  LocalDropServer({
    required this.sharedRoot,
    this.preferredPort = 8080,
    this.onTransfersChanged,
  });

  Directory sharedRoot;
  int preferredPort;
  TransferListener? onTransfersChanged;

  HttpServer? _server;
  int? boundPort;
  String? boundAddress;
  final _uuid = const Uuid();
  final _log = AppLogger.instance;
  final _auth = AuthService.instance;
  final _transfers = TransferTracker.instance;

  // In-memory web assets (loaded once from Flutter assets by the service layer)
  final Map<String, Uint8List> webAssets = {};

  bool get isRunning => _server != null;
  String? get baseUrl {
    if (boundAddress == null || boundPort == null) return null;
    return 'http://$boundAddress:$boundPort';
  }

  Future<void> start({required String bindAddress}) async {
    if (_server != null) await stop();

    final router = Router();
    router.get('/', _handleIndex);
    router.get('/app.js', _handleStatic('app.js', 'application/javascript'));
    router.get('/style.css', _handleStatic('style.css', 'text/css'));
    router.post('/api/auth', _handleAuth);
    router.get('/api/files', _handleListFiles);
    router.get('/api/download/<filename|.*>', _handleDownload);
    router.get('/api/download-zip', _handleDownloadZip);
    router.post('/api/upload', _handleUpload);
    router.get('/api/progress', _handleProgressList);
    router.get('/api/progress/<id>', _handleProgressOne);
    router.get('/api/health', (Request req) {
      return _json({'ok': true, 'pin_set': true});
    });

    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware())
        .addMiddleware(_loggingMiddleware())
        .addMiddleware(_authMiddleware())
        .addHandler(router.call);

    final ports = <int>[
      preferredPort,
      for (var i = 1; i <= 20; i++) preferredPort + i,
      for (var i = 0; i < 10; i++) 18080 + i,
    ];

    Object? lastErr;
    for (final port in ports) {
      try {
        _server = await shelf_io.serve(
          handler,
          InternetAddress.anyIPv4,
          port,
          shared: true,
        );
        // Long transfers — disable aggressive idle timeouts where possible.
        _server!.idleTimeout = const Duration(hours: 6);
        // Auto-compress small text responses only; leave file streams alone.
        _server!.autoCompress = false;
        boundPort = port;
        boundAddress = bindAddress;
        _log.info(
          'server',
          'started url=http://$bindAddress:$port root=${sharedRoot.path}',
        );
        return;
      } catch (e) {
        lastErr = e;
        _log.warn('server', 'port $port busy: $e');
      }
    }
    throw StateError('No free port. Last error: $lastErr');
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    boundPort = null;
    boundAddress = null;
    if (s != null) {
      await s.close(force: true);
      _log.info('server', 'stopped');
    }
    _auth.clearSession();
  }

  void updateRoot(Directory dir) {
    sharedRoot = dir;
    _log.info('server', 'shared root -> ${dir.path}');
  }

  // ── Middleware ──────────────────────────────────────────────

  Middleware _corsMiddleware() {
    return (inner) {
      return (req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders());
        }
        final res = await inner(req);
        return res.change(headers: {...res.headers, ..._corsHeaders()});
      };
    };
  }

  Map<String, String> _corsHeaders() => {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers':
            'Authorization, Content-Type, X-Session-Token, X-Transfer-Id, Content-Disposition, Content-Range',
        'Access-Control-Expose-Headers':
            'Content-Disposition, Content-Length, Content-Range, Accept-Ranges, X-Transfer-Id',
      };

  Middleware _loggingMiddleware() {
    return (inner) {
      return (req) async {
        final sw = Stopwatch()..start();
        try {
          final res = await inner(req);
          sw.stop();
          _log.request(
            req.method,
            req.requestedUri.path,
            status: res.statusCode,
            extra: 'ms=${sw.elapsedMilliseconds}',
          );
          return res;
        } catch (e, st) {
          sw.stop();
          _log.error('http', '${req.method} ${req.requestedUri.path} crashed: $e', st);
          rethrow;
        }
      };
    };
  }

  Middleware _authMiddleware() {
    const public = {'/', '/app.js', '/style.css', '/api/auth', '/api/health'};
    return (inner) {
      return (req) async {
        final path = req.requestedUri.path;
        if (public.contains(path) || req.method == 'OPTIONS') {
          return inner(req);
        }
        final token = _extractToken(req);
        if (!_auth.validateToken(token)) {
          _log.warn('auth', 'rejected path=$path reason=session_expired_or_missing');
          return _json(
            {'error': 'session expired', 'reason': 'session_expired'},
            status: 401,
          );
        }
        return inner(req);
      };
    };
  }

  String? _extractToken(Request req) {
    final h = req.headers['authorization'];
    if (h != null && h.toLowerCase().startsWith('bearer ')) {
      return h.substring(7).trim();
    }
    final x = req.headers['x-session-token'];
    if (x != null && x.isNotEmpty) return x.trim();
    return req.requestedUri.queryParameters['token'];
  }

  // ── Static / index ──────────────────────────────────────────

  Future<Response> _handleIndex(Request req) async {
    final bytes = webAssets['index.html'];
    if (bytes == null) {
      return Response.notFound('Web UI not loaded');
    }
    return Response.ok(
      bytes,
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      },
    );
  }

  Handler _handleStatic(String name, String contentType) {
    return (Request req) {
      final bytes = webAssets[name];
      if (bytes == null) return Response.notFound('missing $name');
      return Response.ok(
        bytes,
        headers: {
          'Content-Type': '$contentType; charset=utf-8',
          'Cache-Control': 'no-store',
        },
      );
    };
  }

  // ── Auth ────────────────────────────────────────────────────

  Future<Response> _handleAuth(Request req) async {
    try {
      final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      final pin = (body['pin'] ?? '').toString();
      final token = _auth.tryAuth(pin);
      if (token == null) {
        _log.warn('auth', 'login failed');
        return _json({'error': 'invalid pin', 'reason': 'invalid_pin'}, status: 401);
      }
      _log.info('auth', 'login success');
      return _json({
        'token': token,
        'expires_in_hours': AuthService.tokenTtl.inHours,
      });
    } catch (e, st) {
      _log.error('auth', 'bad request: $e', st);
      return _json({'error': 'bad request', 'reason': 'bad_request'}, status: 400);
    }
  }

  // ── File listing ────────────────────────────────────────────

  Future<Response> _handleListFiles(Request req) async {
    final rel = req.requestedUri.queryParameters['path'] ?? '';
    final resolved = _resolveSafe(rel);
    if (resolved == null) {
      return _json({'error': 'invalid path', 'reason': 'invalid_path'}, status: 400);
    }
    final dir = Directory(resolved);
    if (!await dir.exists()) {
      return _json({'error': 'not found', 'reason': 'not_found'}, status: 404);
    }
    final entries = <FileEntry>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        final stat = await entity.stat();
        final isDir = entity is Directory;
        final relPath = p.relative(entity.path, from: sharedRoot.path);
        entries.add(FileEntry(
          name: name,
          relativePath: relPath.replaceAll('\\', '/'),
          isDirectory: isDir,
          size: isDir ? 0 : stat.size,
          modified: stat.modified,
          mimeType: isDir ? null : lookupMimeType(name),
        ));
      }
    } catch (e, st) {
      _log.error('files', 'list failed path=$rel: $e', st);
      return _json(
        {'error': 'list failed', 'reason': 'io_error', 'detail': e.toString()},
        status: 500,
      );
    }
    // Directories first, then name
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return _json({
      'path': rel.replaceAll('\\', '/'),
      'root': sharedRoot.path,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
  }

  // ── Download (Range) ────────────────────────────────────────

  Future<Response> _handleDownload(Request req, String filename) async {
    // filename may be URL-encoded path segments
    final decoded = Uri.decodeComponent(filename);
    final resolved = _resolveSafe(decoded);
    if (resolved == null) {
      return _json({'error': 'invalid path', 'reason': 'invalid_path'}, status: 400);
    }
    final file = File(resolved);
    if (!await file.exists()) {
      return _json({'error': 'not found', 'reason': 'not_found'}, status: 404);
    }
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.directory) {
      return _json({'error': 'is a directory', 'reason': 'is_directory'}, status: 400);
    }

    final transferId = req.headers['x-transfer-id']?.trim().isNotEmpty == true
        ? req.headers['x-transfer-id']!.trim()
        : _uuid.v4();
    final displayName = p.basename(file.path);
    _transfers.start(
      id: transferId,
      direction: TransferDirection.download,
      name: displayName,
      bytesTotal: stat.size,
    );
    _notifyTransfers();
    _log.info('transfer', 'download start id=$transferId file=$displayName size=${stat.size}');

    final mime = lookupMimeType(displayName) ?? 'application/octet-stream';
    // RFC 5987 filename* for unicode; also plain filename fallback.
    final disposition = _contentDisposition(displayName);

    final rangeHeader = req.headers['range'];
    try {
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final range = _parseRange(rangeHeader, stat.size);
        if (range == null) {
          _transfers.fail(transferId, 'invalid range');
          _notifyTransfers();
          return Response(
            416,
            body: 'invalid range',
            headers: {'Content-Range': 'bytes */${stat.size}'},
          );
        }
        final (start, end) = range;
        final length = end - start + 1;
        _transfers.markActive(transferId, bytesTotal: stat.size);
        _notifyTransfers();

        final stream = _trackingFileStream(
          file,
          transferId,
          start: start,
          end: end,
          totalSize: stat.size,
        );
        return Response(
          206,
          body: stream,
          headers: {
            'Content-Type': mime,
            'Content-Length': '$length',
            'Content-Range': 'bytes $start-$end/${stat.size}',
            'Accept-Ranges': 'bytes',
            'Content-Disposition': disposition,
            'X-Transfer-Id': transferId,
            'Cache-Control': 'no-store',
          },
        );
      }

      _transfers.markActive(transferId, bytesTotal: stat.size);
      _notifyTransfers();
      final stream = _trackingFileStream(
        file,
        transferId,
        start: 0,
        end: stat.size - 1,
        totalSize: stat.size,
      );
      return Response.ok(
        stream,
        headers: {
          'Content-Type': mime,
          'Content-Length': '${stat.size}',
          'Accept-Ranges': 'bytes',
          'Content-Disposition': disposition,
          'X-Transfer-Id': transferId,
          'Cache-Control': 'no-store',
        },
      );
    } catch (e, st) {
      _log.error('transfer', 'download setup failed id=$transferId: $e', st);
      _transfers.fail(transferId, 'connection lost');
      _notifyTransfers();
      return _json(
        {'error': 'download failed', 'reason': 'connection_lost', 'detail': e.toString()},
        status: 500,
      );
    }
  }

  Stream<List<int>> _trackingFileStream(
    File file,
    String transferId, {
    required int start,
    required int end,
    required int totalSize,
  }) async* {
    final raf = await file.open(mode: FileMode.read);
    var done = start;
    const chunk = 64 * 1024;
    try {
      await raf.setPosition(start);
      var remaining = end - start + 1;
      while (remaining > 0) {
        final toRead = remaining < chunk ? remaining : chunk;
        final data = await raf.read(toRead);
        if (data.isEmpty) break;
        done += data.length;
        remaining -= data.length;
        _transfers.progress(transferId, done, bytesTotal: totalSize);
        // Don't spam UI listeners every chunk — TransferTracker already emits;
        // throttle external notify roughly every 256 KB.
        if (done == start + data.length || done % (256 * 1024) < chunk || remaining <= 0) {
          _notifyTransfers();
        }
        yield data;
      }
      _transfers.complete(transferId, bytesDone: done);
      _notifyTransfers();
      _log.info('transfer', 'download complete id=$transferId bytes=$done');
    } catch (e, st) {
      _log.error('transfer', 'download aborted id=$transferId: $e', st);
      _transfers.fail(transferId, 'connection lost');
      _notifyTransfers();
      rethrow;
    } finally {
      await raf.close();
    }
  }

  // ── Zip download (streamed) ─────────────────────────────────

  Future<Response> _handleDownloadZip(Request req) async {
    final filesParam = req.requestedUri.queryParameters['files'] ?? '';
    if (filesParam.trim().isEmpty) {
      return _json({'error': 'no files', 'reason': 'invalid_filename'}, status: 400);
    }
    final names = filesParam
        .split(',')
        .map((s) => Uri.decodeComponent(s.trim()))
        .where((s) => s.isNotEmpty)
        .toList();
    if (names.isEmpty) {
      return _json({'error': 'no files', 'reason': 'invalid_filename'}, status: 400);
    }

    final files = <File>[];
    for (final n in names) {
      final resolved = _resolveSafe(n);
      if (resolved == null) {
        return _json(
          {'error': 'invalid path', 'reason': 'invalid_path', 'file': n},
          status: 400,
        );
      }
      final f = File(resolved);
      if (!await f.exists()) {
        return _json(
          {'error': 'not found', 'reason': 'not_found', 'file': n},
          status: 404,
        );
      }
      final st = await f.stat();
      if (st.type == FileSystemEntityType.directory) {
        return _json(
          {'error': 'directories not supported in zip yet', 'reason': 'is_directory', 'file': n},
          status: 400,
        );
      }
      files.add(f);
    }

    final transferId = _uuid.v4();
    final zipName = 'localdrop_${files.length}_files.zip';
    var totalBytes = 0;
    for (final f in files) {
      totalBytes += await f.length();
    }
    _transfers.start(
      id: transferId,
      direction: TransferDirection.zip,
      name: zipName,
      bytesTotal: totalBytes,
    );
    _transfers.markActive(transferId);
    _notifyTransfers();
    _log.info('transfer', 'zip start id=$transferId count=${files.length}');

    final stream = _zipStream(files, transferId, totalBytes);
    return Response.ok(
      stream,
      headers: {
        'Content-Type': 'application/zip',
        'Content-Disposition': _contentDisposition(zipName),
        'X-Transfer-Id': transferId,
        'Cache-Control': 'no-store',
        // Length unknown for true streaming zip — omit Content-Length
      },
    );
  }

  /// Minimal stored (no compress) ZIP stream — no full in-memory buffering of file bodies.
  Stream<List<int>> _zipStream(
    List<File> files,
    String transferId,
    int totalBytes,
  ) async* {
    final encoder = ZipEncoder();
    // archive package's streaming is limited; we build local file headers + data
    // ourselves for stored method to avoid loading whole files.
    final central = BytesBuilder(copy: false);
    var offset = 0;
    var writtenPayload = 0;
    final now = DateTime.now();
    final dosTime = _dosTime(now);
    final dosDate = _dosDate(now);

    try {
      for (final file in files) {
        final name = utf8.encode(p.basename(file.path));
        final size = await file.length();
        final crc = await _crc32File(file);

        // Local file header
        final local = BytesBuilder(copy: false);
        local.add(_u32(0x04034b50));
        local.add(_u16(20)); // version needed
        local.add(_u16(0x0800)); // UTF-8 flag
        local.add(_u16(0)); // stored
        local.add(_u16(dosTime));
        local.add(_u16(dosDate));
        local.add(_u32(crc));
        local.add(_u32(size));
        local.add(_u32(size));
        local.add(_u16(name.length));
        local.add(_u16(0)); // extra len
        local.add(name);
        final localBytes = local.toBytes();
        yield localBytes;

        // File data
        final raf = await file.open();
        try {
          const chunk = 64 * 1024;
          var left = size;
          while (left > 0) {
            final n = left < chunk ? left : chunk;
            final data = await raf.read(n);
            if (data.isEmpty) break;
            left -= data.length;
            writtenPayload += data.length;
            _transfers.progress(transferId, writtenPayload, bytesTotal: totalBytes);
            if (writtenPayload % (256 * 1024) < chunk) _notifyTransfers();
            yield data;
          }
        } finally {
          await raf.close();
        }

        // Central directory entry
        final cen = BytesBuilder(copy: false);
        cen.add(_u32(0x02014b50));
        cen.add(_u16(20));
        cen.add(_u16(20));
        cen.add(_u16(0x0800));
        cen.add(_u16(0));
        cen.add(_u16(dosTime));
        cen.add(_u16(dosDate));
        cen.add(_u32(crc));
        cen.add(_u32(size));
        cen.add(_u32(size));
        cen.add(_u16(name.length));
        cen.add(_u16(0));
        cen.add(_u16(0));
        cen.add(_u16(0));
        cen.add(_u16(0));
        cen.add(_u32(0));
        cen.add(_u32(offset));
        cen.add(name);
        central.add(cen.toBytes());

        offset += localBytes.length + size;
      }

      final centralBytes = central.toBytes();
      yield centralBytes;

      // EOCD
      final eocd = BytesBuilder(copy: false);
      eocd.add(_u32(0x06054b50));
      eocd.add(_u16(0));
      eocd.add(_u16(0));
      eocd.add(_u16(files.length));
      eocd.add(_u16(files.length));
      eocd.add(_u32(centralBytes.length));
      eocd.add(_u32(offset));
      eocd.add(_u16(0));
      yield eocd.toBytes();

      // Silence unused encoder warning path — kept for future deflate option
      // ignore: unnecessary_statements
      encoder;

      _transfers.complete(transferId, bytesDone: writtenPayload);
      _notifyTransfers();
      _log.info('transfer', 'zip complete id=$transferId bytes=$writtenPayload');
    } catch (e, st) {
      _log.error('transfer', 'zip failed id=$transferId: $e', st);
      _transfers.fail(transferId, 'connection lost');
      _notifyTransfers();
      rethrow;
    }
  }

  // ── Upload (streamed multipart) ─────────────────────────────

  Future<Response> _handleUpload(Request req) async {
    final contentType = req.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().contains('multipart/form-data')) {
      return _json(
        {'error': 'expected multipart/form-data', 'reason': 'bad_request'},
        status: 400,
      );
    }

    final boundary = _extractBoundary(contentType);
    if (boundary == null) {
      return _json(
        {'error': 'missing boundary', 'reason': 'bad_request'},
        status: 400,
      );
    }

    final relPath = req.requestedUri.queryParameters['path'] ??
        req.headers['x-upload-path'] ??
        '';
    final destDirPath = _resolveSafe(relPath);
    if (destDirPath == null) {
      return _json({'error': 'invalid path', 'reason': 'invalid_path'}, status: 400);
    }
    final destDir = Directory(destDirPath);
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    final transferId = req.headers['x-transfer-id']?.trim().isNotEmpty == true
        ? req.headers['x-transfer-id']!.trim()
        : _uuid.v4();

    // Content-Length of whole body (includes multipart overhead) — good enough for progress.
    final declared = int.tryParse(req.headers['content-length'] ?? '') ?? 0;

    _transfers.start(
      id: transferId,
      direction: TransferDirection.upload,
      name: '(receiving)',
      bytesTotal: declared,
    );
    // CRITICAL: mark active immediately so clients leave "preparing"
    _transfers.markActive(transferId, bytesTotal: declared > 0 ? declared : 0);
    _notifyTransfers();
    _log.info(
      'transfer',
      'upload start id=$transferId path=$relPath contentLength=$declared',
    );

    final results = <Map<String, dynamic>>[];
    try {
      final transformer = MimeMultipartTransformer(boundary);
      // Track raw body bytes approximately via a counting wrapper
      var bodyBytes = 0;
      final counted = req.read().map((chunk) {
        bodyBytes += chunk.length;
        _transfers.progress(
          transferId,
          bodyBytes,
          bytesTotal: declared > 0 ? declared : bodyBytes,
        );
        if (bodyBytes % (256 * 1024) < chunk.length) _notifyTransfers();
        return chunk;
      });

      final parts = counted.transform(transformer);
      await for (final part in parts) {
        final disposition = part.headers['content-disposition'] ?? '';
        final nameMatch = RegExp(r'name="([^"]*)"').firstMatch(disposition);
        final _ = nameMatch; // consumed below, suppressed linter
        final fileMatch = RegExp(r'filename="([^"]*)"').firstMatch(disposition);
        // RFC 5987 filename*
        final fileStar = RegExp(r"filename\*=(?:UTF-8''|utf-8'')([^;]+)").firstMatch(disposition);

        String? filename;
        if (fileStar != null) {
          filename = Uri.decodeFull(fileStar.group(1)!.trim());
        } else if (fileMatch != null) {
          filename = _decodeFilename(fileMatch.group(1)!);
        }

        if (filename == null || filename.isEmpty) {
          // Non-file field — drain
          await part.drain();
          continue;
        }

        filename = p.basename(filename.replaceAll('\\', '/'));
        if (filename.isEmpty || filename == '.' || filename == '..') {
          await part.drain();
          results.add({
            'name': filename,
            'ok': false,
            'reason': 'invalid_filename',
          });
          continue;
        }

        _transfers.start(
          id: transferId,
          direction: TransferDirection.upload,
          name: filename,
          bytesTotal: declared,
        );
        _transfers.markActive(transferId);
        _transfers.progress(transferId, bodyBytes, bytesTotal: declared > 0 ? declared : null);
        _notifyTransfers();

        final dest = File(p.join(destDir.path, filename));
        // Stream part directly to disk — no full buffering
        final sink = dest.openWrite();
        var fileBytes = 0;
        try {
          await for (final chunk in part) {
            sink.add(chunk);
            fileBytes += chunk.length;
          }
          await sink.flush();
          await sink.close();
          results.add({
            'name': filename,
            'ok': true,
            'size': fileBytes,
            'path': p.relative(dest.path, from: sharedRoot.path).replaceAll('\\', '/'),
          });
          _log.info(
            'transfer',
            'upload file saved id=$transferId file=$filename size=$fileBytes',
          );
        } catch (e, st) {
          await sink.close();
          try {
            if (await dest.exists()) await dest.delete();
          } catch (_) {}
          _log.error('transfer', 'upload write failed file=$filename: $e', st);
          results.add({
            'name': filename,
            'ok': false,
            'reason': 'connection_lost',
            'detail': e.toString(),
          });
        }
      }

      final anyFail = results.any((r) => r['ok'] != true);
      if (results.isEmpty) {
        _transfers.fail(transferId, 'invalid filename');
        _notifyTransfers();
        return _json(
          {
            'error': 'no file parts',
            'reason': 'invalid_filename',
            'transfer_id': transferId,
          },
          status: 400,
        );
      }
      if (anyFail && results.every((r) => r['ok'] != true)) {
        _transfers.fail(transferId, results.first['reason']?.toString() ?? 'upload failed');
        _notifyTransfers();
        return _json(
          {'ok': false, 'files': results, 'transfer_id': transferId, 'reason': 'upload_failed'},
          status: 500,
        );
      }

      _transfers.complete(transferId, bytesDone: bodyBytes);
      _notifyTransfers();
      _log.info('transfer', 'upload complete id=$transferId files=${results.length}');
      return _json({
        'ok': true,
        'files': results,
        'transfer_id': transferId,
      });
    } catch (e, st) {
      _log.error('transfer', 'upload failed id=$transferId: $e', st);
      final reason = e is IOException ? 'connection lost' : 'upload failed';
      _transfers.fail(transferId, reason);
      _notifyTransfers();
      return _json(
        {
          'error': reason,
          'reason': reason.replaceAll(' ', '_'),
          'detail': e.toString(),
          'transfer_id': transferId,
        },
        status: 500,
      );
    }
  }

  // ── Progress (polling — more reliable than SSE on shelf/mobile) ──

  Future<Response> _handleProgressList(Request req) async {
    return _json({'transfers': _transfers.listJson()});
  }

  Future<Response> _handleProgressOne(Request req, String id) async {
    final j = _transfers.toJson(id);
    if (j == null) {
      return _json({'error': 'not found', 'reason': 'not_found'}, status: 404);
    }
    return _json(j);
  }

  // ── Helpers ─────────────────────────────────────────────────

  void _notifyTransfers() {
    onTransfersChanged?.call();
  }

  /// Resolve [rel] under [sharedRoot]; reject traversal.
  String? _resolveSafe(String rel) {
    final cleaned = rel.replaceAll('\\', '/').trim();
    if (cleaned.contains('\x00')) return null;
    final root = p.normalize(sharedRoot.absolute.path);
    final target = cleaned.isEmpty || cleaned == '/'
        ? root
        : p.normalize(p.join(root, cleaned));
    // Ensure target is root or under root
    if (target != root && !p.isWithin(root, target)) {
      _log.warn('security', 'path traversal blocked rel=$rel');
      return null;
    }
    return target;
  }

  String _contentDisposition(String filename) {
    // ASCII fallback
    final ascii = filename.replaceAll(RegExp(r'[^\x20-\x7E]'), '_').replaceAll('"', r'\"');
    final encoded = Uri.encodeComponent(filename);
    return 'attachment; filename="$ascii"; filename*=UTF-8\'\'$encoded';
  }

  String _decodeFilename(String raw) {
    // Browsers may send mojibake or percent-encoding
    try {
      if (raw.contains('%')) return Uri.decodeComponent(raw);
    } catch (_) {}
    return raw;
  }

  String? _extractBoundary(String contentType) {
    final m = RegExp(r'boundary=(?:"([^"]+)"|([^;]+))', caseSensitive: false)
        .firstMatch(contentType);
    if (m == null) return null;
    return (m.group(1) ?? m.group(2))?.trim();
  }

  (int, int)? _parseRange(String header, int size) {
    // bytes=start-end | bytes=start- | bytes=-suffix
    final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(header);
    if (m == null) return null;
    final startS = m.group(1)!;
    final endS = m.group(2)!;
    int start;
    int end;
    if (startS.isEmpty && endS.isEmpty) return null;
    if (startS.isEmpty) {
      final suffix = int.parse(endS);
      start = max(0, size - suffix);
      end = size - 1;
    } else {
      start = int.parse(startS);
      end = endS.isEmpty ? size - 1 : int.parse(endS);
    }
    if (start < 0 || end < start || start >= size) return null;
    if (end >= size) end = size - 1;
    return (start, end);
  }

  Future<int> _crc32File(File file) async {
    var crc = 0;
    final raf = await file.open();
    try {
      const chunk = 64 * 1024;
      while (true) {
        final data = await raf.read(chunk);
        if (data.isEmpty) break;
        crc = getCrc32(data, crc);
      }
    } finally {
      await raf.close();
    }
    return crc;
  }

  int _dosTime(DateTime dt) =>
      (dt.second ~/ 2) | (dt.minute << 5) | (dt.hour << 11);
  int _dosDate(DateTime dt) =>
      dt.day | (dt.month << 5) | ((dt.year - 1980) << 9);

  List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];
  List<int> _u32(int v) => [
        v & 0xff,
        (v >> 8) & 0xff,
        (v >> 16) & 0xff,
        (v >> 24) & 0xff,
      ];

  Response _json(Object body, {int status = 200}) {
    return Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    );
  }
}
