from io import StringIO
from pathlib import Path
from typing import TYPE_CHECKING, Callable, Dict, List, Optional

from .base import NeotestAdapter, NeotestError, NeotestResult, NeotestResultStatus

if TYPE_CHECKING:
    from _pytest.config import Config
    from _pytest.reports import TestReport


class PytestNeotestAdapter(NeotestAdapter):
    def run(
        self,
        args: List[str],
        stream: Callable[[str, NeotestResult], None],
    ) -> Dict[str, NeotestResult]:
        import pytest

        result_collector = NeotestResultCollector(self, stream=stream)
        pytest.main(args=args, plugins=[result_collector])
        return result_collector.results


class NeotestResultCollector:
    def __init__(
        self,
        adapter: PytestNeotestAdapter,
        stream: Callable[[str, NeotestResult], None],
    ):
        self.stream = stream
        self.adapter = adapter

        self.pytest_config: "Config" = None  # type: ignore
        self.results: Dict[str, NeotestResult] = {}

    def _get_short_output(
        self, config: "Config", report: "TestReport"
    ) -> Optional[str]:
        from _pytest.terminal import TerminalReporter

        buffer = StringIO()
        # Hack to get pytest to write ANSI codes
        setattr(buffer, "isatty", lambda: True)
        reporter = TerminalReporter(config, buffer)

        # Taked from `_pytest.terminal.TerminalReporter
        msg = reporter._getfailureheadline(report)
        if report.outcome == NeotestResultStatus.FAILED:
            reporter.write_sep("_", msg, red=True, bold=True)
        elif report.outcome == NeotestResultStatus.SKIPPED:
            reporter.write_sep("_", msg, cyan=True, bold=True)
        else:
            reporter.write_sep("_", msg, green=True, bold=True)
        reporter._outrep_summary(report)
        reporter.print_teardown_sections(report)

        buffer.seek(0)
        return buffer.read()

    def pytest_deselected(self, items: List["pytest.Item"]):
        for report in items:
            file_path, *name_path = report.nodeid.split("::")
            abs_path = str(Path(self.pytest_config.rootdir, file_path))
            *namespaces, test_name = name_path
            valid_test_name, *params = test_name.split("[")  # ]
            pos_id = "::".join([abs_path, *(namespaces), valid_test_name])
            result = self.adapter.update_result(
                self.results.get(pos_id),
                {
                    "short": None,
                    "status": NeotestResultStatus.SKIPPED,
                    "errors": [],
                },
            )
            if not params:
                self.stream(pos_id, result)
            self.results[pos_id] = result

    def pytest_cmdline_main(self, config: "Config"):
        self.pytest_config = config

    def pytest_runtest_logreport(self, report: "TestReport"):
        if report.when != "call" and not (
            report.outcome == "skipped" and report.when == "setup"
        ):
            return

        file_path, *name_path = report.nodeid.split("::")
        abs_path = str(Path(self.pytest_config.rootdir, file_path))
        *namespaces, test_name = name_path
        valid_test_name, *params = test_name.split("[")  # ]
        pos_id = "::".join([abs_path, *namespaces, valid_test_name])

        errors: List[NeotestError] = []
        short = self._get_short_output(self.pytest_config, report)

        if report.outcome == "failed":
            from _pytest._code.code import ExceptionChainRepr

            exc_repr = report.longrepr
            # Test fails due to condition outside of test e.g. xfail
            if isinstance(exc_repr, str):
                errors.append({"message": exc_repr, "line": None})
            # Test failed internally
            elif isinstance(exc_repr, ExceptionChainRepr):
                reprtraceback = exc_repr.reprtraceback
                error_message = exc_repr.reprcrash.message  # type: ignore
                error_line = None
                for repr in reversed(reprtraceback.reprentries):
                    if (
                        hasattr(repr, "reprfileloc")
                        and repr.reprfileloc.path == file_path
                    ):
                        error_line = repr.reprfileloc.lineno - 1
                errors.append({"message": error_message, "line": error_line})
            else:
                # TODO: Figure out how these are returned and how to represent
                raise Exception(
                    "Unhandled error type, please report to neotest-python repo"
                )
        result: NeotestResult = self.adapter.update_result(
            self.results.get(pos_id),
            {
                "short": short,
                "status": NeotestResultStatus(report.outcome),
                "errors": errors,
            },
        )
        if not params:
            self.stream(pos_id, result)
        self.results[pos_id] = result
