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


# Backward-compatible alias
AirllmProfile = InferenceProfile


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


class AutopilotResult(BaseModel):
    hw_info: HardwareInfo
    recommended: list[ModelRecommendation]
    bigger_slower: list[ModelRecommendation] = []
