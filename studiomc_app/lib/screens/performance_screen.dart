// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';

import 'package:flutter/material.dart';

import '../utils/platform_utils.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';
import 'package:studiomc_app/services/database_service.dart';
import 'package:studiomc_app/services/hardware_service.dart';
import 'package:studiomc_app/services/supervisor_service.dart';
import 'package:studiomc_app/widgets/performance/auto_tune_card.dart';
import 'package:studiomc_app/widgets/performance/performance_history.dart';
import 'package:studiomc_app/widgets/performance/performance_metrics.dart';
import 'package:studiomc_app/widgets/performance/speed_rating_badge.dart';
import 'package:studiomc_app/widgets/performance/suggestion_card.dart';
import 'package:studiomc_app/widgets/performance/system_status.dart';
import 'package:studiomc_app/services/settings_service.dart';

class PerformanceScreen extends StatefulWidget {
  const PerformanceScreen({super.key});

  @override
  State<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends State<PerformanceScreen> {
  bool _isLoading = true;
  String? _error;

  PerformanceSnapshot? _snapshot;
  HardwareScanResult? _hardware;
  List<Map<String, dynamic>> _history = [];
  List<ServiceInfo> _serviceStatuses = [];

  @override
  void initState() {
    super.initState();
    _loadPerformance();
  }

  Future<void> _loadPerformance() async {
    debugPrint('[perf] _loadPerformance START');
    try {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final api = context.read<ApiClient>();
    final db = context.read<DatabaseService>();

    debugPrint('[perf] Loading performance data. API available: ${api.isAvailable}');

    // ── Try backend data (best case) ──
    if (api.isAvailable) {
      try {
        final hwService = context.read<HardwareService>();
        final supervisor = context.read<SupervisorService>();

        // Fetch each independently so one failure doesn't block the rest
        PerformanceSnapshot? perfSnap;
        List<Map<String, dynamic>> perfHistory = [];
        SupervisorStatus? status;
        HardwareScanResult? hwResult;

        try { perfSnap = await hwService.getPerformance(); } catch (e) {
          debugPrint('[perf] getPerformance failed: $e');
        }
        try { perfHistory = await hwService.getPerformanceHistory(); } catch (e) {
          debugPrint('[perf] getPerformanceHistory failed: $e');
        }
        try { status = await supervisor.getStatus(); } catch (e) {
          debugPrint('[perf] getStatus failed: $e');
        }
        try { hwResult = await supervisor.getHardware(); } catch (e) {
          debugPrint('[perf] getHardware failed: $e');
        }

        if (perfSnap != null) _snapshot = perfSnap;
        if (perfHistory.isNotEmpty) _history = perfHistory;
        _serviceStatuses = status?.services ?? [];
        _hardware = hwResult ?? status?.hardware;
      } catch (e) {
        debugPrint('[perf] Backend load failed: $e');
      }
    }

    // ── Local fallback: build snapshot from DB benchmarks ──
    if (_snapshot == null) {
      debugPrint('[perf] No backend snapshot, building from local data');
      _snapshot = await _buildLocalSnapshot(db);
    }

    // ── Local fallback: build history from DB benchmarks ──
    if (_history.isEmpty) {
      _history = await _buildLocalHistory(db);
    }

    // ── Local fallback: gather basic system info from dart:io ──
    _hardware ??= _gatherLocalHardware();

    debugPrint('[perf] Done. snapshot=${_snapshot != null}, hardware=${_hardware != null}, ram=${_snapshot?.ramTotalMb}MB');
    if (mounted) setState(() => _isLoading = false);
    } catch (e, st) {
      debugPrint('[perf] FATAL ERROR: $e');
      debugPrint('[perf] Stack: $st');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Build a PerformanceSnapshot from local benchmark data in the DB.
  Future<PerformanceSnapshot?> _buildLocalSnapshot(DatabaseService db) async {
    try {
      // Get the most recent benchmark across all models
      final allBenchmarks = await db.rawQuery(
        'SELECT * FROM benchmarks ORDER BY created_at DESC LIMIT 10',
      );

      if (allBenchmarks.isEmpty) return _defaultSnapshot();

      // Use the most recent benchmark for headline numbers
      final latest = allBenchmarks.first;
      final ttft = (latest['ttft_ms'] as num?)?.toInt() ?? 0;
      final tokS = (latest['tok_per_s'] as num?)?.toDouble() ?? 0;

      // Compute averages across recent benchmarks
      double avgTokS = 0;
      int avgTtft = 0;
      for (final b in allBenchmarks) {
        avgTokS += (b['tok_per_s'] as num?)?.toDouble() ?? 0;
        avgTtft += (b['ttft_ms'] as num?)?.toInt() ?? 0;
      }
      avgTokS /= allBenchmarks.length;
      avgTtft = (avgTtft / allBenchmarks.length).round();

      final rating = _computeSpeedRating(avgTtft, avgTokS);

      return PerformanceSnapshot(
        speedRating: rating,
        explanation: _ratingExplanation(rating, avgTtft, avgTokS),
        suggestion: rating != SpeedRating.fast
            ? 'Try a smaller model or increase batch size for better throughput.'
            : null,
        ttftMs: ttft,
        tokPerS: tokS,
        ramUsedMb: 0,
        ramTotalMb: _getTotalRamMb(),
      );
    } catch (_) {
      return _defaultSnapshot();
    }
  }

  PerformanceSnapshot _defaultSnapshot() {
    final totalRam = _getTotalRamMb();
    final usedRam = (ProcessInfo.currentRss / (1024 * 1024)).round();
    return PerformanceSnapshot(
      speedRating: SpeedRating.ok,
      explanation: 'No benchmark data yet. Start a chat to collect performance metrics.',
      ttftMs: 0,
      tokPerS: 0,
      ramUsedMb: usedRam,
      ramTotalMb: totalRam,
    );
  }

  Future<List<Map<String, dynamic>>> _buildLocalHistory(DatabaseService db) async {
    try {
      return await db.rawQuery(
        'SELECT * FROM benchmarks ORDER BY created_at DESC LIMIT 20',
      );
    } catch (_) {
      return [];
    }
  }

  HardwareScanResult _gatherLocalHardware() {
    if (isMobile) return _gatherMobileHardware();

    final ramMb = _getTotalRamMb();
    final cpuName = _getCpuName();

    return HardwareScanResult(
      cpuName: cpuName,
      cpuCores: Platform.numberOfProcessors,
      ramMb: ramMb,
      disk: const DiskInfo(type: 'unknown', readMbps: 0),
      hwFingerprint: '',
    );
  }

  HardwareScanResult _gatherMobileHardware() {
    // On mobile, use basic info available without Process calls.
    // device_info_plus details are fetched asynchronously if needed.
    return HardwareScanResult(
      cpuName: Platform.isAndroid ? 'Android' : 'iOS',
      cpuCores: Platform.numberOfProcessors,
      ramMb: 0, // Not available synchronously on mobile
      disk: const DiskInfo(type: 'flash', readMbps: 0),
      hwFingerprint: '',
    );
  }

  int _getTotalRamMb() {
    if (isMobile) return 0; // RAM info provided by device_info_plus instead
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        final result = Process.runSync('sysctl', ['-n', 'hw.memsize']);
        if (result.exitCode == 0) {
          final bytes = int.tryParse((result.stdout as String).trim()) ?? 0;
          return (bytes / (1024 * 1024)).round();
        }
      }
    } catch (_) {}
    return 0;
  }

  String _getCpuName() {
    if (isMobile) return Platform.operatingSystem;
    try {
      if (Platform.isMacOS) {
        final result = Process.runSync('sysctl', ['-n', 'machdep.cpu.brand_string']);
        if (result.exitCode == 0) {
          return (result.stdout as String).trim();
        }
      }
    } catch (_) {}
    return Platform.operatingSystem;
  }

  SpeedRating _computeSpeedRating(int ttftMs, double tokPerS) {
    if (tokPerS >= 30 && ttftMs < 500) return SpeedRating.fast;
    if (tokPerS >= 15 && ttftMs < 1500) return SpeedRating.ok;
    if (tokPerS >= 5 && ttftMs < 5000) return SpeedRating.slow;
    return SpeedRating.painful;
  }

  String _ratingExplanation(SpeedRating rating, int ttftMs, double tokPerS) {
    switch (rating) {
      case SpeedRating.fast:
        return 'Your inference is running fast — ${tokPerS.toStringAsFixed(1)} tokens/s with ${ttftMs}ms time to first token.';
      case SpeedRating.ok:
        return 'Performance is acceptable at ${tokPerS.toStringAsFixed(1)} tokens/s. A smaller model could improve speed.';
      case SpeedRating.slow:
        return 'Inference is slow at ${tokPerS.toStringAsFixed(1)} tokens/s. Consider a smaller model or tuning your settings.';
      case SpeedRating.painful:
        return 'Inference is very slow. Try reducing context length or switching to a smaller model.';
    }
  }

  Future<void> _handleExportDiagnostics() async {
    final api = context.read<ApiClient>();

    if (!api.isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Backend not available. Cannot export.')),
        );
      }
      return;
    }

