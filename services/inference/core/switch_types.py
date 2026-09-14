# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Pure dataclasses returned by ``inference.core.loader.safe_switch``.

Lives in its own module so the Core router can import the result type
without dragging in torch (which the actual ``safe_switch`` implementation
needs). See ``SPLIT_BUNDLE.md`` for the Core/Pro contract.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class SwitchResult:
    """Outcome of a ``safe_switch`` operation."""

    success: bool
    active_model_id: str | None
    active_model_path: str | None
    error: str | None = None

    def to_dict(self) -> dict[str, object]:
        return {
            "success": self.success,
            "active_model_id": self.active_model_id,
            "active_model_path": self.active_model_path,
            "error": self.error,
        }
