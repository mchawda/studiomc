// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    // Desktop: use SpliceLLM + Ollama
    bundledInference.init(preferredModel: settingsService.activeModelId);
    await localInference.init(preferredModel: settingsService.activeModelId);

    if (!settingsService.hasActiveModel &&
        localInference.available &&
        localInference.activeModel != null) {
      settingsService.activeModelId = localInference.activeModel;
    }
  }

  // ── Create per-service API clients ──
  final supervisorApi = ApiClient(baseUrl: ServiceUrls.supervisor);
  final modelManagerApi = ApiClient(baseUrl: ServiceUrls.modelManager);

  // Start full backend (desktop only — mobile cannot spawn processes)
  if (isDesktop) {
    ProcessLauncher.launchBackend().then((_) {
      supervisorApi.checkAvailable();
    });
  }

  final supervisorService = SupervisorService();
  final inferenceService = InferenceService();
  final orchestratorService = OrchestratorService();
  final documentService = DocumentService();
  final hardwareService = HardwareService(supervisorApi);
  final modelManagerService = ModelManagerService(modelManagerApi);

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
      child: const StudiomcApp(),
    ),
  );
}

class StudiomcApp extends StatelessWidget {
  const StudiomcApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Watch SettingsService so theme rebuilds when darkMode changes.
    final settings = context.watch<SettingsService>();

    return MaterialApp.router(
      title: 'Studiomc',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: settings.themeMode,
      routerConfig: appRouter,
    );
  }
}
