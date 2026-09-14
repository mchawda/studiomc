// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:studiomc_app/services/api_client.dart';

/// One MCP server registered with the broker.
class McpServer {
  McpServer({
    required this.id,
    required this.name,
    required this.description,
    required this.transport,
    required this.command,
    required this.args,
    required this.env,
    required this.url,
    required this.enabled,
    required this.autoStart,
    required this.running,
    this.lastError,
  });

  final String id;
  final String name;
  final String? description;
  final String transport; // 'stdio' | 'http' | 'sse'
  final String? command;
  final List<String> args;
  final Map<String, String> env;
  final String? url;
  final bool enabled;
  final bool autoStart;
  final bool running;
  final String? lastError;

  factory McpServer.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['args'];
    final rawEnv = json['env'];
    return McpServer(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      transport: json['transport'] as String,
      command: json['command'] as String?,
      args: (rawArgs is List) ? List<String>.from(rawArgs.map((e) => '$e')) : <String>[],
      env: (rawEnv is Map)
          ? rawEnv.map((k, v) => MapEntry(k.toString(), v.toString()))
          : <String, String>{},
      url: json['url'] as String?,
      enabled: (json['enabled'] as bool?) ?? true,
      autoStart: (json['auto_start'] as bool?) ?? true,
      running: (json['running'] as bool?) ?? false,
      lastError: json['last_error'] as String?,
    );
  }
}

/// One tool exposed by an MCP server (cached in the registry DB).
class McpTool {
  McpTool({
    required this.serverId,
    required this.serverName,
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.enabled,
  });

  final String serverId;
  final String serverName;
  final String name;
  final String? description;
  final Map<String, dynamic> inputSchema;
  final bool enabled;

  String get qualifiedName => '$serverName.$name';

  factory McpTool.fromJson(Map<String, dynamic> json) => McpTool(
        serverId: json['server_id'] as String,
        serverName: json['server_name'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        inputSchema: (json['input_schema'] as Map?)?.cast<String, dynamic>() ?? const {},
        enabled: (json['enabled'] as bool?) ?? true,
      );
}

/// One audited tool invocation (enterprise rule §5).
class McpAuditEntry {
  McpAuditEntry({
    required this.id,
    required this.serverId,
    required this.toolName,
    required this.chatId,
    required this.actor,
    required this.arguments,
    required this.resultSummary,
    required this.error,
    required this.durationMs,
    required this.createdAt,
  });

  final int id;
  final String? serverId;
  final String? toolName;
  final String? chatId;
  final String? actor;
  final Map<String, dynamic> arguments;
  final String? resultSummary;
  final String? error;
  final int? durationMs;
  final String createdAt;

  factory McpAuditEntry.fromJson(Map<String, dynamic> json) => McpAuditEntry(
        id: (json['id'] as num).toInt(),
        serverId: json['server_id'] as String?,
        toolName: json['tool_name'] as String?,
        chatId: json['chat_id'] as String?,
        actor: json['actor'] as String?,
        arguments: (json['arguments'] as Map?)?.cast<String, dynamic>() ?? const {},
        resultSummary: json['result_summary'] as String?,
        error: json['error'] as String?,
        durationMs: (json['duration_ms'] as num?)?.toInt(),
        createdAt: json['created_at'] as String,
      );
}

/// Dart client for the Studiomc MCP service (port 8108).
///
/// All endpoints are versioned under `/v1` and return the standard
/// `{success, data, error}` envelope, which is unwrapped here for
/// convenience.
class McpService {
  McpService({ApiClient? client})
      : _api = client ?? ApiClient(baseUrl: ServiceUrls.mcp);

  final ApiClient _api;

  // ── Servers ────────────────────────────────────────────────────────

  Future<List<McpServer>> listServers() async {
    final body = await _api.get('/v1/servers');
    final data = body['data'] as List? ?? const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(McpServer.fromJson)
        .toList(growable: false);
  }

  Future<McpServer> addServer({
    required String name,
    required String transport,
    String? description,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? url,
    bool enabled = true,
    bool autoStart = true,
  }) async {
    final body = await _api.post('/v1/servers', body: {
      'name': name,
      'transport': transport,
      'description': ?description,
      'command': ?command,
      'args': args ?? const <String>[],
      'env': env ?? const <String, String>{},
      'url': ?url,
      'enabled': enabled,
      'auto_start': autoStart,
    });
    return McpServer.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  Future<McpServer> updateServer(
    String id, {
    String? name,
    String? description,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? url,
    bool? enabled,
    bool? autoStart,
  }) async {
    final body = await _api.patch('/v1/servers/$id', body: {
      'name': ?name,
      'description': ?description,
      'command': ?command,
      'args': ?args,
      'env': ?env,
      'url': ?url,
      'enabled': ?enabled,
      'auto_start': ?autoStart,
    });
    return McpServer.fromJson((body['data'] as Map).cast<String, dynamic>());
  }

  Future<void> deleteServer(String id) async {
    await _api.delete('/v1/servers/$id');
  }

  Future<McpServer> startServer(String id) async {
    final body = await _api.post('/v1/servers/$id/start');
    final data = (body['data'] as Map).cast<String, dynamic>();
    // Re-fetch to get full server payload with tool count.
    return McpServer.fromJson({
      'id': data['id'],
      'name': '',
      'description': null,
      'transport': 'stdio',
      'command': null,
      'args': const [],
      'env': const {},
      'url': null,
      'enabled': true,
      'auto_start': true,
      'running': data['running'] ?? true,
    });
  }

  Future<void> stopServer(String id) async {
    await _api.post('/v1/servers/$id/stop');
  }

  Future<void> restartServer(String id) async {
    await _api.post('/v1/servers/$id/restart');
  }

  // ── Tools ──────────────────────────────────────────────────────────

  Future<List<McpTool>> listTools() async {
    final body = await _api.get('/v1/tools');
    final data = body['data'] as List? ?? const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(McpTool.fromJson)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> callTool({
    required String serverId,
    required String toolName,
    Map<String, dynamic>? arguments,
    String? chatId,
    String? actor,
  }) async {
    final body = await _api.post('/v1/tools/call', body: {
      'server_id': serverId,
      'tool_name': toolName,
      'arguments': arguments ?? const <String, dynamic>{},
      'chat_id': ?chatId,
      'actor': ?actor,
    });
    return (body['data'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  // ── Audit ──────────────────────────────────────────────────────────

  Future<List<McpAuditEntry>> listAudit({int limit = 50, String? serverId}) async {
    final qs = StringBuffer('?limit=$limit');
    if (serverId != null) qs.write('&server_id=$serverId');
    final body = await _api.get('/v1/audit$qs');
    final data = body['data'] as List? ?? const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(McpAuditEntry.fromJson)
        .toList(growable: false);
  }
}
