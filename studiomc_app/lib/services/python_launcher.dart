import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Configuration for the Python backend launcher.
class PythonLauncherConfig {
  /// The port the supervisor listens on.
  final int supervisorPort;

  /// Maximum time to wait for the supervisor to become healthy.
  final Duration startupTimeout;

  /// Interval between health-check polls during startup.
  final Duration healthCheckInterval;

  /// Interval between liveness checks while the backend is running.
  final Duration livenessInterval;

  /// Maximum number of automatic restarts before giving up.
  final int maxRestarts;

  /// Cooldown between restart attempts.
  final Duration restartCooldown;

  /// Timeout for graceful shutdown before sending SIGKILL.
  final Duration shutdownTimeout;

  const PythonLauncherConfig({
    this.supervisorPort = 8110,
    this.startupTimeout = const Duration(seconds: 30),
    this.healthCheckInterval = const Duration(milliseconds: 500),
    this.livenessInterval = const Duration(seconds: 5),
    this.maxRestarts = 3,
    this.restartCooldown = const Duration(seconds: 2),
    this.shutdownTimeout = const Duration(seconds: 10),
  });
}

/// Lifecycle states for the Python backend.
enum PythonBackendState {
  /// Not yet started.
  idle,

  /// Process is starting, waiting for health check to pass.
  starting,

  /// Backend is healthy and serving requests.
  running,

  /// Backend process exited, attempting restart.
  restarting,

  /// Backend has been stopped intentionally.
  stopped,

  /// Backend failed to start or exceeded max restarts.
  error,
}

/// Manages the lifecycle of the bundled Python backend.
///
/// **Development mode** (`kDebugMode` or env `STUDIOMC_DEV=1`):
///   Assumes services are running externally (started manually via
///   `cd services && python supervisor/app.py`). Only performs health
///   checks — does NOT launch or manage any process.
///
/// **Production mode** (release build with embedded Python bundle):
///   Locates the `studiomc_services` executable inside the app's
///   platform-specific resources directory, launches it as a child
///   process, polls for health, and auto-restarts on crash.
///
/// Usage:
/// ```dart
/// final launcher = PythonLauncher();
/// await launcher.start();           // blocks until healthy or timeout
/// // ... app is running ...
/// await launcher.shutdown();        // clean stop on app exit
/// ```
class PythonLauncher {
  PythonLauncher({
    PythonLauncherConfig? config,
  }) : _config = config ?? const PythonLauncherConfig();

  final PythonLauncherConfig _config;

  Process? _process;
  int _restartCount = 0;
  Timer? _livenessTimer;
  bool _shutdownRequested = false;

  PythonBackendState _state = PythonBackendState.idle;

  /// Current lifecycle state.
  PythonBackendState get state => _state;

  /// Whether we launched the backend (vs. it running externally).
  bool get isManaged => _process != null;

  /// Whether the backend is in development mode (externally managed).
  bool get isDevelopment => _isDevelopmentMode();

  /// The PID of the managed backend process, or null.
  int? get pid => _process?.pid;

  /// The URL where the supervisor is expected to be reachable.
  String get supervisorUrl => 'http://127.0.0.1:${_config.supervisorPort}';

  // ── Public API ──────────────────────────────────────────────────────────

  /// Start the Python backend.
  ///
  /// In **development mode**, this only polls the health endpoint until
  /// the externally-started supervisor responds (or times out).
  ///
  /// In **production mode**, this:
  ///   1. Locates the bundled executable
  ///   2. Starts the process
  ///   3. Polls until the health endpoint responds
  ///   4. Begins liveness monitoring
  ///
  /// Returns `true` if the backend is healthy, `false` on timeout/error.
  Future<bool> start() async {
    if (_state == PythonBackendState.running) return true;

    _shutdownRequested = false;
    _state = PythonBackendState.starting;

    if (_isDevelopmentMode()) {
      _log('Development mode — waiting for external supervisor…');
      final healthy = await _waitForHealth();
      _state = healthy
          ? PythonBackendState.running
          : PythonBackendState.error;
      if (healthy) {
        _log('External supervisor is healthy');
        _startLivenessMonitor();
      } else {
        _log('External supervisor not reachable (timeout)');
      }
      return healthy;
    }

    // Production mode — launch the bundled executable
    return _launchAndWait();
  }

