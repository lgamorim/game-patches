import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(os.path.dirname(HERE), 'runtime', 'site')   # filled by setup.ps1
sys.path[:0] = [HERE, SITE]

from fontpatch.cli import main  # noqa: E402

sys.exit(main())
