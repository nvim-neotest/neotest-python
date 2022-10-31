import abc
from enum import Enum
from typing import TYPE_CHECKING, Callable, Dict, List, Optional


class NeotestResultStatus(str, Enum):
    SKIPPED = "skipped"
    PASSED = "passed"
    FAILED = "failed"

    def __gt__(self, other) -> bool:
        members = list(self.__class__.__members__.values())
        return members.index(self) > members.index(other)


if TYPE_CHECKING:
    from typing import TypedDict

    class NeotestError(TypedDict):
        message: str
        line: Optional[int]

    class NeotestResult(TypedDict):
        short: Optional[str]
        status: NeotestResultStatus
        errors: Optional[List[NeotestError]]

else:
    NeotestError = Dict
    NeotestResult = Dict


class NeotestAdapter(abc.ABC):
    def update_result(
        self, base: Optional[NeotestResult], update: NeotestResult
    ) -> NeotestResult:
        if not base:
            return update
        return {
            "status": max(base["status"], update["status"]),
            "errors": (base.get("errors") or []) + (update.get("errors") or []) or None,
            "short": (base.get("short") or "") + (update.get("short") or ""),
        }

    @abc.abstractmethod
    def run(self, args: List[str], stream: Callable):
        del args, stream
        raise NotImplementedError