  /// Gracefully shut down the backend.
  ///
  /// Sends SIGTERM (macOS/Linux) or taskkill (Windows), waits for exit,
  /// then force-kills if the timeout expires.
  Future<void> shutdown() async {
    _shutdownRequested = true;
    _livenessTimer?.cancel();
    _livenessTimer = null;

    final proc = _process;
    if (proc == null) {
      _state = PythonBackendState.stopped;
      return;
    }

    _log('Shutting down backend (pid=${proc.pid})…');

    // Try graceful shutdown via the API first
    try {
      final client = http.Client();
      await client
          .post(Uri.parse('$supervisorUrl/shutdown'))
          .timeout(const Duration(seconds: 3));
      client.close();
    } catch (_) {
      // API not available, fall through to signal
    }

    // Send SIGTERM
    proc.kill(ProcessSignal.sigterm);

    final exitCode = await proc.exitCode
        .timeout(_config.shutdownTimeout, onTimeout: () {
      _log('Backend did not exit in ${_config.shutdownTimeout.inSeconds}s — sending SIGKILL');
      proc.kill(ProcessSignal.sigkill);
      return proc.exitCode;
    });

    _log('Backend exited with code $exitCode');
    _process = null;
    _state = PythonBackendState.stopped;
  }

  /// Check if the supervisor is currently responding to health checks.
  Future<bool> isHealthy() async {
    try {
      final client = http.Client();
      final response = await client
          .get(Uri.parse('$supervisorUrl/health'))
          .timeout(const Duration(seconds: 3));
      client.close();
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // ── Process management (production mode) ────────────────────────────────

  Future<bool> _launchAndWait() async {
    final executablePath = _findBundledExecutable();
    if (executablePath == null) {
      _log('No bundled executable found — cannot start in production mode');
      _state = PythonBackendState.error;
      return false;
    }

    _log('Launching: $executablePath');

    try {
      _process = await Process.start(
        executablePath,
        [], // no args → starts the supervisor
        mode: ProcessStartMode.detachedWithStdio,
      );

      _log('Process started (pid=${_process!.pid})');

      // Forward stdout/stderr for diagnostics
      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        developer.log(line, name: 'studiomc.backend');
      });

      _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        developer.log(line, name: 'studiomc.backend.err');
      });

      // Handle unexpected exit
      // ignore: unawaited_futures
      _process!.exitCode.then(_onProcessExit);

