// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter_test/flutter_test.dart';
import 'package:studiomc_app/services/mobile_inference/mobile_inference.dart';

void main() {
  group('MobileModelCatalog', () {
    test('exposes shared Studiomc and desktop catalog IDs', () {
      expect(MobileModelCatalog.studiomc06b.id, 'studiomc-0.6b');
      expect(MobileModelCatalog.studiomc4b.id, 'studiomc-4b');
      expect(MobileModelCatalog.desktop1b.id, 'llama-3.2-1b-q4km');
      expect(MobileModelCatalog.desktop1b.desktopCatalogId, 'llama-3.2-1b-q4km');
      expect(MobileModelCatalog.byId('studiomc-0.6b'), isNotNull);
      expect(MobileModelCatalog.byId('missing'), isNull);
    });

    test('every spec aliases a desktop catalog id', () {
      for (final spec in MobileModelCatalog.all) {
        expect(spec.desktopCatalogId, spec.id, reason: spec.id);
      }
      final studiomcIds = MobileModelCatalog.all
          .map((m) => m.id)
          .where((id) => id.startsWith('studiomc-'))
          .toSet();
      expect(studiomcIds, {'studiomc-0.6b', 'studiomc-4b'});
    });

    test('only the hybrid-thinking Qwen3 build carries enable_thinking=false',
        () {
      expect(MobileModelCatalog.studiomc06b.chatTemplateKwargs,
          {'enable_thinking': false});
      // Qwen3-4B-Instruct-2507 is a plain instruct model.
      expect(MobileModelCatalog.studiomc4b.chatTemplateKwargs, isEmpty);
      for (final spec in MobileModelCatalog.all) {
        if (spec.id != 'studiomc-0.6b') {
          expect(spec.chatTemplateKwargs, isEmpty, reason: spec.id);
        }
      }
    });

    test('chatTemplateKwargsFor resolves by id, filename, then family', () {
      expect(MobileModelCatalog.chatTemplateKwargsFor(modelId: 'studiomc-0.6b'),
          {'enable_thinking': false});
      expect(
        MobileModelCatalog.chatTemplateKwargsFor(
          modelId: 'STUDIOMC-0.6B-Q4_K_M.gguf',
        ),
        {'enable_thinking': false},
      );
      expect(
        MobileModelCatalog.chatTemplateKwargsFor(
          modelPath: '/models/Qwen_Qwen3-0.6B-Q4_K_M.gguf',
        ),
        {'enable_thinking': false},
      );
      expect(
        MobileModelCatalog.chatTemplateKwargsFor(
          modelPath: '/models/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
        ),
        isEmpty,
      );
      expect(
        MobileModelCatalog.chatTemplateKwargsFor(
          modelId: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
        ),
        isEmpty,
      );
      expect(MobileModelCatalog.byFilename('/x/studiomc-4b-q4_k_m.gguf')?.id,
          'studiomc-4b');
    });

    test('applyChatTemplateKwargs renders the Qwen3 no-think header once', () {
      const rendered = '<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n';
      final off = applyChatTemplateKwargs(rendered, {'enable_thinking': false});
      expect(off, '$rendered$qwen3NoThinkSuffix');
      expect(applyChatTemplateKwargs(off, {'enable_thinking': false}), off);
      expect(applyChatTemplateKwargs(rendered, {'enable_thinking': true}),
          rendered);
      expect(applyChatTemplateKwargs(rendered, {}), rendered);
      // An earlier assistant turn containing </think> must not suppress it.
      const history =
          '<|im_start|>assistant\n<think>\n\n</think>\n\nA<|im_end|>\n<|im_start|>assistant\n';
      expect(applyChatTemplateKwargs(history, {'enable_thinking': false}),
          endsWith('assistant\n$qwen3NoThinkSuffix'));
    });

    test('recommends 0.6B-1B on phones', () {
      final phone = HardwareCapabilities(
        ramBytes: 6 * 1024 * 1024 * 1024,
        deviceClass: DeviceClass.phone,
        accelerators: {Accelerator.neuralEngine, Accelerator.metal},
        chipName: 'A17 Pro',
      );

      expect(MobileModelCatalog.recommendId(phone), 'studiomc-0.6b');
      final ids = MobileModelCatalog.forDevice(phone).map((m) => m.id);
      expect(ids, containsAll(['studiomc-0.6b', 'llama-3.2-1b-q4km']));
      expect(ids, isNot(contains('studiomc-4b')));
      expect(MobileModelCatalog.fits('studiomc-0.6b', phone), isTrue);
      expect(MobileModelCatalog.fits('studiomc-4b', phone), isFalse);
    });

    test('recommends 4B on tablets with enough RAM', () {
      final tablet = HardwareCapabilities(
        ramBytes: 8 * 1024 * 1024 * 1024,
        deviceClass: DeviceClass.tablet,
        accelerators: {Accelerator.nnapi, Accelerator.gpu},
        chipName: 'Tensor',
      );

      expect(MobileModelCatalog.recommendId(tablet), 'studiomc-4b');
      final ids = MobileModelCatalog.forDevice(tablet).map((m) => m.id);
      expect(ids, contains('studiomc-4b'));
      expect(ids, contains('llama-3.2-3b-q4km'));
      expect(MobileModelCatalog.fits('studiomc-4b', tablet), isTrue);
    });

    test('keeps 7B+ models on laptop class only', () {
      final laptop = HardwareCapabilities(
        ramBytes: 32 * 1024 * 1024 * 1024,
        deviceClass: DeviceClass.laptop,
        accelerators: {Accelerator.metal, Accelerator.gpu},
      );
      final ids = MobileModelCatalog.forDevice(laptop).map((m) => m.id).toList();
      expect(ids, contains('qwen-2.5-7b-q4km'));
      expect(MobileModelCatalog.recommendId(laptop), isNot('studiomc-0.6b'));
    });

    test('rejects undersized RAM even on the right device class', () {
      final tightPhone = HardwareCapabilities(
        ramBytes: 2 * 1024 * 1024 * 1024,
        deviceClass: DeviceClass.phone,
        accelerators: {Accelerator.cpu},
      );
      expect(MobileModelCatalog.fits('studiomc-0.6b', tightPhone), isFalse);
      expect(MobileModelCatalog.forDevice(tightPhone), isEmpty);
    });

    test('builds the app-support model path used by llama.cpp', () {
      expect(
        MobileModelCatalog.modelPath(
          appSupportDir: '/tmp/support',
          modelId: 'studiomc-0.6b',
        ),
        '/tmp/support/models/studiomc-0.6b/studiomc-0.6b-q4_k_m.gguf',
      );
    });
  });
}
