// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

// ════════════════════════════════════════════════════════════════════════
// Pro pack client
//
// Talks to the Supervisor's `/api/pro-pack/*` endpoints to manage the
// optional Studiomc Pro pack (PyTorch + transformers + peft + MLX, ~1 GB).
//
// Three operations:
//   1. status()    — is the pack installed and current?
//   2. install()   — stream progress events while the pack downloads,
//                    verifies (sha256), extracts (.tar.zst), and atomically
//                    swaps in the new env directory.
//   3. uninstall() — reclaim disk space.
//
// The streaming installer is exposed as `Stream<ProPackProgress>` so any
// UI can show a progress bar without coupling to a specific widget.
// ════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:studiomc_app/services/api_client.dart';

/// One progress tick from the Pro pack installer.
///
/// Mirrors `services/common/pro_pack_installer.py::ProgressEvent`.
class ProPackProgress {
  /// Logical phase: `download`, `verify`, `extract`, `install`, `done`,
  /// `error`. `done` and `error` are terminal — no further events follow.
  final String stage;

  /// 0.0 → 1.0 within the current stage. `null` when unknown
  /// (e.g. some extract steps).
  final double? progress;

  /// Human-readable status line for the UI.
  final String message;

  /// Bytes downloaded / total — populated during `download` only.
  final int? bytesDone;
  final int? bytesTotal;

  /// Set when [stage] is `error`.
  final String? error;

  const ProPackProgress({
    required this.stage,
    required this.message,
    this.progress,
    this.bytesDone,
    this.bytesTotal,
    this.error,
  });

  bool get isTerminal => stage == 'done' || stage == 'error';
  bool get isError => stage == 'error';
  bool get isDone => stage == 'done';

  factory ProPackProgress.fromJson(Map<String, dynamic> json) {
    return ProPackProgress(
      stage: (json['stage'] as String?) ?? 'unknown',
      message: (json['message'] as String?) ?? '',
      progress: (json['progress'] as num?)?.toDouble(),
      bytesDone: json['bytes_done'] as int?,
      bytesTotal: json['bytes_total'] as int?,
      error: json['error'] as String?,
    );
  }
}

/// Snapshot of the Pro pack's install state.
class ProPackStatus {
  final bool installed;
  final String? version;
  final String? pythonPath;
  final bool needsUpgrade;
  final String requiredVersion;

  const ProPackStatus({
    required this.installed,
    required this.version,
    required this.pythonPath,
    required this.needsUpgrade,
    required this.requiredVersion,
  });

  /// `true` when the pack is installed AND on the version this app needs.
  bool get isReady => installed && !needsUpgrade;

  factory ProPackStatus.fromJson(Map<String, dynamic> json) {
    return ProPackStatus(
      installed: json['installed'] == true,
      version: json['version'] as String?,
      pythonPath: json['python_path'] as String?,
      needsUpgrade: json['needs_upgrade'] == true,
      requiredVersion:
          (json['required_version'] as String?) ?? 'unknown',
    );
  }
}

/// Asset descriptor for a single platform's Pro pack tarball as published
/// by the GitHub Release `Pro pack` workflow (see `.github/workflows/pro_pack.yml`).
class ProPackAsset {
  final String archiveUrl;
  final String sha256;
  final String version;
  final String? manifestUrl;

  const ProPackAsset({
    required this.archiveUrl,
    required this.sha256,
    required this.version,
    this.manifestUrl,
  });
}

/// HTTP client for `/api/pro-pack/*`.
class ProPackService {
  static ProPackService? _instance;
  factory ProPackService() => _instance ??= ProPackService._();
  ProPackService._();

  final ApiClient _api = ApiClient(
    baseUrl: ServiceUrls.supervisor,
    // The install endpoint streams; per-request we use a raw http.Client
    // below, but keep a regular ApiClient for the small status/uninstall
    // calls so error handling (incl. ProPackRequiredException) stays
    // consistent with the rest of the app.
    timeout: const Duration(seconds: 15),
  );

  /// Fetch the current Pro pack status from the supervisor.
  ///
  /// Returns `null` if the supervisor is unreachable; callers should treat
  /// that as "unknown" (typically: assume not installed and let the user
  /// retry).
  Future<ProPackStatus?> getStatus() async {
    try {
      final json = await _api.get('/api/pro-pack/status');
      return ProPackStatus.fromJson(json);
    } catch (e) {
      logService('pro_pack', 'Failed to fetch status', error: e);
      return null;
    }
  }

  /// Stream Pro pack installation progress as the supervisor downloads
  /// and unpacks [asset].
  ///
  /// Each emitted [ProPackProgress] is one SSE event from the supervisor.
  /// The stream completes after a `done` event or errors via [StateError]
  /// after an `error` event (so callers can use `await for` + try/catch).
  ///
  /// The connection stays open for the entire install — typically 30 s
  /// to several minutes depending on network speed and disk type.
  Stream<ProPackProgress> install(ProPackAsset asset) async* {
    final uri = Uri.parse('${ServiceUrls.supervisor}/api/pro-pack/install');
    final request = http.Request('POST', uri)
      ..headers[HttpHeaders.contentTypeHeader] = 'application/json'
      ..headers[HttpHeaders.acceptHeader] = 'text/event-stream'
      ..body = jsonEncode({
        'archive_url': asset.archiveUrl,
        'sha256': asset.sha256,
        'version': asset.version,
        if (asset.manifestUrl != null) 'manifest_url': asset.manifestUrl,
      });

    final client = http.Client();
    try {
      final streamed = await client.send(request);
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        throw ApiException(
          streamed.statusCode,
          body.isEmpty ? 'install failed' : body,
        );
      }

      // SSE framing: events are separated by a blank line; each event has
      // one or more `field: value` lines. We only emit `data:` lines.
      final buffer = StringBuffer();
      await for (final chunk
          in streamed.stream.transform(utf8.decoder)) {
        buffer.write(chunk);
        while (true) {
          final raw = buffer.toString();
          final sep = raw.indexOf('\n\n');
          if (sep < 0) break;
          final frame = raw.substring(0, sep);
          buffer
            ..clear()
            ..write(raw.substring(sep + 2));

          for (final line in frame.split('\n')) {
            if (!line.startsWith('data:')) continue;
            final payload = line.substring(5).trim();
            if (payload.isEmpty) continue;
            final Map<String, dynamic> json;
            try {
              json = jsonDecode(payload) as Map<String, dynamic>;
            } catch (e) {
              logService('pro_pack',
                  'Bad SSE payload: $payload', error: e);
              continue;
            }
            final evt = ProPackProgress.fromJson(json);
            yield evt;
            if (evt.isError) {
              throw StateError(evt.error ?? evt.message);
            }
            if (evt.isDone) return;
          }
        }
      }
    } finally {
      client.close();
    }
  }

  /// Remove the installed Pro pack (~1 GB reclaimed). Returns `true` if
  /// something was actually removed.
  Future<bool> uninstall() async {
    try {
      final result = await _api.delete('/api/pro-pack');
      return result['removed'] == true;
    } catch (e) {
      logService('pro_pack', 'Uninstall failed', error: e);
      rethrow;
    }
  }
}
