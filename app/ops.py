"""
Operations CLI helper.
"""
import sys
from app.db import init_db, set_config


def main():
    init_db()
    if len(sys.argv) > 1 and sys.argv[1] == "fail-next":
        set_config("fail_next_run", "true")
        print("Set fail_next_run to true")
    else:
        print("Usage: python -m app.ops fail-next")


if __name__ == "__main__":
    main()

