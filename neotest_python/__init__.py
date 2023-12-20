import argparse
import json
from enum import Enum
from typing import List

from neotest_python.base import NeotestAdapter, NeotestResult


class TestRunner(str, Enum):
    PYTEST = "pytest"
    UNITTEST = "unittest"
    DJANGO = "django"


def get_adapter(runner: TestRunner, emit_parameterized_ids: bool) -> NeotestAdapter:
    if runner == TestRunner.PYTEST:
        from .pytest import PytestNeotestAdapter

        return PytestNeotestAdapter(emit_parameterized_ids)
    elif runner == TestRunner.UNITTEST:
        from .unittest import UnittestNeotestAdapter

        return UnittestNeotestAdapter()
    elif runner == TestRunner.DJANGO:
        from .django_unittest import DjangoNeotestAdapter

        return DjangoNeotestAdapter()
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
parser.add_argument(
    "--emit-parameterized-ids",
    action="store_true",
    help="Emit parameterized test ids (pytest only)",
)
parser.add_argument("args", nargs="*")


def main(argv: List[str]):
    if "--pytest-collect" in argv:
        argv.remove("--pytest-collect")
        from .pytest import collect

        collect(argv)
        return

    args = parser.parse_args(argv)
    adapter = get_adapter(TestRunner(args.runner), args.emit_parameterized_ids)

    with open(args.stream_file, "w") as stream_file:

        def stream(pos_id: str, result: NeotestResult):
            stream_file.write(json.dumps({"id": pos_id, "result": result}) + "\n")
            stream_file.flush()

        results = adapter.run(args.args, stream)

    with open(args.results_file, "w") as results_file:
        json.dump(results, results_file)
