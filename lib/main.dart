import 'package:flutter/material.dart';

import 'ui/permission_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]).then((_) {
    runApp(const LocalDropApp());
  });
}

class LocalDropApp extends StatelessWidget {
  const LocalDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LocalDrop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const PermissionGate(),
    );
  }
}
