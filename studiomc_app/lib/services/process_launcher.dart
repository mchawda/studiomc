// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/platform_utils.dart';
import 'api_client.dart';

/// Automatically launches the Python backend services.
///
/// The app ALWAYS starts its own backend — users never touch Python.
///
/// Resolution order:
///   1. Bundled executable (production release builds)
///   2. Python venv in the services/ directory (development)
///   3. System python3 (fallback)
class ProcessLauncher {
  ProcessLauncher._();

  static Process? _backendProcess;
  static bool _launched = false; // ignore: unused_field — tracks launch state for debugging
  static Future<bool>? _launchInFlight;
  static String? _lastLaunchError;

  static bool get isManaged => _backendProcess != null;
  static String? get lastLaunchError => _lastLaunchError;

  /// Quick check if the supervisor on port 8110 responds to /health.
  static Future<bool> isSupervisorHealthy() => _isAlreadyRunning();

  // ── Public API ──────────────────────────────────────────────────────────

  /// Launch the backend and wait until the supervisor is healthy.
  /// Safe to call multiple times — only the first call has an effect.
  /// On mobile platforms, this is a no-op (cannot spawn processes).
  static Future<bool> launchBackend() async {
    if (isMobile) {
      _log('Skipping backend launch — not available on mobile');
      return false;
    }

    // Fast path: service already healthy (even if we didn't launch it).
    if (await _isAlreadyRunning()) {
      _launched = true;
      _lastLaunchError = null;
      _log('Supervisor already running at ${ServiceUrls.supervisor}');
      return true;
    }

    // De-duplicate concurrent launch attempts.
    if (_launchInFlight != null) {
      return await _launchInFlight!;
    }

    _launchInFlight = _launchBackendInternal();
    try {
      return await _launchInFlight!;
    } finally {
      _launchInFlight = null;
    }
  }

  static Future<bool> _launchBackendInternal() async {
    _launched = true;
    _lastLaunchError = null;

    // 1. Check if supervisor is already running (e.g. started in terminal)
    if (await _isAlreadyRunning()) return true;

    // 2. Try bundled executable (production)
    final bundled = _findBundledExecutable();
    if (bundled != null) {
      _log('Launching bundled backend: $bundled');
      return _startProcess(bundled, []);
    }

    // 3. Try development venv
    final devSetup = _findDevPython();
    if (devSetup != null) {
      _log('Launching dev backend: ${devSetup.python} ${devSetup.appPy}');
      return _startProcess(devSetup.python, [devSetup.appPy],
          workingDirectory: devSetup.servicesDir);
    }

    _launched = false; // allow future retries
    _lastLaunchError = 'Could not find bundled backend or development Python runtime.';
    _log('ERROR: $_lastLaunchError');
    return false;
  }

