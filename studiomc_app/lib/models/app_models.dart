// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

// Core data models for Studiomc

enum SpeedRating { fast, ok, slow, painful }

enum ChatMode { chat, docs, investigate }

enum PresetMode { defaultMode, writing, coding, tutor }

enum MessageRole { system, user, assistant, tool }

enum ModelSource { hf, local, curated }

enum DownloadStatus { notDownloaded, downloading, paused, verifying, ready, error }

enum DocStatus { uploading, processing, ready, error }

enum DocType { pdf, txt, md, docx, pptx, xlsx, json, image }

enum QualityMode { fast, cited, deep }

enum OnboardingStep { welcome, scan, recommend, download, firstChat }

enum TrainingSourceType { collection, extractPaste, extractFile }

enum TrainingRunStatus { idle, preparing, training, completed, failed }

// ── Personalization ──

enum PersonalizationGoal {
  answerQuestions, // → RAG / Knowledge Library
  writeInStyle,   // → LoRA style adapter
  followRules,    // → LoRA workflow/policy adapter
  improveDomain,  // → LoRA domain fine-tune (advanced)
}

enum ExtractCategory { qa, facts, glossary, rules, templates, constraints }

enum PersonalizationMethod { knowledgeLibrary, styleAdapter, workflowFollower }

// ── Models ──

class AIModel {
  final String id;
  final String name;
  final ModelSource source;
  final String? sourceRef;
  final double paramsBillion;
  final String? quant;
  final int diskBytes;
  final String? arch;
  final int contextMax;
  final String? checksum;
  final SpeedRating speedRating;
  final double predictedTokPerS;
  final int predictedTtftMs;
  final String sizeLabel;
  final bool isActive;
  final bool isRecommended;
  final DateTime? lastUsedAt;
  final DownloadStatus downloadStatus;
  final double? downloadProgress;

  const AIModel({
    required this.id,
    required this.name,
    required this.source,
    this.sourceRef,
    required this.paramsBillion,
    this.quant,
    required this.diskBytes,
    this.arch,
    required this.contextMax,
    this.checksum,
    required this.speedRating,
    required this.predictedTokPerS,
    required this.predictedTtftMs,
    required this.sizeLabel,
    this.isActive = false,
    this.isRecommended = false,
    this.lastUsedAt,
    this.downloadStatus = DownloadStatus.notDownloaded,
    this.downloadProgress,
  });
}

class Chat {
  final String id;
  final String title;
  final String modelId;
  final PresetMode mode;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isPinned;

  const Chat({
    required this.id,
    required this.title,
    required this.modelId,
    required this.mode,
    required this.createdAt,
    required this.updatedAt,
    this.isPinned = false,
  });
}

class Message {
  final String id;
  final String chatId;
  final MessageRole role;
  final String content;
  final int tokens;
  final DateTime createdAt;
  final String? parentMessageId;
  final bool isStreaming;

  /// Base64-encoded images attached to this message.
  final List<String> images;

  const Message({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    this.tokens = 0,
    required this.createdAt,
    this.parentMessageId,
    this.isStreaming = false,
    this.images = const [],
  });
}

class Document {
  final String id;
  final String filename;
  final String mime;
  final int bytes;
  final String? sha256;
  final DocType docType;
  final DocStatus status;
  final double processingProgress;
  final int chunkCount;
  final DateTime createdAt;

  const Document({
    required this.id,
    required this.filename,
    required this.mime,
    required this.bytes,
    this.sha256,
    required this.docType,
    required this.status,
    this.processingProgress = 0,
    this.chunkCount = 0,
    required this.createdAt,
  });
}

class Collection {
  final String id;
  final String name;
  final int documentCount;
  final DateTime createdAt;

  const Collection({
    required this.id,
    required this.name,
    this.documentCount = 0,
    required this.createdAt,
  });
}

