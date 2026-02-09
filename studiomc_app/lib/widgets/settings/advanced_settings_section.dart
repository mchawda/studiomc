import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A frontier API provider config stored in SharedPreferences.
class FrontierApiConfig {
  final String name;
  final String baseUrl;
  final String apiKey;
  final bool enabled;

  const FrontierApiConfig({
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    this.enabled = true,
  });
}

class AdvancedSettingsSection extends StatefulWidget {
  final TextEditingController modelIdController;
  final bool localApiEnabled;
  final String localApiKey;
  final bool showApiKey;
  final double contextLength;
  final double batchSize;
  final double prefetchDepth;
  final double threads;
  final List<String> approvedFolders;
  final ValueChanged<bool> onLocalApiChanged;
  final ValueChanged<bool> onShowApiKeyChanged;
  final ValueChanged<double> onContextLengthChanged;
  final ValueChanged<double> onBatchSizeChanged;
  final ValueChanged<double> onPrefetchDepthChanged;
  final ValueChanged<double> onThreadsChanged;
  final ValueChanged<String> onFolderRemoved;
  final VoidCallback onFolderAdded;
  final VoidCallback? onModelImported;

  const AdvancedSettingsSection({
    super.key,
    required this.modelIdController,
    required this.localApiEnabled,
    required this.localApiKey,
    required this.showApiKey,
    required this.contextLength,
    required this.batchSize,
    required this.prefetchDepth,
    required this.threads,
    required this.approvedFolders,
    required this.onLocalApiChanged,
    required this.onShowApiKeyChanged,
    required this.onContextLengthChanged,
    required this.onBatchSizeChanged,
    required this.onPrefetchDepthChanged,
    required this.onThreadsChanged,
    required this.onFolderRemoved,
    required this.onFolderAdded,
    this.onModelImported,
  });

  @override
  State<AdvancedSettingsSection> createState() =>
      _AdvancedSettingsSectionState();
}

class _AdvancedSettingsSectionState extends State<AdvancedSettingsSection> {
  List<FrontierApiConfig> _apis = [];
  bool _importingModel = false;

  @override
  void initState() {
    super.initState();
    _loadApis();
  }

