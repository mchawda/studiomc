// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const _keyLocalOnly = 'settings_local_only';
  static const _keyShareAnonymousData = 'settings_share_anonymous_data';
  static const _keyCloudConsent = 'settings_cloud_consent';
  static const _keySelectedTheme = 'settings_selected_theme';
  static const _keyDarkMode = 'settings_dark_mode';
  static const _keyLocalApiEnabled = 'settings_local_api_enabled';
  static const _keyContextLength = 'settings_context_length';
  static const _keyBatchSize = 'settings_batch_size';
  static const _keyPrefetchDepth = 'settings_prefetch_depth';
  static const _keyThreads = 'settings_threads';
  static const _keyActiveModelId = 'settings_active_model_id';

  late final SharedPreferences _prefs;

  // Model
  String? _activeModelId;

  // Privacy
  bool _localOnly = true;
  bool _shareAnonymousData = false;
  bool _cloudConsent = false;

  // Appearance
  String _selectedTheme = 'Light Blue';
  bool _darkMode = false;

  // Advanced - API
  bool _localApiEnabled = true;

  // Advanced - Performance
  double _contextLength = 4096;
  double _batchSize = 512;
  double _prefetchDepth = 4;
  double _threads = 4;

  // --- Getters ---
  String? get activeModelId => _activeModelId;
  bool get hasActiveModel => _activeModelId != null && _activeModelId!.isNotEmpty;
  bool get localOnly => _localOnly;
  bool get shareAnonymousData => _shareAnonymousData;
  bool get cloudConsent => _cloudConsent;
  String get selectedTheme => _selectedTheme;
  bool get darkMode => _darkMode;
  bool get localApiEnabled => _localApiEnabled;
  double get contextLength => _contextLength;
  double get batchSize => _batchSize;
  double get prefetchDepth => _prefetchDepth;
  double get threads => _threads;

  ThemeMode get themeMode => _darkMode ? ThemeMode.dark : ThemeMode.light;

  /// Initialize from SharedPreferences. Must be called before use.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    _localOnly = _prefs.getBool(_keyLocalOnly) ?? true;
    _shareAnonymousData = _prefs.getBool(_keyShareAnonymousData) ?? false;
    _cloudConsent = _prefs.getBool(_keyCloudConsent) ?? false;
    _selectedTheme = _prefs.getString(_keySelectedTheme) ?? 'Light Blue';
    _darkMode = _prefs.getBool(_keyDarkMode) ?? false;
    _localApiEnabled = _prefs.getBool(_keyLocalApiEnabled) ?? true;
    _contextLength = _prefs.getDouble(_keyContextLength) ?? 4096;
    _batchSize = _prefs.getDouble(_keyBatchSize) ?? 512;
    _prefetchDepth = _prefs.getDouble(_keyPrefetchDepth) ?? 4;
    _threads = _prefs.getDouble(_keyThreads) ?? 4;
    _activeModelId = _prefs.getString(_keyActiveModelId);

    notifyListeners();
  }

  // --- Setters (persist + notify) ---

  set activeModelId(String? value) {
    _activeModelId = value;
    if (value != null) {
      _prefs.setString(_keyActiveModelId, value);
    } else {
      _prefs.remove(_keyActiveModelId);
    }
    notifyListeners();
  }

  set localOnly(bool value) {
    _localOnly = value;
    _prefs.setBool(_keyLocalOnly, value);
    notifyListeners();
  }

  set shareAnonymousData(bool value) {
    _shareAnonymousData = value;
    _prefs.setBool(_keyShareAnonymousData, value);
    notifyListeners();
  }

  set cloudConsent(bool value) {
    _cloudConsent = value;
    _prefs.setBool(_keyCloudConsent, value);
    notifyListeners();
  }

  set selectedTheme(String value) {
    _selectedTheme = value;
    _prefs.setString(_keySelectedTheme, value);
    // When selecting "Dark Blue", auto-enable dark mode
    if (value == 'Dark Blue') {
      darkMode = true;
    } else if (value == 'Light Blue') {
      darkMode = false;
    }
    notifyListeners();
  }

  set darkMode(bool value) {
    _darkMode = value;
    _prefs.setBool(_keyDarkMode, value);
    notifyListeners();
  }

  set localApiEnabled(bool value) {
    _localApiEnabled = value;
    _prefs.setBool(_keyLocalApiEnabled, value);
    notifyListeners();
  }

  set contextLength(double value) {
    _contextLength = value;
    _prefs.setDouble(_keyContextLength, value);
    notifyListeners();
  }

  set batchSize(double value) {
    _batchSize = value;
    _prefs.setDouble(_keyBatchSize, value);
    notifyListeners();
  }

  set prefetchDepth(double value) {
    _prefetchDepth = value;
    _prefs.setDouble(_keyPrefetchDepth, value);
    notifyListeners();
  }

  set threads(double value) {
    _threads = value;
    _prefs.setDouble(_keyThreads, value);
    notifyListeners();
  }
}
