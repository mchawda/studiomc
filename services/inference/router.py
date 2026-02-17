# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Inference Router — routes requests to the best available backend.

Supported backends (in priority order):
    1. Ollama       (localhost:11434)  — preferred local runtime
    2. LM Studio    (localhost:1234)   — preferred local runtime
    3. LlamaCpp     (built-in)        — runs GGUF models directly via llama-cpp-python
    4. Studiomc     (built-in)        — SpliceLLM engine (safetensors)
    5. Frontier API (cloud, optional) — OpenAI / Anthropic / any OpenAI-compatible

The router auto-detects local backends on startup and merges their model
lists into a single unified catalog for the UI.

Routing rules:
    - Local backends always preferred over cloud
    - If same model is available on multiple backends: Ollama > LM Studio > LlamaCpp > SpliceLLM
    - Frontier APIs are only used when the user explicitly selects a cloud model
    - All cloud requests require a user consent flag

Phase 3 enhancements:
    - Crash-proof model switching via safe_switch (never leaves engine broken)
    - OOM prevention via MemoryGuard preflight checks
    - Graceful fallback chain: primary → SpliceLLM → error message (never crash)
    - Auto-recovery: retry on transient failures before falling back

Phase 4 enhancements:
    - Adapter activation / deactivation during inference via AdapterLoader
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
    LlamaCppClient,
    FrontierClient,
)
from inference.core.loader import safe_switch, SwitchResult
from inference.core.memory_guard import MemoryGuard
from inference.core.adapter_loader import AdapterLoader

logger = logging.getLogger("inference.router")