      // Wait for the health endpoint
      final healthy = await _waitForHealth();
      if (healthy) {
        _state = PythonBackendState.running;
        _restartCount = 0;
        _startLivenessMonitor();
        _log('Backend is healthy and serving');
        return true;
      } else {
        _log('Backend process started but health check timed out');
        _state = PythonBackendState.error;
        return false;
      }
    } catch (e) {
      _log('Failed to launch backend: $e', error: e);
      _state = PythonBackendState.error;
      return false;
    }
  }

  void _onProcessExit(int exitCode) {
    _log('Backend process exited with code $exitCode');
    _process = null;

    if (_shutdownRequested) {
      _state = PythonBackendState.stopped;
      return;
    }

    // Unexpected exit — attempt restart
    if (_restartCount < _config.maxRestarts) {
      _restartCount++;
      _log('Attempting restart $_restartCount/${_config.maxRestarts}…');
      _state = PythonBackendState.restarting;

      Future.delayed(_config.restartCooldown, () {
        if (!_shutdownRequested) {
          _launchAndWait();
        }
      });
    } else {
      _log('Max restarts exceeded ($_restartCount) — giving up');
      _state = PythonBackendState.error;
    }
  }

  // ── Health checking ────────────────────────────────────────────────────

  /// Poll the health endpoint until it responds or [_config.startupTimeout] expires.
  Future<bool> _waitForHealth() async {
    final deadline = DateTime.now().add(_config.startupTimeout);

    while (DateTime.now().isBefore(deadline)) {
      if (_shutdownRequested) return false;

      if (await isHealthy()) return true;

      await Future.delayed(_config.healthCheckInterval);
    }

    return false;
  }

  /// Periodic liveness monitor — restarts the backend if it becomes unreachable.
  void _startLivenessMonitor() {
    _livenessTimer?.cancel();
    _livenessTimer = Timer.periodic(_config.livenessInterval, (_) async {
      if (_shutdownRequested || _state != PythonBackendState.running) return;

      final healthy = await isHealthy();
      if (!healthy && _state == PythonBackendState.running) {
        _log('Liveness check failed — backend unreachable');

        // In dev mode, just log (don't try to restart what we don't own)
        if (_isDevelopmentMode()) {
          _state = PythonBackendState.error;
          _livenessTimer?.cancel();
          return;
        }

        // In production mode, the process exit handler will trigger restart
        // If the process is still running but not responding, kill it
        if (_process != null) {
          _log('Killing unresponsive backend process');
          _process!.kill(ProcessSignal.sigterm);
        }
      }
    });
  }

  // ── Platform-specific path resolution ──────────────────────────────────

  /// Detect whether we're running in development mode.
  ///
  /// Development mode is active when:
  ///   - `kDebugMode` is true (Flutter debug build), OR
  ///   - The `STUDIOMC_DEV` environment variable is set to `1`, OR
  ///   - No bundled executable can be found
  bool _isDevelopmentMode() {
    if (kDebugMode) return true;
    if (Platform.environment['STUDIOMC_DEV'] == '1') return true;
    return _findBundledExecutable() == null;
  }

  /// Locate the `studiomc_services` executable bundled inside the app.
  /// Returns `null` if not found (e.g. development builds).
  String? _findBundledExecutable() {
    for (final path in _candidatePaths()) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Platform-specific candidate paths for the bundled executable.
  List<String> _candidatePaths() {
    final exe = Platform.resolvedExecutable;

    if (Platform.isMacOS) {
      // macOS layout:
      //   Studiomc.app/Contents/MacOS/studiomc_app        ← Flutter runner
      //   Studiomc.app/Contents/Resources/studiomc_services/studiomc_services
      final macosDir = File(exe).parent.path;           // .../Contents/MacOS
      final contentsDir = File(macosDir).parent.path;   // .../Contents
      return [
        '$contentsDir/Resources/studiomc_services/studiomc_services',
        '$contentsDir/Resources/python_backend/studiomc_services',
      ];
    }

    if (Platform.isWindows) {
      // Windows layout:
      //   install_dir/studiomc_app.exe
      //   install_dir/studiomc_services/studiomc_services.exe
      final appDir = File(exe).parent.path;
      return [
        '$appDir\\studiomc_services\\studiomc_services.exe',
        '$appDir/studiomc_services/studiomc_services.exe',
      ];
    }

    if (Platform.isLinux) {
      // Linux layout (AppImage or installed):
      //   app_dir/studiomc_app
      //   app_dir/studiomc_services/studiomc_services
      final appDir = File(exe).parent.path;
      return [
        '$appDir/studiomc_services/studiomc_services',
        '$appDir/lib/studiomc_services/studiomc_services',
      ];
    }

    return [];
  }

  // ── Logging ────────────────────────────────────────────────────────────

  void _log(String message, {Object? error}) {
    developer.log(
      message,
      name: 'studiomc.python_launcher',
      error: error,
    );
  }
}
