import 'dart:async';

import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';

/// A curated model entry returned by the backend's recommendation catalogue.
class CuratedModel {
  final String id;
  final String name;
  final String source;
  final String sourceRef;
  final double paramsBillion;
  final String? quant;
  final int diskBytes;
  final String sizeLabel;
  final String? description;

  const CuratedModel({
    required this.id,
    required this.name,
    required this.source,
    required this.sourceRef,
    required this.paramsBillion,
    this.quant,
    required this.diskBytes,
    required this.sizeLabel,
    this.description,
  });

  factory CuratedModel.fromJson(Map<String, dynamic> json) {
    return CuratedModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      source: json['source'] as String? ?? 'hf',
      sourceRef: json['source_ref'] as String? ?? '',
      paramsBillion: (json['params_billion'] as num? ?? 0).toDouble(),
      quant: json['quant'] as String?,
      diskBytes: json['disk_bytes'] as int? ?? 0,
      sizeLabel: json['size_label'] as String? ?? '',
      description: json['description'] as String?,
    );
  }
}

/// Result of the autopilot hardware-based model recommendation.
class AutopilotResult {
  final String recommendedModelId;
  final String reason;
  final SpeedRating expectedSpeed;
  final double estimatedTokPerS;

  const AutopilotResult({
    required this.recommendedModelId,
    required this.reason,
    required this.expectedSpeed,
    required this.estimatedTokPerS,
  });

