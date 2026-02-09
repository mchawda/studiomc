"""Inference Router — routes requests to the best available backend.

Supported backends (in priority order):
    1. Ollama       (localhost:11434)  — preferred local runtime
    2. LM Studio    (localhost:1234)   — preferred local runtime
    3. Studiomc     (built-in)        — Studiomc's own out-of-core engine
    4. Frontier API (cloud, optional) — OpenAI / Anthropic / any OpenAI-compatible

The router auto-detects local backends on startup and merges their model
lists into a single unified catalog for the UI.

Routing rules:
    - Local backends always preferred over cloud
    - If same model is available on multiple backends: Ollama > LM Studio > Studiomc
    - Frontier APIs are only used when the user explicitly selects a cloud model
    - All cloud requests require a user consent flag
"""

from __future__ import annotations

import asyncio
import logging
import sys
from pathlib import Path
from typing import Any, AsyncIterator

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from inference.engine import GenerationMetrics, InferenceEngine
from inference.backends import (
    BackendClient,
    BackendInfo,
    UnifiedModel,
    OllamaClient,
    LMStudioClient,
    StudiomcClient,
    FrontierClient,
)

logger = logging.getLogger("inference.router")


class InferenceRouter:
    """Routes inference requests to the best available backend.

    Usage::

        router = InferenceRouter(engine)
        await router.probe_backends()
        models = await router.list_all_models()
        await router.select_model("ollama/llama3.2:3b")
        async for token, metrics in router.generate_stream(messages):
            ...

    The router satisfies the ``StreamGenerator`` protocol from
    ``inference.streaming``, so it can be passed directly to SSE and
    WebSocket helpers.
    """

    # Backend priority order (first online backend with the model wins).
    # Local backends always come before cloud.
    BACKEND_PRIORITY = ["ollama", "lmstudio", "studiomc"]

    def __init__(self, engine: InferenceEngine) -> None:
        self._engine = engine
        self._backends: dict[str, BackendClient] = {}
        self._frontier_backends: dict[str, FrontierClient] = {}
        self._backend_info: dict[str, BackendInfo] = {}
        self._active_backend: BackendClient | None = None
        self._active_backend_name: str | None = None
        self._active_model_id: str | None = None       # unified id (e.g. "ollama/llama3.2:3b")
        self._active_backend_model_id: str | None = None  # backend-native id (e.g. "llama3.2:3b")
        self._lock = asyncio.Lock()

        # Always register the built-in backends
        self._backends["ollama"] = OllamaClient()
        self._backends["lmstudio"] = LMStudioClient()
        self._backends["studiomc"] = StudiomcClient(engine)

    # ── Properties ────────────────────────────────────────────────────

    @property
    def active_model_id(self) -> str | None:
        """The currently selected unified model id."""
        return self._active_model_id

    @property
    def active_backend_name(self) -> str | None:
        """Name of the active backend (e.g. 'ollama', 'frontier:openai')."""
        return self._active_backend_name

    @property
    def is_ready(self) -> bool:
        """True if a model is selected and the backend is ready."""
        return (
            self._active_backend is not None
            and self._active_model_id is not None
        )

    @property
    def engine(self) -> InferenceEngine:
        """Access the underlying Studiomc engine."""
        return self._engine

    # ── Frontier management ───────────────────────────────────────────

    def add_frontier_backend(
        self,
        name: str,
        base_url: str,
        api_key: str,
        models: list[str] | None = None,
    ) -> None:
        """Register a frontier (cloud) backend.

        Args:
            name:     Provider name (e.g. "openai", "anthropic").
            base_url: API base URL (e.g. "https://api.openai.com").
            api_key:  Bearer token.
            models:   Optional static model list (skip /v1/models probe).
        """
        client = FrontierClient(
            base_url=base_url,
            api_key=api_key,
            provider_name=name,
            models_override=models,
        )
        key = f"frontier:{name}"
        self._backends[key] = client
        self._frontier_backends[name] = client
        logger.info("Registered frontier backend: %s (%s)", name, base_url)

    def remove_frontier_backend(self, name: str) -> bool:
        """Unregister a frontier backend. Returns True if it was found."""
        key = f"frontier:{name}"
        client = self._backends.pop(key, None)
        self._frontier_backends.pop(name, None)
        self._backend_info.pop(key, None)
        if client is not None:
            logger.info("Removed frontier backend: %s", name)
            return True
        return False

    # ── Probing ───────────────────────────────────────────────────────

    async def probe_backends(self) -> dict[str, BackendInfo]:
        """Scan all registered backends for availability.

        Probes are run concurrently. Results are cached in
        ``_backend_info`` for subsequent calls to
        ``get_backend_status()``.

        Returns:
            Dict of backend_name -> BackendInfo.
        """
        async with self._lock:
            tasks = {
                name: asyncio.create_task(client.probe())
                for name, client in self._backends.items()
            }
            results: dict[str, BackendInfo] = {}
            for name, task in tasks.items():
                try:
                    results[name] = await task
                except Exception as e:
                    results[name] = BackendInfo(
                        name=name, online=False, error=str(e)
                    )
            self._backend_info = results

            online = [n for n, i in results.items() if i.online]
            logger.info(
                "Backend probe complete — online: %s",
                ", ".join(online) if online else "(none)",
            )
            return results

    def get_backend_status(self) -> dict[str, BackendInfo]:
        """Return the last-probed backend status (no network calls)."""
        return dict(self._backend_info)

    # ── Model listing ─────────────────────────────────────────────────

    async def list_all_models(self) -> list[UnifiedModel]:
        """Merged model list from all online backends.

        Models are fetched concurrently from each online backend and
        combined into a single list. Each model carries its backend
        badge (e.g. ``backend="ollama"``).
        """
        all_models: list[UnifiedModel] = []

        tasks = {
            name: asyncio.create_task(client.list_models())
            for name, client in self._backends.items()
            if self._backend_info.get(name, BackendInfo(name=name)).online
        }

        for name, task in tasks.items():
            try:
                models = await task
                all_models.extend(models)
            except Exception as e:
                logger.warning("Failed to list models from %s: %s", name, e)

        return all_models

    # ── Model selection ───────────────────────────────────────────────

    async def select_model(
        self,
        model_id: str,
        backend: str | None = None,
    ) -> dict[str, str]:
        """Set the active model and backend for inference.

        Args:
            model_id: Unified model id (e.g. ``"ollama/llama3.2:3b"``) or a
                      bare model id that will be searched across backends.
            backend:  Force a specific backend name. If ``None``, the router
                      auto-selects based on priority (Ollama > LM Studio >
                      Studiomc > Frontier).

        Returns:
            ``{"model_id": ..., "backend": ..., "backend_model_id": ...}``
        """
        async with self._lock:
            # Parse the model_id to determine backend from prefix
            resolved_backend: str | None = backend
            backend_model_id = model_id

            if "/" in model_id and not backend:
                prefix, _, rest = model_id.partition("/")
                if prefix in self._backends or prefix.startswith("frontier:"):
                    resolved_backend = prefix
                    backend_model_id = rest

            # If backend is specified, use it directly
            if resolved_backend and resolved_backend in self._backends:
                client = self._backends[resolved_backend]
                self._active_backend = client
                self._active_backend_name = resolved_backend
                self._active_model_id = model_id
                self._active_backend_model_id = backend_model_id

                # For Studiomc, we need to load the model into the engine
                if resolved_backend == "studiomc" and isinstance(
                    client, StudiomcClient
                ):
                    await client.load_model(backend_model_id, backend_model_id)

                logger.info(
                    "Selected model %s on backend %s",
                    backend_model_id,
                    resolved_backend,
                )
                return {
                    "model_id": model_id,
                    "backend": resolved_backend,
                    "backend_model_id": backend_model_id,
                }

            # Auto-select: search local backends in priority order
            for bname in self.BACKEND_PRIORITY:
                if bname not in self._backends:
                    continue
                info = self._backend_info.get(bname)
                if not info or not info.online:
                    continue

                client = self._backends[bname]
                try:
                    models = await client.list_models()
                    for m in models:
                        if (
                            m.backend_model_id == model_id
                            or m.id == model_id
                            or m.name == model_id
                        ):
                            self._active_backend = client
                            self._active_backend_name = bname
                            self._active_model_id = m.id
                            self._active_backend_model_id = m.backend_model_id
                            logger.info(
                                "Auto-selected model %s on backend %s",
                                m.backend_model_id,
                                bname,
                            )
                            return {
                                "model_id": m.id,
                                "backend": bname,
                                "backend_model_id": m.backend_model_id,
                            }
                except Exception as e:
                    logger.debug("Error searching %s: %s", bname, e)

            # Check frontier backends (cloud — lowest priority)
            for key, client in self._backends.items():
                if not key.startswith("frontier:"):
                    continue
                info = self._backend_info.get(key)
                if not info or not info.online:
                    continue
                try:
                    models = await client.list_models()
                    for m in models:
                        if (
                            m.backend_model_id == model_id
                            or m.id == model_id
                            or m.name == model_id
                        ):
                            self._active_backend = client
                            self._active_backend_name = key
                            self._active_model_id = m.id
                            self._active_backend_model_id = m.backend_model_id
                            return {
                                "model_id": m.id,
                                "backend": key,
                                "backend_model_id": m.backend_model_id,
                            }
                except Exception:
                    pass

            # Fallback: use Studiomc engine (always-on)
            studiomc_client = self._backends.get("studiomc")
            if isinstance(studiomc_client, StudiomcClient):
                self._active_backend = studiomc_client
                self._active_backend_name = "studiomc"
                self._active_model_id = f"studiomc/{model_id}"
                self._active_backend_model_id = model_id
                await studiomc_client.load_model(model_id, model_id)
                logger.info(
                    "Falling back to Studiomc engine for model %s", model_id
                )
                return {
                    "model_id": f"studiomc/{model_id}",
                    "backend": "studiomc",
                    "backend_model_id": model_id,
                }

    # ── Generation (streaming) ────────────────────────────────────────

    async def generate_stream(
        self,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Route streaming generation to the active backend.

        Satisfies the ``StreamGenerator`` protocol, so this router can
        be passed directly to ``sse_generate()`` and
        ``websocket_stream_handler()``.

        Yields:
            ``(token, None)`` for each token, then ``("", metrics)`` at
            the end with the completed ``GenerationMetrics``.
        """
        if not self._active_backend or not self._active_backend_model_id:
            raise RuntimeError(
                "No model selected. Call select_model() first."
            )

        async for token, m in self._active_backend.generate_stream(
            self._active_backend_model_id, messages, **kwargs
        ):
            yield token, m

    # ── Generation (non-streaming) ────────────────────────────────────

    async def generate(
        self,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> tuple[str, GenerationMetrics]:
        """Route non-streaming generation to the active backend.

        Returns:
            ``(text, metrics)`` tuple.
        """
        if not self._active_backend or not self._active_backend_model_id:
            raise RuntimeError(
                "No model selected. Call select_model() first."
            )

        return await self._active_backend.generate(
            self._active_backend_model_id, messages, **kwargs
        )

    # ── Lifecycle ─────────────────────────────────────────────────────

    async def close(self) -> None:
        """Shut down all backend clients and release resources."""
        for name, client in self._backends.items():
            try:
                await client.close()
            except Exception as e:
                logger.debug("Error closing %s: %s", name, e)
        self._backends.clear()
        self._active_backend = None
        self._active_model_id = None
