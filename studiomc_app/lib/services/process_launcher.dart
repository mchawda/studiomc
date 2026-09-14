// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';
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

  /// Rolling tail of the backend's stdout/stderr. When the frozen bundle
  /// dies before its own file logging is set up (missing module, failed
  /// bootloader, port already bound) this is the only place the reason
  /// survives, so it is folded into [lastLaunchError] for the UI.
  static const int _outputTailLines = 40;
  static final List<String> _recentOutput = <String>[];

  /// How long to wait for the supervisor's /health after spawning it.
  /// Mirrors `--supervisor-timeout` in scripts/ci/smoke_services_bundle.py;
  /// change both together.
  static const Duration supervisorStartupTimeout = Duration(seconds: 45);

  static bool get isManaged => _backendProcess != null;
  static String? get lastLaunchError => _lastLaunchError;

  /// Last lines the backend printed, oldest first. Empty if never launched.
  static List<String> get recentBackendOutput =>
      List.unmodifiable(_recentOutput);

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

    // Fast path: service already healthy and it is ours (or we decided to
    // adopt it). A healthy supervisor we did not start is handled below.
    if (await _isAlreadyRunning() && _mayAdoptRunningSupervisor()) {
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

    final bundled = _findBundledExecutable();

    // 1. Check if supervisor is already running (e.g. started in terminal)
    if (await _isAlreadyRunning()) {
      if (_mayAdoptRunningSupervisor()) return true;

      // Production build, and somebody else owns port 8110. Quitting the
      // app via Cmd+Q rarely delivers `AppLifecycleState.detached`, so the
      // previous session's supervisor (possibly an older version with a
      // different API) is usually still alive here. Adopting it made every
      // "install the fix and relaunch" look like the fix did nothing.
      _log('Supervisor at ${ServiceUrls.supervisor} was not started by this '
          'app instance; asking it to shut down before launching ours');
      final freed = await _requestForeignShutdown();
      if (!freed && Platform.isWindows) {
        // Our supervisor cannot evict port holders on Windows, so a fresh
        // launch would just fail to bind. Keep the running one.
        _adoptForeign = true;
        _log('Port still held; adopting the running supervisor');
        return true;
      }
      // On macOS/Linux the new supervisor kills stale port holders itself.
    }

    // 2. Try bundled executable (production)
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

  /// Set when we gave up replacing a foreign supervisor and use it as-is.
  static bool _adoptForeign = false;

  /// Whether a healthy supervisor on port 8110 may be used without
  /// relaunching. True for the one we spawned, for dev checkouts (no
  /// bundled executable, backend started by hand), and after an explicit
  /// adoption decision.
  static bool _mayAdoptRunningSupervisor() {
    if (isManaged || _adoptForeign) return true;
    return _findBundledExecutable() == null;
  }

  /// Ask a supervisor we do not own to stop, then wait for the port to be
  /// released. Returns true if the port is free afterwards.
  static Future<bool> _requestForeignShutdown() async {
    try {
      final client = ApiClient(
        baseUrl: ServiceUrls.supervisor,
        timeout: const Duration(seconds: 5),
      );
      try {
        await client.post('/shutdown');
      } catch (e) {
        // Supervisors older than v0.9.9.8 have no /shutdown; fall through
        // and let the new supervisor's stale-port cleanup handle it.
        _log('Foreign supervisor did not accept /shutdown: $e');
      } finally {
        client.dispose();
      }
    } catch (_) {}

    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (!await _isAlreadyRunning()) {
        _log('Foreign supervisor released ${ServiceUrls.supervisor}');
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    _log('Foreign supervisor still answering after 8s');
    return false;
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

      _recentOutput.clear();
      final process = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: env,
      );
      _backendProcess = process;

      _log('Backend started (pid=${process.pid})');

      // Forward output to the dev console and keep a tail for diagnostics.
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _recordOutput(line));
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _recordOutput(line, isError: true));

      int? exitCode;
      process.exitCode.then((code) {
        exitCode = code;
        _log('Backend process exited with code $code');
        if (identical(_backendProcess, process)) _backendProcess = null;
        _launched = false; // allow clean relaunch after crash/exit
        if (code != 0 && _lastLaunchError == null) {
          _lastLaunchError = _describeExit(code);
        }
      });

      // Poll /health until the supervisor answers. Give up early if the
      // process dies: waiting out the full timeout on a dead process hid
      // the real error behind a generic "timed out" for several releases.
      final healthy = await _waitForHealthy(
        timeout: supervisorStartupTimeout,
        isProcessAlive: () => exitCode == null,
      );
      if (healthy) {
        _lastLaunchError = null;
        return true;
      }

      _launched = false;
      if (exitCode != null) {
        _lastLaunchError = _describeExit(exitCode!);
      } else {
        _lastLaunchError =
            'Backend started but the supervisor did not answer /health within '
            '${supervisorStartupTimeout.inSeconds}s. It is still running; the app '
            'keeps retrying in the background.'
            '${_outputTailForError()}';
      }
      _log('ERROR: $_lastLaunchError');
      return false;
    } catch (e) {
      _launched = false;
      _lastLaunchError = 'Failed to launch backend: $e';
      _log('Failed to launch backend: $e');
      return false;
    }
  }

  static Future<bool> _waitForHealthy({
    Duration timeout = const Duration(seconds: 30),
    bool Function()? isProcessAlive,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final client = ApiClient(
      baseUrl: ServiceUrls.supervisor,
      timeout: const Duration(seconds: 2),
    );

    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          if (await client.checkAvailable()) {
            _log('Supervisor is healthy');
            return true;
          }
        } catch (_) {}
        if (isProcessAlive != null && !isProcessAlive()) {
          _log('Backend process exited before becoming healthy');
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      _log('Timeout waiting for supervisor health check');
      return false;
    } finally {
      client.dispose();
    }
  }

  static void _recordOutput(String line, {bool isError = false}) {
    final trimmed = line.trimRight();
    if (trimmed.isEmpty) return;
    _recentOutput.add(isError ? '[err] $trimmed' : trimmed);
    if (_recentOutput.length > _outputTailLines) {
      _recentOutput.removeRange(0, _recentOutput.length - _outputTailLines);
    }
    _log(isError ? '[err] $trimmed' : trimmed);
  }

  static String _describeExit(int code) =>
      'Backend exited with code $code before becoming healthy.'
      '${_outputTailForError()}';

  /// Last few backend lines, most useful ones first (tracebacks and
  /// "Address already in use" land at the end of the stream).
  static String _outputTailForError({int maxLines = 8}) {
    if (_recentOutput.isEmpty) return '';
    final tail = _recentOutput.length > maxLines
        ? _recentOutput.sublist(_recentOutput.length - maxLines)
        : _recentOutput;
    return '\nLast backend output:\n${tail.join('\n')}';
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
