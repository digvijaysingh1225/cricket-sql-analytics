"""
Idempotent Cricsheet JSON -> PostgreSQL loader.

Loads all *.json match files under one or more Cricsheet data folders into
the 6-table schema (teams, players, venues, matches, deliveries, player_match).

Idempotency strategy: this is a batch analytical load, not an incremental
sync, so idempotency is achieved by truncating all 6 tables at the start of
every run and reloading from scratch. That's simpler and faster than
per-row upserts for a full reload, and it guarantees a clean, reproducible
state every time the script is run.

Usage:
    python load_data.py --data-dir raw_data --host localhost --port 5432 \
        --user cricket --password cricket --dbname cricket_db

`--data-dir` is searched recursively for *.json files, so pointing it at
`raw_data` (containing ipl_json_extracted/, tests_json_extracted/, etc.)
picks up every format in one run.

Known, deliberate simplifications (documented here, not hidden):
  - Only the first date in info.dates[] is used as match_date. For
    multi-day Tests this is the start date only, not every day played.
  - team_home_id / team_away_id are teams[0] / teams[1] from the source --
    Cricsheet does not record true home/away, this is positional only.
  - A delivery's extras_type stores ONE type even though the JSON's
    "extras" object could theoretically hold more than one key on the same
    ball (e.g. a no-ball with byes). Priority order below picks one.
  - A delivery's wicket_type/player_out_id capture only the FIRST entry in
    "wickets" (extremely rare multi-wicket deliveries, e.g. a mankad
    alongside a run out, are not modelled -- matches the brief's schema).
  - Innings flagged "super_over": true are excluded entirely, so Super
    Over runs/wickets never pollute career/season aggregates.
"""

import argparse
import json
import sys
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text

EXTRAS_PRIORITY = ["noballs", "wides", "byes", "legbyes", "penalty"]
FLUSH_EVERY_ROWS = 200_000  # buffer size before bulk-flushing deliveries/player_match


def find_json_files(data_dir: Path):
    return sorted(data_dir.rglob("*.json"))


