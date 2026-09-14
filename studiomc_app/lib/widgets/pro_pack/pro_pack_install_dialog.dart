// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

// ════════════════════════════════════════════════════════════════════════
// Pro pack install dialog
//
// Shown whenever a backend service replies 412 with `pro_pack_required`,
// or when the user explicitly asks to install/upgrade the Pro pack from
// Settings.
//
// Flow:
//   1. Render an explanation + size estimate.
//   2. On "Install", resolve the platform-appropriate asset from the
//      latest GitHub Release manifest.
//   3. Stream progress from `ProPackService.install()` and update the bar.
//   4. On done, return `true` so the caller can re-try the original
//      action that triggered the 412.
//
// The dialog deliberately stays UI-only — the GitHub manifest fetch and
// platform asset selection live here too because they're presentation
// concerns (which platform tag matches this build).
// ════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import 'package:studiomc_app/services/api_client.dart';
import 'package:studiomc_app/services/pro_pack_service.dart';
import 'package:studiomc_app/theme/app_theme.dart';

/// Default GitHub repo where the Pro pack release artifacts live.
/// Override at build time with `--dart-define=STUDIOMC_RELEASE_REPO=...`.
const String _kReleaseRepo = String.fromEnvironment(
  'STUDIOMC_RELEASE_REPO',
  defaultValue: 'studiomc-app/studiomc',
);

/// Show the Pro pack install dialog.
///
/// Returns `true` if the pack was installed successfully, `false` if the
/// user cancelled or the install failed (the dialog already showed the
/// error). The caller should re-issue the original API call when `true`.
///
/// [reason] is a short, user-facing explanation of *why* the pack is
/// needed (e.g. "Training a custom adapter requires the Pro pack.").
/// [requiredVersion] is sourced from the 412 envelope when applicable.
Future<bool> showProPackInstallDialog(
  BuildContext context, {
  required String reason,
  String? requiredVersion,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProPackDialog(
      reason: reason,
      requiredVersion: requiredVersion,
    ),
  );
  return result ?? false;
}

class _ProPackDialog extends StatefulWidget {
  final String reason;
  final String? requiredVersion;
  const _ProPackDialog({required this.reason, this.requiredVersion});

  @override
  State<_ProPackDialog> createState() => _ProPackDialogState();
}

enum _DialogPhase { idle, resolving, installing, done, error }

class _ProPackDialogState extends State<_ProPackDialog> {
  final ProPackService _service = ProPackService();

  _DialogPhase _phase = _DialogPhase.idle;
  ProPackProgress? _last;
  String? _error;
  StreamSubscription<ProPackProgress>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _startInstall() async {
    setState(() {
      _phase = _DialogPhase.resolving;
      _error = null;
    });

    final ProPackAsset asset;
    try {
      asset = await _resolveAsset(widget.requiredVersion);
    } catch (e) {
      setState(() {
        _phase = _DialogPhase.error;
        _error = 'Could not find a Pro pack release for this platform: $e';
      });
      return;
    }

    setState(() => _phase = _DialogPhase.installing);
    _sub = _service.install(asset).listen(
      (evt) => setState(() => _last = evt),
      onError: (e, _) => setState(() {
        _phase = _DialogPhase.error;
        _error = e.toString();
      }),
      onDone: () {
        if (!mounted) return;
        if (_phase == _DialogPhase.installing) {
          setState(() => _phase = _DialogPhase.done);
        }
      },
    );
  }

  // ── GitHub release asset resolution ────────────────────────────

  /// Pick the right asset for this platform from the latest (or pinned)
  /// GitHub Release of the studiomc repo, then fetch its sha256.
  Future<ProPackAsset> _resolveAsset(String? pinnedVersion) async {
    final platform = _detectPlatformTag();
    if (platform == null) {
      throw 'Unsupported platform (${Platform.operatingSystem})';
    }

    final tag = pinnedVersion != null ? 'v$pinnedVersion' : 'latest';
    final apiUrl = tag == 'latest'
        ? 'https://api.github.com/repos/$_kReleaseRepo/releases/latest'
        : 'https://api.github.com/repos/$_kReleaseRepo/releases/tags/$tag';

    final resp = await http
        .get(Uri.parse(apiUrl), headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw 'GitHub API ${resp.statusCode}';
    }

    final release = jsonDecode(resp.body) as Map<String, dynamic>;
    final assets = (release['assets'] as List?) ?? const [];

    Map<String, dynamic>? archive;
    Map<String, dynamic>? sha;
    Map<String, dynamic>? manifest;
    final namePattern = 'pro-$platform';
    for (final a in assets.cast<Map<String, dynamic>>()) {
      final name = (a['name'] as String?) ?? '';
      if (!name.contains(namePattern)) continue;
      if (name.endsWith('.tar.zst')) archive = a;
      if (name.endsWith('.sha256')) sha = a;
      if (name.endsWith('.manifest.json')) manifest = a;
    }
    if (archive == null || sha == null) {
      throw 'No Pro pack asset matched "$namePattern" in release ${release['tag_name']}';
    }

    final shaResp = await http
        .get(Uri.parse(sha['browser_download_url'] as String))
        .timeout(const Duration(seconds: 15));
    if (shaResp.statusCode != 200) {
      throw 'Could not download sha256 (${shaResp.statusCode})';
    }
    // sha256sum format: "<hex>  <filename>"
    final shaHex = shaResp.body.trim().split(RegExp(r'\s+')).first;

    final version = pinnedVersion ??
        ((release['tag_name'] as String?) ?? '').replaceFirst(RegExp(r'^v'), '');

    return ProPackAsset(
      archiveUrl: archive['browser_download_url'] as String,
      sha256: shaHex,
      version: version,
      manifestUrl: manifest?['browser_download_url'] as String?,
    );
  }

