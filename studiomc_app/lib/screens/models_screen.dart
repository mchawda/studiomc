import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';
import 'package:studiomc_app/services/inference_service.dart';
import 'package:studiomc_app/services/model_service.dart';
import 'package:studiomc_app/services/database_service.dart';
import 'package:studiomc_app/widgets/models/model_card.dart';
import 'package:studiomc_app/widgets/models/recommended_hero_card.dart';

class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  bool _isLoading = true;
  String? _error;

  List<AIModel> _installedModels = [];
  List<CuratedModel> _curatedModels = [];
  AIModel? _recommendedModel;
  AutopilotResult? _recommendation;
  String? _activeModelId;

  // Download state tracking
  final Map<String, StreamSubscription<Map<String, dynamic>>>
      _downloadSubscriptions = {};
  final Map<String, double> _downloadProgress = {};
  final Map<String, DownloadStatus> _downloadStatuses = {};

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    for (final sub in _downloadSubscriptions.values) {
      sub.cancel();
    }
    super.dispose();
  }

  Future<void> _loadModels() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final api = context.read<ApiClient>();
    final db = context.read<DatabaseService>();

    try {
      // Always re-check backend availability (don't rely on cached flag)
      final backendUp = await api.checkAvailable();

      if (backendUp) {
        await _loadFromBackend();
      } else {
        await _loadFromDb(db);
        _error =
            'Backend not available. Showing locally cached models. Start the service to manage models.';
      }

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Failed to load models: $e';
      });
    }
  }

  Future<void> _loadFromBackend() async {
    final modelService = ModelService();

    // Fetch all data in parallel
    final results = await Future.wait([
      modelService.listModels(),
      modelService.getCuratedModels(),
    ]);

    final allModels = results[0] as List<AIModel>;
    final curated = results[1] as List<CuratedModel>;

    // Separate installed (ready) vs not
    _installedModels =
        allModels.where((m) => m.downloadStatus == DownloadStatus.ready).toList();
    _activeModelId =
        _installedModels.where((m) => m.isActive).firstOrNull?.id;

    // Find recommended model
    _recommendedModel =
        allModels.where((m) => m.isRecommended).firstOrNull;

    // Filter curated models to only show ones not already installed
    final installedIds = _installedModels.map((m) => m.id).toSet();
    _curatedModels =
        curated.where((c) => !installedIds.contains(c.id)).toList();

    // Try to get hardware-based recommendation
    try {
      final inference = context.read<InferenceService>();
      final models = await inference.getModels();
      if (models.isNotEmpty) {
        _activeModelId ??= models.first['id'] as String?;
      }
    } catch (_) {
      // Not critical
    }
  }

  Future<void> _loadFromDb(DatabaseService db) async {
    final rows = await db.getModels();
    _installedModels = rows
        .map((r) => AIModel(
              id: r['id'] as String,
              name: r['name'] as String,
              source: ModelSource.local,
              paramsBillion:
                  (r['params_billion'] as num?)?.toDouble() ?? 0,
              diskBytes: (r['disk_bytes'] as num?)?.toInt() ?? 0,
              contextMax: (r['context_max'] as num?)?.toInt() ?? 4096,
              speedRating: SpeedRating.ok,
              predictedTokPerS: 0,
              predictedTtftMs: 0,
              sizeLabel: '',
              downloadStatus: DownloadStatus.ready,
            ))
        .toList();
  }

  SpeedRating _parseSpeedRating(String? rating) {
    switch (rating) {
      case 'fast':
        return SpeedRating.fast;
      case 'ok':
        return SpeedRating.ok;
      case 'slow':
        return SpeedRating.slow;
      case 'painful':
        return SpeedRating.painful;
      default:
        return SpeedRating.ok;
    }
  }

  Future<void> _handleModelTap(AIModel model) async {
    if (model.downloadStatus != DownloadStatus.ready) return;

    if (model.speedRating == SpeedRating.painful) {
      _showGuardrailDialog(model);
    } else {
      await _activateModel(model);
    }
  }

  void _showGuardrailDialog(AIModel model) {
    final theme = Theme.of(context);
    final recommended = _recommendedModel;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text('Slow Performance Warning',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 9,
              fontWeight: FontWeight.w600,
            )),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${model.name} will be slow on your hardware.',
              style: GoogleFonts.inter(fontSize: 9, height: 1.5),
            ),
            if (recommended != null) ...[
              const SizedBox(height: 12),
              Text(
                'Recommended alternative: ${recommended.name} (predicted fast).',
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (recommended != null)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _activateModel(recommended);
              },
              child: const Text('Use recommended'),
            ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _activateModel(model);
            },
            child: const Text('Run anyway'),
          ),
        ],
      ),
    );
  }

  Future<void> _activateModel(AIModel model) async {
    final api = context.read<ApiClient>();

    try {
      if (api.isAvailable) {
        final inference = context.read<InferenceService>();
        await inference.selectModel(model.id);
      }

      setState(() {
        _installedModels = _installedModels.map((m) {
          return AIModel(
            id: m.id,
            name: m.name,
            source: m.source,
            sourceRef: m.sourceRef,
            paramsBillion: m.paramsBillion,
            quant: m.quant,
            diskBytes: m.diskBytes,
            arch: m.arch,
            contextMax: m.contextMax,
            checksum: m.checksum,
            speedRating: m.speedRating,
            predictedTokPerS: m.predictedTokPerS,
            predictedTtftMs: m.predictedTtftMs,
            sizeLabel: m.sizeLabel,
            isActive: m.id == model.id,
            isRecommended: m.isRecommended,
            lastUsedAt: m.lastUsedAt,
            downloadStatus: m.downloadStatus,
            downloadProgress: m.downloadProgress,
          );
        }).toList();
        _activeModelId = model.id;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Switched to ${model.name}',
              style: GoogleFonts.inter(fontSize: 9),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to activate model: $e')),
        );
      }
    }
  }

  Future<void> _handleDownloadCurated(CuratedModel curated) async {
    final api = context.read<ApiClient>();

    if (!api.isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Backend not available. Cannot download.')),
        );
      }
      return;
    }

    final modelService = ModelService();

    try {
      // Add the model first
      final model = await modelService.addModel(
        source: curated.source,
        sourceRef: curated.sourceRef,
      );

      if (model == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to add model')),
          );
        }
        return;
      }

      setState(() {
        _downloadStatuses[curated.id] = DownloadStatus.downloading;
        _downloadProgress[curated.id] = 0;
      });

      // Start download and watch progress
      await modelService.resumeDownload(model.id);

      _downloadSubscriptions[curated.id]?.cancel();
      _downloadSubscriptions[curated.id] =
          modelService.watchDownloadProgress(model.id).listen(
        (status) {
          if (!mounted) return;
          final progress =
              (status['progress'] as num?)?.toDouble() ?? 0;
          final isDone = status['status'] == 'ready';
          final isError = status['status'] == 'error';

          setState(() {
            if (isDone) {
              _downloadStatuses.remove(curated.id);
              _downloadProgress.remove(curated.id);
              _curatedModels.removeWhere((c) => c.id == curated.id);

              // Add to installed list
              _installedModels.add(AIModel(
                id: model.id,
                name: model.name,
                source: model.source,
                paramsBillion: model.paramsBillion,
                diskBytes: model.diskBytes,
                contextMax: model.contextMax,
                speedRating: model.speedRating,
                predictedTokPerS: model.predictedTokPerS,
                predictedTtftMs: model.predictedTtftMs,
                sizeLabel: model.sizeLabel,
                downloadStatus: DownloadStatus.ready,
              ));
            } else if (isError) {
              _downloadStatuses[curated.id] = DownloadStatus.error;
            } else {
              _downloadProgress[curated.id] = progress;
            }
          });
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadStatuses[curated.id] = DownloadStatus.error;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }

  Future<void> _handleDeleteModel(AIModel model) async {
    final api = context.read<ApiClient>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text('Delete ${model.name}?',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 9,
                fontWeight: FontWeight.w500,
              )),
          content: Text(
            'This will remove the model from your device. You can re-download it later.',
            style: GoogleFonts.inter(
              fontSize: 9,
              color: theme.colorScheme.secondary,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      if (api.isAvailable) {
        await ModelService().deleteModel(model.id);
      }

      final db = context.read<DatabaseService>();
      await db.deleteModel(model.id);

      setState(() {
        _installedModels.removeWhere((m) => m.id == model.id);
        if (_activeModelId == model.id) _activeModelId = null;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${model.name} deleted'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _loadModels,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Models',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          )),
                      const SizedBox(height: 4),
                      Text('Manage your local AI models',
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            color: theme.colorScheme.secondary,
                          )),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _loadModels,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  tooltip: 'Refresh',
                  style: IconButton.styleFrom(
                    foregroundColor: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Error banner
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: theme.colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            color: theme.colorScheme.error,
                          )),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Content
            Expanded(
              child: ListView(
                children: [
                  // Recommended hero card
                  if (_recommendedModel != null) ...[
                    RecommendedHeroCard(model: _recommendedModel!),
                    const SizedBox(height: 32),
                  ],

                  // Installed models
                  _buildSectionHeader(theme, 'Installed',
                      count: _installedModels.length),
                  const SizedBox(height: 12),
                  if (_installedModels.isEmpty)
                    _buildEmptySection(
                      theme,
                      icon: Icons.download_outlined,
                      title: 'No models installed',
                      subtitle: 'Download a model from the Discover section below',
                    )
                  else
                    ..._installedModels.map((model) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ModelCard(
                            model: model,
                            onTap: () => _handleModelTap(model),
                            trailing: PopupMenuButton<String>(
                              icon: Icon(
                                Icons.more_vert_rounded,
                                size: 18,
                                color: theme.colorScheme.secondary,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'activate',
                                  enabled:
                                      model.id != _activeModelId,
                                  child: Row(
                                    children: [
                                      Icon(Icons.play_arrow_rounded,
                                          size: 16,
                                          color: theme.colorScheme.secondary),
                                      const SizedBox(width: 10),
                                      Text('Set active',
                                          style: GoogleFonts.inter(
                                              fontSize: 9)),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(Icons.delete_outline_rounded,
                                          size: 16,
                                          color: theme.colorScheme.error),
                                      const SizedBox(width: 10),
                                      Text('Delete',
                                          style: GoogleFonts.inter(
                                            fontSize: 9,
                                            color: theme.colorScheme.error,
                                          )),
                                    ],
                                  ),
                                ),
                              ],
                              onSelected: (value) {
                                if (value == 'activate') {
                                  _handleModelTap(model);
                                } else if (value == 'delete') {
                                  _handleDeleteModel(model);
                                }
                              },
                            ),
                          ),
                        )),

                  const SizedBox(height: 32),

                  // Discover section — curated models
                  _buildSectionHeader(theme, 'Discover',
                      count: _curatedModels.length),
                  const SizedBox(height: 12),
                  if (_curatedModels.isEmpty)
                    _buildEmptySection(
                      theme,
                      icon: Icons.explore_outlined,
                      title: 'No additional models available',
                      subtitle: 'All curated models are installed',
                    )
                  else
                    ..._curatedModels.map((curated) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _CuratedModelCard(
                            curated: curated,
                            downloadStatus: _downloadStatuses[curated.id],
                            downloadProgress:
                                _downloadProgress[curated.id] ?? 0,
                            formatBytes: _formatBytes,
                            onDownload: () =>
                                _handleDownloadCurated(curated),
                          ),
                        )),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, {int? count}) {
    return Row(
      children: [
        Text(
          title,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        if (count != null && count > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$count',
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEmptySection(
    ThemeData theme, {
    required IconData icon,
    required String title,
    String? subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 40,
                color: theme.colorScheme.secondary.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(title,
                style: GoogleFonts.inter(
                  fontSize: 9,
                  color: theme.colorScheme.secondary,
                )),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    color: theme.colorScheme.secondary.withValues(alpha: 0.6),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}

/// Card for a curated model in the Discover section.
class _CuratedModelCard extends StatelessWidget {
  final CuratedModel curated;
  final DownloadStatus? downloadStatus;
  final double downloadProgress;
  final String Function(int) formatBytes;
  final VoidCallback onDownload;

  const _CuratedModelCard({
    required this.curated,
    this.downloadStatus,
    required this.downloadProgress,
    required this.formatBytes,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDownloading = downloadStatus == DownloadStatus.downloading;
    final isError = downloadStatus == DownloadStatus.error;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Model info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        curated.name,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _InfoChip(
                            text: curated.sizeLabel,
                            theme: theme,
                          ),
                          const SizedBox(width: 8),
                          _InfoChip(
                            text: '${curated.paramsBillion}B params',
                            theme: theme,
                          ),
                          if (curated.quant != null) ...[
                            const SizedBox(width: 8),
                            _InfoChip(
                              text: curated.quant!,
                              theme: theme,
                            ),
                          ],
                        ],
                      ),
                      if (curated.description != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          curated.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            color: theme.colorScheme.secondary,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        formatBytes(curated.diskBytes),
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ],
                  ),
                ),

                // Download button
                if (!isDownloading)
                  FilledButton.icon(
                    onPressed: isError ? onDownload : onDownload,
                    icon: Icon(
                      isError
                          ? Icons.refresh_rounded
                          : Icons.download_rounded,
                      size: 16,
                    ),
                    label: Text(isError ? 'Retry' : 'Download'),
                    style: FilledButton.styleFrom(
                      backgroundColor: isError
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      textStyle: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
              ],
            ),

            // Download progress bar
            if (isDownloading) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Downloading...',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                  Text(
                    '${(downloadProgress * 100).toInt()}%',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: downloadProgress,
                  minHeight: 4,
                  backgroundColor:
                      theme.colorScheme.primary.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String text;
  final ThemeData theme;

  const _InfoChip({required this.text, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 9,
          fontWeight: FontWeight.w500,
          color: theme.colorScheme.secondary,
        ),
      ),
    );
  }
}
