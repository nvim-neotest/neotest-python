from io import StringIO
from pathlib import Path
from typing import TYPE_CHECKING, Dict, List, Optional, cast

from .base import NeotestAdapter, NeotestError, NeotestResult, NeotestResultStatus

if TYPE_CHECKING:
    from _pytest._code.code import ExceptionChainRepr
    from _pytest.config import Config
    from _pytest.reports import TestReport


class PytestNeotestAdapter(NeotestAdapter):
    def get_short_output(self, config: "Config", report: "TestReport") -> Optional[str]:
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

    def run(self, args: List[str]) -> Dict[str, NeotestResult]:
        results: Dict[str, NeotestResult] = {}
        pytest_config: "Config"

        class NeotestResultCollector:
            @staticmethod
            def pytest_cmdline_main(config: "Config"):
                nonlocal pytest_config
                pytest_config = config

            @staticmethod
            def pytest_runtest_logreport(report: "TestReport"):
                if report.when != "call" and not (
                    report.outcome == "skipped" and report.when == "setup"
                ):
                    return
                file_path, *name_path = report.nodeid.split("::")
                abs_path = str(Path(pytest_config.rootpath, file_path))
                test_name, *namespaces = reversed(name_path)
                valid_test_name, *_ = test_name.split("[")  # ]

                errors: List[NeotestError] = []
                short = self.get_short_output(pytest_config, report)
                if report.outcome == "failed":
                    exc_repr = cast("ExceptionChainRepr", report.longrepr)
                    exc_repr.toterminal
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
                pos_id = "::".join([abs_path, *namespaces, valid_test_name])
                results[pos_id] = self.update_result(
                    results.get(pos_id),
                    {
                        "short": short,
                        "status": NeotestResultStatus(report.outcome),
                        "errors": errors,
                    },
                )

        import pytest

        pytest.main(args=args, plugins=[NeotestResultCollector])
        return results
