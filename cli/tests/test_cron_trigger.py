"""Tests for CronTrigger + CronPlugin lifecycle."""

from __future__ import annotations

import io
import json
import os
import sys
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from hivemoot_agent.plugins.interfaces import AgentResult, Job, PluginConfig
from hivemoot_agent.plugins_builtin.cron import CronPlugin, create_plugin
from hivemoot_agent.plugins_builtin.cron.config import CronConfig, ScheduleEntry
from hivemoot_agent.plugins_builtin.cron.schedule import parse_schedules
from hivemoot_agent.plugins_builtin.cron.trigger import (
    CronTrigger,
    _compute_next_fire,
)


def _make_cfg(entries: list[dict], **cron_kwargs) -> PluginConfig:
    typed = CronConfig(schedules=[ScheduleEntry(**e) for e in entries], **cron_kwargs)
    return PluginConfig(name="cron", settings={}, typed=typed)


# ── Plugin lifecycle ──────────────────────────────────────────────


class PluginLifecycleTests(unittest.TestCase):
    def test_validate_empty_config_ok(self) -> None:
        plugin = create_plugin()
        self.assertEqual(
            plugin.validate(PluginConfig(name="cron", settings={})),
            [],
        )

    def test_validate_always_passes_in_adr003(self) -> None:
        plugin = create_plugin()
        cfg = PluginConfig(name="cron", settings={}, typed=CronConfig())
        errors = plugin.validate(cfg)
        self.assertEqual(errors, [])

    def test_triggers_returns_single_instance(self) -> None:
        plugin = create_plugin()
        trigs = plugin.triggers()
        self.assertEqual(len(trigs), 1)
        self.assertIsInstance(trigs[0], CronTrigger)

    def test_empty_system_prompt(self) -> None:
        plugin = create_plugin()
        self.assertEqual(
            plugin.system_prompt(PluginConfig(name="cron", settings={})),
            "",
        )

    def test_lifecycle_hooks_are_noops(self) -> None:
        plugin = create_plugin()
        cfg = PluginConfig(name="cron", settings={})
        self.assertIsNone(plugin.setup(cfg))
        self.assertIsNone(
            plugin.on_job_started(Job(session_key="", prompt="x"), cfg),
        )
        self.assertIsNone(
            plugin.on_job_finished(
                Job(session_key="", prompt="x"),
                AgentResult(exit_code=0, response=""),
                cfg,
            ),
        )


# ── Trigger.validate ──────────────────────────────────────────────


class TriggerValidationTests(unittest.TestCase):
    def test_valid_config_passes(self) -> None:
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg([
            {"name": "a", "schedule": "@every 1h", "prompt": "p"},
        ])
        self.assertEqual(trig.validate(cfg), [])

    def test_invalid_schedule_raises_at_config_construction(self) -> None:
        from pydantic import ValidationError
        with self.assertRaises(ValidationError):
            CronConfig(schedules=[ScheduleEntry(
                name="a", schedule="not a cron", prompt="p",
            )])


# ── Trigger dispatch loop ────────────────────────────────────────


