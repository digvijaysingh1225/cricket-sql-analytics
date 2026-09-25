"""
Cricket Analytics Dashboard
Reads from the 6 pre-aggregated summary tables on the hosted Neon database
(NOT the raw ~5M-row deliveries table -- see summary_tables.sql and the
project README for why: it keeps the hosted footprint tiny and the
dashboard fast, following a standard "dashboard reads from a data mart"
pattern rather than querying a multi-million-row fact table directly).

Connection string is read from Streamlit secrets (st.secrets) when deployed
on Streamlit Community Cloud, or from the DATABASE_URL environment variable
for local runs. It is never hardcoded here, and .streamlit/secrets.toml is
gitignored -- only .streamlit/secrets.toml.example (with placeholder
values) is committed.
"""

import os

import pandas as pd
import plotly.express as px
import streamlit as st
from sqlalchemy import create_engine, text

st.set_page_config(page_title="Cricket Analytics Dashboard", layout="wide")


@st.cache_resource
def get_engine():
    conn_str = None
    try:
        conn_str = st.secrets["DATABASE_URL"]
    except Exception:
        conn_str = os.environ.get("DATABASE_URL")

    if not conn_str:
        st.error(
            "No database connection configured. Set DATABASE_URL as an "
            "environment variable (local run) or add it to "
            ".streamlit/secrets.toml (see secrets.toml.example)."
        )
        st.stop()

    return create_engine(conn_str)


@st.cache_data(ttl=3600)
def run_query(sql: str, params: dict | None = None) -> pd.DataFrame:
    engine = get_engine()
    with engine.connect() as conn:
        return pd.read_sql(text(sql), conn, params=params or {})


# ---------------------------------------------------------------
# Sidebar navigation
# ---------------------------------------------------------------
st.sidebar.title("Cricket Analytics")
view = st.sidebar.radio(
    "View",
    [
        "Season Leaderboard",
        "Batter Profile",
        "Bowler Economy by Phase",
        "Venue Effects",
        "Head-to-Head",
    ],
)

# ---------------------------------------------------------------
# View 1: Season Leaderboard
# ---------------------------------------------------------------
if view == "Season Leaderboard":
    st.title("Season Leaderboard")

    seasons = run_query(
        "SELECT DISTINCT season FROM season_batting_leaderboard ORDER BY season DESC"
    )["season"].tolist()
    season = st.selectbox("Season", seasons)

    col1, col2 = st.columns(2)

    with col1:
        st.subheader("Top Run Scorers")
        batting = run_query(
            """
            SELECT player_name, competition, runs, matches_played, strike_rate
            FROM season_batting_leaderboard
            WHERE season = :season
            ORDER BY runs DESC
            LIMIT 15
            """,
            {"season": season},
        )
        st.dataframe(batting, width='stretch', hide_index=True)

    with col2:
        st.subheader("Top Wicket Takers")
        bowling = run_query(
            """
            SELECT player_name, competition, wickets, matches_played, economy
            FROM season_bowling_leaderboard
            WHERE season = :season
            ORDER BY wickets DESC
            LIMIT 15
            """,
            {"season": season},
        )
        st.dataframe(bowling, width='stretch', hide_index=True)

# ---------------------------------------------------------------
# View 2: Batter Profile
# ---------------------------------------------------------------
elif view == "Batter Profile":
    st.title("Batter Profile")

    players = run_query(
        """
        SELECT player_name, SUM(runs) AS total_runs
        FROM season_batting_leaderboard
        GROUP BY player_name
        ORDER BY total_runs DESC
        LIMIT 300
        """
    )["player_name"].tolist()
    player = st.selectbox("Batter", players)

    log = run_query(
        """
        SELECT match_date, runs, strike_rate, powerplay_runs, middle_runs, death_runs
        FROM batter_match_log
        WHERE player_name = :player
        ORDER BY match_date
        """,
        {"player": player},
    )

    if log.empty:
        st.warning("No data for this player.")
    else:
        log["moving_avg_10"] = log["runs"].rolling(window=10, min_periods=1).mean()

        st.subheader("Career Progression (runs per match)")
        fig = px.line(log, x="match_date", y=["runs", "moving_avg_10"],
                      labels={"value": "Runs", "match_date": "Match date", "variable": ""})
        st.plotly_chart(fig, width='stretch')

        st.subheader("Phase-wise Run Distribution")
        phase_totals = pd.DataFrame({
            "Phase": ["Powerplay (overs 1-6)", "Middle (overs 7-15)", "Death (overs 16-20)"],
            "Runs": [
                log["powerplay_runs"].sum(),
                log["middle_runs"].sum(),
                log["death_runs"].sum(),
            ],
        })
        fig2 = px.bar(phase_totals, x="Phase", y="Runs")
        st.plotly_chart(fig2, width='stretch')

        c1, c2, c3 = st.columns(3)
        c1.metric("Career Runs", int(log["runs"].sum()))
        c2.metric("Matches", len(log))
        c3.metric("Avg Strike Rate", round(log["strike_rate"].mean(), 2))

