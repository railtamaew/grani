from api.admin_metrics import _build_egress_risk, _build_egress_remediation_actions


def test_build_egress_risk_ok():
    risk = _build_egress_risk(
        conntrack_count=1000,
        conntrack_max=100000,
        ip_forward_enabled=True,
        has_forward_accept_rule=True,
    )
    assert risk["level"] == "ok"
    assert risk["reasons"] == []


def test_build_egress_risk_warn_on_conntrack():
    risk = _build_egress_risk(
        conntrack_count=90000,
        conntrack_max=100000,
        ip_forward_enabled=True,
        has_forward_accept_rule=True,
    )
    assert risk["level"] == "warn"
    assert "conntrack_saturation_ge_85pct" in risk["reasons"]


def test_build_egress_risk_critical_on_ip_forward_off():
    risk = _build_egress_risk(
        conntrack_count=97000,
        conntrack_max=100000,
        ip_forward_enabled=False,
        has_forward_accept_rule=False,
    )
    assert risk["level"] == "critical"
    assert "ip_forward_disabled" in risk["reasons"]


def test_build_egress_remediation_actions():
    actions = _build_egress_remediation_actions(
        [
            "conntrack_saturation_ge_85pct",
            "forward_chain_accept_rule_not_detected",
        ]
    )
    joined = " ".join(actions).lower()
    assert "nf_conntrack_max" in joined
    assert "forward chain" in joined