class TriggerDispatchTests(unittest.TestCase):
    def test_empty_config_idles(self) -> None:
        """No schedules → blocks until stop, does not crash."""
        trig = CronTrigger(MagicMock())
        cfg = PluginConfig(name="cron", settings={}, typed=CronConfig())
        dispatcher = MagicMock()

        done = threading.Event()

        def runner():
            with patch("sys.stderr", io.StringIO()):
                trig.start(cfg, dispatcher)
            done.set()

        t = threading.Thread(target=runner, daemon=True)
        t.start()
        time.sleep(0.05)
        trig.stop()
        self.assertTrue(done.wait(timeout=2.0))
        dispatcher.dispatch.assert_not_called()

    def test_dispatches_single_schedule(self) -> None:
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg([
            {"name": "auto", "schedule": "@every 1h", "prompt": "do things"},
        ])
        dispatcher = MagicMock()

        def stop_after_first(_job):
            trig.stop()
            return AgentResult(exit_code=0, response="")
        dispatcher.dispatch.side_effect = stop_after_first

        # The seed call sets next_fire to (seed + 1h); subsequent calls
        # return a time past that so delay = 0 and dispatch runs
        # immediately with no real sleep.
        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        past_fire = base + timedelta(hours=2)
        # 4 calls: seed, top-of-loop, post-wait, coalesce-probe.
        call_times = iter([base, past_fire, past_fire, past_fire])
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", io.StringIO()):
                trig.start(cfg, dispatcher)

        dispatcher.dispatch.assert_called_once()
        job = dispatcher.dispatch.call_args.args[0]
        self.assertEqual(job.session_key, "")
        self.assertEqual(job.prompt, "do things")
        self.assertEqual(job.metadata["cron"]["schedule_name"], "auto")
        self.assertFalse(job.metadata["cron"]["resume"])

    def test_resume_true_sets_session_key(self) -> None:
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg([{
            "name": "weekly", "schedule": "@every 1h",
            "prompt": "p", "resume": True,
        }])
        dispatcher = MagicMock()

        def stop_after_first(_job):
            trig.stop()
            return AgentResult(exit_code=0, response="")
        dispatcher.dispatch.side_effect = stop_after_first

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        past_fire = base + timedelta(hours=2)
        # 4 calls: seed, top-of-loop, post-wait, coalesce-probe.
        call_times = iter([base, past_fire, past_fire, past_fire])
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", io.StringIO()):
                trig.start(cfg, dispatcher)

        job = dispatcher.dispatch.call_args.args[0]
        self.assertEqual(job.session_key, "cron:weekly")
        self.assertTrue(job.metadata["cron"]["resume"])

    def test_multiple_schedules_fire_in_order(self) -> None:
        """When two schedules come due simultaneously, dispatch is sorted by name."""
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg([
            {"name": "zebra", "schedule": "@every 1h", "prompt": "z"},
            {"name": "alpha", "schedule": "@every 1h", "prompt": "a"},
        ])
        dispatcher = MagicMock()
        dispatched: list[str] = []

        def record(job):
            dispatched.append(job.metadata["cron"]["schedule_name"])
            if len(dispatched) >= 2:
                trig.stop()
            return AgentResult(exit_code=0, response="")
        dispatcher.dispatch.side_effect = record

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        past_fire = base + timedelta(hours=2)
        # 1 shared seed + top-of-loop + post-wait + 2 coalesce probes = 5.
        call_times = iter([base, past_fire, past_fire, past_fire, past_fire])
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", io.StringIO()):
                trig.start(cfg, dispatcher)

        self.assertEqual(dispatched, ["alpha", "zebra"])

    def test_stop_unblocks_long_wait(self) -> None:
        trig = CronTrigger(MagicMock())
        # @every is used deliberately: its reachability probe is O(1),
        # unlike a grammar-valid cron with a rare match (say yearly
        # schedules) which iterate up to a year minute-by-minute.
        cfg = _make_cfg([
            {"name": "a", "schedule": "@every 365d", "prompt": "p"},
        ])
        dispatcher = MagicMock()

        done = threading.Event()

        def runner():
            with patch("sys.stderr", io.StringIO()):
                trig.start(cfg, dispatcher)
            done.set()

        t = threading.Thread(target=runner, daemon=True)
        t.start()
        time.sleep(0.05)
        trig.stop()
        self.assertTrue(done.wait(timeout=2.0),
                        "trigger.start did not exit after stop()")
        dispatcher.dispatch.assert_not_called()

    def test_malformed_config_logs_and_returns(self) -> None:
        """typed=None (config not loaded) is caught gracefully."""
        trig = CronTrigger(MagicMock())
        cfg = PluginConfig(name="cron", settings={}, typed=None)
        dispatcher = MagicMock()
        stderr_io = io.StringIO()
        with patch("sys.stderr", stderr_io):
            trig.start(cfg, dispatcher)
        dispatcher.dispatch.assert_not_called()
        self.assertIn("config.typed is None", stderr_io.getvalue())

    def test_slow_run_coalesces_missed_ticks(self) -> None:
        """A previous run that overran the cadence must NOT produce a
        backlog storm — the cursor advances past ``now`` in one hop,
        matching the legacy on_duplicate_agent semantics.

        Regression test for: ``* * * * *`` schedule, dispatch takes
        5 minutes, naive advance-from-planned would fire 4 more times
        back-to-back after the first dispatch returned (one for each
        minute in the past).  Fix: coalesce into one skip.
        """
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg([
            {"name": "minutely", "schedule": "* * * * *", "prompt": "p"},
        ])
        dispatcher = MagicMock()
        dispatch_count = {"n": 0}

        def stop_after_first(_job):
            dispatch_count["n"] += 1
            trig.stop()
            return AgentResult(exit_code=0, response="")
        dispatcher.dispatch.side_effect = stop_after_first

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        # Simulates "dispatch took 5 minutes."  By the time we're back
        # in the loop the clock is at 12:05 but the last planned fire
        # was 12:00.  Naive advance would fire for 12:01/02/03/04
        # before the while-condition check.
        late = base + timedelta(minutes=5)
        # now_utc call sites: (1) seed, (2) top-of-loop, (3) post-wait,
        # (4) coalesce-probe after dispatch.
        call_times = iter([base, late, late, late])

        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        self.assertEqual(
            dispatch_count["n"], 1,
            "expected exactly one dispatch; backlog storm regression",
        )
        output = stderr_io.getvalue()
        self.assertIn("coalesced", output)
        self.assertIn("missed tick", output)

    def test_on_time_run_does_not_coalesce(self) -> None:
        """Normal on-time runs must NOT log coalesce — only overruns do."""
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg([
            {"name": "hourly", "schedule": "@every 1h", "prompt": "p"},
        ])
        dispatcher = MagicMock()

        def stop_after_first(_job):
            trig.stop()
            return AgentResult(exit_code=0, response="")
        dispatcher.dispatch.side_effect = stop_after_first

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        # "Slight overrun" model: first fire planned at base+1h, actual
        # dispatch returned 5s later.  Post-fire advance gives base+2h
        # which is strictly after now (base+1h+5s) → no coalesce.
        past_fire = base + timedelta(hours=1, seconds=5)
        call_times = iter([base, past_fire, past_fire, past_fire])

        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        self.assertNotIn("coalesced", output)


