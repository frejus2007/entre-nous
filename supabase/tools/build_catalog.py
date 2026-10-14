#!/usr/bin/env python3
"""Construit 0006_seed_catalog.sql à partir des fichiers supabase/catalog/*.txt.

Chaque fichier = une catégorie, une question par ligne. Les lignes vides et
celles commençant par « # » sont ignorées. Les codes sont générés
automatiquement (<préfixe>-<numéro>) et uniques vis-à-vis du seed initial 0004.

Usage :  python3 supabase/tools/build_catalog.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "catalog"
OUT = ROOT / "migrations" / "0006_seed_catalog.sql"

# (valeurs de l'enum, préfixe de code, libellé lisible)
CATEGORIES = [
    ("brise_glace", "bg", "Brise-glace"),
    ("personnalite", "ph", "Personnalité et habitudes"),
    ("amour", "as", "Amour et séduction"),
    ("secrets", "sc", "Secrets et confidences"),
    ("pimente", "pi", "Pimenté"),
    ("tres_intime", "ti", "Très intime — 18+ (consentement requis)"),
    ("avenir", "av", "Avenir et relations"),
]

START = 101  # 0004 utilise 001..008 : on démarre à 101 pour éviter tout doublon.


def main() -> None:
    blocks: list[str] = []
    total = 0

    for cat, prefix, label in CATEGORIES:
        paths = sorted(CATALOG.glob(f"{cat}*.txt"))
        if not paths:
            continue

        lines: list[str] = []
        for path in paths:
            for raw in path.read_text(encoding="utf-8").splitlines():
                s = raw.strip()
                if not s or s.startswith("#"):
                    continue
                lines.append(s)

        values = []
        for i, q in enumerate(lines, start=START):
            code = f"{prefix}-{i}"
            body = q.replace("'", "''")
            values.append(f"  ('{code}', '{cat}', '{body}')")

        total += len(lines)
        blocks.append(
            f"-- {label} ({len(lines)} questions)\n"
            "insert into public.questions (code, category, body) values\n"
            + ",\n".join(values)
            + "\non conflict (code) do nothing;\n"
        )

    header = (
        "-- =============================================================================\n"
        "-- Entre Nous — 0006_seed_catalog.sql\n"
        "-- Catalogue étendu (§5). Rédaction respectueuse : sans contenu coercitif,\n"
        "-- sans demande de photo intime, sans menace ni humiliation (§5, §9).\n"
        "-- Objectif : 300+ questions par catégorie. Rejouable (on conflict do nothing).\n"
        f"-- Total : {total} questions.\n"
        "-- GÉNÉRÉ par supabase/tools/build_catalog.py — ne pas éditer à la main.\n"
        "-- =============================================================================\n\n"
    )

    OUT.write_text(header + "\n".join(blocks), encoding="utf-8")
    print(f"{OUT} écrit — {total} questions, {len(blocks)} catégories.")


if __name__ == "__main__":
    main()
