import argparse
import json
from enum import Enum
from typing import List

from neotest_python.base import NeotestResult


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
parser.add_argument(
    "--stream-file",
    dest="stream_file",
    required=True,
    help="File to stream result JSON to",
)
parser.add_argument("args", nargs="*")


def main(argv: List[str]):
    args = parser.parse_args(argv)
    adapter = get_adapter(TestRunner(args.runner))
    with open(args.stream_file, "w") as stream_file:

        def stream(pos_id: str, result: NeotestResult):
            stream_file.write(json.dumps({"id": pos_id, "result": result}) + "\n")
            stream_file.flush()

        results = adapter.run(args.args, stream)
    with open(args.results_file, "w") as results_file:
        json.dump(results, results_file)
