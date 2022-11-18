from contextlib import contextmanager
import sys
from pathlib import Path


@contextmanager
def add_to_path():
    old_path = sys.path[:]
    sys.path.insert(0, str(Path(__file__).parent))
    try:
        yield
    finally:
        sys.path = old_path


with add_to_path():
    from neotest_python import main

if __name__ == "__main__":
    main(sys.argv[1:])