    try {
      await api.get('/diagnostics/export');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Diagnostics exported successfully',
              style: GoogleFonts.inter(fontSize: 9),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<SettingsService>();

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_snapshot == null) {
      return const Center(child: Text('No performance data available.'));
    }

    final snap = _snapshot!;
    final hasRealData = snap.ttftMs > 0 || snap.tokPerS > 0;

    return RefreshIndicator(
      onRefresh: _loadPerformance,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ──
            Row(
              children: [
                Text('Performance',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    )),
                const Spacer(),
                IconButton(
                  onPressed: _loadPerformance,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: 'Refresh',
                  style: IconButton.styleFrom(
                    foregroundColor: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Empty state ──
            if (!hasRealData) ...[
              _EmptyPerformanceState(
                hardware: _hardware,
                onStartChat: () => context.go('/chat'),
              ),
            ],

            // ── Dashboard with real data ──
            if (hasRealData) ...[
              // Top row: Speed badge + TTFT + tok/s in one row
              Row(
                children: [
                  // Speed badge (compact)
                  _CompactSpeedBadge(rating: snap.speedRating),
                  const SizedBox(width: 12),
                  // Metric cards
                  Expanded(
                    child: _ColorMetricCard(
                      icon: Icons.timer_outlined,
                      label: 'TTFT',
                      value: '${snap.ttftMs}',
                      unit: 'ms',
                      color: snap.ttftMs < 500
                          ? const Color(0xFF10B981)
                          : snap.ttftMs < 1500
                              ? Colors.amber
                              : Colors.red,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ColorMetricCard(
                      icon: Icons.bolt_rounded,
                      label: 'Speed',
                      value: snap.tokPerS.toStringAsFixed(1),
                      unit: 't/s',
                      color: snap.tokPerS >= 30
                          ? const Color(0xFF10B981)
                          : snap.tokPerS >= 15
                              ? Colors.amber
                              : Colors.red,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // System row: RAM + CPU cores + disk
              Row(
                children: [
                  if (snap.ramTotalMb > 0)
                    Expanded(
                      child: _ColorMetricCard(
                        icon: Icons.memory_rounded,
                        label: 'RAM',
                        value: '${(snap.ramTotalMb / 1024).toStringAsFixed(0)}',
                        unit: 'GB',
                        color: const Color(0xFF6366F1),
                      ),
                    ),
                  if (snap.ramTotalMb > 0) const SizedBox(width: 8),
                  if (_hardware != null)
                    Expanded(
                      child: _ColorMetricCard(
                        icon: Icons.developer_board_rounded,
                        label: 'CPU',
                        value: '${_hardware!.cpuCores}',
                        unit: 'cores',
                        color: const Color(0xFF8B5CF6),
                      ),
                    ),
                  if (_hardware != null && _hardware!.disk.readMbps > 0) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ColorMetricCard(
                        icon: Icons.storage_rounded,
                        label: 'Disk',
                        value: _hardware!.disk.readMbps >= 1000
                            ? '${(_hardware!.disk.readMbps / 1000).toStringAsFixed(1)}'
                            : '${_hardware!.disk.readMbps.toStringAsFixed(0)}',
                        unit: _hardware!.disk.readMbps >= 1000 ? 'GB/s' : 'MB/s',
                        color: const Color(0xFF0EA5E9),
                      ),
                    ),
                  ],
                ],
              ),

              // Suggestion (compact, inline)
              if (snap.speedRating != SpeedRating.fast &&
                  snap.suggestion != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Colors.amber.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.lightbulb_outline,
                          size: 16, color: Colors.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(snap.suggestion!,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: theme.colorScheme.onSurface,
                            )),
                      ),
                    ],
                  ),
                ),
              ],
            ],

            // ── Hardware chip row ──
            if (_hardware != null) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _InfoChip(
                    icon: Icons.computer_outlined,
                    label: _hardware!.cpuName,
                  ),
                  if (_hardware!.gpu != null && _hardware!.gpu!.detected)
                    _InfoChip(
                      icon: Icons.videocam_outlined,
                      label:
                          '${_hardware!.gpu!.name} ${_hardware!.gpu!.vramMb > 0 ? '(${(_hardware!.gpu!.vramMb / 1024).toStringAsFixed(0)}GB)' : ''}',
                    ),
                  if (_hardware!.disk.type != 'unknown')
                    _InfoChip(
                      icon: Icons.disc_full_outlined,
                      label: _hardware!.disk.type.toUpperCase(),
                    ),
                ],
              ),
            ],

            // ── Services (compact) ──
            if (_serviceStatuses.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('Services',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _serviceStatuses.map((svc) {
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: svc.running
                          ? const Color(0xFF10B981).withValues(alpha: 0.1)
                          : theme.colorScheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: svc.running
                                ? const Color(0xFF10B981)
                                : theme.colorScheme.error,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(svc.name,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            )),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],

            // ── Export button (compact) ──
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _handleExportDiagnostics,
                icon: const Icon(Icons.download_rounded, size: 16),
                label: Text('Export diagnostics',
                    style: GoogleFonts.inter(fontSize: 11)),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.secondary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays hardware scan information.
class _HardwareInfoCard extends StatelessWidget {
  final HardwareScanResult hardware;

  const _HardwareInfoCard({required this.hardware});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory_outlined,
                    size: 20, color: theme.colorScheme.secondary),
                const SizedBox(width: 8),
                Text('Hardware',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    )),
              ],
            ),
            const SizedBox(height: 16),
            _HardwareRow(
              icon: Icons.computer_outlined,
              label: 'CPU',
              value: '${hardware.cpuName} (${hardware.cpuCores} cores)',
            ),
            _HardwareRow(
              icon: Icons.sd_storage_outlined,
              label: 'RAM',
              value: '${(hardware.ramMb / 1024).toStringAsFixed(1)} GB',
            ),
            if (hardware.gpu != null && hardware.gpu!.detected) ...[
              _HardwareRow(
                icon: Icons.videocam_outlined,
                label: 'GPU',
                value:
                    '${hardware.gpu!.name} (${(hardware.gpu!.vramMb / 1024).toStringAsFixed(1)} GB VRAM)',
              ),
            ],
            _HardwareRow(
              icon: Icons.disc_full_outlined,
              label: 'Storage',
              value:
                  '${hardware.disk.type.toUpperCase()} (${hardware.disk.readMbps.toStringAsFixed(0)} MB/s read)',
            ),
          ],
        ),
      ),
    );
  }
}

