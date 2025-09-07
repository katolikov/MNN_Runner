import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'json_viewer.dart';

enum MnnBackend { auto, cpu, opencl, vulkan, metal, openGL }

enum MemoryMode { low, balanced, high }

enum PrecisionMode { low, normal, high }

enum PowerMode { low, normal, high }

enum InputFill { zero, one, uniform, normal }

class MnnRunConfig {
  final String modelPath;
  final List<int> inputShape; // e.g., [1,3,224,224]
  final Map<String, List<int>>? inputShapes; // optional per-input overrides
  final MnnBackend backend;
  final MnnBackend backupType;
  final MemoryMode memoryMode;
  final PrecisionMode precisionMode;
  final PowerMode powerMode;
  final int threads;
  final InputFill inputFill;
  final bool profile;
  final bool cache;

  const MnnRunConfig({
    required this.modelPath,
    required this.inputShape,
    this.inputShapes,
    required this.backend,
    this.backupType = MnnBackend.cpu,
    required this.memoryMode,
    required this.precisionMode,
    required this.powerMode,
    this.threads = 4,
    this.inputFill = InputFill.zero,
    this.profile = false,
    this.cache = false,
  });

  Map<String, dynamic> toJson() => {
    'modelPath': modelPath,
    'inputShape': inputShape,
    if (inputShapes != null) 'inputShapes': inputShapes,
    'backend': backend.name.toUpperCase(),
    'backupType': backupType.name.toUpperCase(),
    'memoryMode': memoryMode.name.toUpperCase(),
    'precisionMode': precisionMode.name.toUpperCase(),
    'powerMode': powerMode.name.toUpperCase(),
    'inputFill': inputFill.name.toUpperCase(),
    'threads': threads,
    'profile': profile,
    'cache': cache,
  };
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final ValueNotifier<ThemeMode> _mode = ValueNotifier(ThemeMode.light);

  ThemeData _lightTheme() {
    final baseScheme = const ColorScheme.light(
      primary: Colors.black,
      onPrimary: Colors.white,
      secondary: Colors.black,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: Colors.black,
    );
    return ThemeData(
      colorScheme: baseScheme,
      scaffoldBackgroundColor: baseScheme.surface,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0.6,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFF5F5F5),
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Colors.white),
        ),
      ),
    );
  }

  ThemeData _darkTheme() {
    final base = ThemeData.dark();
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF121212),
        foregroundColor: Colors.white,
        elevation: 0.6,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF1E1E1E),
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _mode,
      builder: (context, mode, _) => MaterialApp(
        title: 'MNN Runner',
        themeMode: mode,
        theme: _lightTheme(),
        darkTheme: _darkTheme(),
        home: _RunnerHome(themeMode: _mode),
      ),
    );
  }
}

class _RunnerHome extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeMode;
  const _RunnerHome({required this.themeMode});

  @override
  State<_RunnerHome> createState() => _RunnerHomeState();
}

class _RunnerHomeState extends State<_RunnerHome> {
  static const _channel = MethodChannel('mnn_runner');
  late final int _appStartMs;
  final _modelCtrl = TextEditingController();
  final _shapeCtrl = TextEditingController(text: '1,3,224,224');
  MnnBackend _backend = MnnBackend.auto;
  MnnBackend _backup = MnnBackend.cpu;
  MemoryMode _memory = MemoryMode.balanced;
  PrecisionMode _precision = PrecisionMode.normal;
  PowerMode _power = PowerMode.normal;
  int _threads = 4;
  String _status = 'Idle';
  bool _running = false;
  InputFill _fill = InputFill.zero;
  bool _profile = false;
  bool _cache = false;
  List<_ModelInputInfo>? _inputs; // Populated after detection
  List<_EditableInput>? _editableInputs; // Controllers for per-input shapes
  _ProfileResult? _lastProfile;
  
  // Persistent recent model paths (tap to reuse)
  static const int _recentLimit = 10;
  List<String> _recentModels = <String>[];

