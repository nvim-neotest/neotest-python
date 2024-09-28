import inspect
import os
import subprocess
import sys
import traceback
import unittest
from argparse import ArgumentParser
from pathlib import Path
from types import TracebackType
from typing import Any, Dict, List, Tuple
from unittest import TestCase
from unittest.runner import TextTestResult

from django import setup as django_setup
from django.test.runner import DiscoverRunner

from .base import NeotestAdapter, NeotestError, NeotestResultStatus


class CaseUtilsMixin:
    def case_file(self, case) -> str:
        return str(Path(inspect.getmodule(case).__file__).absolute())

    def case_id_elems(self, case) -> List[str]:
        file = self.case_file(case)
        elems = [file, case.__class__.__name__]
        if isinstance(case, TestCase):
            elems.append(case._testMethodName)
        return elems

    def case_id(self, case: "TestCase | TestSuite") -> str:
        return "::".join(self.case_id_elems(case))


class DjangoNeotestAdapter(CaseUtilsMixin, NeotestAdapter):
    def convert_args(self, case_id: str, args: List[str]) -> List[str]:
        """Converts a neotest ID into test specifier for unittest"""
        path, *child_ids = case_id.split("::")
        if not child_ids:
            child_ids = []
        relative_file = os.path.relpath(path, os.getcwd())
        relative_stem = os.path.splitext(relative_file)[0]
        relative_dotted = relative_stem.replace(os.sep, ".")
        return [*args, ".".join([relative_dotted, *child_ids])]

    def run(self, args: List[str], _) -> Dict:
        errs: Dict[str, Tuple[Exception, Any, TracebackType]] = {}
        results = {}

        class NeotestTextTestResult(CaseUtilsMixin, TextTestResult):
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

        class DjangoUnittestRunner(CaseUtilsMixin, DiscoverRunner):
            def __init__(self, **kwargs):
                django_setup()
                DiscoverRunner.__init__(self, **kwargs)

            @classmethod
            def add_arguments(cls, parser):
                DiscoverRunner.add_arguments(parser)
                parser.add_argument("--verbosity", nargs="?", default=2)
                if "failfast" not in parser.parse_args([]):
                    parser.add_argument(
                        "--failfast",
                        action="store_true",
                    )

            # override
            def get_resultclass(self):
                return NeotestTextTestResult

            def collect_results(self, django_test_results, neotest_results):
                for case, message in (
                    django_test_results.failures + django_test_results.errors
                ):
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
                    neotest_results[case_id] = {
                        "status": NeotestResultStatus.FAILED,
                        "errors": [{"message": message, "line": error_line}],
                        "short": None,
                    }
                for case, message in django_test_results.skipped:
                    neotest_results[self.case_id(case)] = {
                        "short": None,
                        "status": NeotestResultStatus.SKIPPED,
                        "errors": None,
                    }

            # override
            def suite_result(self, suite, suite_results, **kwargs):
                """Collect Django test suite results and convert them to Neotest compatible results."""
                self.collect_results(suite_results, results)
                return (
                    len(suite_results.failures)
                    + len(suite_results.errors)
                    + len(suite_results.unexpectedSuccesses)
                )

        # Make sure we can import relative to current path
        sys.path.insert(0, os.getcwd())
        # Prepend an executable name which is just used in output
        argv = ["neotest-python"] + self.convert_args(args[-1], args[:-1])
        # parse args
        parser = ArgumentParser()
        DjangoUnittestRunner.add_arguments(parser)
        # run tests
        runner = DjangoUnittestRunner(
            **vars(parser.parse_args(argv[1:-1]))  # parse plugin config args
        )
        runner.run_tests(test_labels=[argv[-1]])  # pass test label
        return results
