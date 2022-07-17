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
        file = self.case_file(case)
        elems = [file, case.__class__.__name__]
        if isinstance(case, TestCase):
            elems.append(case._testMethodName)
        return elems

    def case_id(self, case: "TestCase | TestSuite") -> str:
        return "::".join(self.case_id_elems(case))

    def id_to_unittest_args(self, case_id: str) -> List[str]:
        """Converts a neotest ID into test specifier for unittest"""
        path, *child_ids = case_id.split("::")
        if not child_ids:
            if os.path.isfile(path):
                # Test files can be passed directly to unittest
                return [path]
            # Directories need to be run via the 'discover' argument
            return ["discover", "-s", path]

        # Otherwise, convert the ID into a dotted path, relative to current dir
        relative_file = os.path.relpath(path, os.getcwd())
        relative_stem = os.path.splitext(relative_file)[0]
        relative_dotted = relative_stem.replace(os.sep, ".")
        return [".".join([relative_dotted, *child_ids])]

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
                        error_line = next(
                            frame.lineno - 1
                            for frame in reversed(summary)
                            if frame.filename == case_file
                        )
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
        # We only get a single case ID as the argument
        argv = sys.argv[0:1] + self.id_to_unittest_args(args[-1])
        unittest.main(
            module=None,
            argv=argv,
            testRunner=NeotestUnittestRunner(resultclass=NeotestTextTestResult),
            exit=False,
        )

        return results
