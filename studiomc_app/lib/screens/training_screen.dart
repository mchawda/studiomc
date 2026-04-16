// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/database_service.dart';
import 'package:studiomc_app/services/local_inference_service.dart';
import 'package:studiomc_app/services/training_service.dart';

// ── Private helpers ──

class _ExtractItem {
  final String id;
  final ExtractCategory category;
  String content;
  String? sourceDoc;
  int? sourcePage;
  bool isCritical;

  _ExtractItem({
    required this.id,
    required this.category,
    required this.content,
    this.sourceDoc,
    this.sourcePage,
    // ignore: unused_element_parameter
    this.isCritical = false,
  });
}

class _DocContent {
  final String id;
  final String name;
  final String text;
  const _DocContent({required this.id, required this.name, required this.text});
}

const _stepLabels = ['Pick goal', 'Add sources', 'Knowledge Pack', 'Apply & test'];

// ═══════════════════════════════════════════════════════════════════
// Training → Personalize screen — 4-step guided wizard
// ═══════════════════════════════════════════════════════════════════

class TrainingScreen extends StatefulWidget {
  const TrainingScreen({super.key});

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen> {
  final TrainingService _trainingService = TrainingService();

  // ── Wizard ──
  int _currentStep = 0;
  PersonalizationGoal? _selectedGoal;

  // ── DB data ──
  List<Collection> _collections = [];
  List<Adapter> _adapters = [];
  List<Map<String, dynamic>> _documents = [];
  bool _isLoading = true;

  // ── Step 1 — sources ──
  final Set<String> _selectedCollectionIds = {};
  Set<String> _selectedDocumentIds = {};
  bool _showNewCollectionInput = false;
  final _newCollectionCtrl = TextEditingController();

  // ── Step 2 — extract toggles ──
  bool _togQA = true;
  bool _togFacts = true;
  bool _togGlossary = false;
  bool _togRules = false;
  bool _togTemplates = false;
  bool _useCloudExtraction = false;
  bool _isGenerating = false;
  bool _extractsReady = false;
  List<_ExtractItem> _extracts = [];
  ExtractCategory _activeExtractTab = ExtractCategory.qa;

  // ── Step 3 — apply ──
  final _adapterNameCtrl = TextEditingController();

  // ── Training run ──
  String? _currentRunId;
  Map<String, dynamic>? _currentRunStatus;
  Timer? _statusPollTimer;

  // ─────────── lifecycle ───────────

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _newCollectionCtrl.dispose();
    _adapterNameCtrl.dispose();
    _statusPollTimer?.cancel();
    super.dispose();
  }