class _HardwareRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _HardwareRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.secondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 60,
            child: Text(label,
                style: GoogleFonts.inter(
                  fontSize: 9,
                  color: theme.colorScheme.secondary,
                )),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                )),
          ),
        ],
      ),
    );
  }
}

/// Displays the status of backend services.
class _ServiceStatusCard extends StatelessWidget {
  final List<ServiceInfo> services;

  const _ServiceStatusCard({required this.services});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.dns_outlined,
                    size: 20, color: theme.colorScheme.secondary),
                const SizedBox(width: 8),
                Text('Services',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    )),
              ],
            ),
            const SizedBox(height: 16),
            ...services.map((svc) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: svc.running
                              ? const Color(0xFF10B981)
                              : theme.colorScheme.error.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(svc.name,
                            style: GoogleFonts.inter(
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                              color: theme.colorScheme.onSurface,
                            )),
                      ),
                      Text(
                        svc.running
                            ? 'Port ${svc.port}'
                            : 'Stopped',
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          color: svc.running
                              ? theme.colorScheme.secondary
                              : theme.colorScheme.error,
                        ),
                      ),
                      if (svc.version != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'v${svc.version}',
                            style: GoogleFonts.inter(
                              fontSize: 9,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

class _RawNumberRow extends StatelessWidget {
  final String label;
  final String value;

  const _RawNumberRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: GoogleFonts.inter(
                fontSize: 9,
                color: theme.colorScheme.secondary,
              )),
          Text(value,
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              )),
        ],
      ),
    );
  }
}

