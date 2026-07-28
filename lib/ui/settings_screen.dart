1|import 'package:flutter/material.dart';
2|
3|import '../services/server_controller.dart';
4|5|import '../services/app_logger.dart';
6|
7|class SettingsScreen extends StatefulWidget {
8|  const SettingsScreen({super.key});
9|
10|  @override
11|  State<SettingsScreen> createState() => _SettingsScreenState();
12|}
13|
14|class _SettingsScreenState extends State<SettingsScreen> {
15|  final _ctrl = ServerController();
16|  final _folderCtrl = TextEditingController();
17|  final _portCtrl = TextEditingController();
18|  late bool _regenPin;
19|
20|  @override
21|  void initState() {
22|    super.initState();
23|    _ctrl.init().then((_) {
24|      _folderCtrl.text = _ctrl.sharedPath;
25|      _portCtrl.text = _ctrl.portOverride.toString();
26|      _regenPin = _ctrl.regenPinOnStart;
27|      if (mounted) setState(() {});
28|    });
29|  }
30|
31|  @override
32|  Widget build(BuildContext context) {
33|    return Scaffold(
34|      appBar: AppBar(title: const Text('Settings')),
35|      body: ListView(
36|        padding: const EdgeInsets.all(12),
37|        children: [
38|          _section('Shared Folder'),
39|          TextField(
40|            controller: _folderCtrl,
41|            readOnly: true,
42|            decoration: InputDecoration(
43|              suffixIcon: IconButton(
44|                icon: const Icon(Icons.folder_open),
45|                tooltip: 'Change folder',
46|                onPressed: () async {
47|                  // SAF picker — placeholder, calls path_provider for now
48|                  ScaffoldMessenger.of(context).showSnackBar(
49|                    const SnackBar(content: Text('SAF picker: use this in the final implementation')),
50|                  );
51|                },
52|              ),
53|              hintText: 'Shared folder path',
54|            ),
55|          ),
56|          const SizedBox(height: 12),
57|          _section('Server'),
58|          TextField(
59|            controller: _portCtrl,
60|            keyboardType: TextInputType.number,
61|            decoration: const InputDecoration(labelText: 'Port'),
62|          ),
63|          const SizedBox(height: 12),
64|          _section('PIN'),
65|          SwitchListTile(
66|            title: const Text('Regenerate PIN on every server start'),
67|            value: _regenPin,
68|            onChanged: (v) {
69|              setState(() => _regenPin = v);
70|              _ctrl.setRegenPin(v);
71|            },
72|          ),
73|          const SizedBox(height: 8),
74|          _section('Debug'),
75|          ListTile(
76|            leading: const Icon(Icons.delete_sweep),
77|            title: const Text('Clear logs'),
78|            onTap: () async {
79|              await AppLogger.instance.clear();
80|              if (mounted) {
81|                ScaffoldMessenger.of(context).showSnackBar(
82|                  const SnackBar(content: Text('Logs cleared')),
83|                );
84|              }
85|            },
86|          ),
87|          ListTile(
88|            leading: const Icon(Icons.copy_all),
89|            title: const Text('Copy current PIN'),
90|            onTap: () {
91|              // handled in server screen
92|              Navigator.pop(context);
93|            },
94|          ),
95|        ],
96|      ),
97|      floatingActionButton: FloatingActionButton.extended(
98|        onPressed: () {
99|          final port = int.tryParse(_portCtrl.text);
100|          if (port != null && port > 0 && port < 65536) {
101|            _ctrl.setPort(port);
102|          }
103|          _ctrl.setSharedPath(_folderCtrl.text.trim());
104|          Navigator.pop(context);
105|        },
106|        icon: const Icon(Icons.save),
107|        label: const Text('Save'),
108|      ),
109|    );
110|  }
111|
112|  Widget _section(String title) {
113|    return Padding(
114|      padding: const EdgeInsets.only(top: 8, bottom: 4),
115|      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
116|    );
117|  }
118|}
119|