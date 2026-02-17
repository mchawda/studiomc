// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:studiomc_app/models/mobile_model_catalog.dart';
import 'package:studiomc_app/services/bundled_inference_service.dart';
import 'package:studiomc_app/services/local_inference_service.dart';
import 'package:studiomc_app/services/mobile_inference_service.dart';
import 'package:studiomc_app/services/settings_service.dart';
import 'package:studiomc_app/services/training_service.dart';
import 'package:studiomc_app/utils/platform_utils.dart';

/// Discover / Models screen — shows installed Ollama models,
/// personalized (LoRA) adapters, and curated downloads including
/// large models for the SpliceLLM engine.
class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  bool _isLoading = true;
  String? _error;

  // Download progress per tag
  final Map<String, double> _downloadProgress = {};
  final Map<String, bool> _downloading = {};
  final Map<String, String> _downloadErrors = {};

  // Personalized adapters from the training service
  List<Map<String, dynamic>> _adapters = [];
  bool _adaptersLoading = false;

  // Curated models available to download from Ollama
  static const _curatedModels = <_CuratedEntry>[
    _CuratedEntry(
      tag: 'llama3.2',
      name: 'Llama 3.2',
      params: '3B',
      description: 'Meta\'s latest compact model. Great all-rounder.',
      sizeEstimate: '2.0 GB',
      hfRepo: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
      ggufFilename: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    ),
    _CuratedEntry(
      tag: 'llama3.2:1b',
      name: 'Llama 3.2 1B',
      params: '1B',
      description: 'Ultra-light Llama for fast responses.',
      sizeEstimate: '780 MB',
      hfRepo: 'bartowski/Llama-3.2-1B-Instruct-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      ggufFilename: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
    ),
    _CuratedEntry(
      tag: 'llama3.1:8b',
      name: 'Llama 3.1 8B',
      params: '8B',
      description: 'Larger Llama with strong reasoning.',
      sizeEstimate: '4.9 GB',
      hfRepo: 'bartowski/Meta-Llama-3.1-8B-Instruct-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
      ggufFilename: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
    ),
    _CuratedEntry(
      tag: 'qwen3:4b',
      name: 'Qwen 3 4B',
      params: '4B',
      description: 'Alibaba\'s fast multilingual model.',
      sizeEstimate: '2.6 GB',
      hfRepo: 'bartowski/Qwen2.5-3B-Instruct-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf',
      ggufFilename: 'Qwen2.5-3B-Instruct-Q4_K_M.gguf',
    ),
    _CuratedEntry(
      tag: 'qwen2.5:7b',
      name: 'Qwen 2.5 7B',
      params: '7B',
      description: 'Strong coding and reasoning model.',
      sizeEstimate: '4.7 GB',
      hfRepo: 'bartowski/Qwen2.5-7B-Instruct-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf',
      ggufFilename: 'Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    ),
    _CuratedEntry(
      tag: 'mistral',
      name: 'Mistral 7B',
      params: '7B',
      description: 'Efficient general-purpose model from Mistral AI.',
      sizeEstimate: '4.4 GB',
      hfRepo: 'bartowski/Mistral-7B-Instruct-v0.3-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf',
      ggufFilename: 'Mistral-7B-Instruct-v0.3-Q4_K_M.gguf',
    ),
    _CuratedEntry(
      tag: 'phi3',
      name: 'Phi-3 Mini',
      params: '3.8B',
      description: 'Microsoft\'s small but capable model.',
      sizeEstimate: '2.4 GB',
      hfRepo: 'bartowski/Phi-3.5-mini-instruct-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf',
      ggufFilename: 'Phi-3.5-mini-instruct-Q4_K_M.gguf',
    ),
    _CuratedEntry(
      tag: 'gemma2:2b',
      name: 'Gemma 2 2B',
      params: '2B',
      description: 'Google\'s lightweight open model.',
      sizeEstimate: '1.6 GB',
      hfRepo: 'bartowski/gemma-2-2b-it-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf',
      ggufFilename: 'gemma-2-2b-it-Q4_K_M.gguf',
    ),
    _CuratedEntry(
      tag: 'deepseek-coder:6.7b',
      name: 'DeepSeek Coder',
      params: '6.7B',
      description: 'Specialized for code generation.',
      sizeEstimate: '3.8 GB',
      hfRepo: 'bartowski/deepseek-coder-6.7b-instruct-GGUF',
      downloadUrl: 'https://huggingface.co/bartowski/deepseek-coder-6.7b-instruct-GGUF/resolve/main/deepseek-coder-6.7b-instruct-Q4_K_M.gguf',
      ggufFilename: 'deepseek-coder-6.7b-instruct-Q4_K_M.gguf',
    ),
    // ── Large models (run via SpliceLLM / llamacpp) ──
    _CuratedEntry(
      tag: 'llama3.1:70b',
      name: 'Llama 3.1 70B',
      params: '70B',
      description: 'Full-size Llama. Streams from disk on low-RAM machines.',
      sizeEstimate: '40 GB',
      isLargeModel: true,
      hfRepo: 'bartowski/Meta-Llama-3.1-70B-Instruct-GGUF',
    ),
    _CuratedEntry(
      tag: 'qwen2.5:72b',
      name: 'Qwen 2.5 72B',
      params: '72B',
      description: 'Large multilingual model. Streams from disk.',
      sizeEstimate: '41 GB',
      isLargeModel: true,
      hfRepo: 'bartowski/Qwen2.5-72B-Instruct-GGUF',
    ),
    _CuratedEntry(
      tag: 'deepseek-r1:70b',
      name: 'DeepSeek R1 70B',
      params: '70B',
      description: 'Reasoning-focused large model.',
      sizeEstimate: '42 GB',
      isLargeModel: true,
      hfRepo: 'bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF',
    ),
    _CuratedEntry(
      tag: 'mixtral:8x7b',
      name: 'Mixtral 8x7B',
      params: '47B MoE',
      description: 'Mixture-of-experts model.',
      sizeEstimate: '26 GB',
      isLargeModel: true,
      hfRepo: 'bartowski/Mixtral-8x7B-Instruct-v0.1-GGUF',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Models discovered via the bundled inference backend (Ollama + SpliceLLM).
  List<Map<String, dynamic>> _backendModels = [];

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    if (isMobile) {
      final mobile = context.read<MobileInferenceService>();
      if (!mobile.available) {
        await mobile.init();
      }
    } else {
      // Show UI immediately — curated models are hardcoded and need no backend.
      // Check backend availability in the background without blocking.
      final local = context.read<LocalInferenceService>();
      final bundled = context.read<BundledInferenceService>();

      // Quick non-blocking check: if already available, load models
      if (local.available || bundled.available) {
        if (bundled.available) await _loadBackendModels();
        await _loadAdapters();
      } else {
        // Show UI now, probe backends in background
        if (mounted) setState(() => _isLoading = false);
        _probeBackendsInBackground();
        return;
      }
    }

    if (mounted) setState(() => _isLoading = false);
  }

  /// Probes backends in the background without blocking UI rendering.
  Future<void> _probeBackendsInBackground() async {
    final local = context.read<LocalInferenceService>();
    final bundled = context.read<BundledInferenceService>();

    // Try init in parallel — these have their own timeouts
    await Future.wait([
      Future(() async {
        try {
          if (!local.available) await local.init();
        } catch (_) {}
      }),
      Future(() async {
        try {
          if (!bundled.available) await bundled.recheckAvailability();
          if (!bundled.available) await bundled.init();
        } catch (_) {}
      }),
    ]);

    if (bundled.available) await _loadBackendModels();
    await _loadAdapters();

    if (!local.available && !bundled.available) {
      _error = 'Backend still starting. You can still download models below.';
    }

    if (mounted) setState(() {});
  }

  /// Fetch model list from the bundled inference service (/v1/models).
  Future<void> _loadBackendModels() async {
    try {
      final resp = await http
          .get(Uri.parse('http://127.0.0.1:8100/v1/models'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final models = data['data'] as List<dynamic>? ?? [];
        if (mounted) {
          setState(() {
            _backendModels = models.cast<Map<String, dynamic>>();
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _loadAdapters() async {
    if (!mounted) return;
    setState(() => _adaptersLoading = true);

    try {
      final training = TrainingService();
      final adapters = await training.getAdapters();
      if (mounted) {
        setState(() {
          _adapters = adapters;
          _adaptersLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _adapters = [];
          _adaptersLoading = false;
        });
      }
    }
  }

  Set<String> _installedTags(LocalInferenceService local) {
    return local.models.map((m) => m.name).toSet();
  }

  /// Check if a curated tag is already installed (exact or base match).
  bool _isInstalled(String tag, Set<String> installed) {
    if (installed.contains(tag)) return true;
    final base = tag.split(':').first;
    // "llama3.2" matches "llama3.2:latest"
    if (installed.contains('$base:latest')) return true;

    // Also check if the GGUF file exists locally and is large enough
    // to be a real model (> 100MB). This prevents partial downloads
    // from being considered "installed".
    final curated = _curatedModels.where((c) => c.tag == tag).firstOrNull;
    if (curated?.ggufFilename != null) {
      final file = File('$studiomcModelsDir/${curated!.ggufFilename}');
      if (file.existsSync() && file.lengthSync() > 100 * 1024 * 1024) {
        return true;
      }
    }

    return false;
  }

  Future<void> _downloadModel(String tag) async {
    debugPrint('[download] _downloadModel called for tag: $tag');
    final local = context.read<LocalInferenceService>();
    final bundled = context.read<BundledInferenceService>();
    final curated = _curatedModels.where((c) => c.tag == tag).firstOrNull;
    debugPrint('[download] curated found: ${curated != null}, downloadUrl: ${curated?.downloadUrl != null}, ggufFilename: ${curated?.ggufFilename}');

    setState(() {
      _downloading[tag] = true;
      _downloadProgress[tag] = 0.0;
      _downloadErrors.remove(tag);
    });
    debugPrint('[download] setState done, entering try block');

    try {
      if (curated?.downloadUrl != null && curated?.ggufFilename != null) {
        debugPrint('[download] Path 1: Direct GGUF download');
        // Path 1: Direct GGUF download from HuggingFace (works for everyone)
        await _downloadGgufDirect(
          tag: tag,
          url: curated!.downloadUrl!,
          filename: curated.ggufFilename!,
        );
        debugPrint('[download] GGUF download completed');

        // Tell the inference backend to load this model
        if (bundled.available) {
          final modelId = curated.ggufFilename!
              .replaceAll('.gguf', '')
              .replaceAll('.bin', '')
              .toLowerCase()
              .replaceAll(' ', '-');
          debugPrint('[download] Selecting model: $modelId');
          await bundled.selectModel(modelId);
        }
      } else if (local.available) {
        // Path 2: Ollama pull (only for models without direct URLs, e.g. large models)
        await for (final progress in local.pullModelWithProgress(tag)) {
          if (!mounted) return;
          setState(() => _downloadProgress[tag] = progress);
        }
      } else {
        // Path 3: Model manager backend for large models without direct URLs
        final hfRepo = curated?.hfRepo ?? tag;
        final modelName = curated?.name ?? tag;

        final resp = await http.post(
          Uri.parse('http://127.0.0.1:8101/models/add'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'source': 'hf',
            'source_ref': hfRepo,
            'name': modelName,
          }),
        ).timeout(const Duration(seconds: 10));

        if (resp.statusCode == 200) {
          final addData = jsonDecode(resp.body);
          final modelId = addData['id'] as String? ?? tag;

          bool done = false;
          while (!done && mounted) {
            await Future.delayed(const Duration(seconds: 2));
            try {
              final statusResp = await http
                  .get(Uri.parse(
                      'http://127.0.0.1:8101/models/status/${Uri.encodeComponent(modelId)}'))
                  .timeout(const Duration(seconds: 5));
              if (statusResp.statusCode == 200) {
                final data = jsonDecode(statusResp.body);
                final progress = (data['progress'] as num?)?.toDouble() ?? 0;
                final status = data['status'] as String? ?? '';
                setState(() => _downloadProgress[tag] = progress);
                if (status == 'complete' || progress >= 1.0) done = true;
                if (status == 'error') throw Exception('Download failed');
              }
            } catch (_) {
              break;
            }
          }
        } else {
          throw Exception('Failed to start download');
        }
      }
    } catch (e, st) {
      debugPrint('[download] ERROR for $tag: $e');
      debugPrint('[download] Stack trace: $st');
      if (mounted) {
        setState(() => _downloadErrors[tag] = e.toString());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            duration: const Duration(seconds: 5),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }

    debugPrint('[download] Refreshing model lists');
    // Refresh model lists
    await _loadBackendModels();

    if (mounted) {
      setState(() {
        _downloading.remove(tag);
        _downloadProgress.remove(tag);
      });
    }
  }

  /// Check available disk space at [path] in bytes.
  int _availableDiskSpace(String path) {
    try {
      final stat = FileStat.statSync(path);
      if (stat.type == FileSystemEntityType.notFound) return 0;
      // Use the parent directory's filesystem stats
      final result = Process.runSync('df', ['-k', path]);
      if (result.exitCode == 0) {
        final lines = (result.stdout as String).trim().split('\n');
        if (lines.length >= 2) {
          final parts = lines.last.split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            return int.tryParse(parts[3]) ?? 0;  // Available in 1K blocks
          }
        }
      }
    } catch (_) {}
    return 0;  // Unknown — let the download attempt proceed
  }

  /// Download a GGUF file directly from HuggingFace to the shared models dir.
  Future<void> _downloadGgufDirect({
    required String tag,
    required String url,
    required String filename,
  }) async {
    final modelsDir = Directory(studiomcModelsDir);
    if (!modelsDir.existsSync()) {
      modelsDir.createSync(recursive: true);
    }

    final filePath = '${modelsDir.path}/$filename';
    final file = File(filePath);

    // Skip if already downloaded
    if (file.existsSync() && file.lengthSync() > 0) {
      debugPrint('[discover] Model already exists at $filePath');
      if (mounted) setState(() => _downloadProgress[tag] = 1.0);
      return;
    }

    debugPrint('[discover] Downloading $url -> $filePath');

    final client = HttpClient();
    try {
      debugPrint('[discover] Creating HTTP request...');
      final request = await client.getUrl(Uri.parse(url));
      debugPrint('[discover] Closing request (awaiting response)...');
      final response = await request.close();
      debugPrint('[discover] Response status: ${response.statusCode}, contentLength: ${response.contentLength}');

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength;

      // Check disk space before starting download
      if (totalBytes > 0) {
        final availableKB = _availableDiskSpace(modelsDir.path);
        final availableBytes = availableKB * 1024;
        final requiredBytes = totalBytes + (500 * 1024 * 1024); // 500MB buffer
        if (availableBytes > 0 && availableBytes < requiredBytes) {
          final availGB = (availableBytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
          final needGB = (totalBytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
          throw Exception(
            'Not enough disk space. Need ${needGB}GB but only ${availGB}GB available. '
            'Free up space or delete unused models.',
          );
        }
      }

      int receivedBytes = 0;

      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (totalBytes > 0 && mounted) {
            setState(() =>
                _downloadProgress[tag] = receivedBytes / totalBytes);
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // Verify the download completed fully
      if (totalBytes > 0 && receivedBytes < totalBytes) {
        if (file.existsSync()) file.deleteSync();
        throw Exception(
          'Download incomplete: got ${(receivedBytes / (1024 * 1024)).toStringAsFixed(0)}MB '
          'of ${(totalBytes / (1024 * 1024)).toStringAsFixed(0)}MB. Check disk space.',
        );
      }

      debugPrint('[discover] Download complete: $filePath (${receivedBytes} bytes)');
    } catch (e) {
      // Clean up partial file
      if (file.existsSync()) {
        try { file.deleteSync(); } catch (_) {}
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> _deleteModel(OllamaModel model) async {
    final theme = Theme.of(context);
    final local = context.read<LocalInferenceService>();
    final name = local.humanName(model.name);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text('Delete $name?',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            )),
        content: Text(
          'Remove this model from Ollama. You can re-download later.',
          style: GoogleFonts.inter(
            fontSize: 10,
            color: theme.colorScheme.secondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final ok = await local.deleteModel(model.name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? '$name deleted' : 'Failed to delete $name'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        setState(() {});
      }
    }
  }

  void _activateModel(OllamaModel model) {
    final local = context.read<LocalInferenceService>();
    final settings = context.read<SettingsService>();
    local.selectModel(model.name);
    settings.activeModelId = model.name;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Switched to ${local.humanName(model.name)}'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
    setState(() {});
  }

  // ── Adapter actions ──

  Future<void> _toggleAdapter(Map<String, dynamic> adapter) async {
    final id = adapter['id'] as String? ?? '';
    final name = adapter['name'] as String? ?? 'Adapter';
    final isActive = adapter['is_active'] == true || adapter['is_active'] == 1;
    final training = TrainingService();

    try {
      if (isActive) {
        // Deactivate by activating with empty — the backend deactivates all
        // for this base model. We re-fetch to get updated state.
        // Since there's no explicit deactivate endpoint, we just reload.
        // The activate endpoint deactivates others first, so calling activate
        // on an already-active adapter is effectively a no-op.
        // For true deactivation, we'd need a separate endpoint.
        // For now, show a snackbar explaining the adapter is already active.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$name is already active'),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      await training.activateAdapter(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Activated $name'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      await _loadAdapters();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to activate adapter: $e'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }
  }

  Future<void> _deleteAdapter(Map<String, dynamic> adapter) async {
    final theme = Theme.of(context);
    final id = adapter['id'] as String? ?? '';
    final name = adapter['name'] as String? ?? 'Adapter';
    final training = TrainingService();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text('Delete "$name"?',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            )),
        content: Text(
          'This will permanently remove the personalized adapter and its training data.',
          style: GoogleFonts.inter(
            fontSize: 10,
            color: theme.colorScheme.secondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await training.deleteAdapter(id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$name deleted'),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
        await _loadAdapters();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete adapter: $e'),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
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

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso);
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inDays == 0) return 'Today';
      if (diff.inDays == 1) return 'Yesterday';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (isMobile) {
      return _buildMobileModelsView(theme);
    }

    final local = context.watch<LocalInferenceService>();
    final bundled = context.watch<BundledInferenceService>();
    final installed = local.models;
    final installedTags = _installedTags(local);

    // Also include backend model IDs in the installed set
    final backendInstalledIds = _backendModels
        .map((m) => (m['id'] as String? ?? '').toLowerCase())
        .toSet();

    // Filter curated to only show uninstalled (check both Ollama + backend)
    // Keep models that are currently downloading visible so the progress bar stays
    final available = _curatedModels
        .where((c) =>
            _downloading[c.tag] == true ||
            (!_isInstalled(c.tag, installedTags) &&
             !backendInstalledIds.contains(c.tag.toLowerCase())))
        .toList();

    // Partition adapters: active first, then inactive
    final activeAdapters =
        _adapters.where((a) => a['is_active'] == true || a['is_active'] == 1).toList();
    final inactiveAdapters =
        _adapters.where((a) => a['is_active'] != true && a['is_active'] != 1).toList();
    final sortedAdapters = [...activeAdapters, ...inactiveAdapters];

    return RefreshIndicator(
      onRefresh: _load,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          )),
                      const SizedBox(height: 4),
                      Builder(builder: (ctx) {
                        final engine = ctx.watch<BundledInferenceService>();
                        final ollama = ctx.watch<LocalInferenceService>();
                        final hasOllama = ollama.available;
                        final hasEngine = engine.available;

                        String label;
                        bool online;
                        if (hasOllama && hasEngine) {
                          label = 'Ollama + SpliceLLM';
                          online = true;
                        } else if (hasOllama) {
                          label = 'Ollama';
                          online = true;
                        } else if (hasEngine) {
                          label = 'SpliceLLM';
                          online = true;
                        } else if (engine.starting) {
                          label = 'Starting engine...';
                          online = false;
                        } else {
                          label = 'No backend available';
                          online = false;
                        }

                        return Row(
                          children: [
                            Icon(
                              online
                                  ? Icons.circle
                                  : Icons.circle_outlined,
                              size: 8,
                              color: online
                                  ? Colors.green
                                  : theme.colorScheme.secondary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              label,
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                color: theme.colorScheme.secondary,
                              ),
                            ),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  tooltip: 'Refresh',
                ),
              ],
            ),
            const SizedBox(height: 8),

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
                  // ── Personalized Models (Adapters) ──
                  if (_adapters.isNotEmpty || _adaptersLoading) ...[
                    _buildSectionHeader(
                      theme,
                      'Personalized',
                      count: _adapters.length,
                      icon: Icons.auto_awesome_rounded,
                      iconColor: _kAdapterPurple,
                    ),
                    const SizedBox(height: 4),
                    if (_adaptersLoading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else
                      ...sortedAdapters.map((adapter) => _PersonalizedModelCard(
                            adapter: adapter,
                            formatDate: _formatDate,
                            onToggle: () => _toggleAdapter(adapter),
                            onDelete: () => _deleteAdapter(adapter),
                          )),
                    const SizedBox(height: 10),
                  ],

                  // ── Installed Models ──
                  Builder(builder: (_) {
                    final nonOllamaBackend = _backendModels.where((m) {
                      final backend = m['backend'] as String? ?? '';
                      if (backend == 'ollama') return false;
                      final id = m['id'] as String? ?? '';
                      final bmid = m['backend_model_id'] as String? ?? '';
                      return !installedTags.contains(id) &&
                             !installedTags.contains(bmid);
                    }).length;
                    return _buildSectionHeader(theme, 'Installed',
                        count: installed.length + nonOllamaBackend);
                  }),
                  const SizedBox(height: 4),
                  if (installed.isEmpty && _backendModels.isEmpty)
                    _buildEmpty(theme, Icons.download_outlined,
                        'No models installed',
                        subtitle: 'Download a model below')
                  else ...[
                    // Ollama models
                    ...installed.map((model) => _InstalledModelCard(
                          model: model,
                          isActive: model.name == local.activeModel,
                          humanName: local.humanName(model.name),
                          formatBytes: _formatBytes,
                          onActivate: () => _activateModel(model),
                          onDelete: () => _deleteModel(model),
                          adapterName: _activeAdapterForModel(model.name),
                        )),
                    // Backend models (from inference service, not in Ollama)
                    ..._backendModels
                        .where((m) {
                          final id = m['id'] as String? ?? '';
                          final backendModelId = m['backend_model_id'] as String? ?? '';
                          final backend = m['backend'] as String? ?? '';
                          // Skip Ollama models — already shown above from local service
                          if (backend == 'ollama') return false;
                          // Skip if already shown in Ollama list
                          if (installedTags.contains(id)) return false;
                          if (installedTags.contains(backendModelId)) return false;
                          return true;
                        })
                        .map((m) => _BackendModelCard(
                              model: m,
                              isActive:
                                  (m['id'] as String?) == bundled.activeModel,
                              onActivate: () async {
                                final id = m['id'] as String? ?? '';
                                await bundled.selectModel(id,
                                    backend: m['backend'] as String?);
                              },
                            )),
                  ],

                  const SizedBox(height: 10),

                  // ── Discover — downloadable models ──
                  _buildSectionHeader(theme, 'Discover',
                      count: available.length),
                  const SizedBox(height: 4),
                  if (available.isEmpty)
                    _buildEmpty(theme, Icons.check_circle_outline,
                        'All curated models installed')
                  else
                    ...available.map((c) => _DiscoverCard(
                          entry: c,
                          isDownloading: _downloading[c.tag] == true,
                          progress: _downloadProgress[c.tag] ?? 0,
                          error: _downloadErrors[c.tag],
                          onDownload: () => _downloadModel(c.tag),
                        )),

                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Mobile model view ──

  Widget _buildMobileModelsView(ThemeData theme) {
    final mobile = context.watch<MobileInferenceService>();
    final downloadedModels = mobile.downloadedModels;
    final downloadedFilenames = downloadedModels.map((m) => m.filename).toSet();

    // Catalog models not yet downloaded
    final availableCatalog = MobileModelCatalog.models
        .where((c) => !downloadedFilenames.contains(c.filename))
        .toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          )),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            mobile.available ? Icons.circle : Icons.circle_outlined,
                            size: 8,
                            color: mobile.available
                                ? Colors.green
                                : theme.colorScheme.secondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            mobile.available
                                ? 'On-device inference'
                                : 'No model loaded',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  tooltip: 'Refresh',
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Download progress banner
            if (mobile.downloadingModel != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Downloading ${mobile.downloadingModel}...',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: mobile.downloadProgress > 0
                            ? mobile.downloadProgress
                            : null,
                        minHeight: 4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(mobile.downloadStatus,
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          color: theme.colorScheme.secondary,
                        )),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Content
            Expanded(
              child: ListView(
                children: [
                  // ── Downloaded Models ──
                  _buildSectionHeader(theme, 'On Device',
                      count: downloadedModels.length),
                  const SizedBox(height: 4),
                  if (downloadedModels.isEmpty)
                    _buildEmpty(theme, Icons.download_outlined,
                        'No models downloaded',
                        subtitle: 'Download a model below to get started')
                  else
                    ...downloadedModels.map((model) => _MobileModelCard(
                          model: model,
                          isActive: model.filename == mobile.activeModel,
                          humanName: mobile.humanName(model.filename),
                          isLoading: mobile.loading,
                          onActivate: () => _activateMobileModel(model.filename),
                          onDelete: () => _deleteMobileModel(model.filename),
                        )),

                  const SizedBox(height: 10),

                  // ── Available to Download ──
                  _buildSectionHeader(theme, 'Available',
                      count: availableCatalog.length),
                  const SizedBox(height: 4),
                  if (availableCatalog.isEmpty)
                    _buildEmpty(theme, Icons.check_circle_outline,
                        'All models downloaded')
                  else
                    ...availableCatalog.map((c) => _MobileCatalogCard(
                          entry: c,
                          isDownloading: mobile.downloadingModel == c.filename,
                          progress: mobile.downloadProgress,
                          onDownload: () => _downloadMobileModel(c),
                        )),

                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _activateMobileModel(String filename) async {
    final mobile = context.read<MobileInferenceService>();
    final settings = context.read<SettingsService>();
    final success = await mobile.loadModel(filename);

    if (!mounted) return;

    if (!success) {
      final error = mobile.downloadError ?? 'Failed to load model';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    settings.activeModelId = filename;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Switched to ${mobile.humanName(filename)}'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _downloadMobileModel(CatalogModel entry) async {
    final mobile = context.read<MobileInferenceService>();
    await mobile.downloadModel(
      url: entry.downloadUrl,
      filename: entry.filename,
      displayName: entry.name,
    );

    // Auto-load if this is the first model
    if (mobile.downloadedModels.length == 1) {
      _activateMobileModel(entry.filename);
    }

    if (mounted) setState(() {});
  }

  Future<void> _deleteMobileModel(String filename) async {
    final theme = Theme.of(context);
    final mobile = context.read<MobileInferenceService>();
    final name = mobile.humanName(filename);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete $name?',
            style: GoogleFonts.spaceGrotesk(
                fontSize: 12, fontWeight: FontWeight.w500)),
        content: Text('Remove this model from your device. You can re-download later.',
            style: GoogleFonts.inter(
                fontSize: 10, color: theme.colorScheme.secondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final ok = await mobile.deleteModel(filename);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? '$name deleted' : 'Failed to delete $name'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        setState(() {});
      }
    }
  }

  /// Returns the name of the active adapter for a given base model, or null.
  String? _activeAdapterForModel(String modelTag) {
    for (final a in _adapters) {
      final isActive = a['is_active'] == true || a['is_active'] == 1;
      if (!isActive) continue;
      final baseModel = a['base_model_id'] as String? ?? '';
      // Match by substring: adapter's base_model_id may be an Ollama tag or
      // a GGUF reference. Do a best-effort match.
      if (baseModel == modelTag ||
          modelTag.startsWith(baseModel.split(':').first) ||
          baseModel.startsWith(modelTag.split(':').first)) {
        return a['name'] as String? ?? 'Adapter';
      }
    }
    return null;
  }

  // ── Shared purple for adapter UI ──
  static const _kAdapterPurple = Color(0xFF8B5CF6);

  Widget _buildSectionHeader(
    ThemeData theme,
    String title, {
    int? count,
    IconData? icon,
    Color? iconColor,
  }) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: iconColor ?? theme.colorScheme.primary),
          const SizedBox(width: 4),
        ],
        Text(title,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            )),
        if (count != null && count > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: (iconColor ?? theme.colorScheme.primary)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('$count',
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  color: iconColor ?? theme.colorScheme.primary,
                )),
          ),
        ],
      ],
    );
  }

  Widget _buildEmpty(ThemeData theme, IconData icon, String title,
      {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 28,
                color: theme.colorScheme.secondary.withValues(alpha: 0.4)),
            const SizedBox(height: 8),
            Text(title,
                style: GoogleFonts.inter(
                  fontSize: 10,
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

// ── Shared purple constant for sub-widgets ──
const _kAdapterPurple = Color(0xFF8B5CF6);

// ── Curated model entry ──

class _CuratedEntry {
  final String tag;
  final String name;
  final String params;
  final String description;
  final String sizeEstimate;
  final bool isLargeModel;

  /// HuggingFace repo for downloading without Ollama (GGUF format).
  final String? hfRepo;

  /// Direct download URL for GGUF file (fallback when Ollama is unavailable).
  final String? downloadUrl;

  /// GGUF filename for direct download.
  final String? ggufFilename;

  const _CuratedEntry({
    required this.tag,
    required this.name,
    required this.params,
    required this.description,
    required this.sizeEstimate,
    this.isLargeModel = false,
    this.hfRepo,
    this.downloadUrl,
    this.ggufFilename,
  });
}

// ── Personalized model (adapter) card ──

class _PersonalizedModelCard extends StatelessWidget {
  final Map<String, dynamic> adapter;
  final String Function(String?) formatDate;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _PersonalizedModelCard({
    required this.adapter,
    required this.formatDate,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final name = adapter['name'] as String? ?? 'Unnamed Adapter';
    final baseModel = adapter['base_model_id'] as String? ?? '';
    final sourceType = adapter['source_type'] as String? ?? '';
    final createdAt = adapter['created_at'] as String? ?? '';
    final isActive = adapter['is_active'] == true || adapter['is_active'] == 1;
    final dateStr = formatDate(createdAt);

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: isActive ? null : onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: isActive
              ? _kAdapterPurple.withValues(alpha: 0.06)
              : null,
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor,
              width: 0.5,
            ),
          ),
          // Highlighted left border for active adapter
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // Adapter icon
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isActive
                        ? _kAdapterPurple.withValues(alpha: 0.12)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 13,
                    color: isActive
                        ? _kAdapterPurple
                        : theme.colorScheme.secondary,
                  ),
                ),
                const SizedBox(width: 8),

                // Name + base model
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.w500,
                            color: theme.colorScheme.onSurface,
                          )),
                      const SizedBox(height: 1),
                      Row(
                        children: [
                          Icon(Icons.link_rounded,
                              size: 10,
                              color: theme.colorScheme.secondary),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              baseModel.isNotEmpty
                                  ? 'Based on $baseModel'
                                  : 'Unknown base model',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 9,
                                color: theme.colorScheme.secondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Badges
                const SizedBox(width: 6),

                // Fine-tuned badge
                _adapterBadge(theme, isActive),

                const SizedBox(width: 4),

                // Active status badge
                if (isActive) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: _kAdapterPurple.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('Active',
                        style: GoogleFonts.inter(
                          fontSize: 8,
                          fontWeight: FontWeight.w600,
                          color: _kAdapterPurple,
                        )),
                  ),
                  const SizedBox(width: 4),
                ],

                // Date
                if (dateStr.isNotEmpty)
                  Text(dateStr,
                      style: GoogleFonts.inter(
                        fontSize: 8,
                        color: theme.colorScheme.secondary,
                      )),

                // Actions
                SizedBox(
                  width: 28,
                  height: 28,
                  child: PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert_rounded,
                        size: 14, color: theme.colorScheme.secondary),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    itemBuilder: (_) => [
                      if (!isActive)
                        PopupMenuItem(
                          value: 'activate',
                          height: 32,
                          child: Row(children: [
                            Icon(Icons.play_arrow_rounded,
                                size: 14,
                                color: theme.colorScheme.secondary),
                            const SizedBox(width: 8),
                            Text('Activate',
                                style: GoogleFonts.inter(fontSize: 10)),
                          ]),
                        ),
                      PopupMenuItem(
                        value: 'delete',
                        height: 32,
                        child: Row(children: [
                          Icon(Icons.delete_outline_rounded,
                              size: 14, color: theme.colorScheme.error),
                          const SizedBox(width: 8),
                          Text('Delete',
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                color: theme.colorScheme.error,
                              )),
                        ]),
                      ),
                    ],
                    onSelected: (v) {
                      if (v == 'activate') onToggle();
                      if (v == 'delete') onDelete();
                    },
                  ),
                ),
              ],
            ),

            // Source type chip row
            if (sourceType.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 2),
                child: Row(
                  children: [
                    _sourceChip(theme, sourceType),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _adapterBadge(ThemeData theme, bool isActive) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: _kAdapterPurple.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: _kAdapterPurple.withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded,
              size: 8, color: _kAdapterPurple),
          const SizedBox(width: 2),
          Text('Fine-tuned',
              style: GoogleFonts.inter(
                fontSize: 8,
                fontWeight: FontWeight.w600,
                color: _kAdapterPurple,
              )),
        ],
      ),
    );
  }

  Widget _sourceChip(ThemeData theme, String sourceType) {
    final label = switch (sourceType) {
      'collection' => 'Collection',
      'extract_paste' => 'Extract',
      'extract_file' => 'File extract',
      _ => sourceType,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: GoogleFonts.inter(
            fontSize: 8,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.secondary,
          )),
    );
  }
}

// ── Installed model card ──

class _InstalledModelCard extends StatelessWidget {
  final OllamaModel model;
  final bool isActive;
  final String humanName;
  final String Function(int) formatBytes;
  final VoidCallback onActivate;
  final VoidCallback onDelete;
  final String? adapterName;

  const _InstalledModelCard({
    required this.model,
    required this.isActive,
    required this.humanName,
    required this.formatBytes,
    required this.onActivate,
    required this.onDelete,
    this.adapterName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasAdapter = adapterName != null;

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: isActive ? null : onActivate,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primary.withValues(alpha: 0.05)
              : null,
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor,
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // Model icon
                Icon(
                  Icons.smart_toy_outlined,
                  size: 14,
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.secondary,
                ),
                const SizedBox(width: 8),

                // Name
                Expanded(
                  child: Text(humanName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
                        color: theme.colorScheme.onSurface,
                      )),
                ),

                // Active badge
                if (isActive) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('Active',
                        style: GoogleFonts.inter(
                          fontSize: 8,
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.primary,
                        )),
                  ),
                  const SizedBox(width: 6),
                ],

                // Chips inline
                if (model.parameterSize.isNotEmpty) ...[
                  _chip(theme, model.parameterSize),
                  const SizedBox(width: 4),
                ],
                if (model.quantization.isNotEmpty) ...[
                  _chip(theme, model.quantization),
                  const SizedBox(width: 4),
                ],
                Text(formatBytes(model.sizeBytes),
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      color: theme.colorScheme.secondary,
                    )),

                // Actions
                SizedBox(
                  width: 28,
                  height: 28,
                  child: PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert_rounded,
                        size: 14, color: theme.colorScheme.secondary),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    itemBuilder: (_) => [
                      if (!isActive)
                        PopupMenuItem(
                          value: 'activate',
                          height: 32,
                          child: Row(children: [
                            Icon(Icons.play_arrow_rounded,
                                size: 14, color: theme.colorScheme.secondary),
                            const SizedBox(width: 8),
                            Text('Set active',
                                style: GoogleFonts.inter(fontSize: 10)),
                          ]),
                        ),
                      PopupMenuItem(
                        value: 'delete',
                        height: 32,
                        child: Row(children: [
                          Icon(Icons.delete_outline_rounded,
                              size: 14, color: theme.colorScheme.error),
                          const SizedBox(width: 8),
                          Text('Delete',
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                color: theme.colorScheme.error,
                              )),
                        ]),
                      ),
                    ],
                    onSelected: (v) {
                      if (v == 'activate') onActivate();
                      if (v == 'delete') onDelete();
                    },
                  ),
                ),
              ],
            ),

            // Adapter connection indicator
            if (hasAdapter && isActive)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 2),
                child: Row(
                  children: [
                    Container(
                      width: 1,
                      height: 8,
                      color: _kAdapterPurple.withValues(alpha: 0.3),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.auto_awesome_rounded,
                        size: 9, color: _kAdapterPurple),
                    const SizedBox(width: 3),
                    Text(
                      'Using adapter: $adapterName',
                      style: GoogleFonts.inter(
                        fontSize: 8,
                        fontWeight: FontWeight.w500,
                        color: _kAdapterPurple,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: GoogleFonts.inter(
            fontSize: 8,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.secondary,
          )),
    );
  }
}

