import 'package:studiomc_app/services/api_client.dart';
import 'package:studiomc_app/models/app_models.dart';

/// Handles hardware scanning and performance monitoring
/// via the local supervisor service.
class HardwareService {
  final ApiClient _api;

  HardwareService(this._api);

  /// Run a hardware scan and return structured results.
  Future<HardwareScanResult> scanHardware() async {
    final data = await _api.post('/hardware/scan');
    return _parseHardware(data);
  }

  /// Get cached hardware info (no scan, fast).
  Future<HardwareScanResult> getHardware() async {
    final data = await _api.get('/hardware');
    return _parseHardware(data);
  }

  HardwareScanResult _parseHardware(Map<String, dynamic> data) {
    // Backend returns flat: gpu_name, vram_bytes, ram_bytes, cpu_name, cpu_cores,
    // disk_type, disk_read_mbps, hw_fingerprint
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

  /// Get current performance snapshot.
  Future<PerformanceSnapshot> getPerformance() async {
    final data = await _api.get('/performance/snapshot');

    return PerformanceSnapshot(
      speedRating: _parseSpeedRating(data['speed_rating']),
      explanation: data['explanation'] ?? '',
      suggestion: data['suggestion'],
      ttftMs: data['ttft_ms'] ?? 0,
      tokPerS: (data['tok_per_s'] ?? 0).toDouble(),
      ramUsedMb: data['ram_used_mb'] ?? 0,
      ramTotalMb: data['ram_total_mb'] ?? 0,
      vramUsedMb: data['vram_used_mb'],
      vramTotalMb: data['vram_total_mb'],
    );
  }

  /// Get performance history (per-chat metrics).
  Future<List<Map<String, dynamic>>> getPerformanceHistory() async {
    return _api.getList('/performance/history').then(
        (list) => list.cast<Map<String, dynamic>>());
  }

  SpeedRating _parseSpeedRating(String? rating) {
    switch (rating) {
      case 'fast':
        return SpeedRating.fast;
      case 'ok':
        return SpeedRating.ok;
      case 'slow':
        return SpeedRating.slow;
      case 'painful':
        return SpeedRating.painful;
      default:
        return SpeedRating.ok;
    }
  }
}
