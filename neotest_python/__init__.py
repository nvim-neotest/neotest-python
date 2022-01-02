import argparse
import json
from enum import Enum
from typing import List


class TestRunner(str, Enum):
    PYTEST = "pytest"
    UNITTEST = "unittest"


def get_adapter(runner: TestRunner):
    if runner == TestRunner.PYTEST:
        from .pytest import PytestNeotestAdapter

        return PytestNeotestAdapter()
    elif runner == TestRunner.UNITTEST:
        from .unittest import UnittestNeotestAdapter

        return UnittestNeotestAdapter()
    raise NotImplementedError(runner)


parser = argparse.ArgumentParser()
parser.add_argument("--runner", required=True)
parser.add_argument(
    "--results-file",
    dest="results_file",
    required=True,
    help="File to store result JSON in",
)
parser.add_argument("args", nargs="*")


def main(argv: List[str]):
    args = parser.parse_args(argv)
    adapter = get_adapter(TestRunner(args.runner))
    results = adapter.run(args.args)
    with open(args.results_file, "w") as results_file:
        json.dump(results, results_file)