// ── Discover card (downloadable) ──

class _DiscoverCard extends StatelessWidget {
  final _CuratedEntry entry;
  final bool isDownloading;
  final double progress;
  final String? error;
  final VoidCallback onDownload;

  const _DiscoverCard({
    required this.entry,
    required this.isDownloading,
    required this.progress,
    this.error,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Name + chips
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface,
                          )),
                    ),
                    const SizedBox(width: 6),
                    _chip(theme, entry.params),
                    const SizedBox(width: 4),
                    _chip(theme, entry.sizeEstimate),
                    if (entry.isLargeModel) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 0),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('SpliceLLM',
                            style: GoogleFonts.inter(
                              fontSize: 8,
                              fontWeight: FontWeight.w600,
                              color: Colors.orange.shade700,
                            )),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Download button
              if (!isDownloading)
                FilledButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_rounded, size: 12),
                  label: const Text('Download'),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
            ],
          ),
          // Description
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(entry.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    color: theme.colorScheme.secondary,
                    height: 1.2,
                  )),
            ),
          ),
          if (isDownloading) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Downloading...',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      color: theme.colorScheme.secondary,
                    )),
                Text('${(progress * 100).toInt()}%',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.primary,
                    )),
              ],
            ),
            const SizedBox(height: 2),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor:
                    theme.colorScheme.primary.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.colorScheme.primary,
                ),
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 4),
            Text(
              'Error: $error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 9,
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: GoogleFonts.inter(
            fontSize: 8,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.secondary,
          )),
    );
  }
}

