import 'dart:convert';
import 'package:flutter/material.dart';

class JsonViewerScreen extends StatefulWidget {
  final dynamic jsonData; // Map/List already parsed
  final String? title;
  const JsonViewerScreen({super.key, required this.jsonData, this.title});

  factory JsonViewerScreen.fromText(String jsonText, {String? title}) {
    dynamic parsed;
    try {
      parsed = jsonDecode(jsonText);
    } catch (_) {
      parsed = jsonText;
    }
    return JsonViewerScreen(jsonData: parsed, title: title);
  }

  @override
  State<JsonViewerScreen> createState() => _JsonViewerScreenState();
}

class _JsonViewerScreenState extends State<JsonViewerScreen> {
  bool _rawMode = false;

  ProfileReportData? get _profile => ProfileReportData.tryParse(widget.jsonData);

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final data = widget.jsonData;
    final isStructured = data is Map || data is List;
    final showPretty = profile != null && !_rawMode;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? (showPretty ? 'Run Report' : 'JSON Viewer')),
        actions: [
          if (profile != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Pretty')),
                    ButtonSegment(value: true, label: Text('Raw')),
                  ],
                  selected: {_rawMode},
                  onSelectionChanged: (s) => setState(() => _rawMode = s.first),
                ),
              ),
            ),
        ],
      ),
      body: showPretty
          ? _ProfileReportView(data: profile)
          : (isStructured
              ? _buildTreeOrRaw(data)
              : _buildRaw(data)),
    );
  }

  Widget _buildTreeOrRaw(dynamic json) {
    // Keep legacy viewer for non-profile JSON
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Tree'), Tab(text: 'Raw')]),
          Expanded(
            child: TabBarView(
              children: [
                _buildTree(json),
                _buildRaw(json),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTree(dynamic json) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 3.0,
      panEnabled: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: _JsonTreeNode(value: json, name: 'root', depth: 0),
      ),
    );
  }

  Widget _buildRaw(dynamic json) {
    final text = _pretty(json);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
    );
  }

  String _pretty(dynamic data) {
    if (data is String) return data;
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(data);
    } catch (_) {
      return data.toString();
    }
  }
}

class _JsonTreeNode extends StatefulWidget {
  final String? name;
  final dynamic value;
  final int depth;
  const _JsonTreeNode({required this.value, required this.depth, this.name});

  @override
  State<_JsonTreeNode> createState() => _JsonTreeNodeState();
}

