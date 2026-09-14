// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/bundled_inference_service.dart';
import '../services/local_inference_service.dart';
import '../services/mobile_inference_service.dart';
import '../services/settings_service.dart';
import '../utils/platform_utils.dart';
import '../widgets/common/studiomc_logo.dart';

/// Onboarding: two screens, one click.
///
///   1. Welcome — pick "Get started" or, if Ollama models were detected,
///      tap an existing model to skip setup entirely.
///   2. Setup — scan, recommend, and download run automatically inside a
///      single progress card. When the bar reaches 100% the user taps
///      "Start chatting" once and lands in /chat.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Phase { welcome, setup }

enum _SetupStage { scanning, downloading, ready, error }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Phase _phase = _Phase.welcome;
  _SetupStage _stage = _SetupStage.scanning;

  // Hardware
  int _ramMb = 0;
  String _cpuName = '';
  int _cpuCores = 0;

  // Recommendation + download
  _RecommendedModel? _recommended;
  double _progress = 0;
  String _statusLine = '';
  String? _errorMessage;
  bool _isPaused = false;
  int _totalBytes = 0;

  // Existing models
  List<String> _existingOllamaModels = [];

  @override
  void initState() {
    super.initState();
    if (isDesktop) _detectExistingModels();
  }

  // ── Welcome phase ────────────────────────────────────────────────────

  Future<void> _detectExistingModels() async {
    try {
      final localInference = context.read<LocalInferenceService>();
      if (localInference.available && localInference.models.isNotEmpty) {
        if (mounted) {
          setState(() {
            _existingOllamaModels =
                localInference.models.map((m) => m.name).toList();
          });
        }
      }
    } catch (_) {}
  }

  void _useExistingModel(String modelName) {
    final settings = context.read<SettingsService>();
    settings.activeModelId = modelName;
    settings.onboardingComplete = true;
    context.read<LocalInferenceService>().selectModel(modelName);
    context.go('/chat');
  }

  // ── Setup phase: scan → recommend → download → ready ────────────────

  Future<void> _beginSetup() async {
    setState(() {
      _phase = _Phase.setup;
      _stage = _SetupStage.scanning;
      _statusLine = 'Checking your hardware…';
      _progress = 0;
    });

    await _scanHardware();
    if (!mounted) return;

    _recommended = _pickBestModel();
    setState(() {
      _stage = _SetupStage.downloading;
      _statusLine = 'Preparing ${_recommended!.name}…';
    });
    await _startDownload();
  }

  Future<void> _scanHardware() async {
    try {
      _cpuCores = Platform.numberOfProcessors;
      if (isMobile) {
        await _scanMobileHardware();
      } else {
        await _scanDesktopHardware();
      }
    } catch (_) {
      _ramMb = 0;
      _cpuName = '${Platform.operatingSystem} ($_cpuCores cores)';
    }
  }

  Future<void> _scanMobileHardware() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      _cpuName = android.hardware;
      final sdkInt = android.version.sdkInt;
      _ramMb = sdkInt >= 31 ? 6144 : 4096;
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      _cpuName = ios.utsname.machine;
      _ramMb = _estimateIosRam(ios.utsname.machine);
    }
  }

  int _estimateIosRam(String machine) {
    if (machine.contains('iPhone16') || machine.contains('iPhone17')) return 8192;
    if (machine.contains('iPhone15') || machine.contains('iPhone14')) return 6144;
    if (machine.contains('iPad14') || machine.contains('iPad16')) return 8192;
    return 4096;
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

  // ── Download (with pause/resume) ─────────────────────────────────────

  Future<void> _startDownload() async {
    try {
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
      final expectedBytes = await _fetchRemoteContentLength(rec.downloadUrl);

      int existingBytes = 0;
      if (await destFile.exists()) {
        existingBytes = await destFile.length();
        if (expectedBytes > 0 && existingBytes >= expectedBytes) {
          _markReady();
          return;
        }
      }

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);
      client.autoUncompress = false;

      final request = await client.getUrl(Uri.parse(rec.downloadUrl));
      if (existingBytes > 0) {
        request.headers.add('Range', 'bytes=$existingBytes-');
      }

      final response = await request.close();

      if (response.statusCode == 416) {
        _markReady();
        return;
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('HTTP ${response.statusCode}');
      }

      if (response.statusCode == 206) {
        final contentRange = response.headers.value('content-range') ?? '';
        if (contentRange.contains('/')) {
          final total = contentRange.split('/').last;
          if (total != '*') {
            _totalBytes = int.parse(total);
          }
        }
      } else {
        _totalBytes = expectedBytes > 0 ? expectedBytes : response.contentLength;
        existingBytes = 0;
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
          final mbDone = receivedBytes / (1024 * 1024);
          final mbTotal = _totalBytes / (1024 * 1024);
          final sessionMb = (receivedBytes - existingBytes) / (1024 * 1024);
          final seconds = stopwatch.elapsedMilliseconds / 1000;
          final speed = seconds > 0 ? sessionMb / seconds : 0.0;

          String eta = '';
          if (progress > 0.01 && stopwatch.elapsedMilliseconds > 2000) {
            final totalEst = seconds / progress;
            final remaining = (totalEst - seconds).round();
            eta = remaining > 60
                ? ' • ${(remaining / 60).round()} min left'
                : ' • $remaining s left';
          }

          setState(() {
            _progress = progress;
            _statusLine = _totalBytes > 0
                ? '${mbDone.toStringAsFixed(0)} / ${mbTotal.toStringAsFixed(0)} MB'
                  ' • ${speed.toStringAsFixed(1)} MB/s$eta'
                : '${mbDone.toStringAsFixed(0)} MB downloaded';
          });
        }
      } finally {
        await raf.close();
        client.close();
      }

      if (_isPaused) {
        if (mounted) {
          setState(() {
            _statusLine =
                'Paused at ${(receivedBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
          });
        }
        return;
      }

      _markReady();
    } catch (e) {
      if (_isPaused) return;
      if (mounted) {
        setState(() {
          _stage = _SetupStage.error;
          _errorMessage =
              'Download failed. Check your internet connection and try again.';
        });
      }
    }
  }

  void _markReady() {
    if (!mounted) return;
    setState(() {
      _progress = 1.0;
      _stage = _SetupStage.ready;
      _statusLine = '${_recommended?.name ?? "Model"} ready to use';
    });
  }

  Future<int> _fetchRemoteContentLength(String url) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl('HEAD', Uri.parse(url));
      final response = await request.close();
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return response.contentLength;
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return -1;
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
      if (!_isPaused) {
        _errorMessage = null;
        _startDownload();
      }
    });
  }

  void _retry() {
    setState(() {
      _errorMessage = null;
      _progress = 0;
      _statusLine = '';
      _isPaused = false;
      _stage = _SetupStage.downloading;
    });
    _startDownload();
  }

  Future<void> _startChatting() async {
    final settings = context.read<SettingsService>();
    settings.onboardingComplete = true;
    if (_recommended != null) {
      settings.activeModelId = _recommended!.filename;

      if (isMobile) {
        final mobile = context.read<MobileInferenceService>();
        await mobile.init();
        await mobile.loadModel(_recommended!.filename);
      } else {
        final inference = context.read<BundledInferenceService>();
        final modelId = _recommended!.filename
            .replaceAll('.gguf', '')
            .replaceAll('.bin', '')
            .toLowerCase()
            .replaceAll(' ', '-');
        unawaited(inference.selectModel(modelId));
      }
    }
    if (mounted) context.go('/chat');
  }

  // ── Build ────────────────────────────────────────────────────────────

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
                  duration: const Duration(milliseconds: 220),
                  child: _phase == _Phase.welcome
                      ? _buildWelcome(theme)
                      : _buildSetup(theme),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

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

        if (_existingOllamaModels.isNotEmpty) ...[
          _existingModelsCard(theme),
          const SizedBox(height: 16),
          Text('— or —',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.secondary)),
          const SizedBox(height: 16),
        ],

        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _beginSetup,
            child: Text(_existingOllamaModels.isEmpty
                ? 'Get started'
                : 'Download a fresh model'),
          ),
        ),
      ],
    );
  }

  Widget _existingModelsCard(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline,
                  size: 18, color: Colors.green.shade700),
              const SizedBox(width: 8),
              Text('Models found on your system',
                  style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.green.shade700)),
            ],
          ),
          const SizedBox(height: 12),
          ..._existingOllamaModels.take(5).map((name) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => _useExistingModel(name),
                    child: Text('Use $name'),
                  ),
                ),
              )),
        ],
      ),
    );
  }

  // ── Setup card: one continuous progress experience ─────────────────

  Widget _buildSetup(ThemeData theme) {
    final headline = switch (_stage) {
      _SetupStage.scanning => 'Setting up your AI',
      _SetupStage.downloading =>
        _isPaused ? 'Download paused' : 'Setting up your AI',
      _SetupStage.ready => 'You\'re all set',
      _SetupStage.error => 'Something went wrong',
    };

    final modelLine = _recommended != null
        ? '${_recommended!.name} • ${_recommended!.sizeLabel}'
        : null;

    final color = switch (_stage) {
      _SetupStage.ready => Colors.green.shade400,
      _SetupStage.error => theme.colorScheme.error,
      _ => theme.colorScheme.primary,
    };

    return Column(
      key: const ValueKey('setup'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          switch (_stage) {
            _SetupStage.ready => Icons.check_circle_rounded,
            _SetupStage.error => Icons.error_outline_rounded,
            _ => Icons.auto_awesome_rounded,
          },
          size: 40,
          color: color,
        ),
        const SizedBox(height: 16),
        Text(headline,
            style: theme.textTheme.headlineMedium,
            textAlign: TextAlign.center),
        if (modelLine != null) ...[
          const SizedBox(height: 6),
          Text(modelLine,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.secondary),
              textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),

        if (_stage != _SetupStage.error) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _stage == _SetupStage.scanning
                  ? null
                  : (_progress > 0 ? _progress : null),
              minHeight: 6,
              color: color,
            ),
          ),
          const SizedBox(height: 8),
          if (_progress > 0 && _stage == _SetupStage.downloading)
            Text('${(_progress * 100).toInt()}%',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                )),
          const SizedBox(height: 4),
          Text(_statusLine.isEmpty ? ' ' : _statusLine,
              style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
          const SizedBox(height: 20),
        ],

        // Action area: changes per stage
        if (_stage == _SetupStage.downloading)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _togglePause,
              icon: Icon(
                _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                size: 20,
              ),
              label: Text(_isPaused ? 'Resume' : 'Pause'),
            ),
          ),

        if (_stage == _SetupStage.ready)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _startChatting,
              icon: const Icon(Icons.chat_rounded, size: 18),
              label: const Text('Start chatting'),
            ),
          ),

        if (_stage == _SetupStage.error) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_errorMessage ?? 'Unknown error',
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
                  onPressed: _retry,
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ── Built-in model recommendation (no backend needed) ──

  _RecommendedModel _pickBestModel() {
    if (isMobile) return _pickBestMobileModel();

    if (_ramMb >= 8000) {
      return const _RecommendedModel(
        name: 'Studiomc 4B',
        filename: 'studiomc-4b-q4_k_m.gguf',
        downloadUrl:
            'https://huggingface.co/bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
        sizeLabel: '~2.5 GB • Q4',
        speedLabel: 'Fast',
        explanation:
            'Studiomc specialized 4B for cited answers. Fits desktop memory.',
      );
    } else {
      return const _RecommendedModel(
        name: 'Llama 3.2 1B',
        filename: 'llama-3.2-1b-instruct-q4_k_m.gguf',
        downloadUrl:
            'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
        sizeLabel: '~0.8 GB • Q4',
        speedLabel: 'Fast',
        explanation: 'Smallest model — instant responses for quick tasks.',
      );
    }
  }

  _RecommendedModel _pickBestMobileModel() {
    return const _RecommendedModel(
      name: 'Qwen2 0.5B',
      filename: 'qwen2-0_5b-instruct-q4_k_m.gguf',
      downloadUrl:
          'https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF/resolve/main/qwen2-0_5b-instruct-q4_k_m.gguf',
      sizeLabel: '~0.4 GB • Q4',
      speedLabel: 'Instant',
      explanation:
          'Ultra-lightweight — instant responses, easy on battery. '
          'Upgrade anytime from Settings.',
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