// ── Backend model card (non-Ollama models from inference service) ──

class _BackendModelCard extends StatelessWidget {
  final Map<String, dynamic> model;
  final bool isActive;
  final VoidCallback onActivate;

  const _BackendModelCard({
    required this.model,
    required this.isActive,
    required this.onActivate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name =
        model['name'] as String? ?? model['id'] as String? ?? 'Unknown';
    final backend = model['backend'] as String? ?? '';
    final params = model['params_billion'];
    final sizeBytes = model['size_bytes'] as int?;

    String detail = backend;
    if (params != null) detail = '${params}B · $detail';
    if (sizeBytes != null && sizeBytes > 0) {
      detail +=
          ' · ${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: isActive ? null : onActivate,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primary.withValues(alpha: 0.05)
              : null,
          border: Border(
            bottom: BorderSide(color: theme.dividerColor, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.smart_toy_outlined,
                size: 14,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.secondary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight:
                            isActive ? FontWeight.w500 : FontWeight.w400,
                        color: theme.colorScheme.onSurface,
                      )),
                  if (detail.isNotEmpty)
                    Text(detail,
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          color: theme.colorScheme.secondary,
                        )),
                ],
              ),
            ),
            if (isActive)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Active',
                    style: GoogleFonts.inter(
                      fontSize: 8,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.primary,
                    )),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Mobile on-device model card ──

