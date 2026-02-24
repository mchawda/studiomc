// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'theme/app_theme.dart';
import 'router/app_router.dart';
import 'services/api_client.dart';
import 'services/bundled_inference_service.dart';
import 'services/database_service.dart';
import 'services/inference_service.dart';
import 'services/mobile_inference_service.dart';
import 'services/orchestrator_service.dart';
import 'services/process_launcher.dart';
import 'services/supervisor_service.dart';
import 'services/hardware_service.dart';
import 'services/model_manager_service.dart';
import 'services/document_service.dart';
import 'services/settings_service.dart';
import 'services/local_inference_service.dart';
import 'utils/platform_utils.dart';

void main() async {
  // Use FFI-based SQLite on desktop so all database I/O runs in the Dart
  // isolate instead of on the platform/main thread. On mobile, the default
  // sqflite implementation works fine.
  if (isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  WidgetsFlutterBinding.ensureInitialized();

  // Global error handlers to prevent unhandled exceptions from crashing
  // the app in release mode.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exception}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled error: $error\n$stack');
    return true; // Prevent crash
  };

  // ── Initialize settings from SharedPreferences ──
  final settingsService = SettingsService();
  await settingsService.init();

  // ── Initialize local database ──
  // Start opening the database in the background so the slow APFS I/O
  // on external drives doesn't block the UI. The first actual DB query
  // will wait for it to finish, but the UI stays responsive until then.
  final databaseService = DatabaseService();
  databaseService.warmUp();

  // ── Create per-service API clients ──
  final supervisorApi = ApiClient(baseUrl: ServiceUrls.supervisor);
  final modelManagerApi = ApiClient(baseUrl: ServiceUrls.modelManager);

  // ── Initialize inference services (platform-aware) ──
  final bundledInference = BundledInferenceService();
  final localInference = LocalInferenceService();
  final mobileInference = MobileInferenceService();

  if (isMobile) {
    // Mobile: use on-device llama.cpp inference
    await mobileInference.init(preferredModel: settingsService.activeModelId);
    if (!settingsService.hasActiveModel &&
        mobileInference.available &&
        mobileInference.activeModel != null) {
      settingsService.activeModelId = mobileInference.activeModel;
    }
  } else {
    // Desktop: start backend + inference services concurrently.
    // ProcessLauncher starts the supervisor which spawns child services
    // (inference on 8100, model_manager on 8101, etc.).
    // BundledInferenceService.init() has its own wait + background retry
    // for when the backend takes longer than expected (first launch can
    // be 30-60s due to hardware scan + sequential service startup).
    //
    // We launch these concurrently to avoid blocking the UI. The chat
    // screen and Discover screen handle "backend starting" state.
    final backendFuture = ProcessLauncher.launchBackend().then((ok) {
      debugPrint('[main] ProcessLauncher completed (success=$ok)');
      if (ok) supervisorApi.checkAvailable();
    });

    // Ollama check is fast and independent of the bundled backend
    await localInference.init(preferredModel: settingsService.activeModelId);

    // Bundled inference has its own wait + retry loop
    bundledInference.init(preferredModel: settingsService.activeModelId);

    // Ensure backend launch errors are logged, not silently dropped
    backendFuture.catchError((e) {
      debugPrint('[main] Backend launch error: $e');
    });

    if (!settingsService.hasActiveModel &&
        localInference.available &&
        localInference.activeModel != null) {
      settingsService.activeModelId = localInference.activeModel;
    }
  }

  final supervisorService = SupervisorService();
  final inferenceService = InferenceService();
  final orchestratorService = OrchestratorService();
  final documentService = DocumentService();
  final hardwareService = HardwareService(supervisorApi);
  final modelManagerService = ModelManagerService(modelManagerApi);

  // Check if any model is actually usable (downloaded GGUF or Ollama model
  // with at least one real model pulled). SharedPreferences may claim
  // onboarding is complete from a prior install, but if models were deleted
  // or the app was installed on a new machine, we need to re-run onboarding.
  bool hasUsableModel = false;
  if (isMobile) {
    hasUsableModel = mobileInference.available && mobileInference.activeModel != null;
  } else {
    // Ollama counts only if it has real pulled models (not just the binary)
    if (localInference.available && localInference.models.isNotEmpty) {
      hasUsableModel = true;
    }
    // Also check for downloaded GGUF files on disk
    if (!hasUsableModel) {
      final modelsDir = io.Directory(studiomcModelsDir);
      if (modelsDir.existsSync()) {
        try {
          hasUsableModel = modelsDir
              .listSync(recursive: true)
              .any((f) => f.path.endsWith('.gguf') || f.path.endsWith('.bin'));
        } catch (_) {}
      }
    }
  }

  if (settingsService.onboardingComplete && !hasUsableModel) {
    settingsService.onboardingComplete = false;
    settingsService.activeModelId = null;
  }

  final router = buildAppRouter(settingsService);

  runApp(
    MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: databaseService),
        Provider<ApiClient>.value(value: supervisorApi),
        Provider<InferenceService>.value(value: inferenceService),
        Provider<OrchestratorService>.value(value: orchestratorService),
        Provider<HardwareService>.value(value: hardwareService),
        Provider<ModelManagerService>.value(value: modelManagerService),
        Provider<SupervisorService>.value(value: supervisorService),
        Provider<DocumentService>.value(value: documentService),
        ChangeNotifierProvider<SettingsService>.value(value: settingsService),
        ChangeNotifierProvider<BundledInferenceService>.value(
            value: bundledInference),
        ChangeNotifierProvider<LocalInferenceService>.value(
            value: localInference),
        ChangeNotifierProvider<MobileInferenceService>.value(
            value: mobileInference),
      ],
      child: StudiomcApp(router: router),
    ),
  );
}

class StudiomcApp extends StatefulWidget {
  final GoRouter router;

  const StudiomcApp({super.key, required this.router});

  @override
  State<StudiomcApp> createState() => _StudiomcAppState();
}

class _StudiomcAppState extends State<StudiomcApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      ProcessLauncher.shutdownBackend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();

    return MaterialApp.router(
      title: 'Studiomc',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: settings.themeMode,
      routerConfig: widget.router,
    );
  }
}
