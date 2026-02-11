"""Pydantic models shared across all services.

These mirror the SQLite schema and are used for API request/response validation.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


# ── Enums ──

class ModelSource(str, Enum):
    hf = "hf"
    local = "local"


class ChatMode(str, Enum):
    default = "default"
    writing = "writing"
    coding = "coding"
    tutor = "tutor"


class MessageRole(str, Enum):
    system = "system"
    user = "user"
    assistant = "assistant"
    tool = "tool"


class DocStatus(str, Enum):
    uploaded = "uploaded"
    extracting = "extracting"
    chunking = "chunking"
    indexing = "indexing"
    ready = "ready"
    error = "error"


class ReasoningMode(str, Enum):
    fast = "fast"
    cited = "cited"
    investigate = "investigate"


class SpeedRating(str, Enum):
    fast = "fast"
    ok = "ok"
    slow = "slow"
    painful = "painful"


class InferenceProfile(str, Enum):
    fast = "fast"
    balanced = "balanced"
    quality = "quality"


# Backward-compatible aliases
SpliceLLMProfile = InferenceProfile
AirllmProfile = InferenceProfile  # deprecated: use SpliceLLMProfile


# ── Settings ──

class Setting(BaseModel):
    key: str
    value: str


# ── Models ──

class AIModel(BaseModel):
    id: str
    name: str
    source: ModelSource
    source_ref: str | None = None
    params_billion: float | None = None
    quant: str | None = None
    disk_bytes: int | None = None
    arch: str | None = None
    context_max: int | None = None
    checksum: str | None = None
    manifest_json: str | None = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    last_used_at: datetime | None = None


class ModelDownloadRequest(BaseModel):
    source: ModelSource
    source_ref: str  # HF repo id or local path
    name: str | None = None


class ModelDownloadStatus(BaseModel):
    model_id: str
    progress: float = 0.0  # 0.0 - 1.0
    downloaded_bytes: int = 0
    total_bytes: int = 0
    speed_mbps: float = 0.0
    status: str = "pending"  # pending, downloading, verifying, complete, paused, error
    error: str | None = None


# ── Benchmarks ──

class Benchmark(BaseModel):
    id: str
    model_id: str
    hw_fingerprint: str
    disk_read_mbps: float | None = None
    ttft_ms: int | None = None
    tok_per_s: float | None = None
    notes: str | None = None
    created_at: datetime = Field(default_factory=datetime.utcnow)


# ── Hardware ──

class HardwareInfo(BaseModel):
    gpu_name: str | None = None
    vram_bytes: int | None = None
    ram_bytes: int = 0
    cpu_name: str = ""
    cpu_cores: int = 0
    disk_type: str = "unknown"  # nvme, sata, unknown
    disk_read_mbps: float = 0.0
    hw_fingerprint: str = ""


class SpeedRatingResult(BaseModel):
    rating: SpeedRating
    tok_per_s: float
    ttft_ms: int
    explanation: str  # plain english


# ── Chats ──

class Chat(BaseModel):
    id: str
    title: str | None = None
    model_id: str | None = None
    mode: ChatMode = ChatMode.default
    pinned: bool = False
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class ChatCreate(BaseModel):
    title: str | None = None
    model_id: str | None = None
    mode: ChatMode = ChatMode.default


class ChatUpdate(BaseModel):
    title: str | None = None
    pinned: bool | None = None
    mode: ChatMode | None = None


class Message(BaseModel):
    id: str
    chat_id: str
    role: MessageRole
    content: str
    tokens: int | None = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    parent_message_id: str | None = None


class ChatCompletionRequest(BaseModel):
    """OpenAI-compatible chat completion request."""
    model: str | None = None
    messages: list[dict[str, str]]
    temperature: float = 0.7
    max_tokens: int | None = None
    stream: bool = False
    # Extensions
    x_inference_profile: InferenceProfile = InferenceProfile.balanced
    x_inference_slowmode: bool = False


class ChatCompletionChoice(BaseModel):
    index: int = 0
    message: dict[str, str]
    finish_reason: str = "stop"


class ChatCompletionResponse(BaseModel):
    """OpenAI-compatible chat completion response."""
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: list[ChatCompletionChoice]
    usage: dict[str, int] = {}


# ── Documents ──

class Document(BaseModel):
    id: str
    filename: str
    mime: str | None = None
    bytes: int | None = None
    sha256: str | None = None
    status: DocStatus = DocStatus.uploaded
    error_message: str | None = None
    created_at: datetime = Field(default_factory=datetime.utcnow)


class Collection(BaseModel):
    id: str
    name: str
    created_at: datetime = Field(default_factory=datetime.utcnow)


class DocChunk(BaseModel):
    id: str
    document_id: str
    chunk_index: int
    text: str
    token_count: int | None = None
    metadata_json: str | None = None


# ── CLaRa ──

class ClaraIngestRequest(BaseModel):
    collection_id: str
    document_ids: list[str]


class ClaraIngestStatus(BaseModel):
    job_id: str
    status: str  # pending, processing, complete, error
    progress: float = 0.0
    error: str | None = None


class ClaraQueryRequest(BaseModel):
    collection_id: str
    query: str
    top_k: int = 8
    include_snippets: bool = False


class ClaraQueryResult(BaseModel):
    chunks: list[DocChunk]
    scores: list[float]
    snippets: list[str] | None = None


class Citation(BaseModel):
    document_id: str
    filename: str
    chunk_index: int
    snippet: str
    relevance_score: float


class ClaraAnswerRequest(BaseModel):
    collection_id: str
    query: str
    mode: ReasoningMode = ReasoningMode.cited
    top_k: int = 8


class ClaraAnswerResponse(BaseModel):
    answer: str
    citations: list[Citation]
    groundedness: float  # 0.0 - 1.0
    metrics: dict[str, Any] = {}


# ── Orchestrator / Reasoning ──

class TraceStep(BaseModel):
    tool: str
    input: dict[str, Any]
    output: str
    duration_ms: int


class ReasoningRequest(BaseModel):
    chat_id: str
    user_query: str
    mode: ReasoningMode = ReasoningMode.fast
    budgets: dict[str, Any] | None = None


class ReasoningResponse(BaseModel):
    answer: str
    citations: list[Citation] = []
    groundedness: float = 0.0  # 0.0 – 1.0, fraction of claims supported by citations
    trace: list[TraceStep] = []
    metrics: dict[str, Any] = {}
    stopped_reason: str | None = None  # "budget_exceeded", "no_evidence", etc.


# ── LRE Tools ──

class LRESearchRequest(BaseModel):
    query: str
    scope: str | None = None  # collection_id or folder path


class LREGrepRequest(BaseModel):
    pattern: str
    files: list[str] | None = None


class LREOpenRequest(BaseModel):
    doc_id: str
    span: str | None = None  # "p3-p4" page range


class LRESummarizeRequest(BaseModel):
    doc_id: str
    span: str | None = None


class LRETableExtractRequest(BaseModel):
    doc_id: str
    span: str | None = None


# ── Supervisor ──

class ServiceStatus(BaseModel):
    name: str
    port: int
    status: str  # running, stopped, error
    pid: int | None = None
    uptime_seconds: float | None = None
    error: str | None = None


class SupervisorStatus(BaseModel):
    services: list[ServiceStatus]
    hw_info: HardwareInfo | None = None


class SearchResult(BaseModel):
    """A single search result returned by the global search endpoint."""
    type: str  # "chat" or "document"
    id: str
    title: str  # chat title or filename
    snippet: str  # matching text excerpt
    timestamp: str  # ISO 8601


class SearchResponse(BaseModel):
    """Response from the global search endpoint."""
    query: str
    results: list[SearchResult] = []
    total: int = 0


# ── Autopilot / Recommendation ──

class ModelRecommendation(BaseModel):
    model_id: str
    name: str
    predicted_tok_per_s: float
    predicted_ttft_ms: int
    speed_rating: SpeedRating
    explanation: str  # plain english
    disk_bytes: int = 0
    recommended: bool = True  # True = top pick, False = "bigger slower" list
    recommended_adapter: str | None = None  # adapter ID if a trained adapter boosts this model
    adapter_reason: str | None = None  # e.g. "Personalized for your documents"


class AutopilotResult(BaseModel):
    hw_info: HardwareInfo
    recommended: list[ModelRecommendation]
    bigger_slower: list[ModelRecommendation] = []


# ── Training / Adapters ──

class TrainingSourceType(str, Enum):
    collection = "collection"
    extract_paste = "extract_paste"
    extract_file = "extract_file"


class TrainingRunStatus(str, Enum):
    pending = "pending"
    preparing = "preparing"
    training = "training"
    completed = "completed"
    failed = "failed"


class Adapter(BaseModel):
    id: str
    name: str
    base_model_id: str
    source_type: TrainingSourceType
    source_ref: str | None = None
    disk_bytes: int = 0
    created_at: datetime = Field(default_factory=datetime.utcnow)
    last_used_at: datetime | None = None
    is_active: bool = False


class TrainingRun(BaseModel):
    id: str
    adapter_id: str | None = None
    status: TrainingRunStatus = TrainingRunStatus.pending
    progress_percent: float = 0.0
    eta_seconds: int | None = None
    error_message: str | None = None
    metrics_json: str | None = None
    started_at: datetime = Field(default_factory=datetime.utcnow)
    completed_at: datetime | None = None


class TrainingCreateRequest(BaseModel):
    """Start a new training run."""
    base_model_id: str
    adapter_name: str
    source_type: TrainingSourceType
    source_ref: str | None = None  # collection_id or null for paste
    extract_content: str | None = None  # pasted/uploaded extract text
    goal: str | None = None  # personalization goal (e.g. style_adapter, knowledge_library)
    document_ids: list[str] | None = None  # selected document IDs
    collection_ids: list[str] | None = None  # selected collection IDs


class SuggestedExtractPrompt(BaseModel):
    id: str
    label: str
    prompt: str


# ── Groundedness ──

class GroundednessRequest(BaseModel):
    """Request to evaluate groundedness of an answer against source snippets."""
    answer: str
    snippets: list[str]


class GroundednessResponse(BaseModel):
    """Result of groundedness evaluation."""
    score: float  # 0.0 – 1.0
    supported_count: int
    total_count: int
    unsupported: list[str] = []


# ── CLaRa Training (Phase 3) ──

class ClaraTrainConfig(BaseModel):
    """Configuration for CLaRa compression-aware training."""
    learning_rate: float = 2e-4
    epochs: int = 3
    batch_size: int = 16
    compression_target_ratio: float = 0.3  # target: compress to 30% of original
    contrastive_margin: float = 0.5
    negative_samples: int = 5
    warmup_steps: int = 50
    max_seq_length: int = 512


class ClaraTrainRequest(BaseModel):
    """Start a CLaRa compression training run on a document collection."""
    collection_id: str
    config: ClaraTrainConfig = Field(default_factory=ClaraTrainConfig)
    incremental: bool = False  # if True, add new docs without full retrain


class ClaraTrainStatus(BaseModel):
    """Status of a CLaRa compression training run."""
    run_id: str
    status: str = "pending"  # pending, preparing, training, evaluating, complete, error
    progress: float = 0.0  # 0.0 – 1.0
    current_epoch: int = 0
    total_epochs: int = 0
    metrics: dict[str, Any] = {}
    error: str | None = None


# ── Knowledge Distillation (Phase 4) ──

class DistillConfig(BaseModel):
    """Configuration for knowledge distillation."""
    temperature: float = 3.0
    alpha: float = 0.7  # weight for KL divergence vs cross-entropy
    epochs: int = 3
    batch_size: int = 4
    learning_rate: float = 1e-4
    max_seq_length: int = 512
    lora_rank: int = 8
    lora_alpha: int = 16


class DistillRequest(BaseModel):
    """Start a knowledge distillation run."""
    teacher_model_id: str
    student_model_id: str
    dataset_collection_id: str | None = None  # CLaRa collection for training data
    dataset_text: str | None = None  # or provide raw training text
    config: DistillConfig = Field(default_factory=DistillConfig)
    use_cloud_teacher: bool = False  # if True, use frontier API as teacher
    cloud_consent: bool = False  # explicit consent required for cloud teacher


class DistillStatus(BaseModel):
    """Status of a knowledge distillation run."""
    run_id: str
    status: str = "pending"  # pending, preparing, generating_soft_labels, training, evaluating, complete, error
    progress: float = 0.0  # 0.0 – 1.0
    current_epoch: int = 0
    total_epochs: int = 0
    metrics: dict[str, Any] = {}
    error: str | None = None


# ── Context Distillation (Phase 4) ──

class ContextDistillConfig(BaseModel):
    """Configuration for context distillation."""
    num_qa_pairs_per_doc: int = 10
    compression_ratio: float = 0.3  # target CLaRa compression ratio
    learning_rate: float = 1e-4
    epochs: int = 3
    batch_size: int = 4
    max_seq_length: int = 512
    lora_rank: int = 8
    lora_alpha: int = 16


class ContextDistillRequest(BaseModel):
    """Start a context distillation run."""
    model_id: str
    collection_id: str  # CLaRa collection with documents
    config: ContextDistillConfig = Field(default_factory=ContextDistillConfig)


class ContextDistillStatus(BaseModel):
    """Status of a context distillation run."""
    run_id: str
    status: str = "pending"  # pending, generating_qa, compressing, training, evaluating, complete, error
    progress: float = 0.0  # 0.0 – 1.0
    current_phase: str = ""  # human-readable current phase
    metrics: dict[str, Any] = {}
    error: str | None = None
