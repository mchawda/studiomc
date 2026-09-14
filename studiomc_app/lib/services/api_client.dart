// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;

/// Per-service base URLs for all backend microservices.
///
/// Override [_host] at startup via the STUDIOMC_SERVICE_HOST environment
/// variable (e.g. for remote or container-based backends).
class ServiceUrls {
  static const _host = String.fromEnvironment(
    'STUDIOMC_SERVICE_HOST',
    defaultValue: '127.0.0.1',
  );

  static const supervisor = 'http://$_host:8110';
  static const inference = 'http://$_host:8100';
  static const modelManager = 'http://$_host:8101';
  static const documents = 'http://$_host:8102';
  static const clara = 'http://$_host:8103';
  static const lre = 'http://$_host:8104';
  static const orchestrator = 'http://$_host:8105';
  static const training = 'http://$_host:8106';
  static const dataRecipes = 'http://$_host:8107';
  static const mcp = 'http://$_host:8108';
  static const memory = 'http://$_host:8109';
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

  /// PATCH [path] with an optional JSON [body]. Returns decoded JSON object.
  Future<Map<String, dynamic>> patch(String path,
      {Map<String, dynamic>? body}) async {
    final request = http.Request('PATCH', Uri.parse('$baseUrl$path'));
    request.headers.addAll(_jsonHeaders);
    if (body != null) request.body = jsonEncode(body);
    final streamed = await _http.send(request).timeout(_timeout);
    final response = await http.Response.fromStream(streamed);
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

    String message = response.body;
    Map<String, dynamic>? bodyJson;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        bodyJson = decoded;
        message = (decoded['detail'] ?? decoded['error'] ?? decoded['message'] ?? response.body)
            .toString();
      }
    } catch (_) {/* non-JSON body — keep raw */}

    // Pro pack contract: any service can raise 412 + error="pro_pack_required"
    // (see services/SPLIT_BUNDLE.md). Surface a typed exception so the UI
    // can pop the install dialog instead of a generic error toast.
    if (response.statusCode == 412 &&
        bodyJson != null &&
        bodyJson['error'] == 'pro_pack_required') {
      throw ProPackRequiredException.fromJson(bodyJson);
    }

    throw ApiException(response.statusCode, message, body: bodyJson);
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

  /// Decoded JSON body when the response was JSON, else `null`.
  /// Useful for callers that want to inspect a structured error envelope
  /// (e.g. validation errors, retry hints, etc.) without re-parsing.
  final Map<String, dynamic>? body;

  ApiException(this.statusCode, this.message, {this.body});

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thrown when any backend service refuses a request because the optional
/// Studiomc Pro pack (heavy ML stack: PyTorch + transformers + peft +
/// sentence-transformers + MLX) is not installed or is on the wrong
/// version. The Flutter UI catches this and shows
/// [ProPackInstallDialog] instead of a generic error.
///
/// The 412 envelope contract is documented in
/// `services/SPLIT_BUNDLE.md` and produced by
/// `services/common/fastapi_pro_pack.py`.
class ProPackRequiredException extends ApiException {
  /// Which feature triggered the requirement (e.g. `"training"`,
  /// `"mlx"`, `"splicellm"`). Used to give the user a friendly reason.
  final String feature;

  /// The Pro pack version this Studiomc build needs.
  final String requiredVersion;

  /// Currently installed Pro pack version, or `null` if none.
  final String? currentVersion;

  /// `true` when a Pro pack is installed but on the wrong version.
  /// (Distinguishes "need to install" from "need to upgrade" in the UI.)
  final bool needsUpgrade;

  ProPackRequiredException({
    required this.feature,
    required this.requiredVersion,
    required this.currentVersion,
    required this.needsUpgrade,
    required String message,
    Map<String, dynamic>? body,
  }) : super(412, message, body: body);

  factory ProPackRequiredException.fromJson(Map<String, dynamic> json) {
    final pack = (json['pro_pack'] as Map<String, dynamic>?) ?? const {};
    return ProPackRequiredException(
      feature: (json['feature'] as String?) ?? 'unknown',
      requiredVersion: (json['required_version'] as String?) ?? 'unknown',
      currentVersion: pack['version'] as String?,
      needsUpgrade: pack['needs_upgrade'] == true,
      message: (json['message'] as String?) ??
          'This feature requires the Studiomc Pro pack.',
      body: json,
    );
  }

  @override
  String toString() =>
      'ProPackRequiredException($feature, need=$requiredVersion, have=${currentVersion ?? "none"})';
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
