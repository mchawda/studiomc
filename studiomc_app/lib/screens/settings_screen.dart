import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/settings_service.dart';
import '../widgets/settings/advanced_settings_section.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _showAdvanced = false;
  final TextEditingController _modelIdController = TextEditingController();
  bool _showApiKey = false;

  static const _keyApprovedFolders = 'settings_approved_folders';
  List<String> _approvedFolders = [];
  String _localApiKey = '';

  @override
  void initState() {
    super.initState();
    _loadPersistedState();
  }

  Future<void> _loadPersistedState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _approvedFolders = prefs.getStringList(_keyApprovedFolders) ?? [];
      _localApiKey = prefs.getString('local_api_key') ?? _generateLocalKey();
    });
    if (!prefs.containsKey('local_api_key')) {
      await prefs.setString('local_api_key', _localApiKey);
    }
  }

  String _generateLocalKey() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return 'sk-local-${timestamp.toRadixString(36)}';
  }

  Future<void> _saveApprovedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyApprovedFolders, _approvedFolders);
  }

  Future<void> _handleAddFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select folder to grant access',
      );
      if (result != null && !_approvedFolders.contains(result)) {
        setState(() => _approvedFolders.add(result));
        await _saveApprovedFolders();
      }
    } catch (_) {}
  }

  Future<void> _handleRemoveFolder(String folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove folder access?'),
        content: Text('Remove access to:\n$folder'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() => _approvedFolders.remove(folder));
      await _saveApprovedFolders();
    }
  }

  @override
  void dispose() {
    _modelIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<SettingsService>();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings',
              style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface)),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // ── Appearance ──
                _compactCard(
                  theme,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Appearance',
                                style: GoogleFonts.spaceGrotesk(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                            Text('Theme & display',
                                style: GoogleFonts.inter(
                                    fontSize: 10,
                                    color: theme.colorScheme.secondary)),
                          ],
                        ),
                      ),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                              value: 'Light Blue', label: Text('Light')),
                          ButtonSegment(
                              value: 'Dark Blue', label: Text('Dark')),
                        ],
                        selected: {settings.selectedTheme},
                        onSelectionChanged: (v) =>
                            settings.selectedTheme = v.first,
                        style: ButtonStyle(
                          textStyle: WidgetStatePropertyAll(
                              GoogleFonts.inter(fontSize: 10)),
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const WidgetStatePropertyAll(
                              EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4)),
                          minimumSize: const WidgetStatePropertyAll(
                              Size(0, 28)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // ── Advanced toggle ──
                _compactCard(
                  theme,
                  onTap: () =>
                      setState(() => _showAdvanced = !_showAdvanced),
                  child: Row(
                    children: [
                      Text('Advanced',
                          style: GoogleFonts.spaceGrotesk(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Icon(
                        _showAdvanced
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 18,
                        color: theme.colorScheme.secondary,
                      ),
                    ],
                  ),
                ),

                // ── Advanced content ──
                if (_showAdvanced) ...[
                  const SizedBox(height: 8),
                  AdvancedSettingsSection(
                    modelIdController: _modelIdController,
                    localApiEnabled: settings.localApiEnabled,
                    localApiKey: _localApiKey,
                    showApiKey: _showApiKey,
                    contextLength: settings.contextLength,
                    batchSize: settings.batchSize,
                    prefetchDepth: settings.prefetchDepth,
                    threads: settings.threads,
                    approvedFolders: _approvedFolders,
                    onLocalApiChanged: (v) => settings.localApiEnabled = v,
                    onShowApiKeyChanged: (v) =>
                        setState(() => _showApiKey = v),
                    onContextLengthChanged: (v) =>
                        settings.contextLength = v,
                    onBatchSizeChanged: (v) => settings.batchSize = v,
                    onPrefetchDepthChanged: (v) =>
                        settings.prefetchDepth = v,
                    onThreadsChanged: (v) => settings.threads = v,
                    onFolderRemoved: _handleRemoveFolder,
                    onFolderAdded: _handleAddFolder,
                  ),
                ],

                // ── About — minimal, at the very bottom ──
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Text('Studiomc v1.0.0',
                          style: GoogleFonts.inter(
                              fontSize: 10,
                              color: theme.colorScheme.secondary)),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: 'Studiomc',
                          applicationVersion: '1.0.0',
                        ),
                        child: Text('Licenses',
                            style: GoogleFonts.inter(
                                fontSize: 10,
                                color: theme.colorScheme.primary,
                                decoration: TextDecoration.underline)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactCard(ThemeData theme,
      {required Widget child, VoidCallback? onTap}) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: child,
        ),
      ),
    );
  }
}
