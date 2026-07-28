import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single-session PIN auth. One active browser session is enough for Phase 1.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _kPort = 'port_override';
  static const _kShared = 'shared_folder';
  static const _kRegen = 'pin_regen_on_start';
  static const _kPin = 'last_pin';

  String _pin = '000000';
  String? _token;
  DateTime? _tokenIssuedAt;
  // Long-lived: don't expire mid-transfer. Manual regen / server stop clears it.
  static const Duration tokenTtl = Duration(hours: 12);

  int portOverride = 8080;
  String? sharedFolderPath;
  bool regeneratePinOnStart = true;

  String get pin => _pin;
  String? get token => _token;
  bool get hasSession =>
      _token != null &&
      _tokenIssuedAt != null &&
      DateTime.now().difference(_tokenIssuedAt!) < tokenTtl;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    portOverride = prefs.getInt(_kPort) ?? 8080;
    sharedFolderPath = prefs.getString(_kShared);
    regeneratePinOnStart = prefs.getBool(_kRegen) ?? true;
    final saved = prefs.getString(_kPin);
    if (saved != null && saved.length == 6) _pin = saved;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPort, portOverride);
    if (sharedFolderPath != null) {
      await prefs.setString(_kShared, sharedFolderPath!);
    } else {
      await prefs.remove(_kShared);
    }
    await prefs.setBool(_kRegen, regeneratePinOnStart);
    await prefs.setString(_kPin, _pin);
  }

  void generatePin({bool force = false}) {
    if (!force && !regeneratePinOnStart && _pin != '000000') return;
    final r = Random.secure();
    _pin = List.generate(6, (_) => r.nextInt(10)).join();
    // Invalidate existing session when PIN changes
    _token = null;
    _tokenIssuedAt = null;
  }

  /// Returns session token on success, null on failure.
  String? tryAuth(String pin) {
    if (pin.trim() != _pin) return null;
    final raw =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    _token = sha256.convert(utf8.encode(raw)).toString();
    _tokenIssuedAt = DateTime.now();
    return _token;
  }

  bool validateToken(String? token) {
    if (token == null || token.isEmpty) return false;
    if (!hasSession) return false;
    return token == _token;
  }

  void clearSession() {
    _token = null;
    _tokenIssuedAt = null;
  }
}
