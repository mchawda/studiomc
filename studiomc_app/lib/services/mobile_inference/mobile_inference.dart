// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'channel_engine.dart';
import 'engine.dart';
import 'stub_engine.dart';

export 'catalog.dart';
export 'channel_contract.dart';
export 'channel_engine.dart';
export 'engine.dart';
export 'rag.dart';
export 'stub_engine.dart';

/// Desktop keeps FastAPI sidecars. Mobile uses this engine (or the CI stub).
MobileInferenceEngine createMobileInferenceEngine({
  bool stub = false,
  HardwareCapabilities? stubHardware,
}) {
  if (stub) {
    return StubMobileInferenceEngine(hardware: stubHardware);
  }
  return ChannelMobileInferenceEngine();
}
