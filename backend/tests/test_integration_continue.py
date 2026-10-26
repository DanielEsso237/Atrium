"""La verification continue ne doit jamais etre verte sans base.

Sur un poste sans PostgreSQL, les tests avec base sont ignores, et c'est
voulu. En integration continue, le meme saut transformerait un service
PostgreSQL mal monte en succes : les tests ignores se lisent comme des tests
passes. Pur : lance un pytest enfant, sans base.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]


def _pytest_enfant(**env) -> subprocess.CompletedProcess:
    environ = {k: v for k, v in os.environ.items() if k not in ("CI", "TEST_DATABASE_URL")}
    environ.update(env)
    return subprocess.run(
        [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests/test_droits_coherents.py"],
        cwd=BACKEND,
        env=environ,
        capture_output=True,
        text=True,
        timeout=120,
    )


def test_en_ci_une_base_absente_fait_echouer():
    resultat = _pytest_enfant(CI="true")
    assert resultat.returncode != 0
    assert "TEST_DATABASE_URL" in resultat.stdout + resultat.stderr


def test_hors_ci_une_base_absente_saute_les_tests_avec_base():
    resultat = _pytest_enfant()
    assert resultat.returncode == 0, resultat.stdout + resultat.stderr
