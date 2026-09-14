// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:path/path.dart' as p;

import 'engine.dart';

class MobileModelSpec {
  final String id;
  final String displayName;
  final double paramsBillion;
  final DeviceClass minClass;
  final int minRamBytes;
  final String filenameHint;
  final String? desktopCatalogId;

  const MobileModelSpec({
    required this.id,
    required this.displayName,
    required this.paramsBillion,
    required this.minClass,
    required this.minRamBytes,
    required this.filenameHint,
    this.desktopCatalogId,
  });
}

/// Phone (0.6B-1B), tablet (4B), laptop (7B+) policy.
///
/// Every id here is also a desktop catalog id
/// (services/model_manager/registry.py, `CURATED_MODELS`), so a model
/// downloaded on one tier is recognised on every other. Studiomc ids are
/// cross-checked by services/tests/test_studiomc_model.py.
class MobileModelCatalog {
  static const int _gb = 1024 * 1024 * 1024;

  static const studiomc06b = MobileModelSpec(
    id: 'studiomc-0.6b',
    displayName: 'Studiomc 0.6B',
    paramsBillion: 0.6,
    minClass: DeviceClass.phone,
    minRamBytes: 3 * _gb,
    filenameHint: 'studiomc-0.6b-q4_k_m.gguf',
    desktopCatalogId: 'studiomc-0.6b',
  );

  static const desktop1b = MobileModelSpec(
    id: 'llama-3.2-1b-q4km',
    displayName: 'Llama 3.2 1B (Q4_K_M)',
    paramsBillion: 1.24,
    minClass: DeviceClass.phone,
    minRamBytes: 4 * _gb,
    filenameHint: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
    desktopCatalogId: 'llama-3.2-1b-q4km',
  );

  static const studiomc4b = MobileModelSpec(
    id: 'studiomc-4b',
    displayName: 'Studiomc 4B',
    paramsBillion: 4.0,
    minClass: DeviceClass.tablet,
    minRamBytes: 6 * _gb,
    filenameHint: 'studiomc-4b-q4_k_m.gguf',
    desktopCatalogId: 'studiomc-4b',
  );

  static const desktop3b = MobileModelSpec(
    id: 'llama-3.2-3b-q4km',
    displayName: 'Llama 3.2 3B (Q4_K_M)',
    paramsBillion: 3.21,
    minClass: DeviceClass.tablet,
    minRamBytes: 6 * _gb,
    filenameHint: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    desktopCatalogId: 'llama-3.2-3b-q4km',
  );

  static const desktopPhi = MobileModelSpec(
    id: 'phi-3-mini-3.8b-q4km',
    displayName: 'Phi-3 Mini 3.8B (Q4_K_M)',
    paramsBillion: 3.82,
    minClass: DeviceClass.tablet,
    minRamBytes: 6 * _gb,
    filenameHint: 'Phi-3.5-mini-instruct-Q4_K_M.gguf',
    desktopCatalogId: 'phi-3-mini-3.8b-q4km',
  );

  static const desktop8b = MobileModelSpec(
    id: 'llama-3.2-8b-q4km',
    displayName: 'Llama 3.2 8B (Q4_K_M)',
    paramsBillion: 8.03,
    minClass: DeviceClass.laptop,
    minRamBytes: 16 * _gb,
    filenameHint: 'Llama-3.1-8B-Instruct-Q4_K_M.gguf',
    desktopCatalogId: 'llama-3.2-8b-q4km',
  );

  static const desktopQwen7b = MobileModelSpec(
    id: 'qwen-2.5-7b-q4km',
    displayName: 'Qwen 2.5 7B (Q4_K_M)',
    paramsBillion: 7.62,
    minClass: DeviceClass.laptop,
    minRamBytes: 16 * _gb,
    filenameHint: 'Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    desktopCatalogId: 'qwen-2.5-7b-q4km',
  );

  static const all = <MobileModelSpec>[
    studiomc06b,
    desktop1b,
    studiomc4b,
    desktop3b,
    desktopPhi,
    desktop8b,
    desktopQwen7b,
  ];

  static final Map<String, MobileModelSpec> _byId = {
    for (final spec in all) spec.id: spec,
  };

  static MobileModelSpec? byId(String id) => _byId[id];

  static String modelPath({
    required String appSupportDir,
    required String modelId,
  }) {
    final spec = byId(modelId);
    final file = spec?.filenameHint ?? '$modelId.gguf';
    return p.join(appSupportDir, 'models', modelId, file);
  }

  static bool fits(String modelId, HardwareCapabilities hw) {
    final spec = byId(modelId);
    if (spec == null) return false;
    return _classRank(hw.deviceClass) >= _classRank(spec.minClass) &&
        hw.ramBytes >= spec.minRamBytes;
  }

  static List<MobileModelSpec> forDevice(HardwareCapabilities hw) {
    return all.where((spec) => fits(spec.id, hw)).toList(growable: false);
  }

  static String recommendId(HardwareCapabilities hw) {
    final available = forDevice(hw);
    if (available.isEmpty) {
      return studiomc06b.id;
    }
    switch (hw.deviceClass) {
      case DeviceClass.phone:
        return _prefer(available, const ['studiomc-0.6b', 'llama-3.2-1b-q4km']);
      case DeviceClass.tablet:
        return _prefer(available, const ['studiomc-4b', 'llama-3.2-3b-q4km']);
      case DeviceClass.laptop:
        return _prefer(available, const [
          'qwen-2.5-7b-q4km',
          'llama-3.2-8b-q4km',
          'studiomc-4b',
        ]);
    }
  }

  static String _prefer(List<MobileModelSpec> available, List<String> order) {
    for (final id in order) {
      if (available.any((m) => m.id == id)) return id;
    }
    return available.first.id;
  }

  static int _classRank(DeviceClass c) {
    switch (c) {
      case DeviceClass.phone:
        return 0;
      case DeviceClass.tablet:
        return 1;
      case DeviceClass.laptop:
        return 2;
    }
  }
}
