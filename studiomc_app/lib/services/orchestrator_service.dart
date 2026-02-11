// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:studiomc_app/services/api_client.dart';

/// Handles reasoning runs via the Orchestrator service (port 8105).
///
/// Supports fast, cited, and investigate modes with budget enforcement,
/// planning, tool execution, and citation tracking.
class OrchestratorService {
  static OrchestratorService? _instance;
  final ApiClient _api;

  OrchestratorService._(this._api);

  factory OrchestratorService() {
    _instance ??= OrchestratorService._(
      ApiClient(baseUrl: ServiceUrls.orchestrator),
    );
    return _instance!;
  }

  /// Check if orchestrator is available.
  Future<bool> checkAvailable() async {
    return await _api.checkAvailable();
  }

  /// Execute a reasoning run.
  ///
  /// Returns a map with:
  /// - `answer`: final answer string
  /// - `citations`: list of citation objects
  /// - `trace`: list of trace step objects
  /// - `metrics`: map with total_ms, tool_calls, etc.
  /// - `stopped_reason`: optional string if budget was exceeded
  Future<Map<String, dynamic>> runReasoning({
    required String chatId,
    required String userQuery,
    required String mode, // "fast", "cited", or "investigate"
    String? collectionId,
    Map<String, dynamic>? budgets,
  }) async {
    try {
      final body = <String, dynamic>{
        'chat_id': chatId,
        'user_query': userQuery,
        'mode': mode,
        if (collectionId != null) 'collection_id': collectionId,
        if (budgets != null) 'budgets': budgets,
      };

      final response = await _api.post('/reasoning/run', body: body);
      return response;
    } catch (e) {
      logService('orchestrator', 'Reasoning run failed', error: e);
      rethrow;
    }
  }

  /// Get all reasoning runs for a chat.
  Future<List<Map<String, dynamic>>> getReasoningRuns(String chatId) async {
    try {
      final response = await _api.getList('/reasoning/runs/$chatId');
      return response.cast<Map<String, dynamic>>();
    } catch (e) {
      logService('orchestrator', 'Get reasoning runs failed', error: e);
      return [];
    }
  }

  void dispose() {
    _api.dispose();
  }
}