  /// Gracefully shut down the backend if we launched it.
  static Future<void> shutdownBackend() async {
    final proc = _backendProcess;
    if (proc == null) return;

    _log('Shutting down backend (pid=${proc.pid})…');
    proc.kill(ProcessSignal.sigterm);

    final exitCode = await proc.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _log('Backend did not exit in 10s — SIGKILL');
        proc.kill(ProcessSignal.sigkill);
        return proc.exitCode;
      },
    );

    _log('Backend exited with code $exitCode');
    _backendProcess = null;
  }

  // ── Internal ────────────────────────────────────────────────────────────

  static Future<bool> _isAlreadyRunning() async {
    try {
      final client = ApiClient(
        baseUrl: ServiceUrls.supervisor,
        timeout: const Duration(seconds: 2),
      );
      final result = await client.checkAvailable();
      client.dispose();
      return result;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _startProcess(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async {
    try {
      // Fresh machines can lose executable bit when files are copied/unpacked.
      if (!Platform.isWindows) {
        final exeFile = File(executable);
        if (exeFile.existsSync()) {
          try {
            await Process.run('chmod', ['+x', executable]);
          } catch (_) {}
        }
      }

      final env = Map<String, String>.from(Platform.environment);
      env['PYTHONUNBUFFERED'] = '1';

      _backendProcess = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: env,
      );

      _log('Backend started (pid=${_backendProcess!.pid})');

      // Forward output to dev console
      _backendProcess!.stdout.listen((data) {
        _log(String.fromCharCodes(data).trimRight());
      });
      _backendProcess!.stderr.listen((data) {
        _log('[err] ${String.fromCharCodes(data).trimRight()}');
      });

      _backendProcess!.exitCode.then((code) {
        _log('Backend process exited with code $code');
        _backendProcess = null;
        _launched = false; // allow clean relaunch after crash/exit
        if (code != 0 && _lastLaunchError == null) {
          _lastLaunchError = 'Backend exited unexpectedly with code $code.';
        }
      });

      // Check for early crash — if process exits within 3s, it failed to start
      await Future.delayed(const Duration(seconds: 3));
      if (_backendProcess == null) {
        _launched = false;
        _lastLaunchError = 'Backend process crashed immediately after launch.';
        _log('ERROR: $_lastLaunchError');
        return false;
      }

      // Wait for supervisor to become healthy (up to 45s — first launch
      // does hardware scan + starts 7 services sequentially)
      final healthy = await _waitForHealthy(timeout: const Duration(seconds: 45));
      if (!healthy) {
        _launched = false;
        _lastLaunchError = 'Backend started but supervisor health check timed out.';
      } else {
        _lastLaunchError = null;
      }
      return healthy;
    } catch (e) {
      _launched = false;
      _lastLaunchError = 'Failed to launch backend: $e';
      _log('Failed to launch backend: $e');
      return false;
    }
  }

  static Future<bool> _waitForHealthy({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final client = ApiClient(
      baseUrl: ServiceUrls.supervisor,
      timeout: const Duration(seconds: 2),
    );

    while (DateTime.now().isBefore(deadline)) {
      try {
        if (await client.checkAvailable()) {
          client.dispose();
          _log('Supervisor is healthy');
          return true;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }

    client.dispose();
    _log('Timeout waiting for supervisor health check');
    return false;
  }

  // ── Path resolution ─────────────────────────────────────────────────────

  /// Find the bundled executable (production builds).
  static String? _findBundledExecutable() {
    final exe = Platform.resolvedExecutable;

    List<String> candidates = [];

    if (Platform.isMacOS) {
      final macosDir = File(exe).parent.path;
      final contentsDir = File(macosDir).parent.path;
      candidates = [
        '$contentsDir/Resources/studiomc_services/studiomc_services',
      ];
    } else if (Platform.isWindows) {
      final appDir = File(exe).parent.path;
      candidates = [
        '$appDir/studiomc_services/studiomc_services.exe',
      ];
    } else if (Platform.isLinux) {
      final appDir = File(exe).parent.path;
      candidates = [
        '$appDir/studiomc_services/studiomc_services',
        '$appDir/lib/studiomc_services/studiomc_services',
      ];
    }

    for (final path in candidates) {
      final exists = File(path).existsSync();
      _log('Checking bundled path: $path (exists: $exists)');
      if (exists) return path;
    }
    _log('No bundled executable found');
    return null;
  }

  /// Find the development Python venv and supervisor app.py.
  static _DevPython? _findDevPython() {
    // Walk up from the Flutter app to find the services/ directory
    final exe = Platform.resolvedExecutable;
    Directory? current;

    if (Platform.isMacOS) {
      // Release: .../studiomc_app.app/Contents/MacOS/studiomc_app
      // The project root is several levels up
      current = File(exe).parent;
      // Walk up to find a directory containing 'services/'
      for (int i = 0; i < 10; i++) {
        final servicesDir = Directory('${current!.path}/services');
        if (servicesDir.existsSync()) {
          return _resolveDevPython(servicesDir.path);
        }
        // Also check sibling — the app is in studiomc_app/, services is at same level
        final parent = current.parent;
        final siblingServices = Directory('${parent.path}/services');
        if (siblingServices.existsSync()) {
          return _resolveDevPython(siblingServices.path);
        }
        current = parent;
      }
    }

    // Fallback: check STUDIOMC_SERVICES_PATH env var
    final envPath = Platform.environment['STUDIOMC_SERVICES_PATH'];
    if (envPath != null && Directory(envPath).existsSync()) {
      return _resolveDevPython(envPath);
    }

    return null;
  }

  static _DevPython? _resolveDevPython(String servicesDir) {
    final appPy = '$servicesDir/supervisor/app.py';
    if (!File(appPy).existsSync()) return null;

    // Prefer venv Python
    final venvPython = '$servicesDir/.venv/bin/python';
    if (File(venvPython).existsSync()) {
      return _DevPython(
        python: venvPython,
        appPy: appPy,
        servicesDir: servicesDir,
      );
    }

    // Fallback: Homebrew python3
    for (final p in ['/opt/homebrew/bin/python3', '/usr/local/bin/python3', 'python3']) {
      try {
        final result = Process.runSync('which', [p]);
        if (result.exitCode == 0) {
          return _DevPython(python: p, appPy: appPy, servicesDir: servicesDir);
        }
      } catch (e) {
        _log('Python lookup failed for $p: $e');
      }
    }

    return null;
  }

  static void _log(String message) {
    debugPrint('[launcher] $message');
    developer.log(message, name: 'studiomc.launcher');
  }
}

class _DevPython {
  final String python;
  final String appPy;
  final String servicesDir;
  const _DevPython({
    required this.python,
    required this.appPy,
    required this.servicesDir,
  });
}