def load_match(path: Path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def primary_extras_type(extras: dict):
    if not extras:
        return None
    for key in EXTRAS_PRIORITY:
        if key in extras:
            return key
    return next(iter(extras))  # unexpected extras key -- fall back to whatever is there


def extract_dimensions(files):
    """Pass 1: scan every file just for teams / players / venues, so the
    dimension tables can be fully populated (and their DB-assigned ids
    looked up) before any match/delivery rows are inserted."""
    teams, players, venues = {}, {}, set()
    unreadable = 0
    for path in files:
        try:
            data = load_match(path)
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            print(f"  SKIP (unreadable): {path.name}: {e}")
            unreadable += 1
            continue
        info = data.get("info", {})
        team_type = info.get("team_type")
        for t in info.get("teams", []):
            teams.setdefault(t, team_type)
        for name, rid in info.get("registry", {}).get("people", {}).items():
            players[rid] = name  # last-seen display name wins; id is the real key
        venue, city = info.get("venue"), info.get("city")
        if venue:
            venues.add((venue, city))
    if unreadable:
        print(f"  {unreadable} file(s) skipped as unreadable during dimension scan")
    return teams, players, venues


def bulk_insert_dimensions(engine, teams, players, venues):
    with engine.begin() as conn:
        if teams:
            pd.DataFrame(
                [{"team_name": n, "team_type": t} for n, t in teams.items()]
            ).to_sql("teams", conn, if_exists="append", index=False)
        if players:
            pd.DataFrame(
                [{"player_name": n, "cricsheet_registry_id": rid} for rid, n in players.items()]
            ).to_sql("players", conn, if_exists="append", index=False)
        if venues:
            pd.DataFrame(
                [{"venue_name": v, "city": c} for v, c in venues]
            ).to_sql("venues", conn, if_exists="append", index=False)


def load_lookup_maps(engine):
    with engine.connect() as conn:
        team_map = dict(conn.execute(text("SELECT team_name, team_id FROM teams")).fetchall())
        player_map = dict(conn.execute(text("SELECT cricsheet_registry_id, player_id FROM players")).fetchall())
        venue_map = {
            (row.venue_name, row.city): row.venue_id
            for row in conn.execute(text("SELECT venue_id, venue_name, city FROM venues"))
        }
    return team_map, player_map, venue_map


def build_match_row(info, team_map, venue_map):
    teams_list = info.get("teams", [])
    if len(teams_list) != 2:
        return None  # not a standard two-team match -- skip

    venue_id = venue_map.get((info.get("venue"), info.get("city")))
    if venue_id is None:
        return None

    dates = info.get("dates", [])
    toss = info.get("toss", {})
    outcome = info.get("outcome", {})
    winner_name = outcome.get("winner")
    by = outcome.get("by", {})

    return {
        "competition": info.get("event", {}).get("name") or info.get("match_type", "Unknown"),
        "season": str(info.get("season")),
        "match_date": dates[0] if dates else None,
        "venue_id": venue_id,
        "team_home_id": team_map.get(teams_list[0]),
        "team_away_id": team_map.get(teams_list[1]),
        "toss_winner_id": team_map.get(toss.get("winner")),
        "toss_decision": toss.get("decision"),
        "winner_id": team_map.get(winner_name) if winner_name else None,
        "result_type": "win" if winner_name else outcome.get("result", "unknown"),
        "margin_runs": by.get("runs"),
        "margin_wickets": by.get("wickets"),
    }


def build_player_match_rows(info, reg, team_map, player_map):
    """Real Cricsheet data occasionally lists the same player twice within
    one team's roster for a match (a data-entry quirk, and modern formats
    with an Impact Player/substitute rule can add a second roster entry
    for what resolves to the same registry id). player_match's primary
    key is (match_id, player_id), so dedupe by player_id here -- first
    team encountered wins. This does NOT fully replace the ON CONFLICT
    safety net at insert time below, which also guards edge cases this
    per-match dedupe wouldn't catch."""
    rows = {}
    for team_name, roster in info.get("players", {}).items():
        team_id = team_map.get(team_name)
        for pname in roster:
            pid = player_map.get(reg.get(pname))
            if pid is not None and team_id is not None and pid not in rows:
                rows[pid] = {"player_id": pid, "team_id": team_id}
    return list(rows.values())


def build_delivery_rows(innings_list, reg, player_map):
    rows = []
    for innings_idx, innings in enumerate(innings_list, start=1):
        if innings.get("super_over"):
            continue  # exclude Super Overs from core ball-by-ball stats
        seq = 0
        for over in innings.get("overs", []):
            over_no = over.get("over")
            legal_ball_no = 0
            for delivery in over.get("deliveries", []):
                seq += 1
                extras = delivery.get("extras", {})
                extras_type = primary_extras_type(extras)
                if extras_type not in ("wides", "noballs"):
                    legal_ball_no += 1

                runs = delivery.get("runs", {})
                wickets = delivery.get("wickets", [])
                wicket_type = wickets[0].get("kind") if wickets else None
                player_out_name = wickets[0].get("player_out") if wickets else None

                rows.append({
                    "innings_no": innings_idx,
                    "innings_seq": seq,
                    "over_no": over_no,
                    "ball_no": legal_ball_no,
                    "batter_id": player_map.get(reg.get(delivery.get("batter"))),
                    "bowler_id": player_map.get(reg.get(delivery.get("bowler"))),
                    "non_striker_id": player_map.get(reg.get(delivery.get("non_striker"))),
                    "runs_batter": runs.get("batter", 0),
                    "runs_extras": runs.get("extras", 0),
                    "extras_type": extras_type,
                    "wicket_type": wicket_type,
                    "player_out_id": player_map.get(reg.get(player_out_name)) if player_out_name else None,
                })
    return rows


def flush_buffer(engine, table_name, buffer):
    if not buffer:
        return
    pd.DataFrame(buffer).to_sql(
        table_name, engine, if_exists="append", index=False, method="multi", chunksize=5000
    )
    buffer.clear()


def flush_player_match_buffer(engine, buffer):
    """player_match gets its own flush (not the generic to_sql one) so it
    can use ON CONFLICT DO NOTHING as a safety net beneath the per-match
    dedupe in build_player_match_rows -- belt and braces against the
    duplicate-roster-entry quirk in the real data."""
    if not buffer:
        return
    stmt = text("""
        INSERT INTO player_match (player_id, team_id, match_id)
        VALUES (:player_id, :team_id, :match_id)
        ON CONFLICT (match_id, player_id) DO NOTHING
    """)
    with engine.begin() as conn:
        conn.execute(stmt, buffer)
    buffer.clear()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data-dir", required=True, help="Folder to search recursively for *.json Cricsheet files")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", default="5432")
    ap.add_argument("--user", default="cricket")
    ap.add_argument("--password", default="cricket")
    ap.add_argument("--dbname", default="cricket_db")
    args = ap.parse_args()

    data_dir = Path(args.data_dir)
    files = find_json_files(data_dir)
    if not files:
        print(f"No .json files found under {data_dir}", file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(files)} match files under {data_dir}")

    engine = create_engine(
        f"postgresql+psycopg2://{args.user}:{args.password}@{args.host}:{args.port}/{args.dbname}"
    )

    print("Pass 1: scanning for teams, players, venues...")
    teams, players, venues = extract_dimensions(files)
    print(f"  {len(teams)} teams, {len(players)} players, {len(venues)} venues")

    print("Truncating all 6 tables for a clean, idempotent reload...")
    with engine.begin() as conn:
        conn.execute(text(
            "TRUNCATE deliveries, player_match, matches, players, teams, venues RESTART IDENTITY CASCADE"
        ))

    print("Inserting dimension tables...")
    bulk_insert_dimensions(engine, teams, players, venues)
    team_map, player_map, venue_map = load_lookup_maps(engine)

    print("Pass 2: loading matches, rosters, and deliveries...")
    pm_buffer, delivery_buffer = [], []
    total_deliveries, skipped = 0, 0

    with engine.connect() as conn:
        for i, path in enumerate(files, start=1):
            try:
                data = load_match(path)
            except (json.JSONDecodeError, UnicodeDecodeError):
                skipped += 1
                continue

            info = data.get("info", {})
            match_row = build_match_row(info, team_map, venue_map)
            if match_row is None:
                skipped += 1
                continue

            with conn.begin():
                match_id = conn.execute(
                    text("""
                        INSERT INTO matches (competition, season, match_date, venue_id,
                            team_home_id, team_away_id, toss_winner_id, toss_decision,
                            winner_id, result_type, margin_runs, margin_wickets)
                        VALUES (:competition, :season, :match_date, :venue_id,
                            :team_home_id, :team_away_id, :toss_winner_id, :toss_decision,
                            :winner_id, :result_type, :margin_runs, :margin_wickets)
                        RETURNING match_id
                    """),
                    match_row,
                ).scalar()

            reg = info.get("registry", {}).get("people", {})

            for row in build_player_match_rows(info, reg, team_map, player_map):
                row["match_id"] = match_id
                pm_buffer.append(row)

            delivery_rows = build_delivery_rows(data.get("innings", []), reg, player_map)
            for row in delivery_rows:
                row["match_id"] = match_id
                delivery_buffer.append(row)
            total_deliveries += len(delivery_rows)

            if len(delivery_buffer) >= FLUSH_EVERY_ROWS:
                flush_buffer(engine, "deliveries", delivery_buffer)
            if len(pm_buffer) >= FLUSH_EVERY_ROWS:
                flush_player_match_buffer(engine, pm_buffer)

            if i % 500 == 0:
                print(f"  {i}/{len(files)} matches processed...")

    flush_buffer(engine, "deliveries", delivery_buffer)
    flush_player_match_buffer(engine, pm_buffer)

    print(f"\nDone. {len(files) - skipped} matches loaded, {skipped} skipped, {total_deliveries} deliveries inserted.\n")
    with engine.connect() as conn:
        for tbl in ["teams", "players", "venues", "matches", "player_match", "deliveries"]:
            count = conn.execute(text(f"SELECT COUNT(*) FROM {tbl}")).scalar()
            print(f"  {tbl:15s} {count}")


if __name__ == "__main__":
    main()
