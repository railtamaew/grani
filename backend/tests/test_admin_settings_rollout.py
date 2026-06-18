from api.admin_settings import (
    _is_promotion_eligible,
    _normalize_rollout_policy,
    _should_auto_rollback,
    _next_promotion_percent,
)


def test_normalize_rollout_policy_merges_defaults():
    policy = _normalize_rollout_policy({"enabled": True, "thresholds": {"probe_timeout_rate": 0.5}})
    assert policy["enabled"] is True
    assert policy["thresholds"]["probe_timeout_rate"] == 0.5
    assert "false_connected_rate" in policy["thresholds"]


def test_should_auto_rollback_triggers_on_thresholds():
    policy = _normalize_rollout_policy(
        {
            "enabled": True,
            "auto_rollback_enabled": True,
            "thresholds": {
                "false_connected_rate": 0.1,
                "probe_timeout_rate": 0.2,
                "min_connected_local_total": 10,
            },
        }
    )
    decision = _should_auto_rollback(
        policy=policy,
        sli={"false_connected_rate": 0.12, "probe_timeout_rate": 0.05},
        connected_local_total=20,
    )
    assert decision["rollback"] is True
    assert "false_connected_rate_above_threshold" in decision["reasons"]


def test_should_auto_rollback_respects_sample_size():
    policy = _normalize_rollout_policy({"enabled": True})
    decision = _should_auto_rollback(
        policy=policy,
        sli={"false_connected_rate": 0.9, "probe_timeout_rate": 0.9},
        connected_local_total=1,
    )
    assert decision["rollback"] is False
    assert "insufficient_sample_size" in decision["reasons"]


def test_next_promotion_percent():
    policy = _normalize_rollout_policy(
        {"enabled": True, "current_percent": 10, "promotion_steps": [10, 50, 100]}
    )
    assert _next_promotion_percent(policy) == 50

    policy["current_percent"] = 100
    assert _next_promotion_percent(policy) is None


def test_promotion_not_eligible_with_insufficient_sample():
    policy = _normalize_rollout_policy({"enabled": True, "auto_promotion_enabled": True})
    decision = _is_promotion_eligible(
        policy=policy,
        sli={"false_connected_rate": 0.01, "probe_timeout_rate": 0.01},
        connected_local_total=0,
    )
    assert decision["eligible"] is False
    assert "insufficient_sample_size" in decision["reasons"]
