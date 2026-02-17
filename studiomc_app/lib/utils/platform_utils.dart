// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';

/// Convenience platform checks used throughout the app to gate
/// desktop-only code (Process.start, Ollama, Python backend, etc.)
/// away from mobile platforms where those APIs are unavailable.

bool get isMobile => Platform.isAndroid || Platform.isIOS;
bool get isDesktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

/// Returns the studiomc data directory that matches the Python backend's
/// `platformdirs.user_data_dir('studiomc', 'studiomc')`.
///
/// This ensures the Flutter app and Python services share the same
/// models directory, database paths, etc.
String get studiomcDataDir {
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/Application Support/studiomc';
  } else if (Platform.isWindows) {
    final appData = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        '';
    return '$appData/studiomc/studiomc';
  } else {
    // Linux
    final home = Platform.environment['HOME'] ?? '';
    final xdgData =
        Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
    return '$xdgData/studiomc';
  }
}

/// Returns the shared models directory used by both the Flutter app
/// and the Python inference backends.
///
/// Model file layout:
///   - Flutter onboarding/Discover: `models/<filename>.gguf`  (flat)
///   - Model Manager backend:       `models/<model_id>/<file>.gguf`  (nested)
///
/// The LlamaCpp backend uses `rglob("*.gguf")` so both layouts are
/// discovered automatically. Keep this in mind when checking for
/// installed models — a file may exist at either depth.
String get studiomcModelsDir => '$studiomcDataDir/models';