  /// Maps the host platform to the asset name suffix used by the Pro pack
  /// release pipeline (`.github/workflows/pro_pack.yml`).
  String? _detectPlatformTag() {
    if (Platform.isMacOS) {
      // We don't have a robust runtime arch check that works in the
      // Flutter sandbox without FFI; fall back to a heuristic on
      // the dart vm string. Apple Silicon's `Platform.version`
      // contains "arm64".
      final isArm = Platform.version.contains('arm64');
      return isArm ? 'macos-arm64' : 'macos-x64';
    }
    if (Platform.isLinux) return 'linux-x64';
    if (Platform.isWindows) return 'windows-x64';
    return null;
  }

  // ── UI ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(_phase == _DialogPhase.done
              ? Icons.check_circle
              : Icons.download_for_offline_outlined,
              color: _phase == _DialogPhase.done
                  ? AppTheme.success
                  : theme.colorScheme.primary),
          const SizedBox(width: 12),
          Text(_titleForPhase(), style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _bodyForPhase(theme),
        ),
      ),
      actions: _actionsForPhase(),
    );
  }

  String _titleForPhase() {
    switch (_phase) {
      case _DialogPhase.done:
        return 'Pro pack installed';
      case _DialogPhase.error:
        return 'Install failed';
      case _DialogPhase.installing:
      case _DialogPhase.resolving:
        return 'Installing Pro pack…';
      case _DialogPhase.idle:
        return widget.requiredVersion != null
            ? 'Install Studiomc Pro pack'
            : 'Studiomc Pro pack required';
    }
  }

  List<Widget> _bodyForPhase(ThemeData theme) {
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );

    switch (_phase) {
      case _DialogPhase.idle:
        return [
          Text(widget.reason, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Text(
            'The Pro pack adds local model training, MLX acceleration, and '
            'high-quality embeddings. It is a one-time download '
            '(~1 GB) and can be removed any time from Settings.',
            style: muted,
          ),
          if (widget.requiredVersion != null) ...[
            const SizedBox(height: 12),
            Text('Required version: ${widget.requiredVersion}', style: muted),
          ],
        ];

      case _DialogPhase.resolving:
        return const [
          LinearProgressIndicator(),
          SizedBox(height: 12),
          Text('Looking up the latest Pro pack release…'),
        ];

      case _DialogPhase.installing:
        final p = _last;
        final pct = p?.progress;
        final stage = p?.stage ?? 'starting';
        final msg = p?.message ?? 'Preparing…';
        return [
          LinearProgressIndicator(value: pct),
          const SizedBox(height: 12),
          Text(_stageLabel(stage), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(msg, style: muted),
          if (p?.bytesTotal != null && p!.bytesTotal! > 0) ...[
            const SizedBox(height: 4),
            Text(
              '${_formatBytes(p.bytesDone ?? 0)} / ${_formatBytes(p.bytesTotal!)}',
              style: muted,
            ),
          ],
        ];

      case _DialogPhase.done:
        return [
          Text('You\'re all set — Pro features are ready to use.',
              style: theme.textTheme.bodyMedium),
        ];

      case _DialogPhase.error:
        return [
          Text(_error ?? 'Unknown error',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppTheme.error)),
          const SizedBox(height: 8),
          Text(
            'You can retry, or check your network connection and the GitHub '
            'release page for the matching Pro pack asset.',
            style: muted,
          ),
        ];
    }
  }

  List<Widget> _actionsForPhase() {
    switch (_phase) {
      case _DialogPhase.idle:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton.icon(
            onPressed: _startInstall,
            icon: const Icon(Icons.download),
            label: const Text('Install Pro pack'),
          ),
        ];
      case _DialogPhase.resolving:
      case _DialogPhase.installing:
        return [
          TextButton(
            onPressed: () {
              _sub?.cancel();
              Navigator.of(context).pop(false);
            },
            child: const Text('Cancel'),
          ),
        ];
      case _DialogPhase.done:
        return [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ];
      case _DialogPhase.error:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: _startInstall,
            child: const Text('Retry'),
          ),
        ];
    }
  }

  String _stageLabel(String stage) {
    switch (stage) {
      case 'download':
        return 'Downloading…';
      case 'verify':
        return 'Verifying checksum…';
      case 'extract':
        return 'Extracting…';
      case 'install':
        return 'Installing…';
      case 'done':
        return 'Done';
      case 'error':
        return 'Error';
      default:
        return stage;
    }
  }

  String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

// ════════════════════════════════════════════════════════════════════════
// Convenience: wrap an action that may need the Pro pack.
// ════════════════════════════════════════════════════════════════════════

/// Run [action]. If it throws [ProPackRequiredException], prompt the user
/// to install the Pro pack and (on success) re-run [action] once.
///
/// Returns whatever [action] returns, or `null` if the user declined or
/// the install failed.
Future<T?> withProPackGuard<T>(
  BuildContext context,
  Future<T> Function() action, {
  String fallbackReason = 'This feature requires the Studiomc Pro pack.',
}) async {
  try {
    return await action();
  } on ProPackRequiredException catch (e) {
    if (!context.mounted) return null;
    final installed = await showProPackInstallDialog(
      context,
      reason: e.message.isNotEmpty ? e.message : fallbackReason,
      requiredVersion: e.requiredVersion,
    );
    if (!installed || !context.mounted) return null;
    return await action();
  }
}
