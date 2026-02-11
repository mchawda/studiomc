import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/database_service.dart';
import '../services/settings_service.dart';
import '../widgets/settings/advanced_settings_section.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _showAdvanced = false;
  bool _showPersonalization = false;
  final TextEditingController _modelIdController = TextEditingController();
  final TextEditingController _newFactController = TextEditingController();
  bool _showApiKey = false;

  static const _keyApprovedFolders = 'settings_approved_folders';
  List<String> _approvedFolders = [];
  String _localApiKey = '';

  /// Permanent memory facts: [{id: int, fact: String, created_at: String}]
  List<Map<String, dynamic>> _facts = [];
  int? _editingFactId;
  final TextEditingController _editFactController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPersistedState();
    _loadFacts();
  }

  Future<void> _loadFacts() async {
    final db = context.read<DatabaseService>();
    await db.ensureMemoryTables();
    final facts = await db.getGlobalFactsWithId();
    if (mounted) setState(() => _facts = facts);
  }

  Future<void> _addFact() async {
    final text = _newFactController.text.trim();
    if (text.isEmpty) return;
    final db = context.read<DatabaseService>();
    await db.saveGlobalFact(text);
    _newFactController.clear();
    await _loadFacts();
  }

  Future<void> _deleteFact(int id) async {
    final db = context.read<DatabaseService>();
    await db.deleteGlobalFact(id);
    await _loadFacts();
  }

  Future<void> _saveEditedFact(int id) async {
    final text = _editFactController.text.trim();
    if (text.isEmpty) return;
    final db = context.read<DatabaseService>();
    await db.updateGlobalFact(id, text);
    setState(() => _editingFactId = null);
    await _loadFacts();
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
    _newFactController.dispose();
    _editFactController.dispose();
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

                // ── Privacy & Cloud ──
                _compactCard(
                  theme,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Privacy',
                                    style: GoogleFonts.spaceGrotesk(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                                Text(
                                    'Control whether data can leave your device',
                                    style: GoogleFonts.inter(
                                        fontSize: 10,
                                        color: theme.colorScheme.secondary)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(Icons.cloud_outlined,
                              size: 18, color: theme.colorScheme.secondary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Allow cloud AI requests',
                                    style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500)),
                                const SizedBox(height: 2),
                                Text(
                                  'When enabled, Studiomc may send prompts to '
                                  'external APIs (OpenAI, Anthropic, etc.) for '
                                  'frontier-class models. Your data will leave '
                                  'this device.',
                                  style: GoogleFonts.inter(
                                      fontSize: 9,
                                      color: theme.colorScheme.secondary),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value: settings.cloudConsent,
                            onChanged: (value) {
                              if (value) {
                                _showCloudConsentDialog(settings);
                              } else {
                                settings.cloudConsent = false;
                              }
                            },
                          ),
                        ],
                      ),
                      if (settings.cloudConsent) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3E0),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 14,
                                  color: Colors.orange.shade700),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Cloud AI is enabled. Prompts sent to '
                                  'frontier models will leave your device.',
                                  style: GoogleFonts.inter(
                                      fontSize: 9,
                                      color: Colors.orange.shade800),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // ── Personalization ──
                _compactCard(
                  theme,
                  onTap: () => setState(
                      () => _showPersonalization = !_showPersonalization),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Personalization',
                                style: GoogleFonts.spaceGrotesk(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                            Text('Permanent memory — things the model always knows',
                                style: GoogleFonts.inter(
                                    fontSize: 10,
                                    color: theme.colorScheme.secondary)),
                          ],
                        ),
                      ),
                      Icon(
                        _showPersonalization
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 18,
                        color: theme.colorScheme.secondary,
                      ),
                    ],
                  ),
                ),

                if (_showPersonalization) ...[
                  const SizedBox(height: 8),
                  _buildPersonalizationContent(theme),
                ],

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

  // ── Personalization panel ──
  Widget _buildPersonalizationContent(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add facts about yourself the model should always remember.',
              style: GoogleFonts.inter(
                  fontSize: 10, color: theme.colorScheme.secondary),
            ),
            const SizedBox(height: 4),
            Text(
              'Examples: "My name is Alex", "I prefer Python over JS", "I work at Acme Corp"',
              style: GoogleFonts.inter(
                  fontSize: 9,
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.secondary.withOpacity(0.7)),
            ),
            const SizedBox(height: 10),

            // ── Add new fact ──
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newFactController,
                    style: GoogleFonts.inter(fontSize: 11),
                    decoration: InputDecoration(
                      hintText: 'Add something the model should remember...',
                      hintStyle: GoogleFonts.inter(
                          fontSize: 10, color: theme.colorScheme.secondary),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    onSubmitted: (_) => _addFact(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 32,
                  child: FilledButton.icon(
                    onPressed: _addFact,
                    icon: const Icon(Icons.add, size: 14),
                    label: Text('Add',
                        style: GoogleFonts.inter(fontSize: 10)),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Fact list ──
            if (_facts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('No memories yet. Add your first one above.',
                    style: GoogleFonts.inter(
                        fontSize: 10, color: theme.colorScheme.secondary)),
              )
            else
              ..._facts.map((f) {
                final id = f['id'] as int;
                final fact = f['fact'] as String;
                final isEditing = _editingFactId == id;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withOpacity(0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: isEditing
                        ? Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _editFactController,
                                  style: GoogleFonts.inter(fontSize: 10),
                                  autofocus: true,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 4),
                                    border: OutlineInputBorder(),
                                  ),
                                  onSubmitted: (_) => _saveEditedFact(id),
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.check, size: 14),
                                onPressed: () => _saveEditedFact(id),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 24, minHeight: 24),
                                color: theme.colorScheme.primary,
                                tooltip: 'Save',
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 14),
                                onPressed: () =>
                                    setState(() => _editingFactId = null),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 24, minHeight: 24),
                                color: theme.colorScheme.secondary,
                                tooltip: 'Cancel',
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Icon(Icons.memory,
                                  size: 14,
                                  color: theme.colorScheme.primary
                                      .withOpacity(0.7)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(fact,
                                    style: GoogleFonts.inter(fontSize: 10)),
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 14),
                                onPressed: () {
                                  _editFactController.text = fact;
                                  setState(() => _editingFactId = id);
                                },
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 24, minHeight: 24),
                                color: theme.colorScheme.secondary,
                                tooltip: 'Edit',
                              ),
                              IconButton(
                                icon:
                                    const Icon(Icons.delete_outline, size: 14),
                                onPressed: () => _deleteFact(id),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 24, minHeight: 24),
                                color: theme.colorScheme.error,
                                tooltip: 'Remove',
                              ),
                            ],
                          ),
                  ),
                );
              }),

            // ── Info note ──
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.info_outline,
                    size: 12, color: theme.colorScheme.secondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'These facts are injected into every conversation when Memory is on.',
                    style: GoogleFonts.inter(
                        fontSize: 9, color: theme.colorScheme.secondary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCloudConsentDialog(SettingsService settings) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dialogTheme = Theme.of(ctx);
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.cloud_outlined,
                  size: 22, color: dialogTheme.colorScheme.primary),
              const SizedBox(width: 10),
              const Expanded(child: Text('Enable Cloud AI?')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'When you use frontier-class models (like GPT-4o or Claude), '
                'your prompts and conversations will be sent to external '
                'cloud APIs operated by third parties.',
                style: GoogleFonts.inter(fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 12),
              Text(
                'This means your data will leave your device. '
                'Local models are not affected — they always run privately.',
                style: GoogleFonts.inter(fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color:
                      dialogTheme.colorScheme.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 16, color: dialogTheme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You can revoke this at any time in Settings.',
                        style: GoogleFonts.inter(
                            fontSize: 10,
                            color: dialogTheme.colorScheme.primary,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep Local Only'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Allow Cloud AI'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      settings.cloudConsent = true;
    }
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
