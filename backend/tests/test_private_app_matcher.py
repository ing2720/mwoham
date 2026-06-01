from app.services.private_app_matcher import PrivateAppMatcher, PrivateAppRule


def test_private_app_matcher_matches_exact_contains_and_regex() -> None:
    matcher = PrivateAppMatcher()

    assert matcher.is_private_app(
        "KakaoTalk",
        [PrivateAppRule(app_name="KakaoTalk", match_type="exact")],
    )
    assert matcher.is_private_app(
        "Discord Canary",
        [PrivateAppRule(app_name="discord", match_type="contains")],
    )
    assert matcher.is_private_app(
        "BankSecure",
        [PrivateAppRule(app_name="^Bank", match_type="regex")],
    )


def test_private_app_matcher_ignores_disabled_rules() -> None:
    matcher = PrivateAppMatcher()

    assert not matcher.is_private_app(
        "KakaoTalk",
        [PrivateAppRule(app_name="KakaoTalk", match_type="exact", is_enabled=False)],
    )


def test_private_app_matcher_ignores_invalid_regex() -> None:
    matcher = PrivateAppMatcher()

    assert not matcher.is_private_app(
        "BankSecure",
        [PrivateAppRule(app_name="[", match_type="regex")],
    )
