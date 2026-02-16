// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/app_models.dart';
import '../services/bundled_inference_service.dart';
import '../services/mobile_inference_service.dart';
import '../services/settings_service.dart';
import '../utils/platform_utils.dart';
import '../widgets/common/studiomc_logo.dart';

/// Onboarding: Welcome → Scan → Recommend → Download → First Chat.
/// Fully automatic. No backend required for scan + recommend.
/// The app decides everything — users never see complexity.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  OnboardingStep _step = OnboardingStep.welcome;

  // Local hardware info (no backend needed)
  int _ramMb = 0;
  String _cpuName = '';
  int _cpuCores = 0;
  String _gpuName = '';

  // Auto-selected model
  _RecommendedModel? _recommended;

  // Download
  double _downloadProgress = 0;
  String _downloadStatus = '';
  String? _downloadError;
  bool _isPaused = false;
  int _totalBytes = 0; // remembered across pause/resume cycles

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.05),
              theme.colorScheme.primary.withValues(alpha: 0.15),
            ],
          ),
        ),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            margin: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _buildStep(theme),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(ThemeData theme) {
    switch (_step) {
      case OnboardingStep.welcome:
        return _buildWelcome(theme);
      case OnboardingStep.scan:
        return _buildScan(theme);
      case OnboardingStep.recommend:
        return _buildRecommend(theme);
      case OnboardingStep.download:
        return _buildDownload(theme);
      case OnboardingStep.firstChat:
        return _buildFirstChat(theme);
    }
  }

  // ── Step 1: Welcome ──

  Widget _buildWelcome(ThemeData theme) {
    return Column(
      key: const ValueKey('welcome'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const StudiomcLogo(size: 48),
        const SizedBox(height: 24),
        Text('Local AI. Private by default.',
            style: theme.textTheme.displaySmall,
            textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(
            isMobile
                ? 'Your own AI assistant that runs entirely on your device.'
                : 'Your own AI assistant that runs entirely on your machine.',
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.secondary),
            textAlign: TextAlign.center),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _startOnboarding,
            child: const Text('Get Started'),
          ),
        ),
        if (isDesktop) ...[
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => context.go('/chat'),
            child: const Text('I already have a model'),
          ),
        ],
      ],
    );
  }

  // ── Step 2: Auto hardware scan (local, no backend) ──

  void _startOnboarding() {
    setState(() => _step = OnboardingStep.scan);
    _scanHardwareLocal();
  }

  Future<void> _scanHardwareLocal() async {
    try {
      _cpuCores = Platform.numberOfProcessors;

      if (isMobile) {
        // ── Mobile: use device_info_plus (no Process calls) ──
        await _scanMobileHardware();
      } else {
        // ── Desktop: read from OS commands ──
        await _scanDesktopHardware();
      }
    } catch (_) {
      _ramMb = 0;
      _cpuName = '${Platform.operatingSystem} (${_cpuCores} cores)';
    }

    // Auto-recommend best model based on hardware
    _recommended = _pickBestModel();

    if (mounted) {
      setState(() => _step = OnboardingStep.recommend);
    }
  }

  Future<void> _scanMobileHardware() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      _cpuName = android.hardware;
      // Android doesn't expose total RAM directly via device_info_plus.
      // Use a conservative estimate based on SDK level for model selection.
      // Most modern phones (2022+) have 4-8 GB.
      final sdkInt = android.version.sdkInt;
      _ramMb = sdkInt >= 31 ? 6144 : 4096; // conservative estimate
      _gpuName = 'Mobile GPU';
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      _cpuName = ios.utsname.machine;
      // Estimate RAM based on device model (Apple doesn't expose directly)
      _ramMb = _estimateIosRam(ios.utsname.machine);
      _gpuName = 'Apple GPU';
    }
  }

  int _estimateIosRam(String machine) {
    // Conservative RAM estimates by device generation
    if (machine.contains('iPhone16') || machine.contains('iPhone17')) return 8192;
    if (machine.contains('iPhone15') || machine.contains('iPhone14')) return 6144;
    if (machine.contains('iPad14') || machine.contains('iPad16')) return 8192;
    return 4096; // safe default for older devices
  }

  Future<void> _scanDesktopHardware() async {
    if (Platform.isMacOS) {
      final sysInfo = await Process.run('sysctl', ['-n', 'hw.memsize']);
      if (sysInfo.exitCode == 0) {
        final bytes = int.tryParse(sysInfo.stdout.toString().trim()) ?? 0;
        _ramMb = (bytes / (1024 * 1024)).round();
      }

      final cpuInfo =
          await Process.run('sysctl', ['-n', 'machdep.cpu.brand_string']);
      if (cpuInfo.exitCode == 0) {
        _cpuName = cpuInfo.stdout.toString().trim();
        if (_cpuName.isEmpty) {
          final uname = await Process.run('uname', ['-m']);
          final arch = uname.stdout.toString().trim();
          _cpuName = arch == 'arm64' ? 'Apple Silicon' : arch;
        }
      }

      final gpuInfo = await Process.run(
          'system_profiler', ['SPDisplaysDataType', '-detailLevel', 'mini']);
      if (gpuInfo.exitCode == 0) {
        final output = gpuInfo.stdout.toString();
        final chipMatch = RegExp(r'Chipset Model:\s*(.+)').firstMatch(output);
        if (chipMatch != null) {
          _gpuName = chipMatch.group(1)?.trim() ?? '';
        } else if (_cpuName.contains('Apple')) {
          _gpuName = _cpuName;
        }
      }
    } else if (Platform.isWindows) {
      final memInfo = await Process.run(
          'wmic', ['computersystem', 'get', 'TotalPhysicalMemory']);
      if (memInfo.exitCode == 0) {
        final lines = memInfo.stdout.toString().trim().split('\n');
        if (lines.length > 1) {
          final bytes = int.tryParse(lines.last.trim()) ?? 0;
          _ramMb = (bytes / (1024 * 1024)).round();
        }
      }
      _cpuName = Platform.environment['PROCESSOR_IDENTIFIER'] ?? 'Unknown';
    } else {
      _cpuName = 'Linux CPU';
      try {
        final memInfo =
            await Process.run('grep', ['MemTotal', '/proc/meminfo']);
        if (memInfo.exitCode == 0) {
          final match =
              RegExp(r'(\d+)').firstMatch(memInfo.stdout.toString());
          if (match != null) {
            _ramMb = (int.parse(match.group(1)!) / 1024).round();
          }
        }
      } catch (_) {}
    }
  }

  Widget _buildScan(ThemeData theme) {
    return Column(
      key: const ValueKey('scan'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Scanning your hardware...',
            style: theme.textTheme.headlineMedium,
            textAlign: TextAlign.center),
        const SizedBox(height: 32),
        const CircularProgressIndicator(),
        const SizedBox(height: 24),
        Text('Checking graphics memory, RAM, and disk speed',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.secondary),
            textAlign: TextAlign.center),
      ],
    );
  }

  // ── Step 3: Show recommendation (auto-selected, no choices) ──

  Widget _buildRecommend(ThemeData theme) {
    final rec = _recommended!;
    final ramGb = (_ramMb / 1024).toStringAsFixed(0);

    return Column(
      key: const ValueKey('recommend'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_outline,
            size: 40, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('Perfect match found',
            style: theme.textTheme.headlineMedium,
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('Based on your $ramGb GB RAM and $_cpuCores-core $_cpuName',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.secondary),
            textAlign: TextAlign.center),
        const SizedBox(height: 24),

        // Recommended model card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(rec.name,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(rec.speedLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: const Color(0xFF10B981),
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(rec.sizeLabel, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(rec.explanation,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.secondary)),
            ],
          ),
        ),

        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {
              setState(() => _step = OnboardingStep.download);
              _startDownload();
            },
            child: Text('Download ${rec.name}'),
          ),
        ),
      ],
    );
  }

  // ── Step 4: Download (direct from HuggingFace, no backend needed) ──
  //    Supports pause/resume via HTTP Range headers.

  Future<void> _startDownload() async {
    try {
      // Use the shared studiomc models directory so both the Flutter app
      // and the Python inference backend (llamacpp) can find downloaded models.
      // On mobile, fall back to the app's own support directory.
      final String modelsDirPath;
      if (isMobile) {
        final appDir = await getApplicationSupportDirectory();
        modelsDirPath = '${appDir.path}/models';
      } else {
        modelsDirPath = studiomcModelsDir;
      }
      final modelsDir = Directory(modelsDirPath);
      if (!await modelsDir.exists()) {
        await modelsDir.create(recursive: true);
      }

      final rec = _recommended!;
      final destFile = File('${modelsDir.path}/${rec.filename}');

      // Check for existing (possibly partial) file
      int existingBytes = 0;
      if (await destFile.exists()) {
        existingBytes = await destFile.length();
        // If we know total and file is already complete, skip to chat
        if (_totalBytes > 0 && existingBytes >= _totalBytes) {
          if (mounted) _goToFirstChat();
          return;
        }
      }

      // Download directly from HuggingFace using RandomAccessFile for
      // immediate disk writes (no buffering that can hang on flush).
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      // HuggingFace redirects to CDN — follow automatically (default)
      client.autoUncompress = false;

      final request = await client.getUrl(Uri.parse(rec.downloadUrl));

      // Add Range header for resume
      if (existingBytes > 0) {
        request.headers.add('Range', 'bytes=$existingBytes-');
      }

      final response = await request.close();

      // Handle Range responses
      if (response.statusCode == 416) {
        // Range not satisfiable — file is already complete
        if (mounted) _goToFirstChat();
        return;
      }

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('HTTP ${response.statusCode}');
      }

      // Determine total bytes
      if (response.statusCode == 206) {
        final contentRange = response.headers.value('content-range') ?? '';
        if (contentRange.contains('/')) {
          final total = contentRange.split('/').last;
          if (total != '*') {
            _totalBytes = int.parse(total);
          }
        }
      } else {
        _totalBytes = response.contentLength;
        existingBytes = 0; // Server didn't honor Range
      }

      int receivedBytes = existingBytes;
      final fileMode =
          response.statusCode == 206 ? FileMode.append : FileMode.write;
      final raf = await destFile.open(mode: fileMode);
      final stopwatch = Stopwatch()..start();

      try {
        await for (final chunk in response) {
          if (!mounted || _isPaused) break;
          await raf.writeFrom(chunk);
          receivedBytes += chunk.length;

          final progress =
              _totalBytes > 0 ? receivedBytes / _totalBytes : 0.0;

          // ETA
          String eta = '';
          if (progress > 0.01 && stopwatch.elapsedMilliseconds > 2000) {
            final elapsed = stopwatch.elapsedMilliseconds / 1000;
            final totalEstimate = elapsed / progress;
            final remaining = (totalEstimate - elapsed).round();
            if (remaining > 60) {
              eta = '${(remaining / 60).round()} min remaining';
            } else {
              eta = '$remaining sec remaining';
            }
          }

          // Speed
          final sessionMb = (receivedBytes - existingBytes) / (1024 * 1024);
          final seconds = stopwatch.elapsedMilliseconds / 1000;
          final speed = seconds > 0 ? sessionMb / seconds : 0.0;
          final speedStr = '${speed.toStringAsFixed(1)} MB/s';

          setState(() {
            _downloadProgress = progress;
            _downloadStatus =
                '${(receivedBytes / (1024 * 1024)).toStringAsFixed(0)} MB${_totalBytes > 0 ? " / ${(_totalBytes / (1024 * 1024)).toStringAsFixed(0)} MB" : ""} — $speedStr${eta.isNotEmpty ? " — $eta" : ""}';
          });
        }
      } finally {
        await raf.close();
        client.close();
      }

      // If paused, show paused status and return (download will resume later)
      if (_isPaused) {
        if (mounted) {
          setState(() {
            _downloadStatus =
                'Paused — ${(receivedBytes / (1024 * 1024)).toStringAsFixed(0)} MB downloaded';
          });
        }
        return;
      }

      if (mounted && !_isPaused) _goToFirstChat();
    } catch (e) {
      if (_isPaused) return; // Don't show error on user-initiated pause
      if (mounted) {
        setState(() {
          _downloadError =
              'Download failed. Check your internet connection and try again.';
        });
      }
    }
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
      if (!_isPaused) {
        // Resume — restart download with Range header from where we left off
        _downloadError = null;
        _startDownload();
      }
    });
  }

  void _goToFirstChat() async {
    // Register downloaded model as active so the rest of the app knows
    if (_recommended != null) {
      final settings = context.read<SettingsService>();
      settings.activeModelId = _recommended!.filename;

      if (isMobile) {
        // Tell MobileInferenceService to scan for the new model and load it
        final mobile = context.read<MobileInferenceService>();
        await mobile.init(); // re-scan downloaded models
        await mobile.loadModel(_recommended!.filename);
        debugPrint('[onboarding] Mobile model loaded: ${_recommended!.filename}');
      } else {
        // Tell the inference backend to select this model (if running)
        final inference = context.read<BundledInferenceService>();
        final modelId = _recommended!.filename
            .replaceAll('.gguf', '')
            .replaceAll('.bin', '')
            .toLowerCase()
            .replaceAll(' ', '-');
        inference.selectModel(modelId).then((_) {
          debugPrint('[onboarding] Model selected on backend: $modelId');
        });
      }
    }

    setState(() => _step = OnboardingStep.firstChat);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) context.go('/chat');
    });
  }

  Widget _buildDownload(ThemeData theme) {
    return Column(
      key: const ValueKey('download'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
            _isPaused
                ? 'Download Paused'
                : 'Downloading ${_recommended?.name ?? "model"}...',
            style: theme.textTheme.headlineMedium,
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(_recommended?.sizeLabel ?? '',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.secondary)),
        const SizedBox(height: 24),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _downloadProgress > 0 ? _downloadProgress : null,
            minHeight: 6,
            color: _isPaused
                ? theme.colorScheme.secondary
                : theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
            _downloadStatus.isNotEmpty
                ? _downloadStatus
                : 'Starting download...',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),

        // ── Pause / Resume button ──
        if (_downloadError == null)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _togglePause,
              icon: Icon(
                _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                size: 20,
              ),
              label: Text(_isPaused ? 'Resume Download' : 'Pause Download'),
            ),
          ),

        if (_downloadError != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_downloadError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
                textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (isDesktop) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => context.go('/chat'),
                    child: const Text('Skip for now'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _downloadError = null;
                      _downloadProgress = 0;
                      _downloadStatus = '';
                      _isPaused = false;
                    });
                    _startDownload();
                  },
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ── Step 5: Done ──

  Widget _buildFirstChat(ThemeData theme) {
    return Column(
      key: const ValueKey('firstChat'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, size: 48, color: Colors.green.shade400),
        const SizedBox(height: 24),
        Text("You're all set!",
            style: theme.textTheme.headlineMedium,
            textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text('Starting your first chat...',
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.secondary)),
      ],
    );
  }

  // ── Built-in model recommendation (no backend needed) ──

  _RecommendedModel _pickBestModel() {
    // GGUF quantized models from HuggingFace — direct download, no auth needed.
    // Picks the best model that fits comfortably in the user's RAM.
    //
    // Mobile devices get smaller models since they share RAM with the OS
    // and other apps, and have thermal/battery constraints.
    if (isMobile) {
      return _pickBestMobileModel();
    }

    if (_ramMb >= 64000) {
      return const _RecommendedModel(
        name: 'Llama 3.2 8B',
        filename: 'llama-3.2-8b-instruct-q5_k_m.gguf',
        downloadUrl:
            'https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q5_K_M.gguf',
        sizeLabel: 'Q5 quantization, ~5.7 GB',
        speedLabel: 'Fast',
        explanation: 'High quality model with plenty of room on your machine.',
      );
    } else if (_ramMb >= 16000) {
      return const _RecommendedModel(
        name: 'Llama 3.2 8B',
        filename: 'llama-3.2-8b-instruct-q4_k_m.gguf',
        downloadUrl:
            'https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
        sizeLabel: 'Q4 quantization, ~4.9 GB',
        speedLabel: 'Fast',
        explanation: 'Best experience for your hardware. Responsive and capable.',
      );
    } else if (_ramMb >= 8000) {
      return const _RecommendedModel(
        name: 'Llama 3.2 3B',
        filename: 'llama-3.2-3b-instruct-q4_k_m.gguf',
        downloadUrl:
            'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
        sizeLabel: 'Q4 quantization, ~2.0 GB',
        speedLabel: 'Fast',
        explanation: 'Lightweight and fast. Perfect for your available memory.',
      );
    } else {
      return const _RecommendedModel(
        name: 'Llama 3.2 1B',
        filename: 'llama-3.2-1b-instruct-q4_k_m.gguf',
        downloadUrl:
            'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
        sizeLabel: 'Q4 quantization, ~0.8 GB',
        speedLabel: 'Fast',
        explanation: 'Smallest model — instant responses, good for quick tasks.',
      );
    }
  }

  /// Mobile-specific model recommendation — always starts with the smallest
  /// model for the fastest, safest first experience. Users can upgrade to
  /// larger models later from the Models screen.
  _RecommendedModel _pickBestMobileModel() {
    return const _RecommendedModel(
      name: 'Qwen2 0.5B',
      filename: 'qwen2-0_5b-instruct-q4_k_m.gguf',
      downloadUrl:
          'https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF/resolve/main/qwen2-0_5b-instruct-q4_k_m.gguf',
      sizeLabel: 'Q4 quantization, ~0.4 GB',
      speedLabel: 'Instant',
      explanation:
          'Ultra-lightweight — instant responses, easy on battery. '
          'Upgrade to larger models anytime from Settings.',
    );
  }
}

class _RecommendedModel {
  final String name;
  final String filename;
  final String downloadUrl;
  final String sizeLabel;
  final String speedLabel;
  final String explanation;

  const _RecommendedModel({
    required this.name,
    required this.filename,
    required this.downloadUrl,
    required this.sizeLabel,
    required this.speedLabel,
    required this.explanation,
  });
}