class _MobileModelCard extends StatelessWidget {
  final MobileModel model;
  final bool isActive;
  final String humanName;
  final bool isLoading;
  final VoidCallback onActivate;
  final VoidCallback onDelete;

  const _MobileModelCard({
    required this.model,
    required this.isActive,
    required this.humanName,
    required this.isLoading,
    required this.onActivate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: isActive ? null : onActivate,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primary.withValues(alpha: 0.05)
              : null,
          border: Border(
            bottom: BorderSide(color: theme.dividerColor, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 18,
              color: isActive
                  ? theme.colorScheme.primary
                  : theme.colorScheme.secondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(humanName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
                        color: theme.colorScheme.onSurface,
                      )),
                  Text(model.sizeLabel,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: theme.colorScheme.secondary,
                      )),
                ],
              ),
            ),
            if (isActive) ...[
              if (isLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Active',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.primary,
                      )),
                ),
              const SizedBox(width: 6),
            ],
            SizedBox(
              width: 32,
              height: 32,
              child: PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded,
                    size: 18, color: theme.colorScheme.secondary),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                itemBuilder: (_) => [
                  if (!isActive)
                    PopupMenuItem(
                      value: 'activate',
                      height: 36,
                      child: Row(children: [
                        Icon(Icons.play_arrow_rounded,
                            size: 16, color: theme.colorScheme.secondary),
                        const SizedBox(width: 8),
                        Text('Set active',
                            style: GoogleFonts.inter(fontSize: 12)),
                      ]),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    height: 36,
                    child: Row(children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Text('Delete',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: theme.colorScheme.error,
                          )),
                    ]),
                  ),
                ],
                onSelected: (v) {
                  if (v == 'activate') onActivate();
                  if (v == 'delete') onDelete();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Mobile catalog card (available to download) ──

class _MobileCatalogCard extends StatelessWidget {
  final CatalogModel entry;
  final bool isDownloading;
  final double progress;
  final VoidCallback onDownload;

  const _MobileCatalogCard({
    required this.entry,
    required this.isDownloading,
    required this.progress,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.onSurface,
                              )),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(entry.parameterCount,
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.secondary,
                              )),
                        ),
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(entry.sizeLabel,
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.secondary,
                              )),
                        ),
                        if (entry.recommended) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('Recommended',
                                style: GoogleFonts.inter(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF10B981),
                                )),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(entry.description,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: theme.colorScheme.secondary,
                        )),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (!isDownloading)
                FilledButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_rounded, size: 14),
                  label: const Text('Get'),
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    textStyle: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
            ],
          ),
          if (isDownloading) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress > 0 ? progress : null,
                minHeight: 3,
              ),
            ),
            const SizedBox(height: 2),
            Text('${(progress * 100).toInt()}%',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  color: theme.colorScheme.secondary,
                )),
          ],
        ],
      ),
    );
  }
}
