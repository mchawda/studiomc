// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';

/// Convenience platform checks used throughout the app to gate
/// desktop-only code (Process.start, Ollama, Python backend, etc.)
/// away from mobile platforms where those APIs are unavailable.

bool get isMobile => Platform.isAndroid || Platform.isIOS;
bool get isDesktop => Platform.isMacOS || Platform.isLinux || Platform.isWindows;
