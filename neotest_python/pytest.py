import json
import re
from io import StringIO
from pathlib import Path
from typing import Callable, Dict, Generator, List, Optional, Union

import pytest
from _pytest._code.code import ExceptionRepr
from _pytest.fixtures import FixtureLookupErrorRepr
from _pytest.terminal import TerminalReporter

from .base import NeotestAdapter, NeotestError, NeotestResult, NeotestResultStatus

ANSI_ESCAPE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")


class PytestNeotestAdapter(NeotestAdapter):
    def __init__(self, emit_parameterized_ids: bool):
        self.emit_parameterized_ids = emit_parameterized_ids

    def run(
        self,
        args: List[str],
        stream: Callable[[str, NeotestResult], None],
    ) -> Dict[str, NeotestResult]:
        result_collector = NeotestResultCollector(
            self, stream=stream, emit_parameterized_ids=self.emit_parameterized_ids
        )
        pytest.main(
            args=args,
            plugins=[
                result_collector,
                NeotestDebugpyPlugin(),
            ],
        )
        return result_collector.results


class NeotestResultCollector:
    def __init__(
        self,
        adapter: PytestNeotestAdapter,
        stream: Callable[[str, NeotestResult], None],
        emit_parameterized_ids: bool,
    ):
        self.stream = stream
        self.adapter = adapter
        self.emit_parameterized_ids = emit_parameterized_ids

        self.pytest_config: Optional["pytest.Config"] = None  # type: ignore
        self.results: Dict[str, NeotestResult] = {}

    def _get_short_output(
        self, config: "pytest.Config", report: "pytest.TestReport"
    ) -> Optional[str]:
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

    def pytest_configure(self, config: "pytest.Config"):
        self.pytest_config = config

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

    @pytest.hookimpl(hookwrapper=True)
    def pytest_runtest_makereport(
        self, item: "pytest.Item", call: "pytest.CallInfo"
    ) -> Generator:
        outcome = yield
        report: pytest.TestReport = outcome.get_result()

        if report.when not in {"call", "setup"} or report.outcome != "failed":
            return

        exc_repr = report.longrepr
        if not isinstance(exc_repr, ExceptionRepr):
            return

        file_path, *_ = item.nodeid.split("::")
        abs_path = str(Path(self.pytest_config.rootdir, file_path))
        report.error_line = next(
            (
                traceback_entry.lineno
                for traceback_entry in reversed(call.excinfo.traceback)
                if str(traceback_entry.path) == abs_path
            ),
            None,
        )

    def pytest_runtest_logreport(self, report: "pytest.TestReport") -> None:
        if not (
            report.when == "call"
            or (report.when == "setup" and report.outcome in ("skipped", "failed"))
        ):
            return

        file_path, *name_path = report.nodeid.split("::")
        abs_path = str(Path(self.pytest_config.rootdir, file_path))
        *namespaces, test_name = name_path
        valid_test_name, *params = test_name.split("[")  # ]

        pos_id = "::".join([abs_path, *namespaces, valid_test_name])

        errors: List[NeotestError] = []
        short = self._get_short_output(self.pytest_config, report)

        msg_prefix = ""
        param_id = None
        if "[" in test_name and test_name.endswith("]"):
            param_id = test_name[len(valid_test_name) + 1 : -1]
        if param_id:
            if self.emit_parameterized_ids:
                pos_id += f"[{param_id}]"
            else:
                msg_prefix = f"[{param_id}] "

        if report.outcome == "failed":
            exc_repr = report.longrepr
            # Test fails due to condition outside of test e.g. xfail
            if isinstance(exc_repr, str):
                errors.append({"message": msg_prefix + exc_repr, "line": None})
            # Test failed internally
            elif isinstance(exc_repr, ExceptionRepr):
                # Try to use reprcrash, but ensure the line is 0-based
                error_message = ANSI_ESCAPE.sub("", exc_repr.reprcrash.message)  # type: ignore
                # error_line = report.error_line
                error_line = getattr(report, "error_line", None)
                errors.append(
                    {"message": msg_prefix + error_message, "line": error_line}
                )
            elif isinstance(exc_repr, FixtureLookupErrorRepr):
                line0 = getattr(exc_repr, "firstlineno", None)
                if isinstance(line0, int):
                    line0 = max(0, line0 - 1)  # 0-based
                errors.append(
                    {
                        "message": msg_prefix + exc_repr.errorstring,
                        "line": line0,
                    }
                )
            else:
                # Preserve compatibility with previous behavior
                errors.append({"message": msg_prefix + str(exc_repr), "line": None})

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


class NeotestDebugpyPlugin:
    """A pytest plugin that would make debugpy stop at thrown exceptions."""

    def pytest_exception_interact(
        self,
        node: Union["pytest.Item", "pytest.Collector"],
        call: "pytest.CallInfo",
        report: Union["pytest.CollectReport", "pytest.TestReport"],
    ):
        # call.excinfo: _pytest._code.ExceptionInfo
        self.maybe_debugpy_postmortem(call.excinfo._excinfo)

    @staticmethod
    def maybe_debugpy_postmortem(excinfo):
        """Make the debugpy debugger enter and stop at a raised exception.

        excinfo: A (type(e), e, e.__traceback__) tuple. See sys.exc_info()
        """
        # Reference: https://github.com/microsoft/debugpy/issues/723
        import threading

        try:
            import pydevd
        except ImportError:
            return  # debugpy or pydevd not available, do nothing

        py_db = pydevd.get_global_debugger()
        if py_db is None:
            # Do nothing if not running with a DAP debugger,
            # e.g. neotest was invoked with {strategy = dap}
            return
        thread = threading.current_thread()
        additional_info = py_db.set_additional_thread_info(thread)
        additional_info.is_tracing += 1
        try:
            py_db.stop_on_unhandled_exception(py_db, thread, additional_info, excinfo)
        finally:
            additional_info.is_tracing -= 1


class TestNameTemplateExtractor:
    @staticmethod
    def pytest_collection_modifyitems(config):
        config = {"python_functions": config.getini("python_functions")[0]}
        print(f"\n{json.dumps(config)}\n")


def extract_test_name_template(args):
    pytest.main(args=["-k", "neotest_none"], plugins=[TestNameTemplateExtractor])


def collect(args):
    pytest.main(["--collect-only", "--verbosity=0", "-q"] + args)