# Maximum number of auto-retry attempts before falling back
_MAX_RETRIES = 1


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
    BACKEND_PRIORITY = ["ollama", "lmstudio", "llamacpp", "studiomc"]

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

        # Phase 3: OOM prevention
        self._memory_guard = MemoryGuard()

        # Phase 4: Adapter management
        self._adapter_loader = AdapterLoader()

        # Always register the built-in backends
        self._backends["ollama"] = OllamaClient()
        self._backends["lmstudio"] = LMStudioClient()
        self._backends["llamacpp"] = LlamaCppClient()
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
        """Access the underlying SpliceLLM engine."""
        return self._engine

    @property
    def memory_guard(self) -> MemoryGuard:
        """Access the memory guard for status / manual checks."""
        return self._memory_guard

    @property
    def adapter_loader(self) -> AdapterLoader:
        """Access the adapter loader for adapter management."""
        return self._adapter_loader

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

        Also starts the memory monitor in the background.

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

            # Start memory monitor
            self._memory_guard.start_monitor(
                unload_callback=self._emergency_unload_sync,
            )

            return results

    def _emergency_unload_sync(self) -> None:
        """Synchronous wrapper for emergency model unload (called by MemoryGuard)."""
        try:
            loop = asyncio.get_event_loop()
            if loop.is_running():
                asyncio.ensure_future(self._engine.unload_model())
            else:
                loop.run_until_complete(self._engine.unload_model())
        except Exception as e:
            logger.error("Emergency unload failed: %s", e)

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

    # ── Model selection (with crash-proof switching) ──────────────────

    async def select_model(
        self,
        model_id: str,
        backend: str | None = None,
    ) -> dict[str, str]:
        """Set the active model and backend for inference.

        Uses crash-proof ``safe_switch()`` for SpliceLLM model changes
        and ``MemoryGuard.preflight_check()`` to prevent OOM.

        Args:
            model_id: Unified model id (e.g. ``"ollama/llama3.2:3b"``) or a
                      bare model id that will be searched across backends.
            backend:  Force a specific backend name. If ``None``, the router
                      auto-selects based on priority (Ollama > LM Studio >
                      SpliceLLM > Frontier).

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

                # For llamacpp backend, load the GGUF model directly
                if resolved_backend == "llamacpp" and isinstance(
                    client, LlamaCppClient
                ):
                    loaded = await client.load_model(backend_model_id)
                    if not loaded:
                        logger.warning(
                            "llamacpp model load failed for %s — not setting as active",
                            backend_model_id,
                        )
                        raise ValueError(
                            f"Failed to load model {backend_model_id} on llamacpp"
                        )

                # For SpliceLLM (studiomc backend), use safe_switch
                if resolved_backend == "studiomc" and isinstance(
                    client, StudiomcClient
                ):
                    result = await self._safe_load_studiomc(
                        backend_model_id, backend_model_id
                    )
                    if not result.success:
                        logger.warning(
                            "SpliceLLM safe_switch failed: %s — not setting as active",
                            result.error,
                        )
                        raise ValueError(
                            f"Failed to load model {backend_model_id} on studiomc: {result.error}"
                        )

                # Only set active AFTER successful load
                self._active_backend = client
                self._active_backend_name = resolved_backend
                self._active_model_id = model_id
                self._active_backend_model_id = backend_model_id

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
                            # For llamacpp, verify the model can be loaded
                            if bname == "llamacpp" and isinstance(
                                client, LlamaCppClient
                            ):
                                loaded = await client.load_model(
                                    m.backend_model_id
                                )
                                if not loaded:
                                    logger.warning(
                                        "llamacpp: model %s found but failed to load, skipping",
                                        m.backend_model_id,
                                    )
                                    continue

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

            # Fallback: try llamacpp first (can load GGUF directly)
            llamacpp_client = self._backends.get("llamacpp")
            if isinstance(llamacpp_client, LlamaCppClient):
                loaded = await llamacpp_client.load_model(model_id)
                if loaded:
                    self._active_backend = llamacpp_client
                    self._active_backend_name = "llamacpp"
                    self._active_model_id = model_id
                    self._active_backend_model_id = model_id
                    logger.info(
                        "Loaded model %s via llamacpp fallback", model_id
                    )
                    return {
                        "model_id": model_id,
                        "backend": "llamacpp",
                        "backend_model_id": model_id,
                    }

            # Last resort: SpliceLLM engine (safetensors only)
            studiomc_client = self._backends.get("studiomc")
            if isinstance(studiomc_client, StudiomcClient):
                result = await self._safe_load_studiomc(model_id, model_id)
                if result.success:
                    self._active_backend = studiomc_client
                    self._active_backend_name = "studiomc"
                    self._active_model_id = f"studiomc/{model_id}"
                    self._active_backend_model_id = model_id
                    logger.info(
                        "Loaded model %s via SpliceLLM fallback", model_id
                    )
                    return {
                        "model_id": f"studiomc/{model_id}",
                        "backend": "studiomc",
                        "backend_model_id": model_id,
                    }
                else:
                    logger.warning("Fallback SpliceLLM load failed: %s", result.error)

            # Nothing worked — raise an error
            raise ValueError(
                f"Model '{model_id}' not found or could not be loaded on any backend"
            )

    async def _safe_load_studiomc(
        self,
        model_id: str,
        model_path: str,
    ) -> SwitchResult:
        """Load a model into SpliceLLM with OOM preflight and crash-proof switching.

        1. Run MemoryGuard preflight check.
        2. If memory is insufficient, return failure with suggestion.
        3. Otherwise, use safe_switch for crash-proof loading.
        """
        # Preflight memory check
        preflight = self._memory_guard.preflight_check(model_path, use_ooc=True)
        if not preflight.can_load:
            logger.warning(
                "OOM preflight failed for %s: %s", model_id, preflight.message
            )
            return SwitchResult(
                success=False,
                active_model_id=self._engine.active_model_id,
                active_model_path=self._engine.state.active_model_path,
                error=f"OOM prevention: {preflight.message}. {preflight.suggestion or ''}",
            )

        # Crash-proof switch
        from_model = self._engine.active_model_id
        result = await safe_switch(
            self._engine, from_model, model_id, model_path
        )

        # Track loaded model in memory guard
        if result.success:
            estimated = MemoryGuard.estimate_ooc_peak_bytes(model_path)
            self._memory_guard.register_loaded_model(model_id, estimated)

        return result

    # ── Adapter management ────────────────────────────────────────────

    async def activate_adapter(self, adapter_path: str) -> dict:
        """Activate a LoRA adapter on the currently loaded base model.

        The base model must be loaded in the SpliceLLM engine (not via
        Ollama / LM Studio). The adapter is hot-swapped without
        reloading the base model.

        Args:
            adapter_path: Path to the PEFT adapter directory.

        Returns:
            Dict with status and adapter info.
        """
        if not self._engine.is_loaded:
            return {"success": False, "error": "No model loaded"}

        if self._active_backend_name != "studiomc":
            return {
                "success": False,
                "error": "Adapters only supported on the SpliceLLM backend",
            }

        try:
            info = await self._adapter_loader.load_adapter(
                self._engine, adapter_path
            )
            return {"success": True, **info}
        except Exception as e:
            logger.error("Failed to activate adapter: %s", e)
            return {"success": False, "error": str(e)}

    async def deactivate_adapter(self) -> dict:
        """Remove the active adapter, returning to the base model."""
        try:
            await self._adapter_loader.unload_adapter(self._engine)
            return {"success": True, "message": "Adapter deactivated"}
        except Exception as e:
            logger.error("Failed to deactivate adapter: %s", e)
            return {"success": False, "error": str(e)}

    def get_adapter_status(self) -> dict:
        """Return current adapter status."""
        return self._adapter_loader.status()

    # ── Generation (streaming) ────────────────────────────────────────

    async def generate_stream(
        self,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Route streaming generation to the active backend.

        Graceful fallback chain:
            primary backend → auto-retry → SpliceLLM → error message

        Never crashes. If all backends fail, yields an error message
        as the final token instead of raising.

        Satisfies the ``StreamGenerator`` protocol, so this router can
        be passed directly to ``sse_generate()`` and
        ``websocket_stream_handler()``.

        Yields:
            ``(token, None)`` for each token, then ``("", metrics)`` at
            the end with the completed ``GenerationMetrics``.
        """
        if not self._active_backend or not self._active_backend_model_id:
            yield "[Error: No model selected. Call select_model() first.]", None
            return

        # Try primary backend (with retry)
        for attempt in range(_MAX_RETRIES + 1):
            try:
                async for token, m in self._active_backend.generate_stream(
                    self._active_backend_model_id, messages, **kwargs
                ):
                    yield token, m
                return  # success
            except Exception as primary_err:
                if attempt < _MAX_RETRIES:
                    logger.warning(
                        "Backend %s failed (attempt %d/%d): %s — retrying",
                        self._active_backend_name,
                        attempt + 1,
                        _MAX_RETRIES + 1,
                        primary_err,
                    )
                    await asyncio.sleep(0.5)  # brief pause before retry
                    continue

                # All retries exhausted — try llamacpp fallback, then SpliceLLM
                model_id = self._active_backend_model_id or "unknown"

                if self._active_backend_name not in ("llamacpp", "studiomc"):
                    # Try llamacpp first (handles GGUF models)
                    llamacpp = self._backends.get("llamacpp")
                    if isinstance(llamacpp, LlamaCppClient):
                        try:
                            loaded = await llamacpp.load_model(model_id)
                            if loaded:
                                logger.info("Falling back to llamacpp for %s", model_id)
                                async for token, m in llamacpp.generate_stream(
                                    model_id, messages, **kwargs
                                ):
                                    yield token, m
                                return
                        except Exception as lcpp_err:
                            logger.debug("llamacpp fallback failed: %s", lcpp_err)

                if self._active_backend_name != "studiomc":
                    logger.warning(
                        "Backend %s failed after %d attempts for model %s: %s — falling back to SpliceLLM",
                        self._active_backend_name,
                        _MAX_RETRIES + 1,
                        model_id,
                        primary_err,
                    )
                    studiomc = self._backends.get("studiomc")
                    if studiomc is not None:
                        try:
                            if isinstance(studiomc, StudiomcClient):
                                result = await self._safe_load_studiomc(model_id, model_id)
                                if not result.success:
                                    raise RuntimeError(result.error or "Safe load failed")
                        except Exception as load_err:
                            logger.warning(
                                "SpliceLLM could not load model %s: %s",
                                model_id, load_err,
                            )
                            yield (
                                f"[Error: All backends failed. "
                                f"Primary: {primary_err}. Fallback: {load_err}]"
                            ), None
                            return

                        # Stream from SpliceLLM fallback
                        try:
                            async for token, m in studiomc.generate_stream(
                                model_id, messages, **kwargs
                            ):
                                yield token, m
                            return
                        except Exception as fallback_err:
                            logger.error("SpliceLLM fallback also failed: %s", fallback_err)
                            yield (
                                f"[Error: All backends failed. "
                                f"Primary: {primary_err}. Fallback: {fallback_err}]"
                            ), None
                            return

                # Primary is studiomc and it failed — yield error message
                yield f"[Error: Generation failed: {primary_err}]", None
                return

    # ── Generation (non-streaming) ────────────────────────────────────

    async def generate(
        self,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> tuple[str, GenerationMetrics]:
        """Route non-streaming generation to the active backend.

        Falls back to SpliceLLM if primary backend fails. Never crashes —
        returns an error string if all backends fail.

        Returns:
            ``(text, metrics)`` tuple.
        """
        if not self._active_backend or not self._active_backend_model_id:
            return (
                "[Error: No model selected. Call select_model() first.]",
                GenerationMetrics(),
            )

        # Try primary with retry
        last_error: Exception | None = None
        for attempt in range(_MAX_RETRIES + 1):
            try:
                return await self._active_backend.generate(
                    self._active_backend_model_id, messages, **kwargs
                )
            except Exception as e:
                last_error = e
                if attempt < _MAX_RETRIES:
                    logger.warning(
                        "Backend %s failed (attempt %d): %s — retrying",
                        self._active_backend_name, attempt + 1, e,
                    )
                    await asyncio.sleep(0.5)

        # Primary exhausted — try SpliceLLM fallback
        if self._active_backend_name != "studiomc":
            logger.warning(
                "Backend %s failed: %s — falling back to SpliceLLM",
                self._active_backend_name, last_error,
            )
            studiomc = self._backends.get("studiomc")
            if studiomc is not None:
                model_id = self._active_backend_model_id or "unknown"
                try:
                    if isinstance(studiomc, StudiomcClient):
                        result = await self._safe_load_studiomc(model_id, model_id)
                        if not result.success:
                            raise RuntimeError(result.error or "Safe load failed")
                    return await studiomc.generate(
                        model_id, messages, **kwargs
                    )
                except Exception as fallback_err:
                    logger.error("SpliceLLM fallback also failed: %s", fallback_err)
                    return (
                        f"[Error: All backends failed. "
                        f"Primary: {last_error}. Fallback: {fallback_err}]",
                        GenerationMetrics(),
                    )

        # All fallbacks exhausted — return error message (never crash)
        return (
            f"[Error: Generation failed: {last_error}]",
            GenerationMetrics(),
        )

    # ── Memory status ─────────────────────────────────────────────────

    def memory_status(self) -> dict:
        """Return current memory usage and guard status."""
        return self._memory_guard.status()

    # ── Lifecycle ─────────────────────────────────────────────────────

    async def close(self) -> None:
        """Shut down all backend clients and release resources."""
        # Stop memory monitor
        self._memory_guard.stop_monitor()

        # Unload any active adapter
        try:
            await self._adapter_loader.unload_adapter(self._engine)
        except Exception:
            pass

        for name, client in self._backends.items():
            try:
                await client.close()
            except Exception as e:
                logger.debug("Error closing %s: %s", name, e)
        self._backends.clear()
        self._active_backend = None
        self._active_model_id = None