  // ─────────── data ───────────

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final db = context.read<DatabaseService>();
      await db.ensureTrainingTables();
      final cData = await db.getCollections();
      final aData = await db.getAdapters();
      final dData = await db.getDocuments();
      setState(() {
        _collections = cData
            .map((c) => Collection(
                  id: c['id'] as String,
                  name: c['name'] as String,
                  createdAt: DateTime.parse(c['created_at'] as String),
                ))
            .toList();
        _adapters = aData
            .map((a) => Adapter(
                  id: a['id'] as String,
                  name: a['name'] as String,
                  baseModelId: a['base_model_id'] as String,
                  sourceType: _parseSource(a['source_type'] as String? ?? 'collection'),
                  sourceRef: a['source_ref'] as String?,
                  diskBytes: a['disk_bytes'] as int? ?? 0,
                  createdAt: DateTime.parse(a['created_at'] as String),
                  lastUsedAt: a['last_used_at'] != null
                      ? DateTime.parse(a['last_used_at'] as String)
                      : null,
                  isActive: (a['is_active'] as int? ?? 0) == 1,
                ))
            .toList();
        _documents = dData;
      });
    } catch (_) {}
    if (mounted) setState(() => _isLoading = false);
  }

  TrainingSourceType _parseSource(String v) {
    switch (v) {
      case 'collection':
        return TrainingSourceType.collection;
      case 'extract_paste':
        return TrainingSourceType.extractPaste;
      case 'extract_file':
        return TrainingSourceType.extractFile;
      default:
        return TrainingSourceType.collection;
    }
  }

  // ─────────── actions ───────────

  void _nextStep() {
    if (_currentStep < 3) {
      setState(() => _currentStep++);
    } else {
      _startPersonalization();
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() {
        // If going back from extracts to sources, invalidate stale extracts
        if (_currentStep == 2) {
          _extractsReady = false;
          _extracts.clear();
        }
        _currentStep--;
      });
    }
  }

  bool get _canProceed {
    switch (_currentStep) {
      case 0:
        return _selectedGoal != null;
      case 1:
        return _selectedCollectionIds.isNotEmpty || _selectedDocumentIds.isNotEmpty;
      case 2:
        return _extractsReady && _extracts.isNotEmpty;
      case 3:
        return !_isGenerating;
      default:
        return false;
    }
  }

  String get _ctaLabel {
    switch (_currentStep) {
      case 0:
        return 'Continue';
      case 1:
        return 'Build Knowledge Pack';
      case 2:
        return 'Approve Extracts';
      case 3:
        return 'Personalize Model';
      default:
        return 'Continue';
    }
  }

  String? get _disabledHint {
    if (_canProceed) return null;
    switch (_currentStep) {
      case 0:
        return 'Select a goal to continue';
      case 1:
        return 'Select at least 1 document or collection';
      case 2:
        return 'Generate extracts first';
      default:
        return null;
    }
  }

  bool get _isRAGGoal => _selectedGoal == PersonalizationGoal.answerQuestions;

  /// Whether the user selected many docs with a non-RAG goal
  bool get _shouldSuggestRAG =>
      !_isRAGGoal &&
      (_selectedDocumentIds.length + _selectedCollectionIds.length) > 5;

  Future<void> _createInlineCollection() async {
    final name = _newCollectionCtrl.text.trim();
    if (name.isEmpty) return;
    final db = context.read<DatabaseService>();
    final id = 'col-${DateTime.now().millisecondsSinceEpoch}';
    await db.insertCollection({
      'id': id,
      'name': name,
      'created_at': DateTime.now().toIso8601String(),
    });
    _newCollectionCtrl.clear();
    setState(() => _showNewCollectionInput = false);
    await _loadData();
    setState(() => _selectedCollectionIds.add(id));
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['pdf', 'txt', 'md', 'doc', 'docx'],
      );
      if (result == null || !mounted) return;
      final db = context.read<DatabaseService>();
      for (final f in result.files) {
        if (f.path == null) continue;
        final id = 'doc-${DateTime.now().millisecondsSinceEpoch}-${f.name.hashCode}';
        await db.insertDocument({
          'id': id,
          'filename': f.name,
          'mime': 'application/octet-stream',
          'bytes': f.size,
          'created_at': DateTime.now().toIso8601String(),
        });
        // Save content for text files
        if (f.path != null && (f.name.endsWith('.txt') || f.name.endsWith('.md'))) {
          try {
            final content = await File(f.path!).readAsString();
            await db.saveDocumentContent(id, content);
          } catch (_) {}
        }
        _selectedDocumentIds.add(id);
      }
      await _loadData();
    } catch (_) {}
  }

  // ── Extract generation (via local inference) ──

  Future<void> _generateExtracts() async {
    setState(() {
      _isGenerating = true;
      _extracts.clear();
      _extractsReady = false;
    });

    final db = context.read<DatabaseService>();
    final inference = context.read<LocalInferenceService>();

    // Gather selected document content from the database
    final docs = _documents
        .where((d) => _selectedDocumentIds.contains(d['id']))
        .toList();

    final contentParts = <_DocContent>[];
    for (final d in docs) {
      final id = d['id'] as String;
      final name = d['filename'] as String? ?? 'Untitled';
      final text = await db.getDocumentContent(id);
      if (text != null && text.trim().isNotEmpty) {
        contentParts.add(_DocContent(id: id, name: name, text: text));
      }
    }

    if (!mounted) return;

    if (contentParts.isEmpty) {
      _showSnack(
        'No readable text found in the selected documents. '
        'Make sure documents are .txt or .md files with content.',
        isError: true,
      );
      setState(() => _isGenerating = false);
      return;
    }

    // Build extraction prompt based on enabled toggles
    final enabledCategories = <ExtractCategory, String>{};
    if (_togQA) {
      enabledCategories[ExtractCategory.qa] =
          'Q&A PAIRS — Generate question-and-answer pairs. '
          'Format each as:\nQ: [question]\nA: [answer]';
    }
    if (_togFacts) {
      enabledCategories[ExtractCategory.facts] =
          'KEY FACTS — List the most important factual statements, one per line.';
    }
    if (_togGlossary) {
      enabledCategories[ExtractCategory.glossary] =
          'GLOSSARY — Extract important terms, acronyms, and definitions. '
          'Format: Term: definition.';
    }
    if (_togRules) {
      enabledCategories[ExtractCategory.rules] =
          'RULES / CHECKLISTS — Extract rules, policies, must-do/must-not-do items.';
    }
    if (_togTemplates) {
      enabledCategories[ExtractCategory.templates] =
          'TEMPLATES / EXAMPLES — Extract document templates, example formats, or repeatable structures.';
    }

    if (enabledCategories.isEmpty) {
      setState(() {
        _isGenerating = false;
        _extractsReady = true; // empty but "ready"
      });
      return;
    }

    // Check if local inference is available
    if (!inference.available || inference.activeModel == null) {
      _showSnack(
        'Local inference (Ollama) is not available. '
        'Please start Ollama or switch to the Models screen to set up a model.',
        isError: true,
      );
      setState(() => _isGenerating = false);
      return;
    }

    // Process each document through local inference
    int extractId = 0;
    final allItems = <_ExtractItem>[];

    for (final doc in contentParts) {
      // Truncate very long documents to avoid overflowing context
      final truncated = doc.text.length > 12000
          ? '${doc.text.substring(0, 12000)}\n\n[... truncated — document continues ...]'
          : doc.text;

      final categoryInstructions = enabledCategories.entries
          .map((e) => '### ${e.value}')
          .join('\n\n');

      final prompt = '''Extract the following from this document.
Respond with ONLY the extracts, grouped under category headers.
Use the exact category headers shown below. Put each extract on its own line.

$categoryInstructions

--- DOCUMENT: ${doc.name} ---
$truncated
--- END DOCUMENT ---''';

      try {
        final response = await inference.chatCompletion(
          messages: [
            {'role': 'system', 'content': 'You are a precise extraction assistant. Output only the requested extracts, nothing else.'},
            {'role': 'user', 'content': prompt},
          ],
        );

        if (!mounted) return;

        if (response != null && response.trim().isNotEmpty) {
          // Parse the response into extract items by category
          final parsed = _parseExtractResponse(
            response,
            doc.name,
            enabledCategories.keys.toList(),
            extractId,
          );
          allItems.addAll(parsed);
          extractId += parsed.length;
        }
      } catch (e) {
        if (!mounted) return;
        _showSnack('Error extracting from ${doc.name}: $e', isError: true);
      }
    }

    if (!mounted) return;

    setState(() {
      _extracts = allItems;
      _isGenerating = false;
      _extractsReady = true;
    });

    if (allItems.isEmpty) {
      _showSnack('Extraction completed but no items were found. Try different documents or categories.');
    }
  }

  /// Parse the LLM's extract response into structured items.
  List<_ExtractItem> _parseExtractResponse(
    String response,
    String docName,
    List<ExtractCategory> enabledCategories,
    int startId,
  ) {
    final items = <_ExtractItem>[];
    int id = startId;

    // Try to split by category headers
    ExtractCategory currentCat = enabledCategories.first;
    final lines = response.split('\n');
    final buffer = StringBuffer();

    for (final line in lines) {
      final lower = line.toLowerCase().trim();

      // Detect category headers
      ExtractCategory? detected;
      if (lower.contains('q&a') || lower.contains('question') && lower.contains('answer')) {
        detected = ExtractCategory.qa;
      } else if (lower.contains('key fact') || lower.contains('facts')) {
        detected = ExtractCategory.facts;
      } else if (lower.contains('glossary') || lower.contains('definition') || lower.contains('terms')) {
        detected = ExtractCategory.glossary;
      } else if (lower.contains('rule') || lower.contains('checklist') || lower.contains('policy')) {
        detected = ExtractCategory.rules;
      } else if (lower.contains('template') || lower.contains('example') || lower.contains('format')) {
        detected = ExtractCategory.templates;
      }

      if (detected != null && enabledCategories.contains(detected) && _isHeaderLine(line)) {
        // Flush previous buffer
        final text = buffer.toString().trim();
        if (text.isNotEmpty) {
          items.addAll(_splitBufferIntoItems(text, currentCat, docName, id));
          id += items.length - (id - startId);
        }
        buffer.clear();
        currentCat = detected;
        continue;
      }

      // Skip empty lines between items, accumulate content
      if (line.trim().isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line.trim());
      } else if (buffer.isNotEmpty) {
        // Empty line = item separator
        buffer.write('\n\n');
      }
    }

    // Flush final buffer
    final text = buffer.toString().trim();
    if (text.isNotEmpty) {
      items.addAll(_splitBufferIntoItems(text, currentCat, docName, id));
    }

    return items;
  }

  bool _isHeaderLine(String line) {
    final trimmed = line.trim();
    // Header lines typically start with #, are all-caps, or have trailing colon/dashes
    return trimmed.startsWith('#') ||
        trimmed.startsWith('---') ||
        trimmed == trimmed.toUpperCase() && trimmed.length > 3 ||
        trimmed.endsWith(':');
  }

  List<_ExtractItem> _splitBufferIntoItems(
    String text,
    ExtractCategory category,
    String docName,
    int startId,
  ) {
    final items = <_ExtractItem>[];
    int id = startId;

    // Split on double newlines or Q:/A: boundaries for Q&A
    List<String> chunks;
    if (category == ExtractCategory.qa) {
      // Split on Q: boundaries
      chunks = text.split(RegExp(r'\n(?=Q:)', multiLine: true));
    } else {
      // Split on double newlines or numbered list items
      chunks = text
          .split(RegExp(r'\n\n+|\n(?=\d+\.\s)'))
          .where((c) => c.trim().isNotEmpty)
          .toList();
    }

    for (final chunk in chunks) {
      final clean = chunk.trim();
      if (clean.isEmpty || clean.length < 5) continue;
      items.add(_ExtractItem(
        id: 'e-${id++}',
        category: category,
        content: clean,
        sourceDoc: docName,
      ));
    }

    return items;
  }

  // ── Start personalization ──

  Future<void> _startPersonalization() async {
    final name = _adapterNameCtrl.text.trim().isEmpty
        ? 'Personal v${_adapters.length + 1}'
        : _adapterNameCtrl.text.trim();

    final inference = context.read<LocalInferenceService>();
    final db = context.read<DatabaseService>();
    final baseModelId = inference.activeModel ?? 'unknown-model';

    if (_isRAGGoal) {
      // RAG path — build knowledge index via training service
      _showSnack('Building knowledge index…');
      try {
        final result = await _trainingService.startTraining(
          baseModelId: baseModelId,
          adapterName: name,
          sourceType: 'collection',
          personalizationGoal: 'knowledge_library',
          documentIds: _selectedDocumentIds.toList(),
          collectionIds: _selectedCollectionIds.toList(),
        );

        if (result != null && result['run_id'] != null) {
          setState(() => _currentRunId = result['run_id'] as String);
          _startPolling();
          _showSnack('Knowledge Library indexing started!');
          _resetWizard();
        } else {
          _showSnack('Knowledge Library created locally. You can now ask questions over your documents.');
          _resetWizard();
        }
      } catch (e) {
        // Fallback: save adapter locally even if backend is unavailable
        final adapterId = 'adapter-${DateTime.now().millisecondsSinceEpoch}';
        await db.insertAdapter({
          'id': adapterId,
          'name': name,
          'base_model_id': baseModelId,
          'source_type': 'collection',
          'source_ref': _selectedCollectionIds.isNotEmpty ? _selectedCollectionIds.first : null,
          'disk_bytes': 0,
          'created_at': DateTime.now().toIso8601String(),
          'is_active': 0,
        });
        _showSnack('Knowledge Library saved locally (backend unavailable: $e).', isError: true);
        _resetWizard();
      }
      return;
    }

    // Adapter path — start training
    //
    // The user built extracts in step 2, so the curated extract text is the
    // primary training data.  We always set source_type = 'extract_paste'
    // when extract content is available so the backend uses the extracts
    // rather than raw collection chunks.  The collection/document IDs are
    // sent separately for provenance tracking.
    final extractContent = _extracts.map((e) => e.content).join('\n\n');

    String sourceType;
    String? sourceRef;

    if (extractContent.isNotEmpty) {
      // Extracts are the curated training data — send as paste
      sourceType = 'extract_paste';
      sourceRef = _selectedCollectionIds.isNotEmpty
          ? _selectedCollectionIds.first
          : _selectedDocumentIds.isNotEmpty
              ? _selectedDocumentIds.first
              : null;
    } else if (_selectedCollectionIds.isNotEmpty) {
      sourceType = 'collection';
      sourceRef = _selectedCollectionIds.first;
    } else if (_selectedDocumentIds.isNotEmpty) {
      sourceType = 'extract_file';
      sourceRef = _selectedDocumentIds.first;
    } else {
      sourceType = 'extract_paste';
    }

    // Map goal to API parameter
    final goalStr = switch (_selectedGoal) {
      PersonalizationGoal.writeInStyle => 'style_adapter',
      PersonalizationGoal.followRules => 'workflow_follower',
      PersonalizationGoal.improveDomain => 'domain_accuracy',
      _ => 'style_adapter',
    };

    _showSnack('Starting personalization…');

    try {
      final result = await _trainingService.startTraining(
        baseModelId: baseModelId,
        adapterName: name,
        sourceType: sourceType,
        sourceRef: sourceRef,
        extractContent: extractContent.isNotEmpty ? extractContent : null,
        personalizationGoal: goalStr,
        documentIds: _selectedDocumentIds.toList(),
        collectionIds: _selectedCollectionIds.toList(),
      );

      if (result != null && result['run_id'] != null) {
        // Save adapter record to local DB
        final adapterId = result['adapter_id'] as String? ??
            'adapter-${DateTime.now().millisecondsSinceEpoch}';
        await db.insertAdapter({
          'id': adapterId,
          'name': name,
          'base_model_id': baseModelId,
          'source_type': sourceType,
          'source_ref': sourceRef,
          'disk_bytes': 0,
          'created_at': DateTime.now().toIso8601String(),
          'is_active': 0,
        });

        setState(() {
          _currentRunId = result['run_id'] as String;
          _currentRunStatus = {'status': 'preparing', 'progress_percent': 0};
        });
        _startPolling();
        _showSnack('Personalization started!');
        _resetWizard();
      } else {
        _showSnack('Backend returned no run ID. Check if the training service is running on port 8106.', isError: true);
      }
    } catch (e) {
      _showSnack('Failed to start training: $e', isError: true);
    }
  }

  void _resetWizard() {
    setState(() {
      _currentStep = 0;
      _selectedGoal = null;
      _selectedCollectionIds.clear();
      _selectedDocumentIds.clear();
      _extracts.clear();
      _extractsReady = false;
      _adapterNameCtrl.clear();
    });
    _loadData();
  }

  // ── Adapter management ──

  Future<void> _activateAdapter(String id) async {
    try {
      await _trainingService.activateAdapter(id);
      if (!mounted) return;
      final db = context.read<DatabaseService>();
      await db.updateAdapter(id, {'is_active': 1, 'last_used_at': DateTime.now().toIso8601String()});
      for (final a in _adapters) {
        if (a.id != id && a.isActive) {
          await db.updateAdapter(a.id, {'is_active': 0});
        }
      }
      _loadData();
      _showSnack('Adapter activated');
    } catch (e) {
      _showSnack('Failed: $e', isError: true);
    }
  }

  Future<void> _deleteAdapter(String id) async {
    final adapter = _adapters.firstWhere((a) => a.id == id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Remove adapter?',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w500)),
        content: Text('This will permanently delete "${adapter.name}".',
            style: GoogleFonts.inter(fontSize: 10, color: Theme.of(context).colorScheme.secondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await _trainingService.deleteAdapter(id);
        if (!mounted) return;
        await context.read<DatabaseService>().deleteAdapter(id);
        _loadData();
        _showSnack('Adapter removed');
      } catch (e) {
        _showSnack('Failed: $e', isError: true);
      }
    }
  }

  Future<void> _rollbackAdapter(String id) async {
    final adapter = _adapters.firstWhere((a) => a.id == id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Rollback to base model?',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w500)),
        content: Text(
            'This will deactivate "${adapter.name}" and revert to the base model. The adapter is not deleted — you can reactivate it later.',
            style: GoogleFonts.inter(fontSize: 10, color: Theme.of(context).colorScheme.secondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rollback')),
        ],
      ),
    );
    if (ok == true && mounted) {
      final db = context.read<DatabaseService>();
      await db.updateAdapter(id, {'is_active': 0});
      _loadData();
      _showSnack('Rolled back to base model');
    }
  }

  // ── Polling ──

  void _startPolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (_currentRunId == null) {
        t.cancel();
        return;
      }
      final s = await _trainingService.getRunStatus(_currentRunId!);
      if (!mounted) return;
      setState(() {
        if (s != null) _currentRunStatus = s;
        final status = s?['status'] as String?;
        if (status == 'completed') {
          t.cancel();
          _currentRunId = null;
          _showSnack('Personalization complete! Your adapter is ready.');
          // Clear progress after a short delay so user sees 100%
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) setState(() => _currentRunStatus = null);
          });
          _loadData();
        } else if (status == 'failed') {
          t.cancel();
          _currentRunId = null;
          final errMsg = s?['error_message'] as String? ?? 'Unknown error';
          _showSnack('Training failed: $errMsg', isError: true);
          Future.delayed(const Duration(seconds: 5), () {
            if (mounted) setState(() => _currentRunStatus = null);
          });
          _loadData();
        }
      });
    });
  }

  // ── Helpers ──

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.inter(fontSize: 10)),
      behavior: SnackBarBehavior.floating,
      backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _fmtDate(DateTime d) {
    final diff = DateTime.now().difference(d).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return '$diff days ago';
    return '${d.month}/${d.day}/${d.year}';
  }

  // ═══════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
            Text('Personalize',
                style: GoogleFonts.spaceGrotesk(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Make the model yours — add knowledge or teach it your style.',
                style: GoogleFonts.inter(fontSize: 10, color: theme.colorScheme.secondary)),
            const SizedBox(height: 24),

            // ── Active training progress ──
            if (_currentRunStatus != null) ...[
              _buildRunProgress(theme),
              const SizedBox(height: 24),
            ],

            // ── Step indicator ──
            _buildStepIndicator(theme),
            const SizedBox(height: 24),

            // ── Wizard content ──
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _buildStep(theme),
            ),
            const SizedBox(height: 16),

            // ── Navigation buttons ──
            _buildNav(theme),

            const SizedBox(height: 40),

            // ── Existing personalized models ──
            _buildAdaptersSection(theme),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  STEP INDICATOR
  // ═══════════════════════════════════════════════════════════════

  Widget _buildStepIndicator(ThemeData theme) {
    return Column(
      children: [
        Row(children: _indicatorDots(theme)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(
            4,
            (i) => SizedBox(
              width: 72,
              child: Text(
                _stepLabels[i],
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 8,
                  fontWeight: i == _currentStep ? FontWeight.w600 : FontWeight.w400,
                  color: i <= _currentStep ? theme.colorScheme.onSurface : theme.colorScheme.secondary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _indicatorDots(ThemeData theme) {
    final w = <Widget>[];
    for (int i = 0; i < 4; i++) {
      if (i > 0) {
        w.add(Expanded(
          child: Container(
            height: 1.5,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: i <= _currentStep ? theme.colorScheme.primary : theme.dividerColor,
          ),
        ));
      }
      final done = i < _currentStep;
      final active = i == _currentStep;
      w.add(Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done || active ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: done || active ? theme.colorScheme.primary : theme.dividerColor,
            width: 1.5,
          ),
        ),
        child: Center(
          child: done
              ? Icon(Icons.check, size: 14, color: theme.colorScheme.onPrimary)
              : Text('${i + 1}',
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: active ? theme.colorScheme.onPrimary : theme.colorScheme.secondary,
                  )),
        ),
      ));
    }
    return w;
  }

  // ═══════════════════════════════════════════════════════════════
  //  WIZARD CONTENT DISPATCH
  // ═══════════════════════════════════════════════════════════════

  Widget _buildStep(ThemeData theme) {
    switch (_currentStep) {
      case 0:
        return _stepGoal(theme);
      case 1:
        return _stepSources(theme);
      case 2:
        return _stepExtracts(theme);
      case 3:
        return _stepApply(theme);
      default:
        return const SizedBox.shrink();
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  STEP 0 — PICK YOUR GOAL
  // ═══════════════════════════════════════════════════════════════

  Widget _stepGoal(ThemeData theme) {
    return Column(
      key: const ValueKey('step0'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Microcopy
        Text('Pick your goal',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Add knowledge (recommended) or teach the model (advanced).',
            style: GoogleFonts.inter(fontSize: 10, color: theme.colorScheme.secondary)),
        const SizedBox(height: 20),

        // ── RECOMMENDED ──
        _sectionLabel(theme, 'RECOMMENDED'),
        const SizedBox(height: 8),
        _recipeCard(
          theme,
          goal: PersonalizationGoal.answerQuestions,
          icon: Icons.menu_book_outlined,
          color: const Color(0xFF10B981),
          title: 'Knowledge Library',
          subtitle: 'Ask questions over your docs. No model changes.',
          benefits: const ['Fast', 'Reliable', 'Works on weak hardware'],
          limitations: const ["Doesn't change writing style", "Doesn't memorise content"],
          badge: 'Recommended',
        ),
        const SizedBox(height: 20),

        // ── ADVANCED ──
        _sectionLabel(theme, 'ADVANCED — TEACH THE MODEL'),
        const SizedBox(height: 4),
        Text('Creates a small personal adapter. Best for style and repeatable workflows, not memorising books.',
            style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
        const SizedBox(height: 12),
        _recipeCard(
          theme,
          goal: PersonalizationGoal.writeInStyle,
          icon: Icons.edit_note_outlined,
          color: theme.colorScheme.primary,
          title: 'Style & Tone Adapter',
          subtitle: 'Match your writing voice, structure, and brevity.',
          benefits: const ['Consistent voice', 'Format consistency', 'Adapts verbosity'],
          limitations: const ["Won't memorise long documents", "Won't guarantee factual accuracy"],
        ),
        const SizedBox(height: 8),
        _recipeCard(
          theme,
          goal: PersonalizationGoal.followRules,
          icon: Icons.rule_outlined,
          color: const Color(0xFF8B5CF6),
          title: 'Workflow / Policy Follower',
          subtitle: 'Follow your rules, ask required questions, output your schema.',
          benefits: const ['Workflow compliance', 'Rule enforcement', 'Schema consistency'],
          limitations: const ["Won't replace retrieval for factual Q&A", "Needs clear examples"],
        ),
        const SizedBox(height: 8),
        _recipeCard(
          theme,
          goal: PersonalizationGoal.improveDomain,
          icon: Icons.science_outlined,
          color: Colors.amber.shade700,
          title: 'Domain Accuracy',
          subtitle: 'Fine-tune for specialised tasks. Needs evaluation; can worsen things.',
          benefits: const ['Improved domain terminology', 'Task-specific responses'],
          limitations: const ['Can degrade general quality', 'Requires careful evaluation'],
          badge: 'Advanced',
          isWarning: true,
        ),
      ],
    );
  }

  Widget _recipeCard(
    ThemeData theme, {
    required PersonalizationGoal goal,
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required List<String> benefits,
    required List<String> limitations,
    String? badge,
    bool isWarning = false,
  }) {
    final selected = _selectedGoal == goal;
    return GestureDetector(
      onTap: () => setState(() => _selectedGoal = goal),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.06) : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? color : theme.dividerColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Accent icon
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(title,
                            style: GoogleFonts.spaceGrotesk(fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                      if (badge != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isWarning
                                ? Colors.amber.withValues(alpha: 0.15)
                                : const Color(0xFF10B981).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(badge,
                              style: GoogleFonts.inter(
                                fontSize: 8,
                                fontWeight: FontWeight.w600,
                                color: isWarning ? Colors.amber.shade700 : const Color(0xFF10B981),
                              )),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle, style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
                  const SizedBox(height: 10),
                  // Benefits
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: benefits
                        .map((b) => _chip(theme, b, color.withValues(alpha: 0.10), color))
                        .toList(),
                  ),
                  const SizedBox(height: 6),
                  // Limitations
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: limitations
                        .map((l) => _chip(theme, l, theme.colorScheme.secondary.withValues(alpha: 0.08),
                            theme.colorScheme.secondary))
                        .toList(),
                  ),
                ],
              ),
            ),
            // Radio indicator
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: selected ? color : theme.colorScheme.secondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: GoogleFonts.inter(fontSize: 8, color: fg, fontWeight: FontWeight.w500)),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Text(text,
        style: GoogleFonts.inter(
          fontSize: 8,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: theme.colorScheme.secondary,
        ));
  }

  // ═══════════════════════════════════════════════════════════════
  //  STEP 1 — SELECT SOURCES
  // ═══════════════════════════════════════════════════════════════

  Widget _stepSources(ThemeData theme) {
    return Column(
      key: const ValueKey('step1'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add your documents',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Drag & drop files or choose a collection.',
            style: GoogleFonts.inter(fontSize: 10, color: theme.colorScheme.secondary)),
        const SizedBox(height: 16),

        // ── RAG redirect guardrail ──
        if (_shouldSuggestRAG) ...[
          _guardrailBanner(theme),
          const SizedBox(height: 12),
        ],

        // ── Drop zone / file picker ──
        GestureDetector(
          onTap: _pickFiles,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 32),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: theme.dividerColor, width: 1),
            ),
            child: Column(
              children: [
                Icon(Icons.cloud_upload_outlined, size: 28, color: theme.colorScheme.secondary),
                const SizedBox(height: 8),
                Text('Drop files here or click to browse',
                    style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text('PDF, TXT, Markdown, DOCX',
                    style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // ── Collections ──
        Row(
          children: [
            Text('Collections',
                style: GoogleFonts.spaceGrotesk(fontSize: 10, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (!_showNewCollectionInput)
              TextButton.icon(
                onPressed: () => setState(() => _showNewCollectionInput = true),
                icon: const Icon(Icons.add, size: 14),
                label: Text('Create', style: GoogleFonts.inter(fontSize: 9)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Inline collection creation
        if (_showNewCollectionInput)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newCollectionCtrl,
                    autofocus: true,
                    style: GoogleFonts.inter(fontSize: 10),
                    decoration: InputDecoration(
                      hintText: 'Collection name',
                      hintStyle: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onSubmitted: (_) => _createInlineCollection(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
                  onPressed: _createInlineCollection,
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: theme.colorScheme.secondary),
                  onPressed: () => setState(() => _showNewCollectionInput = false),
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),

        if (_collections.isEmpty && !_showNewCollectionInput)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Column(
              children: [
                Icon(Icons.folder_outlined, size: 24, color: theme.colorScheme.secondary),
                const SizedBox(height: 8),
                Text('No collections yet',
                    style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text('Create one above to organise your documents.',
                    style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
              ],
            ),
          )
        else
          ..._collections.map((c) => _sourceItem(
                theme,
                label: c.name,
                subtitle: '${c.documentCount} documents',
                icon: Icons.folder_outlined,
                selected: _selectedCollectionIds.contains(c.id),
                onTap: () => setState(() {
                  if (_selectedCollectionIds.contains(c.id)) {
                    _selectedCollectionIds.remove(c.id);
                  } else {
                    _selectedCollectionIds.add(c.id);
                  }
                }),
              )),

        // ── Individual documents ──
        if (_documents.isNotEmpty) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Documents',
                  style: GoogleFonts.spaceGrotesk(fontSize: 10, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  if (_selectedDocumentIds.length == _documents.length) {
                    _selectedDocumentIds.clear();
                  } else {
                    _selectedDocumentIds = _documents.map((d) => d['id'] as String).toSet();
                  }
                }),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _selectedDocumentIds.length == _documents.length ? 'Deselect all' : 'Select all',
                  style: GoogleFonts.inter(fontSize: 9),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._documents.map((d) => _sourceItem(
                theme,
                label: d['filename'] as String? ?? 'Untitled',
                subtitle: _fmtBytes(d['bytes'] as int? ?? 0),
                icon: Icons.description_outlined,
                selected: _selectedDocumentIds.contains(d['id']),
                onTap: () => setState(() {
                  final id = d['id'] as String;
                  if (_selectedDocumentIds.contains(id)) {
                    _selectedDocumentIds.remove(id);
                  } else {
                    _selectedDocumentIds.add(id);
                  }
                }),
              )),
        ],
      ],
    );
  }

  Widget _sourceItem(
    ThemeData theme, {
    required String label,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : theme.dividerColor,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_box : Icons.check_box_outline_blank,
                size: 20,
                color: selected ? theme.colorScheme.primary : theme.colorScheme.secondary,
              ),
              const SizedBox(width: 10),
              Icon(icon, size: 18, color: theme.colorScheme.secondary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis),
                    Text(subtitle,
                        style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _guardrailBanner(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 18, color: Colors.amber.shade700),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("You're adding many sources with a style/workflow goal.",
                    style: GoogleFonts.inter(
                        fontSize: 10, fontWeight: FontWeight.w600, color: Colors.amber.shade800)),
                const SizedBox(height: 4),
                Text("For large document sets, Knowledge Library (RAG) gives better results than adapter training.",
                    style: GoogleFonts.inter(fontSize: 9, color: Colors.amber.shade700)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 28,
                  child: OutlinedButton(
                    onPressed: () => setState(() {
                      _selectedGoal = PersonalizationGoal.answerQuestions;
                      _currentStep = 0;
                    }),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      side: BorderSide(color: Colors.amber.shade700),
                      foregroundColor: Colors.amber.shade800,
                    ),
                    child: Text('Switch to Knowledge Library',
                        style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w500)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  STEP 2 — BUILD KNOWLEDGE PACK (EXTRACTS)
  // ═══════════════════════════════════════════════════════════════

  Widget _stepExtracts(ThemeData theme) {
    return Column(
      key: const ValueKey('step2'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('We build a Knowledge Pack',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text("We'll extract key facts, rules, and examples. You can review before applying.",
            style: GoogleFonts.inter(fontSize: 10, color: theme.colorScheme.secondary)),
        const SizedBox(height: 16),

        // ── Extraction toggles ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.dividerColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What to extract',
                  style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              _toggleRow(theme, 'Generate Q&A pairs', _togQA, (v) => setState(() => _togQA = v)),
              _toggleRow(theme, 'Extract key facts', _togFacts, (v) => setState(() => _togFacts = v)),
              _toggleRow(theme, 'Extract definitions / glossary', _togGlossary,
                  (v) => setState(() => _togGlossary = v)),
              _toggleRow(
                  theme, 'Extract rules / checklists', _togRules, (v) => setState(() => _togRules = v)),
              _toggleRow(theme, 'Extract examples / templates', _togTemplates,
                  (v) => setState(() => _togTemplates = v)),
              const SizedBox(height: 8),
              Divider(color: theme.dividerColor, height: 1),
              const SizedBox(height: 8),
              _toggleRow(theme, 'Use cloud model (faster) — off by default', _useCloudExtraction,
                  (v) => setState(() => _useCloudExtraction = v)),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Generate button ──
        if (!_extractsReady)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isGenerating ? null : _generateExtracts,
              icon: _isGenerating
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: theme.colorScheme.onPrimary))
                  : const Icon(Icons.auto_awesome, size: 16),
              label: Text(
                _isGenerating ? 'Generating extracts…' : 'Generate Extracts Locally',
                style: GoogleFonts.inter(fontSize: 10),
              ),
            ),
          ),

        // ── Extracts preview ──
        if (_extractsReady && _extracts.isNotEmpty) ...[
          const SizedBox(height: 20),
          _buildExtractsPreview(theme),
        ],

        if (_extractsReady && _extracts.isEmpty) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Center(
              child: Text('No extracts generated. Enable at least one option above.',
                  style: GoogleFonts.inter(fontSize: 10, color: theme.colorScheme.secondary)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _toggleRow(ThemeData theme, String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            height: 28,
            width: 40,
            child: FittedBox(
              child: Switch(value: value, onChanged: onChanged),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.onSurface)),
          ),
        ],
      ),
    );
  }

  Widget _buildExtractsPreview(ThemeData theme) {
    // Group extracts by category
    final grouped = <ExtractCategory, List<_ExtractItem>>{};
    for (final e in _extracts) {
      grouped.putIfAbsent(e.category, () => []).add(e);
    }

    // Active categories (those with items)
    final cats = grouped.keys.toList();
    if (!cats.contains(_activeExtractTab) && cats.isNotEmpty) {
      _activeExtractTab = cats.first;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Summary bar
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${_extracts.length} extracts generated across ${cats.length} categories.',
                    style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w500)),
              ),
              TextButton(
                onPressed: _generateExtracts,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('Regenerate', style: GoogleFonts.inter(fontSize: 9)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Category tabs
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: cats.map((cat) {
              final active = cat == _activeExtractTab;
              final label = _catLabel(cat);
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('$label (${grouped[cat]!.length})',
                      style: GoogleFonts.inter(fontSize: 8, fontWeight: FontWeight.w500)),
                  selected: active,
                  onSelected: (_) => setState(() => _activeExtractTab = cat),
                  selectedColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  side: BorderSide(
                      color: active ? theme.colorScheme.primary : theme.dividerColor),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),

        // Items list
        if (grouped.containsKey(_activeExtractTab))
          ...grouped[_activeExtractTab]!.map((item) => _extractItemCard(theme, item)),
      ],
    );
  }

  Widget _extractItemCard(ThemeData theme, _ExtractItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: item.isCritical ? theme.colorScheme.primary : theme.dividerColor,
          width: item.isCritical ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.content,
              style: GoogleFonts.inter(fontSize: 9, height: 1.5, color: theme.colorScheme.onSurface)),
          const SizedBox(height: 8),
          Row(
            children: [
              // Source citation
              if (item.sourceDoc != null) ...[
                Icon(Icons.description_outlined, size: 12, color: theme.colorScheme.secondary),
                const SizedBox(width: 4),
                Text(
                  '${item.sourceDoc}${item.sourcePage != null ? ' p.${item.sourcePage}' : ''}',
                  style: GoogleFonts.inter(fontSize: 8, color: theme.colorScheme.secondary),
                ),
              ],
              const Spacer(),
              // Mark critical
              InkWell(
                onTap: () => setState(() => item.isCritical = !item.isCritical),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        item.isCritical ? Icons.star : Icons.star_outline,
                        size: 14,
                        color: item.isCritical ? Colors.amber : theme.colorScheme.secondary,
                      ),
                      const SizedBox(width: 2),
                      Text('Critical',
                          style: GoogleFonts.inter(fontSize: 8, color: theme.colorScheme.secondary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Delete
              InkWell(
                onTap: () => setState(() => _extracts.remove(item)),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline, size: 14, color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _catLabel(ExtractCategory c) {
    switch (c) {
      case ExtractCategory.qa:
        return 'Q&A';
      case ExtractCategory.facts:
        return 'Facts';
      case ExtractCategory.glossary:
        return 'Glossary';
      case ExtractCategory.rules:
        return 'Rules';
      case ExtractCategory.templates:
        return 'Templates';
      case ExtractCategory.constraints:
        return 'Constraints';
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  STEP 3 — APPLY & TEST
  // ═══════════════════════════════════════════════════════════════

  Widget _stepApply(ThemeData theme) {
    return Column(
      key: const ValueKey('step3'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Apply & test',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text("We'll create a new personal version of your model. You can compare and rollback anytime.",
            style: GoogleFonts.inter(fontSize: 10, color: theme.colorScheme.secondary)),
        const SizedBox(height: 16),

        // ── Method card ──
        _methodCard(theme),
        const SizedBox(height: 16),

        // ── Hardware panel ──
        if (!_isRAGGoal) ...[
          _hardwarePanel(theme),
          const SizedBox(height: 16),
        ],

        // ── Name / versioning ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.dividerColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Save as', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _adapterNameCtrl,
                style: GoogleFonts.inter(fontSize: 10),
                decoration: InputDecoration(
                  hintText: 'Personal v${_adapters.length + 1}',
                  hintStyle: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 8),
              Text('You can compare this version against the base model and rollback anytime.',
                  style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _methodCard(ThemeData theme) {
    final isRAG = _isRAGGoal;
    final methodName = isRAG ? 'Knowledge Library (Index)' : 'Personal Adapter (LoRA)';
    final methodDesc = isRAG
        ? 'Creates a search index over your documents. Fast, no model changes, works on any hardware.'
        : 'Trains a small adapter layer on your extracts. Changes how the model writes and responds.';

    final benefitType = switch (_selectedGoal) {
      PersonalizationGoal.answerQuestions => 'Factual Q&A from your docs',
      PersonalizationGoal.writeInStyle => 'Style, tone, format consistency',
      PersonalizationGoal.followRules => 'Workflow compliance, rule enforcement',
      PersonalizationGoal.improveDomain => 'Domain terminology, task accuracy',
      null => '',
    };

    final nonBenefit = isRAG
        ? "Won't change writing style or memorise content"
        : "Won't reliably memorise long documents";

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isRAG ? Icons.search : Icons.tune, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(methodName,
                  style: GoogleFonts.spaceGrotesk(fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Text(methodDesc,
              style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
          const SizedBox(height: 12),
          _infoRow(theme, Icons.check_circle_outline, 'Expected benefit', benefitType,
              color: const Color(0xFF10B981)),
          const SizedBox(height: 4),
          _infoRow(theme, Icons.info_outline, 'Won\'t help with', nonBenefit,
              color: theme.colorScheme.secondary),
          if (!isRAG) ...[
            const SizedBox(height: 4),
            _infoRow(theme, Icons.timer_outlined, 'Estimated time', '5 – 30 min (depends on hardware)',
                color: theme.colorScheme.secondary),
            const SizedBox(height: 4),
            _infoRow(theme, Icons.storage_outlined, 'Disk impact', '10 – 200 MB adapter file',
                color: theme.colorScheme.secondary),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(ThemeData theme, IconData icon, String label, String value, {Color? color}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color ?? theme.colorScheme.secondary),
        const SizedBox(width: 6),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                    text: '$label: ',
                    style: GoogleFonts.inter(
                        fontSize: 9, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
                TextSpan(
                    text: value,
                    style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _hardwarePanel(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Will this work on my machine?',
                  style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          _hwRow(theme, 'GPU detected', 'Checking…', Icons.graphic_eq),
          _hwRow(theme, 'RAM available', '${_estimateRAM()} GB', Icons.developer_board),
          _hwRow(theme, 'Training on CPU', 'Slow (hours)', Icons.speed),
          _hwRow(theme, 'Recommended adapter', 'Small', Icons.tune),
          _hwRow(theme, 'Max doc size for training', '50 MB (use RAG for larger)', Icons.description_outlined),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Your data never leaves this device. Training runs entirely locally.',
              style: GoogleFonts.inter(fontSize: 9, color: Colors.amber.shade700),
            ),
          ),
        ],
      ),
    );
  }

  String _estimateRAM() {
    // Placeholder — in production, use actual system info
    return '16';
  }

  Widget _hwRow(ThemeData theme, String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
          ),
          Text(value,
              style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  NAVIGATION BUTTONS
  // ═══════════════════════════════════════════════════════════════

  Widget _buildNav(ThemeData theme) {
    final hint = _disabledHint;
    return Column(
      children: [
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(hint,
                style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
          ),
        Row(
          children: [
            if (_currentStep > 0)
              OutlinedButton(
                onPressed: _prevStep,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                child: Text('Back', style: GoogleFonts.inter(fontSize: 10)),
              ),
            if (_currentStep > 0) const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _canProceed ? _nextStep : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(_ctaLabel, style: GoogleFonts.inter(fontSize: 10)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  ACTIVE TRAINING PROGRESS
  // ═══════════════════════════════════════════════════════════════

  Widget _buildRunProgress(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 10),
              Text('Personalization in progress',
                  style: GoogleFonts.spaceGrotesk(fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: (_currentRunStatus!['progress_percent'] as num? ?? 0) / 100,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(_currentRunStatus!['progress_percent'] as num? ?? 0).toStringAsFixed(0)}%',
                style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary),
              ),
              if (_currentRunStatus!['eta_seconds'] != null)
                Text(
                  'ETA: ${(_currentRunStatus!['eta_seconds'] as int) ~/ 60} min',
                  style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Runs entirely on this device.',
              style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  PERSONALIZED MODELS LIST
  // ═══════════════════════════════════════════════════════════════

  Widget _buildAdaptersSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your personalized models',
            style: GoogleFonts.spaceGrotesk(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (_adapters.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 32),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Center(
              child: Text('No personalized models yet. Complete the wizard above to create one.',
                  style: GoogleFonts.inter(fontSize: 10, color: theme.colorScheme.secondary)),
            ),
          )
        else
          ..._adapters.asMap().entries.map((entry) {
            final i = entry.key;
            final a = entry.value;
            return _adapterCard(theme, a, i);
          }),
      ],
    );
  }

  Widget _adapterCard(ThemeData theme, Adapter a, int index) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: a.isActive ? theme.colorScheme.primary : theme.dividerColor,
          width: a.isActive ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(a.name,
                        style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w500)),
                    if (a.isActive) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('Active',
                            style: GoogleFonts.inter(
                                fontSize: 8,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.primary)),
                      ),
                    ],
                  ],
                ),
              ),
              // Version badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('v${index + 1}',
                    style: GoogleFonts.inter(fontSize: 8, color: theme.colorScheme.secondary)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(_fmtBytes(a.diskBytes),
                  style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
              const SizedBox(width: 8),
              Text('• ${_fmtDate(a.createdAt)}',
                  style: GoogleFonts.inter(fontSize: 9, color: theme.colorScheme.secondary)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (!a.isActive)
                _miniButton(theme, 'Activate', Icons.play_arrow, () => _activateAdapter(a.id)),
              if (a.isActive)
                _miniButton(theme, 'Compare vs base', Icons.compare_arrows, () {
                  context.go('/arena');
                }),
              if (a.isActive) const SizedBox(width: 8),
              if (a.isActive)
                _miniButton(theme, 'Rollback', Icons.undo, () => _rollbackAdapter(a.id)),
              const Spacer(),
              InkWell(
                onTap: () => _deleteAdapter(a.id),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline, size: 16, color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniButton(ThemeData theme, String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: theme.colorScheme.secondary),
            const SizedBox(width: 4),
            Text(label,
                style: GoogleFonts.inter(
                    fontSize: 8, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface)),
          ],
        ),
      ),
    );
  }
}
