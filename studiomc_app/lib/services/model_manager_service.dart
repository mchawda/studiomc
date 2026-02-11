// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'package:studiomc_app/services/api_client.dart';

/// Handles model downloads, verification, and management
/// via the local model manager service.
class ModelManagerService {
  final ApiClient _api;

  ModelManagerService(this._api);

  /// List all known models and their statuses from the model manager.
  Future<List<Map<String, dynamic>>> listModels() async {
    try {
      final list = await _api.getList('/models');
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Add a model (HuggingFace ID or local path).
  Future<Map<String, dynamic>> addModel({
    required String sourceRef,
    String source = 'hf',
  }) async {
    return _api.post('/models/add', body: {
      'source': source,
      'source_ref': sourceRef,
    });
  }

  /// Get download/status for a model.
  Future<Map<String, dynamic>> getModelStatus(String modelId) async {
    return _api.get('/models/status/$modelId');
  }

  /// Start or resume downloading a model.
  Future<void> downloadModel(String modelId) async {
    await _api.post('/models/download/$modelId/resume');
  }

  /// Pause a model download.
  Future<void> pauseDownload(String modelId) async {
    await _api.post('/models/download/$modelId/pause');
  }

  /// Delete a model.
  Future<void> deleteModel(String modelId) async {
    await _api.delete('/models/$modelId');
  }

  /// Verify model integrity (checksum).
  Future<Map<String, dynamic>> verifyModel(String modelId) async {
    return _api.post('/models/verify/$modelId');
  }

  /// Get recommended model for current hardware.
  /// [hwInfo] should contain the hardware scan result from the supervisor.
  Future<Map<String, dynamic>> getRecommendation({
    Map<String, dynamic>? hwInfo,
    String? userIntent,
  }) async {
    return _api.post('/models/recommend', body: {
      'hw_info': hwInfo ?? {
        'gpu_name': null,
        'vram_bytes': null,
        'ram_bytes': 0,
        'cpu_name': 'unknown',
        'cpu_cores': 1,
        'disk_type': 'unknown',
        'disk_read_mbps': 0,
        'hw_fingerprint': '',
      },
      if (userIntent != null) 'user_intent': userIntent,
    });
  }

  /// Poll download progress. Returns a stream of progress maps.
  Stream<Map<String, dynamic>> watchDownloadProgress(String modelId,
      {Duration interval = const Duration(seconds: 1)}) async* {
    while (true) {
      try {
        final status = await getModelStatus(modelId);
        yield status;
        if (status['status'] == 'ready' || status['status'] == 'error') {
          break;
        }
      } catch (e) {
        yield {'status': 'error', 'message': e.toString()};
        break;
      }
      await Future.delayed(interval);
    }
  }
}
