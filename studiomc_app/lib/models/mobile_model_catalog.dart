// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

/// Curated catalog of small GGUF models suitable for mobile devices.
/// All models are hosted on HuggingFace and require no authentication.
class MobileModelCatalog {
  MobileModelCatalog._();

  static const models = <CatalogModel>[
    CatalogModel(
      id: 'qwen2-0.5b',
      name: 'Qwen2 0.5B',
      description: 'Ultra-lightweight. Instant responses on any phone.',
      filename: 'qwen2-0_5b-instruct-q4_k_m.gguf',
      downloadUrl:
          'https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF/resolve/main/qwen2-0_5b-instruct-q4_k_m.gguf',
      sizeBytes: 400 * 1024 * 1024, // ~400 MB
      parameterCount: '0.5B',
      quantization: 'Q4_K_M',
      minRamMb: 2048,
      recommended: true,
    ),
    CatalogModel(
      id: 'llama-3.2-1b',
      name: 'Llama 3.2 1B',
      description: 'Fast and capable. Great for everyday tasks.',
      filename: 'llama-3.2-1b-instruct-q4_k_m.gguf',
      downloadUrl:
          'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      sizeBytes: 800 * 1024 * 1024, // ~800 MB
      parameterCount: '1B',
      quantization: 'Q4_K_M',
      minRamMb: 3072,
      recommended: false,
    ),
    CatalogModel(
      id: 'llama-3.2-3b',
      name: 'Llama 3.2 3B',
      description: 'Best quality for mobile. Needs 6GB+ RAM.',
      filename: 'llama-3.2-3b-instruct-q4_k_m.gguf',
      downloadUrl:
          'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf',
      sizeBytes: 2000 * 1024 * 1024, // ~2.0 GB
      parameterCount: '3B',
      quantization: 'Q4_K_M',
      minRamMb: 6144,
      recommended: false,
    ),
  ];
}

class CatalogModel {
  final String id;
  final String name;
  final String description;
  final String filename;
  final String downloadUrl;
  final int sizeBytes;
  final String parameterCount;
  final String quantization;
  final int minRamMb;
  final bool recommended;

  const CatalogModel({
    required this.id,
    required this.name,
    required this.description,
    required this.filename,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.parameterCount,
    required this.quantization,
    required this.minRamMb,
    required this.recommended,
  });

  String get sizeLabel {
    if (sizeBytes > 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}
