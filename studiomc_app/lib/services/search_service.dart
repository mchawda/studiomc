// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:studiomc_app/services/api_client.dart';

class SearchHit {
  SearchHit({
    required this.type,
    required this.id,
    required this.title,
    required this.snippet,
    required this.timestamp,
  });

  /// One of: 'chat', 'document', 'memory', 'tool', 'action'.
  final String type;
  final String id;
  final String title;
  final String snippet;
  final String timestamp;

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        type: json['type'] as String? ?? 'unknown',
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Untitled',
        snippet: json['snippet'] as String? ?? '',
        timestamp: json['timestamp'] as String? ?? '',
      );
}

/// Thin wrapper over the supervisor's `/search` endpoint that returns a
/// unified SearchHit list. The command palette also augments these
/// results with synthetic "action" hits client-side.
class SearchService {
  SearchService({ApiClient? client})
      : _api = client ?? ApiClient(baseUrl: ServiceUrls.supervisor);

  final ApiClient _api;

  Future<List<SearchHit>> search(String query, {int limit = 20, String scope = 'all'}) async {
    final encoded = Uri.encodeQueryComponent(query);
    final body = await _api.get('/search?q=$encoded&scope=$scope&limit=$limit');
    final results = body['results'];
    if (results is! List) return const [];
    return results
        .whereType<Map<String, dynamic>>()
        .map(SearchHit.fromJson)
        .toList(growable: false);
  }
}
