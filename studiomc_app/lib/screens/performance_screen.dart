// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';
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
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final api = context.read<ApiClient>();

    if (!api.isAvailable) {
      setState(() {
        _isLoading = false;
        _error =
            'Backend not available. Start the local service to view performance data.';
      });
      return;
    }

    try {
      final hwService = context.read<HardwareService>();
      final supervisor = context.read<SupervisorService>();

      // Load all performance data in parallel
      final results = await Future.wait([
        hwService.getPerformance(),
        hwService.getPerformanceHistory(),
        supervisor.getStatus(),
        supervisor.getHardware(),
      ]);

      _snapshot = results[0] as PerformanceSnapshot;
      _history = results[1] as List<Map<String, dynamic>>;
      final status = results[2] as SupervisorStatus?;
      _serviceStatuses = status?.services ?? [];
      _hardware = results[3] as HardwareScanResult? ?? status?.hardware;

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Failed to load performance data: $e';
      });
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

    if (_error != null && _snapshot == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.signal_wifi_off,
                  size: 48,
                  color: theme.colorScheme.secondary.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              Text('Performance Unavailable',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    color: theme.colorScheme.secondary,
                    height: 1.5,
                  )),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _loadPerformance,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final snap = _snapshot!;
    final showSuggestion = snap.speedRating != SpeedRating.fast;

    return RefreshIndicator(
      onRefresh: _loadPerformance,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Header with refresh
              Row(
                children: [
                  Expanded(
                    child: Text('Performance',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        )),
                  ),
                  IconButton(
                    onPressed: _loadPerformance,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    tooltip: 'Refresh',
                    style: IconButton.styleFrom(
                      foregroundColor: theme.colorScheme.secondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Speed rating badge
              SpeedRatingBadge(speedRating: snap.speedRating),
              const SizedBox(height: 16),

              // Explanation
              Text(snap.explanation,
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    color: theme.colorScheme.onSurface,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center),
              const SizedBox(height: 32),

              // Suggestion card
              if (showSuggestion && snap.suggestion != null) ...[
                SuggestionCard(
                  suggestion: snap.suggestion!,
                  onAction: () {},
                ),
                const SizedBox(height: 24),
              ],

              // Performance metrics (TTFT + tok/s)
              PerformanceMetrics(ttftMs: snap.ttftMs, tokPerS: snap.tokPerS),
              const SizedBox(height: 24),

              // System status (RAM/VRAM)
              SystemStatus(
                ramUsedMb: snap.ramUsedMb,
                ramTotalMb: snap.ramTotalMb,
                vramUsedMb: snap.vramUsedMb ?? 0,
                vramTotalMb: snap.vramTotalMb ?? 0,
                diskMbps: _hardware?.disk.readMbps ?? 0,
              ),

              // Hardware info section
              if (_hardware != null) ...[
                const SizedBox(height: 24),
                _HardwareInfoCard(hardware: _hardware!),
              ],

              // Service status
              if (_serviceStatuses.isNotEmpty) ...[
                const SizedBox(height: 24),
                _ServiceStatusCard(services: _serviceStatuses),
              ],

              // Auto-tune card
              const SizedBox(height: 24),
              AutoTuneCard(
                contextLength: settings.contextLength.toInt(),
                batchSize: settings.batchSize.toInt(),
                prefetchDepth: settings.prefetchDepth.toInt(),
              ),

              // Detailed metrics (expandable)
              const SizedBox(height: 24),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ExpansionTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  title: Text('Raw numbers',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      )),
                  leading: Icon(Icons.analytics_outlined,
                      size: 20, color: theme.colorScheme.secondary),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _RawNumberRow(
                              label: 'Time to First Token',
                              value: '${snap.ttftMs} ms'),
                          _RawNumberRow(
                              label: 'Tokens per second',
                              value: snap.tokPerS.toStringAsFixed(1)),
                          _RawNumberRow(
                              label: 'RAM',
                              value:
                                  '${snap.ramUsedMb} / ${snap.ramTotalMb} MB'),
                          if (snap.vramUsedMb != null &&
                              snap.vramTotalMb != null)
                            _RawNumberRow(
                                label: 'VRAM',
                                value:
                                    '${snap.vramUsedMb} / ${snap.vramTotalMb} MB'),
                          if (_hardware != null)
                            _RawNumberRow(
                                label: 'Disk read',
                                value:
                                    '${_hardware!.disk.readMbps.toStringAsFixed(0)} MB/s'),
                          const SizedBox(height: 16),
                          PerformanceHistory(history: _history),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Export diagnostics
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _handleExportDiagnostics,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text('Export diagnostics',
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      )),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
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
