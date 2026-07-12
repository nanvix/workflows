# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.

"""Minimal SDK fixture used by the reusable workflow's manual test caller."""

from nanvix_zutil import ZScript


class WorkflowsFixture(ZScript):
    """Exercise setup and release metadata without consumer-specific logic."""

    def build(self) -> None:
        """Build no consumer payload."""

    def test(self) -> None:
        """Run no consumer tests."""


if __name__ == "__main__":
    WorkflowsFixture.main()
