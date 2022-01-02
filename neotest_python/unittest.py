import inspect
import traceback
import unittest
from pathlib import Path
from types import TracebackType
from typing import Any, Dict, Iterator, List, Tuple
from unittest import TestCase, TestResult, TestSuite
from unittest.runner import TextTestResult, TextTestRunner

from .base import NeotestAdapter, NeotestResultStatus


class UnittestNeotestAdapter(NeotestAdapter):
    def iter_suite(
        self, suite: "TestSuite | TestCase"
    ) -> Iterator["TestCase | TestSuite"]:
        if isinstance(suite, TestSuite):
            for sub in suite:
                for case in self.iter_suite(sub):
                    yield case
        else:
            yield suite

    def case_file(self, case) -> str:
        return str(Path(inspect.getmodule(case).__file__).absolute())  # type: ignore

    def case_id_elems(self, case) -> List[str]:
        file = self.case_file(case)
        elems = [file, case.__class__.__name__]
        if isinstance(case, TestCase):
            elems.append(case._testMethodName)
        return elems

    def case_id(self, case: "TestCase | TestSuite") -> str:
        return "::".join(self.case_id_elems(case))

    def run(self, args: List[str]) -> Dict:
        results = {}

        errs: Dict[str, Tuple[Exception, Any, TracebackType]] = {}

        class NeotestTextTestResult(TextTestResult):
            def addFailure(_, test: TestCase, err) -> None:
                errs[self.case_id(test)] = err
                return super().addFailure(test, err)

        class NeotestUnittestRunner(TextTestRunner):
            def run(_, test: "TestSuite | TestCase") -> "TestResult":  # type: ignore
                for case in self.iter_suite(test):
                    results[self.case_id(case)] = {
                        "status": NeotestResultStatus.PASSED,
                        "short": None,
                    }
                    results[self.case_file(case)] = {
                        "status": NeotestResultStatus.PASSED,
                        "short": None,
                    }
                result = super().run(test)
                for case, message in result.failures:
                    case_id = self.case_id(case)
                    error_line = None
                    case_file = self.case_file(case)
                    if case_id in errs:
                        trace = errs[case_id][2]
                        summary = traceback.extract_tb(trace)
                        error_line = next(
                            frame.lineno - 1
                            for frame in reversed(summary)
                            if frame.filename == case_file
                        )
                    results[case_id] = self.update_result(
                        results.get(case_id),
                        {
                            "status": NeotestResultStatus.FAILED,
                            "errors": [{"message": message, "line": error_line}],
                            "short": None,
                        },
                    )
                    results[case_file] = self.update_result(
                        results.get(case_file),
                        {
                            "status": NeotestResultStatus.FAILED,
                            "errors": [{"message": message, "line": error_line}],
                            "short": None,
                        },
                    )
                for case, message in result.skipped:
                    results[self.case_id(case)] = self.update_result(
                        results[self.case_id(case)],
                        {
                            "short": None,
                            "status": NeotestResultStatus.SKIPPED,
                            "errors": None,
                        },
                    )
                return result

        unittest.main(
            module=None,
            argv=args,
            testRunner=NeotestUnittestRunner(resultclass=NeotestTextTestResult),
            exit=False,
        )

        return results
