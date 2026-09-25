-- ============================================================
-- Cricsheet ball-by-ball schema
-- 6 tables, normalised, matched against real Cricsheet JSON
-- (verified against IPL match 1082591.json, format v1.2.0)
-- ============================================================

-- ---------- teams ----------
-- team_type uses Cricsheet's own vocabulary: 'international' or 'club'
-- ('club' covers IPL/BBL/etc. franchises — the brief's "franchise" label
-- doesn't match the source data, so we use the source's term.)
CREATE TABLE teams (
    team_id     SERIAL PRIMARY KEY,
    team_name   VARCHAR(100) NOT NULL UNIQUE,
    team_type   VARCHAR(20)  NOT NULL CHECK (team_type IN ('international', 'club'))
);

-- ---------- players ----------
-- cricsheet_registry_id is the REAL stable identifier (8-char hex from
-- info.registry.people). player_name is a display name only — the same
-- person can appear under name variants across files, so name is never
-- used as a join key, only the registry id.
CREATE TABLE players (
    player_id               SERIAL PRIMARY KEY,
    player_name              VARCHAR(150) NOT NULL,
    cricsheet_registry_id    CHAR(8) NOT NULL UNIQUE
);

-- ---------- venues ----------
-- country is nullable: Cricsheet's info block gives venue name + city,
-- never country. Country is backfilled separately (small manual
-- venue->country lookup) rather than invented at parse time.
CREATE TABLE venues (
    venue_id     SERIAL PRIMARY KEY,
    venue_name   VARCHAR(200) NOT NULL,
    city         VARCHAR(100),
    country      VARCHAR(100),
    UNIQUE (venue_name, city)
);

-- ---------- matches ----------
-- season stored as TEXT: IPL seasons are plain years (2017) but
-- international seasons in Cricsheet can be "2009/10" — a single
-- numeric type can't hold both cleanly.
-- match_date uses the FIRST date in info.dates[]: correct for
-- single-day matches (IPL/ODI/T20I); for multi-day Tests this is the
-- start date only, not every day played — documented simplification.
-- team_home_id/team_away_id are just teams[0]/teams[1] from the source
-- — Cricsheet doesn't record true home/away, so this is positional,
-- not a home-ground claim.
CREATE TABLE matches (
    match_id         SERIAL PRIMARY KEY,
    competition      VARCHAR(100) NOT NULL,
    season           VARCHAR(10)  NOT NULL,
    match_date       DATE NOT NULL,
    venue_id         INTEGER NOT NULL REFERENCES venues(venue_id),
    team_home_id     INTEGER NOT NULL REFERENCES teams(team_id),
    team_away_id     INTEGER NOT NULL REFERENCES teams(team_id),
    toss_winner_id   INTEGER REFERENCES teams(team_id),
    toss_decision    VARCHAR(10) CHECK (toss_decision IN ('bat', 'field')),
    winner_id        INTEGER REFERENCES teams(team_id),
    result_type      VARCHAR(20),     -- 'win', 'tie', 'no result', etc.
    margin_runs      INTEGER,
    margin_wickets   INTEGER,
    CHECK (team_home_id <> team_away_id)
);

-- ---------- deliveries ----------
-- innings_seq is the fix for the duplicate-ball-number problem found in
-- the real data: "0.5" appeared twice in one over (a wide, then the
-- legal ball replacing it), because extras don't increment ball_no.
-- over_no/ball_no are kept for readability and for queries that
-- genuinely need over/ball (death-overs filters), but innings_seq
-- (strict 1,2,3... chronological order per innings) is what LAG(),
-- moving averages and any "in order" window function must use —
-- (over_no, ball_no) is not reliably unique or ordered on its own.
CREATE TABLE deliveries (
    delivery_id      BIGSERIAL PRIMARY KEY,
    match_id         INTEGER NOT NULL REFERENCES matches(match_id),
    innings_no       SMALLINT NOT NULL,
    innings_seq      INTEGER NOT NULL,   -- strict chronological order within the innings
    over_no          SMALLINT NOT NULL,
    ball_no          SMALLINT NOT NULL,
    batter_id        INTEGER NOT NULL REFERENCES players(player_id),
    bowler_id        INTEGER NOT NULL REFERENCES players(player_id),
    non_striker_id   INTEGER NOT NULL REFERENCES players(player_id),
    runs_batter      SMALLINT NOT NULL DEFAULT 0,
    runs_extras      SMALLINT NOT NULL DEFAULT 0,
    extras_type      VARCHAR(20),        -- 'wides','noballs','byes','legbyes', NULL if none
    wicket_type      VARCHAR(30),        -- NULL if no wicket fell
    player_out_id    INTEGER REFERENCES players(player_id),
    UNIQUE (match_id, innings_no, innings_seq)
);

-- ---------- player_match ----------
-- Built from info.players{team_name: [...]} — the match-day squad,
-- independent of who actually batted/bowled (so non-playing squad
-- members are still captured for "did X play in season Y" queries).
CREATE TABLE player_match (
    match_id    INTEGER NOT NULL REFERENCES matches(match_id),
    player_id   INTEGER NOT NULL REFERENCES players(player_id),
    team_id     INTEGER NOT NULL REFERENCES teams(team_id),
    PRIMARY KEY (match_id, player_id)
);

-- ============================================================
-- Baseline indexes
-- Deliberately NOT including a (batter_id, over_no) composite index
-- yet — that's the subject of query 10's before/after EXPLAIN ANALYZE
-- study. Adding it now would spoil the exercise.
-- ============================================================

-- FK join performance: deliveries is the huge table, every join into
-- it needs match_id indexed, and batter_id/bowler_id are the two
-- columns nearly every analytical query filters or aggregates on.
CREATE INDEX idx_deliveries_match_id  ON deliveries(match_id);
CREATE INDEX idx_deliveries_batter_id ON deliveries(batter_id);
CREATE INDEX idx_deliveries_bowler_id ON deliveries(bowler_id);

-- player_match's PK is (match_id, player_id), which does NOT help
-- lookups by player_id alone ("which matches did X play") — Postgres
-- can only use a leading-column prefix of a composite index/PK.
CREATE INDEX idx_player_match_player_id ON player_match(player_id);

-- Season leaderboard / season-partitioned window functions filter or
-- partition by season on nearly every Half-A query.
CREATE INDEX idx_matches_season ON matches(season);