# ── Seed boundary race (P1a) ──────────────────────────────────────


class SeedBoundaryRaceTests(unittest.TestCase):
    """Regression: per-schedule ``now_utc()`` calls at seed time could
    straddle a schedule's fire boundary, making identical schedules
    diverge by a full cron period.
    """

    def test_seed_uses_single_now_utc_call(self) -> None:
        """Three identical schedules must all produce the same first
        fire time — which requires seeding against a single ``now``."""
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg([
            {"name": f"s{i}", "schedule": "0 9 * * *", "prompt": "p"}
            for i in range(3)
        ])

        call_count = 0
        far_future = datetime(2030, 1, 1, tzinfo=timezone.utc)

        def spy_now():
            nonlocal call_count
            call_count += 1
            return far_future

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        done = threading.Event()

        def runner():
            with patch.object(expr_mod, "now_utc", spy_now):
                with patch("sys.stderr", io.StringIO()):
                    trig.start(cfg, MagicMock())
            done.set()

        t = threading.Thread(target=runner, daemon=True)
        t.start()
        time.sleep(0.05)
        trig.stop()
        self.assertTrue(done.wait(timeout=2.0))

        # Expected call pattern (fixed): 1 seed + 1 top-of-loop + (0 or
        # 1 post-wait depending on when stop landed) = 2 or 3.  Buggy
        # per-schedule seed with 3 schedules would be 3 + 1 or 2 = 4-5.
        self.assertLessEqual(
            call_count, 3,
            f"now_utc called {call_count} times — expected <=3; "
            f"regression in per-schedule seeding (3 schedules × 1 "
            f"seed call each = 3 seed calls instead of 1)",
        )


# ── Jitter semantics (P1b and @every preservation) ─────────────────


