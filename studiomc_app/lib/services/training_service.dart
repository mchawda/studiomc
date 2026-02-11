// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:convert';
import 'package:http/http.dart' as http;

class TrainingService {
  static const _baseUrl = 'http://127.0.0.1:8106';

  /// Start a new training run.
  /// Returns the run ID and adapter ID if successful.
  /// Throws on network errors or non-2xx responses so callers can show
  /// the actual error message.
  Future<Map<String, dynamic>?> startTraining({
    required String baseModelId,
    required String adapterName,
    required String sourceType,
    String? sourceRef,
    String? extractContent,
    String? personalizationGoal,
    List<String>? documentIds,
    List<String>? collectionIds,
  }) async {
    final url = Uri.parse('$_baseUrl/training/create');
    final body = {
      'base_model_id': baseModelId,
      'adapter_name': adapterName,
      'source_type': sourceType,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (extractContent != null) 'extract_content': extractContent,
      if (personalizationGoal != null) 'goal': personalizationGoal,
      if (documentIds != null && documentIds.isNotEmpty) 'document_ids': documentIds,
      if (collectionIds != null && collectionIds.isNotEmpty) 'collection_ids': collectionIds,
    };

    final http.Response response;
    try {
      response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw Exception('Cannot reach training service at $_baseUrl — $e');
    }

    if (response.statusCode == 200 || response.statusCode == 201) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    // Surface backend error message if available
    String detail = 'HTTP ${response.statusCode}';
    try {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      detail = decoded['detail'] as String? ?? decoded['error'] as String? ?? detail;
    } catch (_) {}
    throw Exception('Training service error: $detail');
  }

  /// Get list of available adapters
  Future<List<Map<String, dynamic>>> getAdapters() async {
    try {
      final url = Uri.parse('$_baseUrl/training/adapters');
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) {
          return data.cast<Map<String, dynamic>>();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Get status of a training run
  Future<Map<String, dynamic>?> getRunStatus(String runId) async {
    try {
      final url = Uri.parse('$_baseUrl/training/runs/$runId/status');
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Activate an adapter (make it the active one).
  /// Throws on failure so callers can display the error.
  Future<void> activateAdapter(String adapterId) async {
    final url = Uri.parse('$_baseUrl/training/adapters/$adapterId/activate');
    try {
      final resp = await http.post(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 && resp.statusCode != 204) {
        throw Exception('Activate failed (HTTP ${resp.statusCode})');
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('Cannot reach training service — $e');
    }
  }

  /// Delete an adapter.
  /// Throws on failure so callers can display the error.
  Future<void> deleteAdapter(String adapterId) async {
    final url = Uri.parse('$_baseUrl/training/adapters/$adapterId');
    try {
      final resp = await http.delete(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 && resp.statusCode != 204) {
        throw Exception('Delete failed (HTTP ${resp.statusCode})');
      }
    } on Exception {
      rethrow;
    } catch (e) {
      throw Exception('Cannot reach training service — $e');
    }
  }

  /// Get suggested extract prompts
  Future<List<Map<String, dynamic>>> getExtractPrompts() async {
    try {
      final url = Uri.parse('$_baseUrl/training/prompts');
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) {
          return data.cast<Map<String, dynamic>>();
        }
        return [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}
