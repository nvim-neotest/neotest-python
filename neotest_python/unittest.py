import inspect
import os
import sys
import traceback
import unittest
from pathlib import Path
from types import TracebackType
from typing import Any, Dict, List, Tuple
from unittest import TestCase, TestResult, TestSuite
from unittest.runner import TextTestResult, TextTestRunner

from .base import NeotestAdapter, NeotestResultStatus


class UnittestNeotestAdapter(NeotestAdapter):
    def case_file(self, case) -> str:
        return str(Path(inspect.getmodule(case).__file__).absolute())  # type: ignore

    def case_id_elems(self, case) -> List[str]:
        if case.__class__.__name__ == "_SubTest":
            case = case.test_case
        file = self.case_file(case)
        elems = [file, case.__class__.__name__]
        if isinstance(case, TestCase):
            elems.append(case._testMethodName)
        return elems

    def case_id(self, case: "TestCase | TestSuite") -> str:
        return "::".join(self.case_id_elems(case))

    def convert_args(self, case_id: str, args: List[str]) -> List[str]:
        """Converts a neotest ID into test specifier for unittest"""
        path, *child_ids = case_id.split("::")
        if not child_ids:
            if os.path.isfile(path):
                # Test files can be passed directly to unittest
                return [path]
            # Directories need to be run via the 'discover' argument
            return ["discover", "-s", path, *args]

        # Otherwise, convert the ID into a dotted path, relative to current dir
        relative_file = os.path.relpath(path, os.getcwd())
        relative_stem = os.path.splitext(relative_file)[0]
        relative_dotted = relative_stem.replace(os.sep, ".")
        return [*args, ".".join([relative_dotted, *child_ids])]

    # TODO: Stream results
    def run(self, args: List[str], _) -> Dict:
        results = {}

        errs: Dict[str, Tuple[Exception, Any, TracebackType]] = {}

        class NeotestTextTestResult(TextTestResult):
            def addFailure(_, test: TestCase, err) -> None:
                errs[self.case_id(test)] = err
                return super().addFailure(test, err)

            def addError(_, test: TestCase, err) -> None:
                errs[self.case_id(test)] = err
                return super().addError(test, err)

            def addSuccess(_, test: TestCase) -> None:
                results[self.case_id(test)] = {
                    "status": NeotestResultStatus.PASSED,
                }

        class NeotestUnittestRunner(TextTestRunner):
            def run(_, test: "TestSuite | TestCase") -> "TestResult":  # type: ignore
                result = super().run(test)
                for case, message in result.failures + result.errors:
                    case_id = self.case_id(case)
                    error_line = None
                    case_file = self.case_file(case)
                    if case_id in errs:
                        trace = errs[case_id][2]
                        summary = traceback.extract_tb(trace)
                        for frame in reversed(summary):
                            if frame.filename == case_file:
                                error_line = frame.lineno - 1
                                break
                    results[case_id] = {
                        "status": NeotestResultStatus.FAILED,
                        "errors": [{"message": message, "line": error_line}],
                        "short": None,
                    }
                for case, message in result.skipped:
                    results[self.case_id(case)] = {
                        "short": None,
                        "status": NeotestResultStatus.SKIPPED,
                        "errors": None,
                    }
                return result

        # Make sure we can import relative to current path
        sys.path.insert(0, os.getcwd())

        # Prepend an executable name which is just used in output
        argv = ["neotest-python"] + self.convert_args(args[-1], args[:-1])
        unittest.main(
            module=None,
            argv=argv,
            testRunner=NeotestUnittestRunner(resultclass=NeotestTextTestResult),
            exit=False,
        )

        return results