/// Engaging placeholder when no benchmark data exists yet.
class _EmptyPerformanceState extends StatelessWidget {
  final HardwareScanResult? hardware;
  final VoidCallback onStartChat;

  const _EmptyPerformanceState({
    this.hardware,
    required this.onStartChat,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Hero illustration area
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.06),
                theme.colorScheme.tertiary.withValues(alpha: 0.04),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
            ),
          ),
          child: Column(
            children: [
              // Animated-looking speed gauge placeholder
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 120,
                    height: 120,
                    child: CircularProgressIndicator(
                      value: 0.75,
                      strokeWidth: 6,
                      strokeCap: StrokeCap.round,
                      backgroundColor:
                          theme.colorScheme.primary.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.speed_rounded,
                        size: 32,
                        color: theme.colorScheme.primary.withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '—',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 24),

              Text(
                'Ready to benchmark',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Send your first message to start collecting\nperformance metrics automatically.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: theme.colorScheme.secondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),

              FilledButton.icon(
                onPressed: onStartChat,
                icon: const Icon(Icons.chat_rounded, size: 18),
                label: Text(
                  'Start a chat',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // Preview cards showing what metrics will look like
        Row(
          children: [
            Expanded(
              child: _PreviewMetricCard(
                icon: Icons.timer_outlined,
                label: 'Time to First Token',
                placeholder: '— ms',
                description: 'How fast your model responds',
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PreviewMetricCard(
                icon: Icons.bolt_outlined,
                label: 'Tokens / Second',
                placeholder: '— t/s',
                description: 'Generation throughput',
                color: theme.colorScheme.tertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _PreviewMetricCard(
                icon: Icons.memory_outlined,
                label: 'Memory Usage',
                placeholder: '— GB',
                description: 'RAM and VRAM utilization',
                color: Colors.teal,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PreviewMetricCard(
                icon: Icons.trending_up_rounded,
                label: 'Speed Rating',
                placeholder: '—',
                description: 'Overall performance score',
                color: Colors.green,
              ),
            ),
          ],
        ),

        // What gets tracked section
        const SizedBox(height: 32),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'What gets tracked',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _TrackingItem(
          icon: Icons.speed_rounded,
          title: 'Speed rating',
          subtitle: 'Fast, OK, Slow, or Painful — at a glance',
        ),
        _TrackingItem(
          icon: Icons.analytics_outlined,
          title: 'Live metrics',
          subtitle: 'TTFT, tokens/sec, and memory per conversation',
        ),
        _TrackingItem(
          icon: Icons.download_rounded,
          title: 'Export diagnostics',
          subtitle: 'Share a full performance report for debugging',
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _PreviewMetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String placeholder;
  final String description;
  final Color color;

  const _PreviewMetricCard({
    required this.icon,
    required this.label,
    required this.placeholder,
    required this.description,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color.withValues(alpha: 0.6)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.secondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            placeholder,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: GoogleFonts.inter(
              fontSize: 10,
              color: theme.colorScheme.secondary.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _TrackingItem({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Compact speed badge (fits in a row) ──
class _CompactSpeedBadge extends StatelessWidget {
  final SpeedRating rating;
  const _CompactSpeedBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = switch (rating) {
      SpeedRating.fast => (const Color(0xFF10B981), 'Fast'),
      SpeedRating.ok => (Colors.amber.shade700, 'OK'),
      SpeedRating.slow => (Colors.orange, 'Slow'),
      SpeedRating.painful => (Colors.red, 'Slow'),
    };

    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2.5),
      ),
      child: Center(
        child: Text(label,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: color,
            )),
      ),
    );
  }
}

// ── Colorful metric card ──
class _ColorMetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color color;

  const _ColorMetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(label,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.secondary,
                  )),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: color,
                  )),
              const SizedBox(width: 2),
              Text(unit,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: color.withValues(alpha: 0.7),
                  )),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Info chip for hardware details ──
class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: theme.colorScheme.secondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