# ---------------------------------------------------------------
# View 3: Bowler Economy by Phase
# ---------------------------------------------------------------
elif view == "Bowler Economy by Phase":
    st.title("Bowler Economy Rate Distribution by Phase")
    st.caption(
        "Each point is one bowler's economy rate in one match, in one phase of the innings. "
        "Filtered to spells of at least 1 over to avoid single-ball noise."
    )

    econ = run_query(
        """
        SELECT phase, economy
        FROM bowler_phase_economy
        WHERE legal_balls >= 6
        """
    )

    phase_order = ["powerplay", "middle", "death"]
    fig = px.box(econ, x="phase", y="economy", category_orders={"phase": phase_order},
                 labels={"phase": "Phase", "economy": "Economy rate (runs/over)"})
    st.plotly_chart(fig, width='stretch')

    st.subheader("Summary")
    summary = econ.groupby("phase")["economy"].agg(["median", "mean", "count"]).reindex(phase_order)
    st.dataframe(summary, width='stretch')

# ---------------------------------------------------------------
# View 4: Venue Effects
# ---------------------------------------------------------------
elif view == "Venue Effects":
    st.title("Venue Effects on First-Innings Totals")

    min_matches = st.slider("Minimum matches at venue (filters out small-sample noise)", 1, 20, 5)

    venues = run_query(
        """
        SELECT venue_name, city, matches_played, avg_first_innings_score
        FROM venue_effects
        WHERE matches_played >= :min_matches
        ORDER BY avg_first_innings_score DESC
        LIMIT 30
        """,
        {"min_matches": min_matches},
    )

    fig = px.bar(
        venues, x="avg_first_innings_score", y="venue_name", orientation="h",
        hover_data=["city", "matches_played"],
        labels={"avg_first_innings_score": "Avg 1st innings score", "venue_name": ""},
    )
    fig.update_layout(yaxis={"categoryorder": "total ascending"}, height=800)
    st.plotly_chart(fig, width='stretch')

# ---------------------------------------------------------------
# View 5: Head-to-Head
# ---------------------------------------------------------------
elif view == "Head-to-Head":
    st.title("Head-to-Head Team Record")

    teams = run_query(
        """
        SELECT DISTINCT team1 AS team FROM head_to_head
        UNION
        SELECT DISTINCT team2 AS team FROM head_to_head
        ORDER BY team
        """
    )["team"].tolist()

    col1, col2 = st.columns(2)
    team_a = col1.selectbox("Team A", teams, index=0)
    team_b = col2.selectbox("Team B", teams, index=1 if len(teams) > 1 else 0)

    if team_a == team_b:
        st.info("Pick two different teams.")
    else:
        # head_to_head stores team1/team2 alphabetically -- look up regardless
        # of which order the user picked them in.
        lo, hi = sorted([team_a, team_b])
        record = run_query(
            "SELECT * FROM head_to_head WHERE team1 = :lo AND team2 = :hi",
            {"lo": lo, "hi": hi},
        )

        if record.empty:
            st.warning("These teams haven't played each other in this dataset.")
        else:
            row = record.iloc[0]
            wins_a = row["team1_wins"] if lo == team_a else row["team2_wins"]
            wins_b = row["team2_wins"] if lo == team_a else row["team1_wins"]

            c1, c2, c3 = st.columns(3)
            c1.metric(f"{team_a} wins", int(wins_a))
            c2.metric(f"{team_b} wins", int(wins_b))
            c3.metric("No result", int(row["no_result"]))

            fig = px.pie(
                names=[team_a, team_b, "No result"],
                values=[wins_a, wins_b, row["no_result"]],
                hole=0.4,
            )
            st.plotly_chart(fig, width='stretch')