  factory AutopilotResult.fromJson(Map<String, dynamic> json) {
    return AutopilotResult(
      recommendedModelId: json['recommended_model_id'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      expectedSpeed: _parseSpeed(json['expected_speed'] as String?),
      estimatedTokPerS:
          (json['estimated_tok_per_s'] as num? ?? 0).toDouble(),
    );
  }

  static SpeedRating _parseSpeed(String? s) {
    switch (s) {
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
}

/// Communicates with the Model Manager service (port 8101).
///
/// Handles model CRUD, downloads with pause/resume, verification,
/// curated model catalogue, and hardware-based autopilot recommendation.
class ModelService {
  static ModelService? _instance;
  final ApiClient _api;

  ModelService._(this._api);

  factory ModelService() {
    _instance ??= ModelService._(
      ApiClient(
        baseUrl: ServiceUrls.modelManager,
        // Downloads can take a long time — use longer timeout.
        downloadTimeout: const Duration(seconds: 300),
      ),
    );
    return _instance!;
  }

  // ── Model listing ─────────────────────────────────────────────────

  /// List all models known to the model manager.
  Future<List<AIModel>> listModels() async {
    try {
      final items = await _api.getList('/models');
      return items
          .map((e) => _parseAIModel(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      logService('model', 'Failed to list models', error: e);
      return [];
    }
  }

  /// Fetch the curated model catalogue.
  Future<List<CuratedModel>> getCuratedModels() async {
    try {
      final items = await _api.getList('/models/curated');
      return items
          .map((e) =>
              CuratedModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      logService('model', 'Failed to get curated models', error: e);
      return [];
    }
  }

  // ── Model CRUD ────────────────────────────────────────────────────

  /// Add a model (e.g. from HuggingFace or a local path).
  /// Returns the created [AIModel], or `null` on failure.
  Future<AIModel?> addModel({
    required String source,
    required String sourceRef,
  }) async {
    try {
      final data = await _api.post('/models/add', body: {
        'source': source,
        'source_ref': sourceRef,
      });
      return _parseAIModel(data);
    } catch (e) {
      logService('model', 'Failed to add model', error: e);
      return null;
    }
  }

  /// Delete a model by its ID.
  Future<bool> deleteModel(String modelId) async {
    try {
      await _api.delete('/models/$modelId');
      return true;
    } catch (e) {
      logService('model', 'Failed to delete model $modelId', error: e);
      return false;
    }
  }

  // ── Downloads ─────────────────────────────────────────────────────

  /// Get the current download status for [modelId].
  Future<DownloadStatus> getDownloadStatus(String modelId) async {
    try {
      final data = await _api.get('/models/status/$modelId');
      return _parseDownloadStatus(data['status'] as String?);
    } catch (e) {
      logService('model', 'Failed to get download status', error: e);
      return DownloadStatus.error;
    }
  }

  /// Pause an in-progress download.
  Future<bool> pauseDownload(String modelId) async {
    try {
      await _api.post('/models/download/$modelId/pause');
      return true;
    } catch (e) {
      logService('model', 'Failed to pause download', error: e);
      return false;
    }
  }

  /// Resume a paused download.
  Future<bool> resumeDownload(String modelId) async {
    try {
      await _api.post('/models/download/$modelId/resume');
      return true;
    } catch (e) {
      logService('model', 'Failed to resume download', error: e);
      return false;
    }
  }

  /// Poll download progress. Yields maps with `status`, `progress`, etc.
  /// Completes when status becomes `ready` or `error`.
  Stream<Map<String, dynamic>> watchDownloadProgress(
    String modelId, {
    Duration interval = const Duration(seconds: 1),
  }) async* {
    while (true) {
      try {
        final status = await _api.get('/models/status/$modelId');
        yield status;
        final s = status['status'] as String?;
        if (s == 'ready' || s == 'error') break;
      } catch (e) {
        yield {'status': 'error', 'message': e.toString()};
        break;
      }
      await Future.delayed(interval);
    }
  }

  // ── Verification ──────────────────────────────────────────────────

  /// Verify the integrity (checksum) of a downloaded model.
  /// Returns `true` if verification passes, `false` otherwise.
  Future<bool> verifyModel(String modelId) async {
    try {
      final data = await _api.post('/models/verify/$modelId');
      return data['verified'] == true;
    } catch (e) {
      logService('model', 'Verification failed for $modelId', error: e);
      return false;
    }
  }

  // ── Autopilot recommendation ──────────────────────────────────────

  /// Get a model recommendation based on the provided hardware info.
  Future<AutopilotResult?> getRecommendation(
      HardwareScanResult hardwareInfo) async {
    try {
      final data = await _api.post('/models/recommend', body: {
        'ram_mb': hardwareInfo.ramMb,
        'cpu_name': hardwareInfo.cpuName,
        'cpu_cores': hardwareInfo.cpuCores,
        'hw_fingerprint': hardwareInfo.hwFingerprint,
        if (hardwareInfo.gpu != null)
          'gpu': {
            'name': hardwareInfo.gpu!.name,
            'vram_mb': hardwareInfo.gpu!.vramMb,
            'detected': hardwareInfo.gpu!.detected,
          },
        'disk': {
          'type': hardwareInfo.disk.type,
          'read_mbps': hardwareInfo.disk.readMbps,
        },
      });
      return AutopilotResult.fromJson(data);
    } catch (e) {
      logService('model', 'Recommendation failed', error: e);
      return null;
    }
  }

  // ── Parsing helpers ───────────────────────────────────────────────

  AIModel _parseAIModel(Map<String, dynamic> json) {
    return AIModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      source: _parseModelSource(json['source'] as String?),
      sourceRef: json['source_ref'] as String?,
      paramsBillion: (json['params_billion'] as num? ?? 0).toDouble(),
      quant: json['quant'] as String?,
      diskBytes: json['disk_bytes'] as int? ?? 0,
      arch: json['arch'] as String?,
      contextMax: json['context_max'] as int? ?? 0,
      checksum: json['checksum'] as String?,
      speedRating: _parseSpeedRating(json['speed_rating'] as String?),
      predictedTokPerS:
          (json['predicted_tok_per_s'] as num? ?? 0).toDouble(),
      predictedTtftMs: json['predicted_ttft_ms'] as int? ?? 0,
      sizeLabel: json['size_label'] as String? ?? '',
      isActive: json['is_active'] as bool? ?? false,
      isRecommended: json['is_recommended'] as bool? ?? false,
      lastUsedAt: json['last_used_at'] != null
          ? DateTime.tryParse(json['last_used_at'] as String)
          : null,
      downloadStatus:
          _parseDownloadStatus(json['download_status'] as String?),
      downloadProgress:
          (json['download_progress'] as num?)?.toDouble(),
    );
  }

  ModelSource _parseModelSource(String? s) {
    switch (s) {
      case 'hf':
        return ModelSource.hf;
      case 'local':
        return ModelSource.local;
      case 'curated':
        return ModelSource.curated;
      default:
        return ModelSource.hf;
    }
  }

  SpeedRating _parseSpeedRating(String? s) {
    switch (s) {
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

  DownloadStatus _parseDownloadStatus(String? s) {
    switch (s) {
      case 'not_downloaded':
        return DownloadStatus.notDownloaded;
      case 'downloading':
        return DownloadStatus.downloading;
      case 'paused':
        return DownloadStatus.paused;
      case 'verifying':
        return DownloadStatus.verifying;
      case 'ready':
        return DownloadStatus.ready;
      case 'error':
        return DownloadStatus.error;
      default:
        return DownloadStatus.notDownloaded;
    }
  }
}
