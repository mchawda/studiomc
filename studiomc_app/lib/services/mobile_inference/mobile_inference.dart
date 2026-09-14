// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show TargetPlatform, kIsWeb;

import 'channel_engine.dart';
import 'engine.dart';
import 'fcllama_engine.dart';
import 'stub_engine.dart';

export 'catalog.dart';
export 'channel_contract.dart';
export 'channel_engine.dart';
export 'engine.dart';
export 'fcllama_engine.dart';
export 'rag.dart';
export 'stub_engine.dart';

/// Desktop keeps FastAPI sidecars. Mobile uses this engine (or the CI stub).
///
/// On iOS and Android the working engine is [FcllamaInferenceEngine]:
/// llama.cpp through the `fcllama` plugin for generation, the Studiomc
/// channel host for `probe` and (once native embed lands) `embed`.
/// Anywhere else the bare [ChannelMobileInferenceEngine] is returned so
/// the absence of a host is a typed [LlamaCppNotLinkedException], not a
/// crash in a plugin that was never registered.
MobileInferenceEngine createMobileInferenceEngine({
  bool stub = false,
  HardwareCapabilities? stubHardware,
  TargetPlatform? platform,
}) {
  if (stub) {
    return StubMobileInferenceEngine(hardware: stubHardware);
  }
  final target = platform ?? _hostPlatform();
  if (target == TargetPlatform.iOS || target == TargetPlatform.android) {
    return FcllamaInferenceEngine();
  }
  return ChannelMobileInferenceEngine();
}

/// The OS the Dart VM is actually running on. `defaultTargetPlatform`
/// reports Android inside `flutter test`, which would hand the fcllama
/// engine to a macOS test process.
TargetPlatform? _hostPlatform() {
  if (kIsWeb) return null;
  if (Platform.isIOS) return TargetPlatform.iOS;
  if (Platform.isAndroid) return TargetPlatform.android;
  if (Platform.isMacOS) return TargetPlatform.macOS;
  if (Platform.isWindows) return TargetPlatform.windows;
  if (Platform.isLinux) return TargetPlatform.linux;
  return null;
}
