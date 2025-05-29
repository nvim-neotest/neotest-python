import pytest


def main():
    # use a dummy marker to make sure no test is run
    pytest.main(args=["-k", "neotest_none"], plugins=["neotest_python.pytest"])


if __name__ == "__main__":
    main()
