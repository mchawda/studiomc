// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:studiomc_app/services/process_launcher.dart';
import 'package:studiomc_app/utils/platform_utils.dart';

void main() {
  group('ProcessLauncher.identityMatchesBundle', () {
    late Directory tmp;
    late String bundled;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('studiomc-launcher-');
      bundled = '${tmp.path}/Studiomc.app/Contents/Resources/studiomc_services/studiomc_services';
      File(bundled).createSync(recursive: true);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('accepts a supervisor launched from this bundle', () {
      expect(
        ProcessLauncher.identityMatchesBundle(
          {'executable': bundled, 'bundled': true, 'pid': 42},
          bundled,
        ),
        isTrue,
      );
    });

    test('rejects a supervisor from a different install path', () {
      expect(
        ProcessLauncher.identityMatchesBundle(
          {
            'executable': '/Applications/Old.app/Contents/Resources/studiomc_services/studiomc_services',
            'bundled': true,
          },
          bundled,
        ),
        isFalse,
      );
    });

    test('rejects a dev interpreter even if it answers /health', () {
      expect(
        ProcessLauncher.identityMatchesBundle(
          {'executable': '/repo/services/.venv/bin/python', 'bundled': false},
          bundled,
        ),
        isFalse,
      );
    });

    test('rejects pre-identity supervisors (no executable field)', () {
      expect(
        ProcessLauncher.identityMatchesBundle(
          {'status': 'ok', 'service': 'supervisor'},
          bundled,
        ),
        isFalse,
      );
    });

    test('resolves symlinks before comparing', () {
      final link = Link('${tmp.path}/services-link');
      link.createSync(File(bundled).parent.path);
      expect(
        ProcessLauncher.identityMatchesBundle(
          {'executable': '${link.path}/studiomc_services', 'bundled': true},
          bundled,
        ),
        isTrue,
      );
    });
  });

  group('studiomcDataDir', () {
    test('matches the Python platformdirs layout when unset', () {
      final dir = studiomcDataDir;
      if (Platform.environment['STUDIOMC_HOME']?.isNotEmpty ?? false) {
        expect(dir, Platform.environment['STUDIOMC_HOME']);
      } else if (Platform.isMacOS) {
        expect(dir, endsWith('/Library/Application Support/studiomc'));
      } else if (Platform.isLinux) {
        expect(dir, endsWith('/studiomc'));
      }
    });
  });
}