class HardwareScanResult {
  final GpuInfo? gpu;
  final int ramMb;
  final DiskInfo disk;
  final String cpuName;
  final int cpuCores;
  final String hwFingerprint;

  const HardwareScanResult({
    this.gpu,
    required this.ramMb,
    required this.disk,
    required this.cpuName,
    required this.cpuCores,
    required this.hwFingerprint,
  });
}

class GpuInfo {
  final String name;
  final int vramMb;
  final bool detected;

  const GpuInfo({required this.name, required this.vramMb, required this.detected});
}

class DiskInfo {
  final String type;
  final double readMbps;

  const DiskInfo({required this.type, required this.readMbps});
}

class PerformanceSnapshot {
  final SpeedRating speedRating;
  final String explanation;
  final String? suggestion;
  final int ttftMs;
  final double tokPerS;
  final int ramUsedMb;
  final int ramTotalMb;
  final int? vramUsedMb;
  final int? vramTotalMb;

  const PerformanceSnapshot({
    required this.speedRating,
    required this.explanation,
    this.suggestion,
    required this.ttftMs,
    required this.tokPerS,
    required this.ramUsedMb,
    required this.ramTotalMb,
    this.vramUsedMb,
    this.vramTotalMb,
  });
}

class TraceStep {
  final String id;
  final String type;
  final String description;
  final String result;
  final int durationMs;

  const TraceStep({
    required this.id,
    required this.type,
    required this.description,
    required this.result,
    required this.durationMs,
  });
}

class Citation {
  final String documentId;
  final String filename;
  final int chunkIndex;
  final String snippet;
  final double relevanceScore;

  const Citation({
    required this.documentId,
    required this.filename,
    required this.chunkIndex,
    required this.snippet,
    this.relevanceScore = 0,
  });
}

// ── Training / Adapters ──

class Adapter {
  final String id;
  final String name;
  final String baseModelId;
  final TrainingSourceType sourceType;
  final String? sourceRef;
  final int diskBytes;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final bool isActive;

  const Adapter({
    required this.id,
    required this.name,
    required this.baseModelId,
    required this.sourceType,
    this.sourceRef,
    this.diskBytes = 0,
    required this.createdAt,
    this.lastUsedAt,
    this.isActive = false,
  });
}

class TrainingRun {
  final String id;
  final String? adapterId;
  final TrainingRunStatus status;
  final double progressPercent;
  final int? etaSeconds;
  final String? errorMessage;
  final DateTime startedAt;
  final DateTime? completedAt;

  const TrainingRun({
    required this.id,
    this.adapterId,
    required this.status,
    this.progressPercent = 0,
    this.etaSeconds,
    this.errorMessage,
    required this.startedAt,
    this.completedAt,
  });
}

class SuggestedExtractPrompt {
  final String id;
  final String label;
  final String prompt;

  const SuggestedExtractPrompt({
    required this.id,
    required this.label,
    required this.prompt,
  });

  static const List<SuggestedExtractPrompt> defaults = [
    SuggestedExtractPrompt(
      id: 'prompt-qa',
      label: 'Q&A pairs',
      prompt:
          'Extract every question and a short answer from this document. Format each as:\nQ: [question]\nA: [answer]\n\nUse plain text, one Q/A pair per block.',
    ),
    SuggestedExtractPrompt(
      id: 'prompt-facts',
      label: 'Key facts',
      prompt:
          'List key facts and definitions from this text. One fact or definition per line. Use clear, concise language.',
    ),
    SuggestedExtractPrompt(
      id: 'prompt-summaries',
      label: 'Section summaries',
      prompt:
          'Summarize each section or major topic in 1–2 sentences. List them in order. Format: "Section/topic: summary."',
    ),
    SuggestedExtractPrompt(
      id: 'prompt-glossary',
      label: 'Terms & definitions',
      prompt:
          'Extract important terms, jargon, or acronyms and their definitions from this document. Format: Term: definition.',
    ),
  ];
}