class _JsonTreeNodeState extends State<_JsonTreeNode> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    final isMap = v is Map;
    final isList = v is List;
    final title =
        widget.name ??
        (isList
            ? '[]'
            : isMap
            ? '{}'
            : '(value)');
    if (!isMap && !isList) {
      return _leaf(title, v);
    }

    final int count = v.length;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        border: Border.all(color: const Color(0xFFE6E6E6)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: EdgeInsets.only(
                left: 8.0 + widget.depth * 12.0,
                right: 8,
                top: 8,
                bottom: 8,
              ),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  Text(
                    isMap ? '{...} ($count)' : '[...] ($count)',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: EdgeInsets.only(
                left: 16.0 + widget.depth * 12.0,
                right: 8,
                bottom: 8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isMap)
                    for (final e in v.entries)
                      _JsonTreeNode(
                        name: e.key.toString(),
                        value: e.value,
                        depth: widget.depth + 1,
                      ),
                  if (isList)
                    for (int i = 0; i < v.length; i++)
                      _JsonTreeNode(
                        name: '[$i]',
                        value: v[i],
                        depth: widget.depth + 1,
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _leaf(String name, dynamic value) {
    return Padding(
      padding: EdgeInsets.only(
        left: 12.0 + widget.depth * 12.0,
        right: 8,
        top: 6,
        bottom: 6,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$name: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          Expanded(
            child: Text(
              _valueToString(value),
              style: const TextStyle(fontFamily: 'monospace'),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  String _valueToString(dynamic v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return v.toString();
    if (v is String) return '"${v.replaceAll('\n', '\\n')}"';
    try {
      return const JsonEncoder().convert(v);
    } catch (_) {
      return v.toString();
    }
  }
}

// ----- Pretty Profile Report -----

class ProfileReportData {
  final String backend;
  final String backup;
  final int threads;
  final Map<String, double> metrics;
  final List<OutputShape> outputs;
  final List<ProfileOpData> ops;

  ProfileReportData({
    required this.backend,
    required this.backup,
    required this.threads,
    required this.metrics,
    required this.outputs,
    required this.ops,
  });

  static ProfileReportData? tryParse(dynamic json) {
    if (json is! Map) return null;
    final m = json.cast<String, dynamic>();
    final metricsRaw = m['metrics'];
    if (metricsRaw is! Map) return null;
    try {
      final backend = (m['backend']?.toString() ?? '').toUpperCase();
      final backup = (m['backup']?.toString() ?? '').toUpperCase();
      final threads = (m['threads'] as num?)?.toInt() ?? 0;
      final metrics = metricsRaw.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
      final outputs = <OutputShape>[];
      final outRaw = m['outputs'];
      if (outRaw is List) {
        for (final e in outRaw) {
          if (e is Map) {
            outputs.add(OutputShape(
              name: e['name']?.toString() ?? 'out',
              shape: (e['shape'] as List?)?.map((x) => (x as num).toInt()).toList() ?? const [],
            ));
          }
        }
      }
      final opsRaw = m['ops'];
      final ops = (opsRaw is List)
          ? opsRaw.map((e) => ProfileOpData.fromJson(e as Map)).cast<ProfileOpData>().toList()
          : <ProfileOpData>[];
      return ProfileReportData(
        backend: backend,
        backup: backup,
        threads: threads,
        metrics: metrics,
        outputs: outputs,
        ops: ops,
      );
    } catch (_) {
      return null;
    }
  }
}

class OutputShape {
  final String name;
  final List<int> shape;
  OutputShape({required this.name, required this.shape});
}

class ProfileOpData {
  final int index;
  final String type;
  final String name;
  final String backend;
  final double startMs;
  final double endMs;
  final double durationMs;
  ProfileOpData({
    required this.index,
    required this.type,
    required this.name,
    required this.backend,
    required this.startMs,
    required this.endMs,
    required this.durationMs,
  });
  factory ProfileOpData.fromJson(Map j) => ProfileOpData(
        index: (j['index'] as num?)?.toInt() ?? 0,
        type: j['type']?.toString() ?? 'unknown',
        name: j['name']?.toString() ?? 'op',
        backend: j['backend']?.toString() ?? 'CPU',
        startMs: (j['start_ms'] as num?)?.toDouble() ?? 0.0,
        endMs: (j['end_ms'] as num?)?.toDouble() ?? 0.0,
        durationMs: (j['duration_ms'] as num?)?.toDouble() ?? 0.0,
      );
}

Color _colorForBackend(String backend) {
  switch (backend.toUpperCase()) {
    case 'VULKAN':
      return Colors.deepPurple;
    case 'OPENCL':
      return Colors.teal;
    case 'OPENGL':
      return Colors.orange;
    case 'METAL':
      return Colors.brown;
    case 'CUDA':
      return Colors.indigo;
    default:
      return Colors.blueGrey;
  }
}

class _ProfileReportView extends StatelessWidget {
  final ProfileReportData data;
  const _ProfileReportView({required this.data});

  @override
  Widget build(BuildContext context) {
    final ops = data.ops;
    final maxMs =
        ops.isEmpty ? 0.0 : ops.map((o) => o.endMs).reduce((a, b) => a > b ? a : b);
    final scale = 0.4; // px per ms similar to main timeline
    final double width = (maxMs * scale).clamp(300.0, 8000.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Run Info', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Chip(label: 'Backend', value: data.backend),
                  _Chip(label: 'Backup', value: data.backup),
                  _Chip(label: 'Threads', value: data.threads.toString()),
                ],
              ),
              const SizedBox(height: 10),
              _MetricsGrid(metrics: data.metrics),
              if (data.outputs.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Outputs', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: data.outputs
                      .map((o) => _Chip(label: o.name, value: o.shape.join('x')))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (ops.isNotEmpty)
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Timeline',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    // Fullscreen button
                    IconButton(
                      tooltip: 'Open fullscreen timeline',
                      icon: const Icon(Icons.fullscreen),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TimelineFullscreen(data: data),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: width),
                    child: _TimelineContent(
                      width: width,
                      maxMs: maxMs,
                      scale: scale,
                      ops: ops,
                      colorFor: _colorForBackend,
                      enableTapDetails: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Reusable timeline content (axis + bars) with optional tap-to-details.
class _TimelineContent extends StatelessWidget {
  final double width;
  final double maxMs;
  final double scale;
  final List<ProfileOpData> ops;
  final Color Function(String backend) colorFor;
  final bool enableTapDetails;

  const _TimelineContent({
    required this.width,
    required this.maxMs,
    required this.scale,
    required this.ops,
    required this.colorFor,
    this.enableTapDetails = false,
  });

  @override
  Widget build(BuildContext context) {
    // Pack ops into rows (lanes) so non-overlapping ops share a row.
    final sorted = [...ops]..sort((a, b) => a.startMs.compareTo(b.startMs));
    const eps = 1e-6;
    final List<List<ProfileOpData>> lanes = [];
    final List<double> laneEnds = [];
    for (final op in sorted) {
      bool placed = false;
      for (var i = 0; i < laneEnds.length; i++) {
        if (op.startMs >= laneEnds[i] - eps) {
          lanes[i].add(op);
          laneEnds[i] = op.endMs;
          placed = true;
          break;
        }
      }
      if (!placed) {
        lanes.add([op]);
        laneEnds.add(op.endMs);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 30,
          width: width,
          child: CustomPaint(
            painter: _AxisPainter(maxMs: maxMs, scale: scale),
          ),
        ),
        const SizedBox(height: 6),
        for (final lane in lanes) ...[
          SizedBox(
            height: 28,
            width: width,
            child: Stack(
              children: [
                for (final op in lane)
                  Positioned(
                    left: op.startMs * scale,
                    width: (op.durationMs * scale).clamp(1.0, double.infinity),
                    top: 0,
                    bottom: 0,
                    child: _OpBar(
                      op: op,
                      color: colorFor(op.backend).withValues(alpha: 0.75),
                      enableTapDetails: enableTapDetails,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _OpBar extends StatelessWidget {
  final ProfileOpData op;
  final Color color;
  final bool enableTapDetails;
  const _OpBar({required this.op, required this.color, required this.enableTapDetails});

  void _showDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${op.index}. ${op.name}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _InfoRow(label: 'Type', value: op.type),
                _InfoRow(label: 'Backend', value: op.backend),
                _InfoRow(label: 'Start', value: '${op.startMs.toStringAsFixed(3)} ms'),
                _InfoRow(label: 'End', value: '${op.endMs.toStringAsFixed(3)} ms'),
                _InfoRow(label: 'Duration', value: '${op.durationMs.toStringAsFixed(3)} ms'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bar = Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message:
            '${op.index}. ${op.name} (${op.type})\n${op.backend} • ${op.durationMs.toStringAsFixed(2)} ms',
        child: Text(
          '${op.name} (${op.type})',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.white),
        ),
      ),
    );
    if (!enableTapDetails) return bar;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showDetails(context),
        child: bar,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE6E6E6)),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value, style: const TextStyle(color: Colors.black87)),
          ],
        ),
      ),
    );
  }
}

class TimelineFullscreen extends StatefulWidget {
  final ProfileReportData data;
  const TimelineFullscreen({super.key, required this.data});
  @override
  State<TimelineFullscreen> createState() => _TimelineFullscreenState();
}

class _TimelineFullscreenState extends State<TimelineFullscreen> {
  double _scale = 1.0; // InteractiveViewer will handle pinch, this is for buttons

  @override
  Widget build(BuildContext context) {
    final ops = widget.data.ops;
    final maxMs =
        ops.isEmpty ? 0.0 : ops.map((o) => o.endMs).reduce((a, b) => a > b ? a : b);
    final baseScale = 0.5; // base px per ms in fullscreen
    final double width = (maxMs * baseScale).clamp(400.0, 16000.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Timeline'),
        actions: [
          IconButton(
            tooltip: 'Zoom out',
            onPressed: () => setState(() => _scale = (_scale / 1.2).clamp(0.2, 8.0)),
            icon: const Icon(Icons.zoom_out),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: () => setState(() => _scale = (_scale * 1.2).clamp(0.2, 8.0)),
            icon: const Icon(Icons.zoom_in),
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.2,
        maxScale: 8.0,
        scaleEnabled: true,
        panEnabled: true,
        child: Transform.scale(
          scale: _scale,
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: width),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _TimelineContent(
                width: width,
                maxMs: maxMs,
                scale: baseScale,
                ops: widget.data.ops,
                colorFor: _colorForBackend,
                enableTapDetails: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  final Map<String, double> metrics;
  const _MetricsGrid({required this.metrics});
  @override
  Widget build(BuildContext context) {
    final entries = metrics.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final total = metrics.values.fold<double>(0.0, (a, b) => a + b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in entries)
              _Chip(label: e.key.replaceAll('_', ' '), value: '${e.value.toStringAsFixed(2)} ms'),
            _Chip(label: 'total', value: '${total.toStringAsFixed(2)} ms'),
          ],
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  const _Chip({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final color = Colors.black87;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE6E6E6)),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(text: '$label: ', style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
            TextSpan(text: value, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
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

class _AxisPainter extends CustomPainter {
  final double maxMs;
  final double scale;
  _AxisPainter({required this.maxMs, required this.scale});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFAAAAAA)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      paint,
    );
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

// Public wrapper to embed the pretty report inline in other screens.
class ProfileReport extends StatelessWidget {
  final dynamic jsonData;
  const ProfileReport({super.key, required this.jsonData});
  @override
  Widget build(BuildContext context) {
    final parsed = ProfileReportData.tryParse(jsonData);
    if (parsed == null) return const SizedBox.shrink();
    return _ProfileReportView(data: parsed);
  }
}