class JitterBehaviorTests(unittest.TestCase):
    """Jitter is baked into the stored fire time (``next_fires``) at
    compute time, not applied as a sleep in ``_fire_one``.  This is
    load-bearing for two properties:

      * A jittered schedule does not block other schedules that come
        due during its jitter window (the main loop's natural wait
        handles the jitter and wakes for any earlier fire).
      * ``@every Nh`` keeps "at least N hours between actual fires"
        because advancement happens from the jittered fire, not the
        planned fire.
    """

    def _schedules(self, entries: list[dict]):
        return parse_schedules(json.dumps(entries))

    def test_jitter_applied_to_stored_fire_time(self) -> None:
        """With jitter=300 and mocked randint=180, the fire time is
        planned + 180s, not planned."""
        schedules = self._schedules([
            {"name": "a", "schedule": "@every 1h",
             "jitter_secs": 300, "prompt": "p"},
        ])
        s = schedules[0]
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        from hivemoot_agent.plugins_builtin.cron import trigger as trig_mod
        with patch.object(trig_mod.random, "randint", return_value=180):
            fire = _compute_next_fire(s, base)
        self.assertEqual(fire, base + timedelta(hours=1, seconds=180))

    def test_jitter_does_not_affect_other_schedules(self) -> None:
        """Two schedules sharing a seed: one with jitter, one without.
        The unjittered schedule's fire time must not be shifted by
        the other's jitter — which can only hold if jitter is per-
        schedule state (baked into each entry), not a shared sleep."""
        schedules = self._schedules([
            {"name": "a", "schedule": "@every 1h",
             "jitter_secs": 300, "prompt": "p"},
            {"name": "b", "schedule": "@every 1h", "prompt": "p"},
        ])
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        from hivemoot_agent.plugins_builtin.cron import trigger as trig_mod
        with patch.object(trig_mod.random, "randint", return_value=240):
            a_fire = _compute_next_fire(schedules[0], base)
            b_fire = _compute_next_fire(schedules[1], base)
        self.assertEqual(a_fire, base + timedelta(hours=1, seconds=240))
        self.assertEqual(b_fire, base + timedelta(hours=1))
        # B fires *before* A — A's jitter cannot delay B.
        self.assertLess(b_fire, a_fire)

    def test_every_advances_from_effective_fire(self) -> None:
        """@every 1h with jitter: next fire MUST be at least 1h after
        the previous actual (jittered) fire.  Regression: advancing
        from planned let a fire at 13:05 schedule the next at 14:00
        (only 55 min elapsed)."""
        schedules = self._schedules([
            {"name": "hourly", "schedule": "@every 1h",
             "jitter_secs": 300, "prompt": "p"},
        ])
        s = schedules[0]
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        from hivemoot_agent.plugins_builtin.cron import trigger as trig_mod

        # Worst case: first jitter is max (+300s), second jitter is 0.
        # If advancement were from planned, fire2 would be exactly
        # fire1.planned + 1h = 14:00 = only 55 min after fire1 (13:05).
        # With effective-based advancement, fire2 is fire1 + 1h = 14:05.
        with patch.object(trig_mod.random, "randint",
                          side_effect=[300, 0]):
            fire1 = _compute_next_fire(s, base)
            fire2 = _compute_next_fire(s, fire1)

        elapsed = (fire2 - fire1).total_seconds()
        self.assertGreaterEqual(
            elapsed, 3600,
            f"elapsed {elapsed}s < 3600s; @every 1h semantics violated",
        )

    def test_cron_advance_preserves_anchor_through_jitter(self) -> None:
        """For cron expressions, jitter must NOT drift the anchor:
        ``0 9 * * *`` must fire at 09:00 tomorrow no matter where
        within today's jitter window the actual fire landed."""
        schedules = self._schedules([
            {"name": "daily9am", "schedule": "0 9 * * *",
             "jitter_secs": 300, "prompt": "p"},
        ])
        s = schedules[0]
        # Seed at 8am, jitter +240s → fire 1 lands at 09:04 today.
        base = datetime(2026, 4, 18, 8, 0, tzinfo=timezone.utc)
        from hivemoot_agent.plugins_builtin.cron import trigger as trig_mod
        with patch.object(trig_mod.random, "randint",
                          side_effect=[240, 0]):
            fire1 = _compute_next_fire(s, base)
            fire2 = _compute_next_fire(s, fire1)

        # Fire 2 planned is 09:00 tomorrow (cron anchor), with 0 jitter.
        self.assertEqual(
            fire2.replace(tzinfo=timezone.utc),
            datetime(2026, 4, 19, 9, 0, tzinfo=timezone.utc),
        )

    def test_zero_jitter_reduces_to_planned(self) -> None:
        """jitter_secs=0 must yield fire time exactly at the planned
        slot — no off-by-one from random.randint(0, 0)."""
        schedules = self._schedules([
            {"name": "a", "schedule": "@every 1h", "prompt": "p"},
        ])
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        fire = _compute_next_fire(schedules[0], base)
        self.assertEqual(fire, base + timedelta(hours=1))


