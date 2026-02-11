// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/local_inference_service.dart';
import 'package:studiomc_app/services/model_manager_service.dart';
import 'package:studiomc_app/services/settings_service.dart';
import 'package:studiomc_app/widgets/chat/groundedness_meter.dart';

class ContextPanel extends StatelessWidget {
  final ChatMode chatMode;
  final String modelName;
  final SpeedRating speedRating;
  final double tokPerS;
  final List<Citation> citations;
  final double groundedness;
  final int groundednessSupportedCount;
  final int groundednessTotalCount;
  final List<String> groundednessUnsupported;
  final List<TraceStep> traceSteps;
  final VoidCallback? onModelSelected;

  const ContextPanel({
    super.key,
    required this.chatMode,
    required this.modelName,
    required this.speedRating,
    required this.tokPerS,
    this.citations = const [],
    this.groundedness = 0.0,
    this.groundednessSupportedCount = 0,
    this.groundednessTotalCount = 0,
    this.groundednessUnsupported = const [],
    this.traceSteps = const [],
    this.onModelSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<SettingsService>();
    final hasModel = settings.hasActiveModel;

    // If in chat mode and no model → show model browser
    final showModelBrowser = chatMode == ChatMode.chat && !hasModel;

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Icon(
                  showModelBrowser ? Icons.download_rounded : _modeIcon(),
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  showModelBrowser ? 'Get Started' : _modeTitle(),
                  style: GoogleFonts.spaceGrotesk(
                      fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),

          // Content
          Expanded(
            child: showModelBrowser
                ? _ModelBrowserPanel(onModelSelected: onModelSelected)
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: _buildContent(context, theme),
                  ),
          ),
        ],
      ),
    );
  }

  IconData _modeIcon() {
    switch (chatMode) {
      case ChatMode.chat:
        return Icons.info_outline_rounded;
      case ChatMode.docs:
        return Icons.description_outlined;
      case ChatMode.investigate:
        return Icons.search_rounded;
    }
  }

  String _modeTitle() {
    switch (chatMode) {
      case ChatMode.chat:
        return 'Model Info';
      case ChatMode.docs:
        return 'Sources';
      case ChatMode.investigate:
        return 'Trace';
    }
  }

  Widget _buildContent(BuildContext context, ThemeData theme) {
    switch (chatMode) {
      case ChatMode.chat:
        return _buildChatPanel(theme);
      case ChatMode.docs:
        return _buildDocsPanel(theme);
      case ChatMode.investigate:
        return _buildInvestigatePanel(theme);
    }
  }

  // ── Chat mode: Model info ──

  Widget _buildChatPanel(ThemeData theme) {
    final speedColor = _speedColor(speedRating);
    final speedLabel = _speedLabel(speedRating);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Model
        const _SectionLabel(label: 'Model'),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: theme.dividerColor),
          ),
          child: Row(
            children: [
              Icon(Icons.smart_toy_outlined,
                  size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(modelName,
                    style: GoogleFonts.inter(
                        fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Speed + Throughput side by side
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionLabel(label: 'Speed'),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: speedColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.speed_rounded,
                            size: 12, color: speedColor),
                        const SizedBox(width: 4),
                        Text(speedLabel,
                            style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: speedColor)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionLabel(label: 'Throughput'),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: theme.scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: theme.dividerColor),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt_rounded,
                            size: 12, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text('${tokPerS.toStringAsFixed(1)} tok/s',
                            style: GoogleFonts.jetBrainsMono(
                                fontSize: 10, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        // ── Available models to download ──
        const SizedBox(height: 14),
        Divider(height: 1, color: theme.dividerColor),
        const SizedBox(height: 10),
        const _SectionLabel(label: 'Available Models'),
        const SizedBox(height: 6),
        const _OllamaModelList(),
      ],
    );
  }

  // ── Docs mode ──

  Widget _buildDocsPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel(label: 'Groundedness'),
        const SizedBox(height: 4),
        GroundednessMeter(
          percentage: groundedness,
          sourceCount: citations.length,
          supportedCount: groundednessSupportedCount,
          totalCount: groundednessTotalCount,
          unsupportedClaims: groundednessUnsupported,
        ),
        const SizedBox(height: 10),
        _SectionLabel(label: 'Citations (${citations.length})'),
        const SizedBox(height: 4),
        if (citations.isEmpty)
          Text('No citations available',
              style: GoogleFonts.inter(fontSize: 10, color: theme.hintColor))
        else
          ...citations.asMap().entries.map((entry) {
            final idx = entry.key;
            final citation = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 18,
                          height: 18,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text('${idx + 1}',
                              style: GoogleFonts.inter(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.primary)),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(citation.filename,
                              style: GoogleFonts.inter(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(citation.snippet,
                        style: GoogleFonts.inter(
                            fontSize: 9, height: 1.3, color: theme.hintColor),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  // ── Investigate mode ──

  Widget _buildInvestigatePanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel(label: 'Groundedness'),
        const SizedBox(height: 4),
        GroundednessMeter(
          percentage: groundedness,
          sourceCount: citations.length,
          supportedCount: groundednessSupportedCount,
          totalCount: groundednessTotalCount,
          unsupportedClaims: groundednessUnsupported,
          compact: true,
        ),
        const SizedBox(height: 10),
        _SectionLabel(label: 'Trace Steps (${traceSteps.length})'),
        const SizedBox(height: 6),
        if (traceSteps.isEmpty)
          Text('No trace data available',
              style: GoogleFonts.inter(fontSize: 10, color: theme.hintColor))
        else
          ...traceSteps.asMap().entries.map((entry) {
            final idx = entry.key;
            final step = entry.value;
            final isLast = idx == traceSteps.length - 1;

            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: Column(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        if (!isLast)
                          Expanded(
                            child: Container(
                              width: 1.5,
                              color: theme.dividerColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: theme.scaffoldBackgroundColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: theme.dividerColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _traceStepIcon(step.type),
                                  size: 14,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    step.type,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${step.durationMs}ms',
                                  style: GoogleFonts.jetBrainsMono(
                                    fontSize: 9,
                                    color: theme.colorScheme.secondary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              step.description,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(height: 1.4),
                            ),
                            if (step.result.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                step.result,
                                style: GoogleFonts.jetBrainsMono(
                                  fontSize: 9,
                                  color: theme.colorScheme.secondary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  IconData _traceStepIcon(String type) {
    switch (type.toLowerCase()) {
      case 'search':
        return Icons.search_rounded;
      case 'retrieve':
        return Icons.download_rounded;
      case 'generate':
        return Icons.auto_awesome;
      case 'rank':
        return Icons.sort_rounded;
      default:
        return Icons.circle_outlined;
    }
  }

  Color _speedColor(SpeedRating rating) {
    switch (rating) {
      case SpeedRating.fast:
        return const Color(0xFF10B981);
      case SpeedRating.ok:
        return const Color(0xFFF59E0B);
      case SpeedRating.slow:
        return const Color(0xFFF97316);
      case SpeedRating.painful:
        return const Color(0xFFEF4444);
    }
  }

  String _speedLabel(SpeedRating rating) {
    switch (rating) {
      case SpeedRating.fast:
        return 'Fast';
      case SpeedRating.ok:
        return 'OK';
      case SpeedRating.slow:
        return 'Slow';
      case SpeedRating.painful:
        return 'Painful';
    }
  }
}

// ─── Model Browser Panel (shown when no model is selected) ──────────────────

class _ModelBrowserPanel extends StatefulWidget {
  final VoidCallback? onModelSelected;

  const _ModelBrowserPanel({this.onModelSelected});

  @override
  State<_ModelBrowserPanel> createState() => _ModelBrowserPanelState();
}

class _ModelBrowserPanelState extends State<_ModelBrowserPanel> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _availableModels = [];
  bool _isLoading = true;
  String? _downloadingId;
  String? _error;

  // Curated starter models (popular, well-tested, small enough for most hardware)
  static const _starterModels = [
    {
      'id': 'microsoft/phi-2',
      'name': 'Phi-2',
      'org': 'Microsoft',
      'size': '2.7B',
      'description': 'Compact, fast reasoning model. Great for coding and math.',
      'vram': '~5 GB',
      'recommended': true,
    },
    {
      'id': 'mistralai/Mistral-7B-Instruct-v0.3',
      'name': 'Mistral 7B Instruct',
      'org': 'Mistral AI',
      'size': '7B',
      'description': 'Excellent all-rounder for chat, writing, and analysis.',
      'vram': '~14 GB',
      'recommended': false,
    },
    {
      'id': 'TinyLlama/TinyLlama-1.1B-Chat-v1.0',
      'name': 'TinyLlama 1.1B',
      'org': 'TinyLlama',
      'size': '1.1B',
      'description': 'Ultra-lightweight. Runs on almost any machine.',
      'vram': '~2 GB',
      'recommended': false,
    },
    {
      'id': 'meta-llama/Llama-3.2-3B-Instruct',
      'name': 'Llama 3.2 3B',
      'org': 'Meta',
      'size': '3B',
      'description': 'Latest Meta model. Strong instruction following.',
      'vram': '~6 GB',
      'recommended': false,
    },
    {
      'id': 'Qwen/Qwen2.5-7B-Instruct',
      'name': 'Qwen 2.5 7B',
      'org': 'Alibaba',
      'size': '7B',
      'description': 'Multilingual powerhouse with strong reasoning.',
      'vram': '~14 GB',
      'recommended': false,
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    try {
      final modelManager = context.read<ModelManagerService>();
      final models = await modelManager.listModels();
      if (mounted) {
        setState(() {
          _availableModels = models;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _downloadModel(Map<String, dynamic> model) async {
    final modelId = model['id'] as String;
    setState(() {
      _downloadingId = modelId;
      _error = null;
    });

    try {
      final modelManager = context.read<ModelManagerService>();
      await modelManager.addModel(sourceRef: modelId);

      // Set as active model
      final settings = context.read<SettingsService>();
      settings.activeModelId = modelId;

      if (mounted) {
        setState(() => _downloadingId = null);
      }
      widget.onModelSelected?.call();
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadingId = null;
          _error = 'Failed to add model: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _searchController.text.toLowerCase();

    final filteredModels = query.isEmpty
        ? _starterModels
        : _starterModels
            .where((m) =>
                (m['name'] as String).toLowerCase().contains(query) ||
                (m['org'] as String).toLowerCase().contains(query) ||
                (m['id'] as String).toLowerCase().contains(query))
            .toList();

    return Column(
      children: [
        // Prompt
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Choose a model to get started. We\'ll download it for you.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.secondary,
              height: 1.4,
            ),
          ),
        ),

        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search models…',
              hintStyle: GoogleFonts.inter(
                fontSize: 13,
                color: theme.colorScheme.secondary.withValues(alpha: 0.6),
              ),
              prefixIcon: Icon(Icons.search, size: 18,
                  color: theme.colorScheme.secondary),
              filled: true,
              fillColor: theme.scaffoldBackgroundColor,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: theme.dividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: theme.dividerColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                    color: theme.colorScheme.primary, width: 1.5),
              ),
              isDense: true,
            ),
            style: GoogleFonts.inter(fontSize: 13),
          ),
        ),

        // Error
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ),

        // Model list
        Expanded(
          child: _isLoading
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  itemCount: filteredModels.length,
                  itemBuilder: (context, index) {
                    final model = filteredModels[index];
                    final isRecommended = model['recommended'] == true;
                    final isDownloading = _downloadingId == model['id'];

                    return _ModelCard(
                      model: model,
                      isRecommended: isRecommended,
                      isDownloading: isDownloading,
                      onTap: () => _downloadModel(model),
                    );
                  },
                ),
        ),

        // HuggingFace search hint
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.info_outline,
                  size: 14, color: theme.colorScheme.secondary),
              const SizedBox(width: 6),
              Text(
                'Or paste any HuggingFace model ID',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: theme.colorScheme.secondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  final Map<String, dynamic> model;
  final bool isRecommended;
  final bool isDownloading;
  final VoidCallback onTap;

  const _ModelCard({
    required this.model,
    required this.isRecommended,
    required this.isDownloading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: isRecommended
            ? theme.colorScheme.primary.withValues(alpha: 0.04)
            : theme.cardColor,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: isDownloading ? null : onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isRecommended
                    ? theme.colorScheme.primary.withValues(alpha: 0.3)
                    : theme.dividerColor,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        model['name'] as String,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (isRecommended)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Recommended',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${model['org']}  •  ${model['size']}  •  ${model['vram']}',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: theme.colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  model['description'] as String,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 32,
                  child: isDownloading
                      ? Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: onTap,
                          icon: Icon(Icons.download_rounded, size: 16),
                          label: Text('Download & Use',
                              style: GoogleFonts.inter(fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.primary,
                            side: BorderSide(
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.4)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Compact Ollama model list with pull support ────────────────────────────

class _OllamaModelList extends StatefulWidget {
  const _OllamaModelList();

  @override
  State<_OllamaModelList> createState() => _OllamaModelListState();
}

class _OllamaModelListState extends State<_OllamaModelList> {
  /// Curated models that can be pulled via Ollama.
  static const _catalog = [
    _CatalogModel('llama3.2', 'Llama 3.2', 'Meta', '3B', '2.0 GB'),
    _CatalogModel('llama3.2:1b', 'Llama 3.2 1B', 'Meta', '1B', '1.3 GB'),
    _CatalogModel('llama3.1', 'Llama 3.1', 'Meta', '8B', '4.7 GB'),
    _CatalogModel('mistral', 'Mistral 7B', 'Mistral AI', '7B', '4.1 GB'),
    _CatalogModel('phi3', 'Phi-3 Mini', 'Microsoft', '3.8B', '2.3 GB'),
    _CatalogModel('qwen2.5', 'Qwen 2.5', 'Alibaba', '7B', '4.7 GB'),
    _CatalogModel('gemma2', 'Gemma 2', 'Google', '9B', '5.4 GB'),
    _CatalogModel('deepseek-r1:8b', 'DeepSeek R1', 'DeepSeek', '8B', '4.9 GB'),
    _CatalogModel(
        'codellama', 'Code Llama', 'Meta', '7B', '3.8 GB'),
  ];

  Set<String> _installed = {};
  String? _pullingTag;
  double _pullProgress = 0;

  @override
  void initState() {
    super.initState();
    _refreshInstalled();
  }

  void _refreshInstalled() {
    final local = context.read<LocalInferenceService>();
    _installed = local.models.map((m) => m.name).toSet();
  }

  bool _isInstalled(String tag) {
    // Exact match: "llama3.2:1b" in installed
    if (_installed.contains(tag)) return true;
    // Tag without variant matches ":latest": "llama3.2" → "llama3.2:latest"
    if (!tag.contains(':') && _installed.contains('$tag:latest')) return true;
    return false;
  }

  Future<void> _pullModel(String tag) async {
    setState(() {
      _pullingTag = tag;
      _pullProgress = 0;
    });

    try {
      final request = http.Request(
          'POST', Uri.parse('http://127.0.0.1:11434/api/pull'));
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode({'name': tag, 'stream': true});

      final client = http.Client();
      final response = await client.send(request);

      await for (final chunk in response.stream.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (line.trim().isEmpty) continue;
          try {
            final json = jsonDecode(line) as Map<String, dynamic>;
            final total = json['total'] as int? ?? 0;
            final completed = json['completed'] as int? ?? 0;
            if (total > 0 && mounted) {
              setState(() => _pullProgress = completed / total);
            }
            if (json['status'] == 'success') {
              // Refresh the local service
              final local = context.read<LocalInferenceService>();
              await local.init(preferredModel: tag);
              if (mounted) {
                _refreshInstalled();
                setState(() {
                  _pullingTag = null;
                  _pullProgress = 0;
                });
              }
              client.close();
              return;
            }
          } catch (_) {}
        }
      }
      client.close();
    } catch (e) {
      if (mounted) {
        setState(() {
          _pullingTag = null;
          _pullProgress = 0;
        });
      }
    }
  }

  void _selectModel(String tag) {
    final local = context.read<LocalInferenceService>();
    final settings = context.read<SettingsService>();
    local.selectModel(tag);
    settings.activeModelId = tag;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localInference = context.watch<LocalInferenceService>();
    final activeTag = localInference.activeModel;

    // Build combined list: installed models first, then catalog (not installed)
    final catalogTags = _catalog.map((c) => c.tag.split(':').first).toSet();
    final installedExtra = localInference.models
        .where((m) => !catalogTags.contains(m.name.split(':').first))
        .map((m) => _CatalogModel(
              m.name,
              localInference.humanName(m.name),
              m.family.isNotEmpty ? m.family : '—',
              m.parameterSize,
              '${(m.sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB',
            ))
        .toList();

    final allModels = [...installedExtra, ..._catalog];

    return Column(
      children: allModels.map((m) {
        final installed = _isInstalled(m.tag);
        final isActive = activeTag == m.tag ||
            activeTag == '${m.tag.split(':').first}:latest' ||
            m.tag == '${activeTag?.split(':').first}';
        final isPulling = _pullingTag == m.tag;

        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: InkWell(
            onTap: installed && !isActive ? () => _selectModel(m.tag) : null,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: isActive
                    ? theme.colorScheme.primary.withValues(alpha: 0.06)
                    : theme.scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isActive
                      ? theme.colorScheme.primary.withValues(alpha: 0.3)
                      : theme.dividerColor,
                ),
              ),
              child: Row(
                children: [
                  // Model info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.name,
                            style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface)),
                        const SizedBox(height: 1),
                        Text('${m.org} · ${m.params} · ${m.size}',
                            style: GoogleFonts.inter(
                                fontSize: 8,
                                color: theme.colorScheme.secondary)),
                      ],
                    ),
                  ),
                  // Action
                  if (isPulling)
                    SizedBox(
                      width: 50,
                      child: Column(
                        children: [
                          SizedBox(
                            width: 40,
                            height: 3,
                            child: LinearProgressIndicator(
                              value: _pullProgress > 0 ? _pullProgress : null,
                              backgroundColor:
                                  theme.dividerColor,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${(_pullProgress * 100).toInt()}%',
                            style: GoogleFonts.inter(
                                fontSize: 7,
                                color: theme.colorScheme.secondary),
                          ),
                        ],
                      ),
                    )
                  else if (isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text('Active',
                          style: GoogleFonts.inter(
                              fontSize: 8,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary)),
                    )
                  else if (installed)
                    InkWell(
                      onTap: () => _selectModel(m.tag),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(color: theme.dividerColor),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text('Use',
                            style: GoogleFonts.inter(
                                fontSize: 8,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.secondary)),
                      ),
                    )
                  else
                    InkWell(
                      onTap: () => _pullModel(m.tag),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.08),
                          border: Border.all(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.3)),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.download_rounded,
                                size: 10,
                                color: theme.colorScheme.primary),
                            const SizedBox(width: 2),
                            Text('Pull',
                                style: GoogleFonts.inter(
                                    fontSize: 8,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.primary)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _CatalogModel {
  final String tag;
  final String name;
  final String org;
  final String params;
  final String size;

  const _CatalogModel(this.tag, this.name, this.org, this.params, this.size);
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: GoogleFonts.inter(
        fontSize: 8,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: Theme.of(context).colorScheme.secondary,
      ),
    );
  }
}
