// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;

/// Per-service base URLs for all backend microservices.
class ServiceUrls {
  static const supervisor = 'http://127.0.0.1:8110';
  static const inference = 'http://127.0.0.1:8100';
  static const modelManager = 'http://127.0.0.1:8101';
  static const documents = 'http://127.0.0.1:8102';
  static const clara = 'http://127.0.0.1:8103';
  static const lre = 'http://127.0.0.1:8104';
  static const orchestrator = 'http://127.0.0.1:8105';
}

/// Reusable HTTP client for communicating with a single backend service.
///
/// **Creation pattern**: Services that are provided via `main.dart` receive
/// an injected [ApiClient] (e.g. `HardwareService`, `ModelManagerService`).
/// Singleton services (e.g. `SupervisorService`, `InferenceService`) create
/// their own [ApiClient] internally — these are long-lived and disposed with
/// the singleton. Avoid creating short-lived [ApiClient]s in hot paths; prefer
/// reusing the service's instance.
///
/// Provides GET, POST, PUT, DELETE with JSON (de)serialization, file
/// uploads, configurable timeouts, and structured error handling.
class ApiClient {
  final String baseUrl;
  final http.Client _http;
  final Duration _timeout;
  final Duration _downloadTimeout;

  /// Create a client for [baseUrl].
  ///
  /// [timeout] applies to normal requests (default 30 s).
  /// [downloadTimeout] applies to long-running requests such as file
  /// downloads (default 120 s).
  ApiClient({
    required this.baseUrl,
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
    Duration downloadTimeout = const Duration(seconds: 120),
  })  : _http = client ?? http.Client(),
        _timeout = timeout,
        _downloadTimeout = downloadTimeout;

  /// Quick health check — returns true if the service responds to GET /health.
  bool _available = false;
  bool get isAvailable => _available;

  Future<bool> checkAvailable() async {
    try {
      await get('/health');
      _available = true;
    } catch (_) {
      _available = false;
    }
    return _available;
  }

  // ── HTTP helpers ──────────────────────────────────────────────────────

  /// GET [path] and return the decoded JSON object.
  Future<Map<String, dynamic>> get(String path) async {
    final response = await _http
        .get(
          Uri.parse('$baseUrl$path'),
          headers: _jsonHeaders,
        )
        .timeout(_timeout);
    _checkResponse(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// GET [path] and return a decoded JSON list.
  Future<List<dynamic>> getList(String path) async {
    final response = await _http
        .get(
          Uri.parse('$baseUrl$path'),
          headers: _jsonHeaders,
        )
        .timeout(_timeout);
    _checkResponse(response);
    return jsonDecode(response.body) as List<dynamic>;
  }

  /// POST [path] with an optional JSON [body]. Returns decoded JSON object.
  Future<Map<String, dynamic>> post(String path,
      {Map<String, dynamic>? body}) async {
    final response = await _http
        .post(
          Uri.parse('$baseUrl$path'),
          headers: _jsonHeaders,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(_timeout);
    _checkResponse(response);
    if (response.body.isEmpty) return <String, dynamic>{};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// POST [path] and return a decoded JSON list.
  Future<List<dynamic>> postList(String path,
      {Map<String, dynamic>? body}) async {
    final response = await _http
        .post(
          Uri.parse('$baseUrl$path'),
          headers: _jsonHeaders,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(_timeout);
    _checkResponse(response);
    return jsonDecode(response.body) as List<dynamic>;
  }

  /// PUT [path] with an optional JSON [body]. Returns decoded JSON object.
  Future<Map<String, dynamic>> put(String path,
      {Map<String, dynamic>? body}) async {
    final response = await _http
        .put(
          Uri.parse('$baseUrl$path'),
          headers: _jsonHeaders,
          body: body != null ? jsonEncode(body) : null,
        )
        .timeout(_timeout);
    _checkResponse(response);
    if (response.body.isEmpty) return <String, dynamic>{};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// DELETE [path]. Returns decoded JSON object (or empty map).
  Future<Map<String, dynamic>> delete(String path) async {
    final response = await _http
        .delete(
          Uri.parse('$baseUrl$path'),
          headers: _jsonHeaders,
        )
        .timeout(_timeout);
    _checkResponse(response);
    if (response.body.isEmpty) return <String, dynamic>{};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Upload a file at [filePath] via multipart POST to [path].
  /// The file is attached under [fieldName].
  Future<Map<String, dynamic>> uploadFile(
    String path,
    String filePath,
    String fieldName,
  ) async {
    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl$path'));
    request.files
        .add(await http.MultipartFile.fromPath(fieldName, filePath));
    final streamedResponse =
        await request.send().timeout(_downloadTimeout);
    final response = await http.Response.fromStream(streamedResponse);
    _checkResponse(response);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// GET that returns the raw response body as a String.
  /// Useful for export endpoints that return plain text / markdown.
  Future<String> getRaw(String path) async {
    final response = await _http
        .get(
          Uri.parse('$baseUrl$path'),
          headers: _jsonHeaders,
        )
        .timeout(_timeout);
    _checkResponse(response);
    return response.body;
  }

  // ── Internals ─────────────────────────────────────────────────────────

  Map<String, String> get _jsonHeaders => {
        HttpHeaders.contentTypeHeader: 'application/json',
        HttpHeaders.acceptHeader: 'application/json',
      };

  void _checkResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;

    String message;
    try {
      final body = jsonDecode(response.body);
      message = body['detail'] ?? body['error'] ?? response.body;
    } catch (_) {
      message = response.body;
    }
    throw ApiException(response.statusCode, message);
  }

  void dispose() {
    _http.close();
  }
}

// ── Exception types ───────────────────────────────────────────────────────

/// Represents an HTTP error returned by the backend.
class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

// ── Logging helper ────────────────────────────────────────────────────────

/// Convenience logger for all service files.
void logService(String service, String message, {Object? error}) {
  developer.log(
    message,
    name: 'studiomc.$service',
    error: error,
  );
}
