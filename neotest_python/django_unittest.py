import inspect
import subprocess
import os
import sys
import traceback
import unittest
from pathlib import Path
from types import TracebackType
from typing import Any, Tuple, Callable, Dict, List
from unittest import TestCase, TestSuite
from unittest.runner import TextTestResult
from django import setup as django_setup
from django.test.runner import DiscoverRunner
from .base import NeotestAdapter, NeotestError, NeotestResultStatus


class DjangoNeotestAdapter(NeotestAdapter):
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

    def convert_args(self, case_id: str, args: List[str]) -> List[str]:
        """Converts a neotest ID into test specifier for unittest"""
        path, *child_ids = case_id.split("::")
        if not child_ids:
            child_ids = []
        # Otherwise, convert the ID into a dotted path, relative to current dir
        relative_file = os.path.relpath(path, os.getcwd())
        relative_stem = os.path.splitext(relative_file)[0]
        relative_dotted = relative_stem.replace(os.sep, ".")
        return [*args, ".".join([relative_dotted, *child_ids])]

    # TODO: Stream results
    def run(self, args: List[str], _) -> Dict:
        errs: Dict[str, Tuple[Exception, Any, TracebackType]] = {}
        results = {}

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

        class DjangoUnittestRunner(DiscoverRunner):
            def __init__(self, *args, **kwargs):
                # env variable DJANGO_SETTINGS_MODULE need to be set
                django_setup()
                super().__init__(*args, **kwargs)
                self.resultclass = kwargs.pop("resultclass", None)

            def get_resultclass(self):
                return (
                    DebugSQLTextTestResult if self.debug_sql else NeotestTextTestResult
                )

            def run_tests(self, test_labels, extra_tests=None, **kwargs):
                self.setup_test_environment()
                old_config = self.setup_databases()
                suite = self.build_suite(test_labels, extra_tests)
                result = self.test_runner(
                    verbosity=self.verbosity,
                    failfast=self.failfast,
                    resultclass=self.resultclass,
                ).run(suite)
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
                # result = self.run_suite(suite)
                self.teardown_databases(old_config)
                self.teardown_test_environment()
                return self.suite_result(suite, result)

        # Make sure we can import relative to current path
        sys.path.insert(0, os.getcwd())
        # Prepend an executable name which is just used in output
        argv = ["neotest-python"] + self.convert_args(args[-1], args[:-1])
        runner = DjangoUnittestRunner(resultclass=NeotestTextTestResult, verbosity=2)
        runner.run_tests(test_labels=[argv[1]])
        return results