  Future<void> _loadApis() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('frontier_apis') ?? [];
    final list = <FrontierApiConfig>[];
    for (final entry in raw) {
      try {
        final parts = entry.split('|||');
        if (parts.length >= 3) {
          list.add(FrontierApiConfig(
            name: parts[0],
            baseUrl: parts[1],
            apiKey: parts[2],
            enabled: parts.length > 3 ? parts[3] == 'true' : true,
          ));
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _apis = list);
  }

  Future<void> _saveApis() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = _apis
        .map((a) => '${a.name}|||${a.baseUrl}|||${a.apiKey}|||${a.enabled}')
        .toList();
    await prefs.setStringList('frontier_apis', raw);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _section(theme, 'Model Import', _buildModelImport(theme)),
        const SizedBox(height: 8),
        _section(theme, 'API Endpoints', _buildApiEndpoints(theme)),
        const SizedBox(height: 8),
        _section(theme, 'Performance', _buildPerformance(theme)),
        const SizedBox(height: 8),
        _section(theme, 'Diagnostics', _buildDiagnostics(theme)),
        const SizedBox(height: 8),
        _section(theme, 'Folder Access', _buildFolderAccess(theme)),
      ],
    );
  }

  Widget _section(ThemeData theme, String title, Widget content) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 11, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            content,
          ],
        ),
      ),
    );
  }

  // ── Model Import ──

  // ── Hardware detection ──
  bool get _isAppleSilicon {
    if (!Platform.isMacOS) return false;
    // Apple Silicon: arm64 architecture
    final arch = Platform.version.toLowerCase();
    // Also check the resolved executable path or environment
    return Platform.resolvedExecutable.contains('arm64') ||
        !Platform.resolvedExecutable.contains('x86_64') &&
            Platform.isMacOS;
  }

  String get _compatibleFormat {
    if (_isAppleSilicon) return 'MLX';
    return 'GGUF';
  }

  Widget _buildModelImport(ThemeData theme) {
    final format = _compatibleFormat;
    final hint = format == 'MLX'
        ? 'Apple Silicon detected — select an MLX model folder.'
        : 'Select a GGUF model file compatible with your hardware.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(hint,
            style: GoogleFonts.inter(
                fontSize: 10, color: theme.colorScheme.secondary)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 24,
          child: _importingModel
              ? const Center(
                  child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5)))
              : OutlinedButton.icon(
                  onPressed: _handleImportModel,
                  icon: const Icon(Icons.download_rounded, size: 11),
                  label: Text('Import model',
                      style: GoogleFonts.inter(fontSize: 9)),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                ),
        ),
      ],
    );
  }

  /// Single import flow — auto-picks the right format for the hardware.
  Future<void> _handleImportModel() async {
    if (_isAppleSilicon) {
      await _importMlxModel();
    } else {
      await _importGgufModel();
    }
  }

  Future<void> _importGgufModel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gguf', 'bin'],
        dialogTitle: 'Select a model file',
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.path == null) return;

      setState(() => _importingModel = true);
      final appDir = await getApplicationSupportDirectory();
      final modelsDir = Directory('${appDir.path}/models');
      if (!await modelsDir.exists()) await modelsDir.create(recursive: true);

      final sourceFile = File(file.path!);
      final destPath = '${modelsDir.path}/${file.name}';
      if (sourceFile.path != destPath) await sourceFile.copy(destPath);

      _showImportSuccess(file.name);
    } catch (e) {
      _showImportError(e);
    }
  }

  Future<void> _importMlxModel() async {
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select a model folder',
      );
      if (dirPath == null) return;

      // Validate: must have config.json (MLX/safetensors format)
      final hasConfig = await File('$dirPath/config.json').exists();
      final hasWeights = await File('$dirPath/weights.npz').exists() ||
          await _hasFilesWithExtension(dirPath, '.safetensors');

      if (!hasConfig) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Not a valid model folder (missing config.json)',
                style: GoogleFonts.inter(fontSize: 10)),
            behavior: SnackBarBehavior.floating,
          ));
        }
        return;
      }

      setState(() => _importingModel = true);
      final appDir = await getApplicationSupportDirectory();
      final modelsDir = Directory('${appDir.path}/models');
      if (!await modelsDir.exists()) await modelsDir.create(recursive: true);

      final folderName = dirPath.split('/').last;
      final destDir = Directory('${modelsDir.path}/$folderName');
      await _copyDirectory(Directory(dirPath), destDir);

      _showImportSuccess(folderName);
    } catch (e) {
      _showImportError(e);
    }
  }

  Future<bool> _hasFilesWithExtension(String dirPath, String ext) async {
    await for (final entity in Directory(dirPath).list()) {
      if (entity is File && entity.path.endsWith(ext)) return true;
    }
    return false;
  }

  void _showImportSuccess(String name) {
    if (mounted) {
      setState(() => _importingModel = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('Model imported: $name', style: GoogleFonts.inter(fontSize: 10)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ));
      widget.onModelImported?.call();
    }
  }

  void _showImportError(Object e) {
    if (mounted) {
      setState(() => _importingModel = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Future<void> _copyDirectory(Directory source, Directory dest) async {
    if (!await dest.exists()) await dest.create(recursive: true);
    await for (final entity in source.list()) {
      final newPath = '${dest.path}/${entity.path.split('/').last}';
      if (entity is File) {
        await entity.copy(newPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      }
    }
  }

  // ── API Endpoints ──

  Widget _buildApiEndpoints(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: Text('Local API',
                    style: GoogleFonts.inter(fontSize: 10))),
            Transform.scale(
              scale: 0.65,
              child: Switch(
                value: widget.localApiEnabled,
                onChanged: widget.onLocalApiChanged,
              ),
            ),
          ],
        ),
        if (widget.localApiEnabled) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                    widget.showApiKey
                        ? widget.localApiKey
                        : 'http://localhost:8000  •  ••••••••',
                    style: GoogleFonts.jetBrainsMono(
                        fontSize: 10, color: theme.colorScheme.secondary)),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: Icon(
                      widget.showApiKey
                          ? Icons.visibility_off
                          : Icons.visibility,
                      size: 14),
                  onPressed: () =>
                      widget.onShowApiKeyChanged(!widget.showApiKey),
                  padding: EdgeInsets.zero,
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: const Icon(Icons.copy, size: 14),
                  onPressed: () {
                    Clipboard.setData(
                        ClipboardData(text: widget.localApiKey));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Copied',
                          style: GoogleFonts.inter(fontSize: 11)),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 1),
                    ));
                  },
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
        const Divider(height: 12),
        Text('Frontier APIs (cloud)',
            style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.secondary)),
        const SizedBox(height: 2),
        Text('Data leaves your device when using cloud APIs.',
            style: GoogleFonts.inter(
                fontSize: 9, color: theme.colorScheme.secondary)),
        ..._apis.asMap().entries.map((entry) {
          final i = entry.key;
          final api = entry.value;
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(api.enabled ? Icons.cloud : Icons.cloud_off,
                    size: 14,
                    color: api.enabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.secondary),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(api.name,
                        style: GoogleFonts.inter(fontSize: 11))),
                SizedBox(
                  height: 24,
                  child: Switch(
                    value: api.enabled,
                    onChanged: (v) {
                      setState(() {
                        _apis[i] = FrontierApiConfig(
                            name: api.name,
                            baseUrl: api.baseUrl,
                            apiKey: api.apiKey,
                            enabled: v);
                      });
                      _saveApis();
                    },
                  ),
                ),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    onPressed: () {
                      setState(() => _apis.removeAt(i));
                      _saveApis();
                    },
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 24,
          child: OutlinedButton.icon(
            onPressed: _showAddFrontierApiDialog,
            icon: const Icon(Icons.add, size: 11),
            label: Text('Add frontier API',
                style: GoogleFonts.inter(fontSize: 9)),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8)),
          ),
        ),
      ],
    );
  }

  Future<void> _showAddFrontierApiDialog() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    String? selectedPreset;

    final presets = {
      'OpenAI': 'https://api.openai.com/v1',
      'Anthropic': 'https://api.anthropic.com/v1',
      'Google AI': 'https://generativelanguage.googleapis.com/v1beta',
      'Groq': 'https://api.groq.com/openai/v1',
      'Together AI': 'https://api.together.xyz/v1',
      'Custom': '',
    };

    final result = await showDialog<FrontierApiConfig>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text('Add Frontier API',
              style: GoogleFonts.spaceGrotesk(
                  fontSize: 14, fontWeight: FontWeight.w600)),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber.shade200),
                  ),
                  child: Row(children: [
                    Icon(Icons.info_outline,
                        size: 14, color: Colors.amber.shade800),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text('Cloud APIs send data externally.',
                            style: GoogleFonts.inter(
                                fontSize: 10,
                                color: Colors.amber.shade900))),
                  ]),
                ),
                const SizedBox(height: 12),
                Text('Provider',
                    style: GoogleFonts.inter(fontSize: 10)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: presets.keys.map((name) {
                    return ChoiceChip(
                      label: Text(name,
                          style: GoogleFonts.inter(fontSize: 10)),
                      selected: selectedPreset == name,
                      visualDensity: VisualDensity.compact,
                      onSelected: (v) {
                        setDialogState(() {
                          selectedPreset = name;
                          nameCtrl.text = name == 'Custom' ? '' : name;
                          urlCtrl.text = presets[name] ?? '';
                        });
                      },
                    );
                  }).toList(),
                ),
                if (selectedPreset == 'Custom') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    style: GoogleFonts.inter(fontSize: 11),
                    decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'My Provider',
                        isDense: true),
                  ),
                ],
                if (selectedPreset != null) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: urlCtrl,
                    style: GoogleFonts.inter(fontSize: 11),
                    decoration: InputDecoration(
                        labelText: 'Base URL',
                        isDense: true,
                        enabled: selectedPreset == 'Custom'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: keyCtrl,
                    obscureText: true,
                    style: GoogleFonts.inter(fontSize: 11),
                    decoration: const InputDecoration(
                        labelText: 'API Key',
                        hintText: 'sk-...',
                        isDense: true),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: selectedPreset != null &&
                      keyCtrl.text.trim().isNotEmpty
                  ? () => Navigator.pop(
                      ctx,
                      FrontierApiConfig(
                        name: nameCtrl.text.trim().isEmpty
                            ? selectedPreset!
                            : nameCtrl.text.trim(),
                        baseUrl: urlCtrl.text.trim(),
                        apiKey: keyCtrl.text.trim(),
                      ))
                  : null,
              child: const Text('Add'),
            ),
          ],
        );
      }),
    );

    if (result != null) {
      setState(() => _apis.add(result));
      await _saveApis();
    }
  }

  // ── Performance ──

  Widget _buildPerformance(ThemeData theme) {
    return Column(
      children: [
        _compactSlider(theme, 'Context length', widget.contextLength, 1024,
            32768, widget.onContextLengthChanged),
        _compactSlider(theme, 'Batch size', widget.batchSize, 64, 2048,
            widget.onBatchSizeChanged),
        _compactSlider(theme, 'Prefetch depth', widget.prefetchDepth, 1, 8,
            widget.onPrefetchDepthChanged),
        _compactSlider(theme, 'Threads', widget.threads, 1, 16,
            widget.onThreadsChanged),
      ],
    );
  }

  Widget _compactSlider(ThemeData theme, String label, double value,
      double min, double max, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child:
                Text(label, style: GoogleFonts.inter(fontSize: 10)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: (max - min) > 100
                    ? ((max - min) / 100).round()
                    : (max - min).round(),
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              value.toInt().toString(),
              textAlign: TextAlign.right,
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  // ── Diagnostics ──

  Widget _buildDiagnostics(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 30,
            child: OutlinedButton.icon(
              onPressed: _exportDiagnostics,
              icon: const Icon(Icons.download, size: 14),
              label: Text('Export', style: GoogleFonts.inter(fontSize: 10)),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 30,
            child: OutlinedButton.icon(
              onPressed: _viewLogs,
              icon: const Icon(Icons.text_snippet_outlined, size: 14),
              label:
                  Text('View logs', style: GoogleFonts.inter(fontSize: 10)),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10)),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _exportDiagnostics() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final diagFile = File(
          '${appDir.path}/diagnostics_${DateTime.now().millisecondsSinceEpoch}.txt');
      final buf = StringBuffer()
        ..writeln('Studiomc Diagnostics')
        ..writeln('Generated: ${DateTime.now().toIso8601String()}')
        ..writeln('OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('Processors: ${Platform.numberOfProcessors}')
        ..writeln('Context: ${widget.contextLength.toInt()}, Batch: ${widget.batchSize.toInt()}, Threads: ${widget.threads.toInt()}');

      final modelsDir = Directory('${appDir.path}/models');
      if (await modelsDir.exists()) {
        buf.writeln('--- Models ---');
        await for (final entity in modelsDir.list()) {
          if (entity is File) {
            final stat = await entity.stat();
            buf.writeln(
                '${entity.path.split('/').last}: ${(stat.size / (1024 * 1024)).toStringAsFixed(1)} MB');
          }
        }
      }
      await diagFile.writeAsString(buf.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved to ${diagFile.path}',
              style: GoogleFonts.inter(fontSize: 10)),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
              label: 'Open',
              onPressed: () => Process.run('open', [appDir.path])),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _viewLogs() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final logFile = File('${appDir.path}/app.log');
      if (!await logFile.exists()) {
        await logFile.writeAsString(
            '${DateTime.now().toIso8601String()} [info] No logs yet.\n');
      }
      if (Platform.isMacOS) {
        await Process.run('open', ['-t', logFile.path]);
      } else if (Platform.isWindows) {
        await Process.run('notepad', [logFile.path]);
      } else {
        await Process.run('xdg-open', [logFile.path]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open logs: $e')));
      }
    }
  }

  // ── Folder Access ──

  Widget _buildFolderAccess(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...widget.approvedFolders.map((folder) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                      child: Text(folder,
                          style: GoogleFonts.inter(fontSize: 10),
                          overflow: TextOverflow.ellipsis)),
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      onPressed: () => widget.onFolderRemoved(folder),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            )),
        SizedBox(
          width: double.infinity,
          height: 32,
          child: OutlinedButton.icon(
            onPressed: widget.onFolderAdded,
            icon: const Icon(Icons.add, size: 14),
            label:
                Text('Add folder', style: GoogleFonts.inter(fontSize: 11)),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12)),
          ),
        ),
      ],
    );
  }
}