# ── Backoff tests ────────────────────────────────────────────────


class BackoffTests(unittest.TestCase):
    """Exponential backoff on quota/auth failures."""

    def test_quota_failure_applies_backoff(self) -> None:
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg(
            [{"name": "job", "schedule": "@every 1h", "prompt": "p"}],
            quota_backoff_secs=600, quota_backoff_max_secs=3600,
        )

        fire_count = {"n": 0}
        next_fire_after_backoff: list[datetime] = []

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        past_fire = base + timedelta(hours=2)
        now_after = base + timedelta(hours=2, seconds=1)

        def dispatch(job):
            fire_count["n"] += 1
            trig.stop()
            return AgentResult(exit_code=1, response="", failure_kind="quota")

        dispatcher = MagicMock()
        dispatcher.dispatch.side_effect = dispatch

        call_times = iter([base, past_fire, past_fire, now_after])
        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        self.assertIn("quota failure", output)
        self.assertIn("backing off 600s", output)
        expected_next = now_after + timedelta(seconds=600)
        self.assertIn(expected_next.isoformat(), output)

    def test_consecutive_quota_failures_double_backoff(self) -> None:
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg(
            [{"name": "job", "schedule": "@every 1h", "prompt": "p"}],
            quota_backoff_secs=600, quota_backoff_max_secs=3600,
        )

        fire_count = {"n": 0}

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        # First fire at base+2h, second fire at base+2h+600s+1s
        first_fire = base + timedelta(hours=2)
        after_first = base + timedelta(hours=2, seconds=1)
        second_fire = after_first + timedelta(seconds=600)
        after_second = second_fire + timedelta(seconds=1)

        # now_utc calls for two full dispatch cycles:
        # seed, top-of-loop-1, post-wait-1, now_after-1,
        # top-of-loop-2, post-wait-2, now_after-2
        call_times = iter([
            base,
            first_fire, first_fire, after_first,
            second_fire, second_fire, after_second,
        ])

        def dispatch(job):
            fire_count["n"] += 1
            if fire_count["n"] >= 2:
                trig.stop()
            return AgentResult(exit_code=1, response="", failure_kind="quota")

        dispatcher = MagicMock()
        dispatcher.dispatch.side_effect = dispatch

        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        self.assertEqual(fire_count["n"], 2)
        self.assertIn("backing off 600s", output)
        self.assertIn("backing off 1200s", output)

    def test_backoff_resets_on_success(self) -> None:
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg(
            [{"name": "job", "schedule": "@every 1h", "prompt": "p"}],
            quota_backoff_secs=600, quota_backoff_max_secs=3600,
        )

        fire_count = {"n": 0}

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        first_fire = base + timedelta(hours=2)
        after_first = base + timedelta(hours=2, seconds=1)
        second_fire = after_first + timedelta(seconds=600)
        after_second = second_fire + timedelta(seconds=1)

        # now_utc: seed, loop1-top, loop1-wait, loop1-after,
        #          loop2-top, loop2-wait, loop2-after (coalesce probe)
        call_times = iter([
            base,
            first_fire, first_fire, after_first,
            second_fire, second_fire, after_second,
        ])

        def dispatch(job):
            fire_count["n"] += 1
            if fire_count["n"] >= 2:
                trig.stop()
            if fire_count["n"] == 1:
                return AgentResult(exit_code=1, response="", failure_kind="quota")
            return AgentResult(exit_code=0, response="ok")

        dispatcher = MagicMock()
        dispatcher.dispatch.side_effect = dispatch

        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        self.assertEqual(fire_count["n"], 2)
        self.assertIn("backing off 600s", output)
        self.assertNotIn("backing off 1200s", output)

    def test_rate_limited_applies_backoff(self) -> None:
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg(
            [{"name": "job", "schedule": "@every 1h", "prompt": "p"}],
            quota_backoff_secs=600, quota_backoff_max_secs=3600,
        )

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        past_fire = base + timedelta(hours=2)
        now_after = base + timedelta(hours=2, seconds=1)

        def dispatch(job):
            trig.stop()
            return AgentResult(exit_code=1, response="", failure_kind="rate_limited")

        dispatcher = MagicMock()
        dispatcher.dispatch.side_effect = dispatch

        call_times = iter([base, past_fire, past_fire, now_after])
        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        self.assertIn("rate_limited failure", output)
        self.assertIn("backing off 600s", output)

    def test_no_backoff_on_transient_failure(self) -> None:
        trig = CronTrigger(MagicMock())
        cfg = _make_cfg(
            [{"name": "job", "schedule": "@every 1h", "prompt": "p"}],
            quota_backoff_secs=600, quota_backoff_max_secs=3600,
        )

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        past_fire = base + timedelta(hours=2)
        now_after = base + timedelta(hours=2, seconds=1)

        def dispatch(job):
            trig.stop()
            return AgentResult(exit_code=1, response="", failure_kind="")

        dispatcher = MagicMock()
        dispatcher.dispatch.side_effect = dispatch

        # need extra call for coalesce probe since it follows normal path
        call_times = iter([base, past_fire, past_fire, now_after, now_after])
        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        self.assertNotIn("backing off", output)

    def test_backoff_never_fires_sooner_than_normal_schedule(self) -> None:
        """max(normal_next, now+delay) — backoff must not accelerate the schedule.

        Regression test for the initial implementation that used
        ``now + delay`` without max(), which for a 600s backoff on an
        hourly schedule would retry in 10 min instead of waiting for
        the next scheduled tick.
        """
        trig = CronTrigger(MagicMock())
        # Small explicit backoff (300s) that is much less than the 1h interval.
        cfg = _make_cfg(
            [{"name": "job", "schedule": "@every 1h", "prompt": "p"}],
            quota_backoff_secs=300, quota_backoff_max_secs=3600,
        )

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod

        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        # Fire at exactly the first scheduled tick (on time, not late).
        on_time_fire = base + timedelta(hours=1)
        # Job finishes 5 seconds after the scheduled tick.
        now_after = on_time_fire + timedelta(seconds=5)

        def dispatch(job):
            trig.stop()
            return AgentResult(exit_code=1, response="", failure_kind="quota")

        dispatcher = MagicMock()
        dispatcher.dispatch.side_effect = dispatch

        # Calls: seed, top-of-loop, post-wait, now_after.
        call_times = iter([base, on_time_fire, on_time_fire, now_after])
        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        self.assertIn("quota failure", output)
        self.assertIn("backing off 300s", output)
        # The next fire time must be >= next normal cron tick (base+2h),
        # NOT now+300s (= base+1h+5s+300s ≈ base+1h5m5s).
        normal_next = base + timedelta(hours=2)
        # Extract the isoformat from the log line.
        import re
        m = re.search(r"next fire at ([^\)]+)\)", output)
        self.assertIsNotNone(m, "expected 'next fire at ...' in log")
        logged_next = datetime.fromisoformat(m.group(1))
        self.assertGreaterEqual(
            logged_next, normal_next,
            f"backoff scheduled next fire at {logged_next}, before normal "
            f"next tick {normal_next} — backoff must not accelerate schedule",
        )

    def test_default_backoff_skips_at_least_one_hourly_cycle(self) -> None:
        """Default quota_backoff_secs=7200 guarantees ≥1 skipped cycle for hourly schedules.

        At default 7200s floor: max(next_hour, now+7200) = now+7200 > next_hour for
        any failure within the first hour.  This is the timing guarantee from #392.
        """
        trig = CronTrigger(MagicMock())
        # Use default config (7200/86400).
        cfg = _make_cfg([{"name": "job", "schedule": "@every 1h", "prompt": "p"}])

        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod

        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        on_time_fire = base + timedelta(hours=1)
        now_after = on_time_fire + timedelta(seconds=5)

        def dispatch(job):
            trig.stop()
            return AgentResult(exit_code=1, response="", failure_kind="quota")

        dispatcher = MagicMock()
        dispatcher.dispatch.side_effect = dispatch

        call_times = iter([base, on_time_fire, on_time_fire, now_after])
        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        # Extract the scheduled next fire time.
        import re
        m = re.search(r"next fire at ([^\)]+)\)", output)
        self.assertIsNotNone(m, "expected 'next fire at ...' in log")
        logged_next = datetime.fromisoformat(m.group(1))
        # With 7200s floor: next fire at now+7200 = base+1h+5s+7200s
        # Normal next tick = base+2h.  7200s > 3600s so we skip the 2h tick.
        two_ticks_out = base + timedelta(hours=2)
        self.assertGreater(
            logged_next, two_ticks_out,
            f"expected next fire after {two_ticks_out} (skipping one cycle); "
            f"got {logged_next}",
        )

    def test_none_dispatch_preserves_active_quota_backoff(self) -> None:
        """dispatch() returning None must not clear active quota backoff.

        Regression test for the P1 bug where the original `else` branch fired
        for `result is None`, calling `quota_backoff.pop()` and erasing an
        active backoff written by a prior quota failure.  Concrete failure path:
        quota hit → backoff set → next fire deferred → dispatch raises exception
        (None) → backoff cleared → crash loop resumes on normal schedule.
        """
        from hivemoot_agent.plugins_builtin.cron import expression as expr_mod

        trig = CronTrigger(MagicMock())
        cfg = _make_cfg(
            [{"name": "job", "schedule": "@every 1h", "prompt": "p"}],
            quota_backoff_secs=7200, quota_backoff_max_secs=86400,
        )

        fire_count = {"n": 0}
        base = datetime(2026, 4, 18, 12, 0, tzinfo=timezone.utc)
        # First fire: exactly at scheduled time (base+1h), quota failure.
        first_fire = base + timedelta(hours=1)
        after_first = first_fire + timedelta(seconds=1)
        # After quota failure: next_fires["job"] = max(base+2h, after_first+7200s)
        # = max(base+2h, base+1h+1s+2h) = base+3h+1s.
        # Second fire: arrive exactly at that deferred time so delay=0.
        second_fire = base + timedelta(hours=3, seconds=1)
        after_second = second_fire + timedelta(seconds=1)

        def dispatch(job):
            fire_count["n"] += 1
            if fire_count["n"] == 1:
                # First run: quota failure — backoff written.
                return AgentResult(exit_code=1, response="", failure_kind="quota")
            # Second run: dispatch exception → None — must preserve backoff.
            trig.stop()
            return None

        dispatcher = MagicMock()
        dispatcher.dispatch.side_effect = dispatch

        # now_utc() call sequence (2 calls per loop iteration + 1 seed + 1
        # now_after per fired schedule):
        #   seed, iter1-top, iter1-post-sleep, iter1-now_after,
        #   iter2-top, iter2-post-sleep, iter2-now_after
        call_times = iter([
            base,
            first_fire, first_fire, after_first,
            second_fire, second_fire, after_second,
        ])

        stderr_io = io.StringIO()
        with patch.object(expr_mod, "now_utc", lambda: next(call_times)):
            with patch("sys.stderr", stderr_io):
                trig.start(cfg, dispatcher)

        output = stderr_io.getvalue()
        # First fire: quota failure → backoff applied.
        self.assertIn("quota failure", output)
        self.assertIn("backing off 7200s", output)
        # Second fire returned None — no second "backing off" line means the
        # None path did not escalate the backoff, and more importantly, it did
        # not clear it via the old `else` branch.  If clearing had occurred,
        # the next quota failure would show "backing off 7200s" (reset to floor)
        # instead of "backing off 14400s" (doubled).
        backoff_lines = [l for l in output.splitlines() if "backing off" in l]
        self.assertEqual(
            len(backoff_lines), 1,
            f"expected exactly one 'backing off' log (from quota failure); "
            f"got {len(backoff_lines)}: {backoff_lines}",
        )


if __name__ == "__main__":
    unittest.main()