  @override
  void initState() {
    super.initState();
    _appStartMs = DateTime.now().millisecondsSinceEpoch;
    // Auto-probe backend availability on Android to populate badges early.
    if (Platform.isAndroid) {
      // Prefer Vulkan by default on Android to avoid OpenCL linker warnings on modern devices.
      _backend = MnnBackend.vulkan;
      WidgetsBinding.instance.addPostFrameCallback((_) => _probeBackends());
    }
    // Load persisted recent models list
    _loadRecentModels();
  }

  _Probe? _vkProbe;
  _Probe? _clProbe;

  @override
  void dispose() {
    _modelCtrl.dispose();
    _shapeCtrl.dispose();
    _disposeEditableInputs();
    super.dispose();
  }

  Future<void> _pickModel() async {
    FilePickerResult? result;
    try {
      // Some Android pickers don't support custom filters for unknown extensions.
      result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Select MNN model',
        allowMultiple: false,
        type: Platform.isAndroid ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isAndroid ? null : const ['mnn'],
        withData: true,
      );
    } on PlatformException catch (e) {
      // Fallback to a generic picker when custom filter isn't supported.
      debugPrint('[FilePicker] Falling back to any: $e');
      result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Select MNN model',
        allowMultiple: false,
        type: FileType.any,
        withData: true,
      );
    }

    if (result == null || result.files.isEmpty) return;

    final f = result.files.single;
    final nameLc = (f.name).toLowerCase();
    if (!nameLc.endsWith('.mnn')) {
      if (!mounted) return;
      setState(() => _status = 'Please select a .mnn file');
      return;
    }

    String? p = f.path;
    if (p == null && f.bytes != null) {
      final cacheDir = await _ensureCacheDir();
      final file = File('${cacheDir.path}/${f.name}');
      await file.writeAsBytes(f.bytes!);
      p = file.path;
    }
    if (!mounted) return;
    if (p != null) {
      setState(() {
        _modelCtrl.text = p!;
        _inputs = null; // reset detections on new model
        _disposeEditableInputs();
        _editableInputs = null;
      });
    } else {
      setState(() => _status = 'Unable to access selected file');
    }
  }

  Future<void> _detectShape() async {
    final modelPath = _modelCtrl.text.trim();
    if (modelPath.isEmpty) return;
    if (!Platform.isAndroid) {
      setState(() => _status = 'Detect shape is available on Android only now');
      return;
    }
    try {
      final res = await _channel.invokeMethod<String>(
        'getModelInfo',
        modelPath,
      );
      if (res == null) {
        setState(() => _status = 'Model info not available');
        return;
      }
      final Map<String, dynamic> obj = jsonDecode(res);
      if (obj['error'] != null) {
        setState(() => _status = 'Info error: ${obj['error']}');
        return;
      }
      final list = (obj['inputs'] as List<dynamic>? ?? const []);
      final parsed = list
          .map((e) => _ModelInputInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      if (parsed.isEmpty) {
        setState(() {
          _inputs = null;
          _status = 'No inputs found in model';
        });
        return;
      }
      final first = parsed.first.dims;
      final same = parsed.every((i) => _listEq(i.dims, first));
      setState(() {
        _inputs = parsed;
        if (same && first.isNotEmpty) {
          _shapeCtrl.text = first.join(',');
          _status =
              'Detected shape: ${first.join('x')} (${parsed.length} input${parsed.length > 1 ? 's' : ''})';
        } else {
          _status = 'Multiple inputs with different shapes; set shape manually';
        }
        _disposeEditableInputs();
        _editableInputs = parsed
            .map((i) => _EditableInput(i.name, i.dtype, i.dims))
            .toList();
      });
    } catch (e) {
      setState(() => _status = 'Detect error: $e');
    }
  }

  bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, List<int>>? _collectPerInputShapes() {
    final edits = _editableInputs;
    if (edits == null || edits.isEmpty) return null;
    final map = <String, List<int>>{};
    for (final e in edits) {
      final dims = _parseShape(e.ctrl.text);
      if (dims == null || dims.isEmpty || dims.any((v) => v <= 0)) {
        setState(() => _status = 'Invalid shape for input "${e.name}"');
        return null;
      }
      map[e.name] = dims;
    }
    return map;
  }

  void _disposeEditableInputs() {
    final list = _editableInputs;
    if (list == null) return;
    for (final e in list) {
      e.dispose();
    }
  }

  Future<Directory> _ensureCacheDir() async => await getTemporaryDirectory();

  Future<File?> _historyFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/recent_models.json');
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadRecentModels() async {
    try {
      final f = await _historyFile();
      if (f == null || !(await f.exists())) return;
      final text = await f.readAsString();
      final obj = jsonDecode(text);
      final list = (obj is List
              ? obj
              : (obj is Map && obj['paths'] is List ? obj['paths'] : const []))
          .cast<dynamic>()
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      setState(() {
        _recentModels = list.take(_recentLimit).toList();
      });
    } catch (_) {
      // ignore
    }
  }

  Future<void> _saveRecentModels() async {
    try {
      final f = await _historyFile();
      if (f == null) return;
      final list = _recentModels.take(_recentLimit).toList();
      final text = jsonEncode({'paths': list});
      await f.writeAsString(text);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _addRecentModel(String path) async {
    final p = path.trim();
    if (p.isEmpty) return;
    setState(() {
      _recentModels.removeWhere((e) => e == p);
      _recentModels.insert(0, p);
      if (_recentModels.length > _recentLimit) {
        _recentModels = _recentModels.take(_recentLimit).toList();
      }
    });
    await _saveRecentModels();
  }

  List<int>? _parseShape(String s) {
    try {
      final parts = s
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
      final vals = parts.map(int.parse).toList();
      if (vals.any((v) => v <= 0)) return null;
      return vals;
    } catch (_) {
      return null;
    }
  }

  Future<void> _run() async {
    final shape = _parseShape(_shapeCtrl.text);
    final modelPath = _modelCtrl.text.trim();
    if (modelPath.isEmpty || shape == null) {
      setState(() => _status = 'Set model and valid shape');
      return;
    }
    final perInput = _collectPerInputShapes();
    if (_editableInputs != null && perInput == null) {
      // Invalid per-input shape present; status already set.
      return;
    }
    _lastProfile = null;
    final cfg = MnnRunConfig(
      modelPath: modelPath,
      inputShape: shape,
      inputShapes: perInput,
      backend: _backend,
      backupType: _backup,
      memoryMode: _memory,
      precisionMode: _precision,
      powerMode: _power,
      inputFill: _fill,
      threads: _threads,
      profile: _profile,
      cache: _cache,
    );
    setState(() {
      _running = true;
      _status = 'Running...';
    });
    try {
      final runStartMs = DateTime.now().millisecondsSinceEpoch;
      final res = await _channel.invokeMethod<String>(
        'runModel',
        jsonEncode(cfg.toJson()),
      );
      String text = res ?? 'Done';
      _ProfileResult? profile;
      if (_profile && res != null && res.trim().startsWith('{')) {
        try {
          final Map<String, dynamic> obj = jsonDecode(res);
          final ops = (obj['ops'] as List<dynamic>? ?? const [])
              .map((e) => _ProfileOp.fromJson(e as Map<String, dynamic>))
              .toList();
          final metrics =
              (obj['metrics'] as Map?)?.cast<String, dynamic>() ?? const {};
          profile = _ProfileResult(
            ops: ops,
            metrics: metrics.map((k, v) => MapEntry(k, (v as num).toDouble())),
            runStartFromAppMs: (runStartMs - _appStartMs).toDouble(),
          );
        } catch (_) {
          // ignore
        }
      }
      setState(() {
        _status = text;
        _lastProfile = profile;
      });
      // Remember successfully attempted model path for quick reuse later
      await _addRecentModel(modelPath);
    } on PlatformException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  dynamic _tryParseJson(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (!(t.startsWith('{') || t.startsWith('['))) return null;
    try {
      return jsonDecode(t);
    } catch (_) {
      return null;
    }
  }

  Future<void> _probeBackends() async {
    if (!Platform.isAndroid) {
      setState(() => _status = 'Probe is available on Android only for now');
      return;
    }
    try {
      final res = await _channel.invokeMethod<String>('probeBackends');
      if (res == null) {
        setState(() => _status = 'Probe returned no result');
        return;
      }
      final Map<String, dynamic> obj = jsonDecode(res);
      final vk = (obj['vulkan'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cl = (obj['opencl'] as Map?)?.cast<String, dynamic>() ?? const {};
      setState(() {
        _vkProbe = _Probe.fromJson(vk);
        _clProbe = _Probe.fromJson(cl);
      });
      String fmtBool(dynamic v) => (v == true) ? 'YES' : 'NO';
      final cpuOk = (obj['cpu'] as Map?)?['available'] ?? true;
      final summary = StringBuffer()
        ..writeln('Backend probe:')
        ..writeln('- CPU: ${fmtBool(cpuOk)}')
        ..writeln(
          '- VULKAN: avail=${fmtBool(vk['available'])}, lib=${fmtBool(vk['lib'])}, plugin=${fmtBool(vk['plugin'])}',
        )
        ..writeln(
          '- OPENCL: avail=${fmtBool(cl['available'])}, lib=${fmtBool(cl['lib'])}, plugin=${fmtBool(cl['plugin'])}, source=${cl['source'] ?? 'null'}',
        );
      setState(() => _status = summary.toString());
    } on PlatformException catch (e) {
      setState(() => _status = 'Probe error: ${e.message}');
    } catch (e) {
      setState(() => _status = 'Probe error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MNN Runner'),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: widget.themeMode,
            builder: (context, mode, _) {
              final isDark = mode == ThemeMode.dark;
              return IconButton(
                tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
                onPressed: _running
                    ? null
                    : () {
                        widget.themeMode.value = isDark ? ThemeMode.light : ThemeMode.dark;
                      },
                icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Section(title: 'Model'),
              TextField(
                controller: _modelCtrl,
                enabled: !_running,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Model path (.mnn)',
                  hintText: '/data/local/tmp/.../model.mnn or picked file',
                ),
              ),
              if (_recentModels.isNotEmpty) ...[
                const SizedBox(height: 8),
                _MonochromeCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Recent models',
                        style: TextStyle(
                          color: Colors.grey.shade800,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final p in _recentModels)
                            OutlinedButton(
                              onPressed: _running
                                  ? null
                                  : () {
                                      setState(() {
                                        _modelCtrl.text = p;
                                        _inputs = null;
                                        _disposeEditableInputs();
                                        _editableInputs = null;
                                      });
                                    },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black,
                                side: const BorderSide(color: Color(0xFFE0E0E0)),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 280),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.history, size: 14),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        p,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ElevatedButton(
                    onPressed: _running ? null : _pickModel,
                    child: const Text('Browse files'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _running || _modelCtrl.text.trim().isEmpty
                        ? null
                        : _detectShape,
                    child: const Text('Detect shape'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Section(title: 'Input'),
              TextField(
                controller: _shapeCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Input shape (comma separated)',
                  hintText: 'e.g. 1,3,224,224',
                ),
              ),
              const SizedBox(height: 12),
              _Dropdown<InputFill>(
                label: 'Input fill',
                value: _fill,
                items: InputFill.values
                    .map(
                      (m) => DropdownMenuItem(
                        value: m,
                        child: Text(m.name.toUpperCase()),
                      ),
                    )
                    .toList(),
                onChanged: _running
                    ? null
                    : (v) => setState(() => _fill = v ?? _fill),
              ),
              if (_inputs != null) ...[
                const SizedBox(height: 12),
                _MonochromeCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Per-input shapes (edit if needed):'),
                      const SizedBox(height: 8),
                      for (final e
                          in _editableInputs ?? const <_EditableInput>[]) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                            controller: e.ctrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: '${e.name} (${e.dtype})',
                              hintText: 'e.g. 1,3,224,224',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _Section(title: 'Backend'),
              _MonochromeCard(
                child: Column(
                  children: [
                    _Dropdown<MnnBackend>(
                      label: 'Compute',
                      value: _backend,
                      items: MnnBackend.values
                          .map(
                            (b) => DropdownMenuItem(
                              value: b,
                              child: Text(b.name.toUpperCase()),
                            ),
                          )
                          .toList(),
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _backend = v ?? _backend),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          const _BackendBadge(label: 'CPU', available: true),
                          _BackendBadge(
                            label: 'VULKAN',
                            available: _vkProbe?.available,
                          ),
                          _BackendBadge(
                            label: 'OPENCL',
                            available: _clProbe?.available,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _Dropdown<MnnBackend>(
                      label: 'Backup compute',
                      value: _backup,
                      items: MnnBackend.values
                          .map(
                            (b) => DropdownMenuItem(
                              value: b,
                              child: Text(b.name.toUpperCase()),
                            ),
                          )
                          .toList(),
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _backup = v ?? _backup),
                    ),
                    const SizedBox(height: 12),
                    _Dropdown<MemoryMode>(
                      label: 'Memory profile',
                      value: _memory,
                      items: MemoryMode.values
                          .map(
                            (m) => DropdownMenuItem(
                              value: m,
                              child: Text(m.name.toUpperCase()),
                            ),
                          )
                          .toList(),
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _memory = v ?? _memory),
                    ),
                    const SizedBox(height: 12),
                    _Dropdown<PrecisionMode>(
                      label: 'Precision',
                      value: _precision,
                      items: PrecisionMode.values
                          .map(
                            (p) => DropdownMenuItem(
                              value: p,
                              child: Text(p.name.toUpperCase()),
                            ),
                          )
                          .toList(),
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _precision = v ?? _precision),
                    ),
                    const SizedBox(height: 12),
                    _Dropdown<PowerMode>(
                      label: 'Power',
                      value: _power,
                      items: PowerMode.values
                          .map(
                            (p) => DropdownMenuItem(
                              value: p,
                              child: Text(p.name.toUpperCase()),
                            ),
                          )
                          .toList(),
                      onChanged: _running
                          ? null
                          : (v) => setState(() => _power = v ?? _power),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: _threads.toDouble(),
                            min: 1,
                            max: 8,
                            divisions: 7,
                            label: '$_threads threads',
                            onChanged: _running
                                ? null
                                : (v) => setState(() => _threads = v.round()),
                          ),
                        ),
                        Text('$_threads'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ElevatedButton.icon(
                        onPressed: _running ? null : _probeBackends,
                        icon: const Icon(Icons.manage_search),
                        label: const Text('Probe backends'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Checkbox(
                          value: _profile,
                          onChanged: _running
                              ? null
                              : (v) => setState(() => _profile = v ?? _profile),
                        ),
                        const Text('Profile performance'),
                      ],
                    ),
                    Row(
                      children: [
                        Checkbox(
                          value: _cache,
                          onChanged: _running
                              ? null
                              : (v) => setState(() => _cache = v ?? _cache),
                        ),
                        const Text('Save GPU cache (Vulkan/OpenCL)'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _running ? null : _run,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_running)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.play_arrow),
                    const SizedBox(width: 8),
                    Text(_running ? 'Running...' : 'Run model'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Inline pretty report when status is a profile JSON; otherwise show raw status text
              Builder(builder: (context) {
                final data = _tryParseJson(_status);
                final isProfile = (() {
                  try {
                    return data != null && ProfileReportData.tryParse(data) != null;
                  } catch (_) {
                    return false;
                  }
                })();
                if (isProfile) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Section(title: 'Run Report'),
                      ProfileReport(jsonData: data),
                    ],
                  );
                }
                return _MonochromeCard(
                  child: Text(
                    _status,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                );
              }),
              if (_tryParseJson(_status) != null &&
                  (() { final d = _tryParseJson(_status); return !(d != null && ProfileReportData.tryParse(d) != null); })()) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ElevatedButton.icon(
                    onPressed: _running
                        ? null
                        : () {
                            final data = _tryParseJson(_status);
                            if (data == null) return;
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => JsonViewerScreen(
                                  jsonData: data,
                                  title: 'Run Report',
                                ),
                              ),
                            );
                          },
                    icon: const Icon(Icons.insights),
                    label: const Text('View Report'),
                  ),
                ),
              ],
              if (_lastProfile != null &&
                  (() { final d = _tryParseJson(_status); return !(d != null && ProfileReportData.tryParse(d) != null); })()) ...[
                const SizedBox(height: 12),
                _Section(title: 'Timeline'),
                _TimelineCard(result: _lastProfile!),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ElevatedButton.icon(
                    onPressed: _running
                        ? null
                        : () {
                            final r = _lastProfile!;
                            final data = ProfileReportData(
                              backend: 'UNKNOWN',
                              backup: 'UNKNOWN',
                              threads: 0,
                              metrics: r.metrics,
                              outputs: const [],
                              ops: r.ops
                                  .map((o) => ProfileOpData(
                                        index: o.index,
                                        type: o.type,
                                        name: o.name,
                                        backend: o.backend,
                                        startMs: o.startMs,
                                        endMs: o.endMs,
                                        durationMs: o.durationMs,
                                      ))
                                  .toList(),
                            );
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => TimelineFullscreen(data: data),
                              ),
                            );
                          },
                    icon: const Icon(Icons.fullscreen),
                    label: const Text('Open Fullscreen Timeline'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  const _Section({required this.title});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    );
  }
}

class _MonochromeCard extends StatelessWidget {
  final Widget child;
  const _MonochromeCard({required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6E6E6)),
      ),
      padding: const EdgeInsets.all(12),
      child: child,
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(label, style: TextStyle(color: Colors.grey.shade700)),
        ),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE6E6E6)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: items,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _ModelInputInfo {
  final String name;
  final List<int> dims;
  final String dtype;
  const _ModelInputInfo({
    required this.name,
    required this.dims,
    required this.dtype,
  });
  factory _ModelInputInfo.fromJson(Map<String, dynamic> j) => _ModelInputInfo(
    name: j['name'] as String? ?? 'input',
    dims: (j['dims'] as List<dynamic>? ?? const [])
        .map((e) => (e as num).toInt())
        .toList(),
    dtype: j['dtype'] as String? ?? 'unknown',
  );
}

class _EditableInput {
  final String name;
  final String dtype;
  final TextEditingController ctrl;
  _EditableInput(this.name, this.dtype, List<int> dims)
    : ctrl = TextEditingController(text: dims.join(','));
  void dispose() => ctrl.dispose();
}

class _ProfileOp {
  final int index;
  final String type;
  final String name;
  final String backend;
  final double startMs;
  final double endMs;
  final double durationMs;
  _ProfileOp({
    required this.index,
    required this.type,
    required this.name,
    required this.backend,
    required this.startMs,
    required this.endMs,
    required this.durationMs,
  });
  factory _ProfileOp.fromJson(Map<String, dynamic> j) => _ProfileOp(
    index: (j['index'] as num?)?.toInt() ?? 0,
    type: j['type'] as String? ?? 'unknown',
    name: j['name'] as String? ?? 'op',
    backend: j['backend'] as String? ?? 'CPU',
    startMs: (j['start_ms'] as num?)?.toDouble() ?? 0.0,
    endMs: (j['end_ms'] as num?)?.toDouble() ?? 0.0,
    durationMs: (j['duration_ms'] as num?)?.toDouble() ?? 0.0,
  );
}

class _ProfileResult {
  final List<_ProfileOp> ops;
  final Map<String, double> metrics;
  final double runStartFromAppMs; // offset from app start
  _ProfileResult({
    required this.ops,
    required this.metrics,
    required this.runStartFromAppMs,
  });
}

class _TimelineCard extends StatelessWidget {
  final _ProfileResult result;
  const _TimelineCard({required this.result});

  Color _colorFor(String backend) {
    switch (backend.toUpperCase()) {
      case 'VULKAN':
        return Colors.deepPurple;
      case 'OPENCL':
        return Colors.teal;
      case 'OPENGL':
        return Colors.orange;
      default:
        return Colors.blueGrey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ops = result.ops;
    if (ops.isEmpty) {
      return const _MonochromeCard(child: Text('No op data'));
    }
    // Compute app-relative start/end for each op and pack them into lanes so that
    // non-overlapping ops share a row, and overlapping ones start a new row.
    final startFromApp = ops.map((o) => result.runStartFromAppMs + o.startMs).toList();
    final endFromApp = ops.map((o) => result.runStartFromAppMs + o.endMs).toList();
    final maxMs = endFromApp.reduce((a, b) => a > b ? a : b);
    // Indices sorted by start time
    final indices = List<int>.generate(ops.length, (i) => i)
      ..sort((a, b) => startFromApp[a].compareTo(startFromApp[b]));
    // Greedy packing into rows
    const eps = 1e-6;
    final List<List<int>> rowsIdx = [];
    final List<double> rowEnds = [];
    for (final i in indices) {
      final s = startFromApp[i];
      bool placed = false;
      for (var r = 0; r < rowEnds.length; r++) {
        if (s >= rowEnds[r] - eps) {
          rowsIdx[r].add(i);
          rowEnds[r] = endFromApp[i];
          placed = true;
          break;
        }
      }
      if (!placed) {
        rowsIdx.add([i]);
        rowEnds.add(endFromApp[i]);
      }
    }
    final scale = 0.4; // pixels per ms
    final width = (maxMs * scale).clamp(300.0, 4000.0);

    List<Widget> rows = [];
    // Axis at top (0 .. maxMs)
    rows.add(
      SizedBox(
        height: 30,
        width: width,
        child: CustomPaint(
          painter: _AxisPainter(maxMs: maxMs, scale: scale),
        ),
      ),
    );
    rows.add(const SizedBox(height: 6));

    // Render each packed row
    for (final row in rowsIdx) {
      rows.add(
        SizedBox(
          height: 28,
          width: width,
          child: Stack(
            children: [
              for (final i in row)
                Positioned(
                  left: startFromApp[i] * scale,
                  width: (endFromApp[i] - startFromApp[i]) * scale,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: () {
                      final op = ops[i];
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(op.name),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Type: ${op.type}'),
                              Text('Backend: ${op.backend}'),
                              Text('Start: ${(result.runStartFromAppMs + op.startMs).toStringAsFixed(3)} ms from app start'),
                              Text('End: ${(result.runStartFromAppMs + op.endMs).toStringAsFixed(3)} ms from app start'),
                              Text('Duration: ${op.durationMs.toStringAsFixed(3)} ms'),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: _colorFor(ops[i].backend).withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Tooltip(
                        message: '${ops[i].index}. ${ops[i].name} (${ops[i].type})\n${ops[i].backend} • ${ops[i].durationMs.toStringAsFixed(2)} ms',
                        child: Text(
                          '${ops[i].name} (${ops[i].type})',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      rows.add(const SizedBox(height: 6));
    }

    return _MonochromeCard(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: width),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          ),
        ),
      ),
    );
  }
}

class _AxisPainter extends CustomPainter {
  final double maxMs;
  final double scale;
  _AxisPainter({required this.maxMs, required this.scale});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;
    // Base line
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      paint,
    );
    // Ticks every 500 ms
    const tick = 500.0;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (double ms = 0; ms <= maxMs; ms += tick) {
      final x = ms * scale;
      canvas.drawLine(
        Offset(x, size.height - 6),
        Offset(x, size.height),
        paint,
      );
      final tp = TextSpan(
        text: '+${ms.toInt()}ms',
        style: const TextStyle(fontSize: 10, color: Colors.black87),
      );
      textPainter.text = tp;
      textPainter.layout();
      textPainter.paint(canvas, Offset(x + 2, 2));
    }
  }

  @override
  bool shouldRepaint(covariant _AxisPainter oldDelegate) =>
      oldDelegate.maxMs != maxMs || oldDelegate.scale != scale;
}

class _Probe {
  final bool available;
  final bool lib;
  final bool plugin;
  final String? source;
  const _Probe({
    required this.available,
    required this.lib,
    required this.plugin,
    this.source,
  });
  factory _Probe.fromJson(Map<String, dynamic> j) => _Probe(
    available: (j['available'] as bool?) ?? false,
    lib: (j['lib'] as bool?) ?? false,
    plugin: (j['plugin'] as bool?) ?? false,
    source: j['source'] as String?,
  );
}

class _BackendBadge extends StatelessWidget {
  final String label;
  final bool? available; // null = unknown
  const _BackendBadge({required this.label, required this.available});
  @override
  Widget build(BuildContext context) {
    final ok = available == true;
    final color = ok ? Colors.green : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color.shade800,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
