import 'dart:async';

import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';

/// Status of a single backend micro-service reported by the supervisor.
class ServiceInfo {
  final String name;
  final int port;
  final bool running;
  final String? version;

  const ServiceInfo({
    required this.name,
    required this.port,
    required this.running,
    this.version,
  });

  factory ServiceInfo.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'stopped';
    return ServiceInfo(
      name: json['name'] as String? ?? '',
      port: json['port'] as int? ?? 0,
      running: status == 'running',
      version: json['version'] as String?,
    );
  }
}

/// Aggregated status returned by the supervisor `/status` endpoint.
class SupervisorStatus {
  final List<ServiceInfo> services;
  final HardwareScanResult? hardware;

  const SupervisorStatus({required this.services, this.hardware});
}

/// Communicates with the Supervisor service (port 8110).
///
/// The supervisor orchestrates all other micro-services, provides health
/// checks, and exposes hardware scanning.
class SupervisorService {
  static SupervisorService? _instance;
  final ApiClient _api;

  SupervisorService._(this._api);

  factory SupervisorService() {
    _instance ??= SupervisorService._(
      ApiClient(baseUrl: ServiceUrls.supervisor),
    );
    return _instance!;
  }

  // ── Health ──────────────────────────────────────────────────────────

  /// Returns `true` if the supervisor process is reachable.
  Future<bool> checkHealth() async {
    try {
      await _api.get('/health');
      return true;
    } catch (e) {
      logService('supervisor', 'Health check failed', error: e);
      return false;
    }
  }

  // ── Status ──────────────────────────────────────────────────────────

  /// Fetch the full supervisor status including running services and
  /// cached hardware info.
  Future<SupervisorStatus?> getStatus() async {
    try {
      final data = await _api.get('/status');

      final servicesList = (data['services'] as List<dynamic>?)
              ?.map((s) =>
                  ServiceInfo.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [];

      HardwareScanResult? hardware;
      if (data['hw_info'] != null) {
        hardware = _parseHardware(data['hw_info'] as Map<String, dynamic>);
      }

      return SupervisorStatus(services: servicesList, hardware: hardware);
    } catch (e) {
      logService('supervisor', 'Failed to get status', error: e);
      return null;
    }
  }

  // ── Service control ────────────────────────────────────────────────

  /// Start all backend micro-services.
  Future<bool> startAll() async {
    try {
      await _api.post('/services/start');
      return true;
    } catch (e) {
      logService('supervisor', 'Failed to start all services', error: e);
      return false;
    }
  }

  /// Stop all backend micro-services.
  Future<bool> stopAll() async {
    try {
      await _api.post('/services/stop');
      return true;
    } catch (e) {
      logService('supervisor', 'Failed to stop all services', error: e);
      return false;
    }
  }

  // ── Hardware ────────────────────────────────────────────────────────

  /// Return cached hardware info from the supervisor.
  Future<HardwareScanResult?> getHardware() async {
    try {
      final data = await _api.get('/hardware');
      return _parseHardware(data);
    } catch (e) {
      logService('supervisor', 'Failed to get hardware info', error: e);
      return null;
    }
  }

  /// Request a fresh hardware scan (may take a few seconds).
  Future<HardwareScanResult?> scanHardware() async {
    try {
      final data = await _api.post('/hardware/scan');
      return _parseHardware(data);
    } catch (e) {
      logService('supervisor', 'Hardware scan failed', error: e);
      return null;
    }
  }

  // ── Parsing helpers ────────────────────────────────────────────────

  HardwareScanResult _parseHardware(Map<String, dynamic> data) {
    // Backend returns flat fields: gpu_name, vram_bytes, ram_bytes,
    // cpu_name, cpu_cores, disk_type, disk_read_mbps, hw_fingerprint
    // Also handles nested format from /status endpoint (hw_info sub-object)
    final gpuName = data['gpu_name'] as String?;
    final vramBytes = data['vram_bytes'] as int?;
    final ramBytes = data['ram_bytes'] as int? ?? 0;

    return HardwareScanResult(
      gpu: gpuName != null
          ? GpuInfo(
              name: gpuName,
              vramMb: vramBytes != null ? (vramBytes / (1024 * 1024)).round() : 0,
              detected: gpuName.isNotEmpty,
            )
          : null,
      ramMb: (ramBytes / (1024 * 1024)).round(),
      disk: DiskInfo(
        type: data['disk_type'] as String? ?? 'unknown',
        readMbps: (data['disk_read_mbps'] as num? ?? 0).toDouble(),
      ),
      cpuName: data['cpu_name'] as String? ?? 'Unknown',
      cpuCores: data['cpu_cores'] as int? ?? 0,
      hwFingerprint: data['hw_fingerprint'] as String? ?? '',
    );
  }
}
