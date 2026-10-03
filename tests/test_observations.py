import unittest

from observed_usage import claude_usage, observation


class ObservedUsageTests(unittest.TestCase):
    def test_claude_tracks_session_and_week_including_zero(self):
        result = claude_usage({"five_hour": {"utilization": 0, "resets_at": "2026-10-01T16:00:00Z"},
                              "seven_day": {"utilization": 96}})
        self.assertTrue(result.authenticated)
        self.assertEqual(result.value, "4%")
        self.assertEqual(result.status, "warning")
        self.assertEqual([w.remaining_percent for w in result.windows], [100, 4])
        self.assertIn(("Woche übrig", "4% übrig"), result.metrics)

    def test_invalid_or_changed_quota_schema_is_unavailable(self):
        for payload in ({}, [], {"five_hour": {"utilization": "NaN"}},
                        {"five_hour": {"utilization": 150}}, {"five_hour": {"utilization": -1}}):
            self.assertIsNone(claude_usage(payload))

    def test_guest_auth_session_is_not_login(self):
        self.assertEqual(observation("chatgpt", "https://chatgpt.com/api/auth/session", 200, {}), (False, None))
        self.assertEqual(observation("chatgpt", "https://chatgpt.com/api/auth/session", 200, {"user": {}}), (False, None))

    def test_verified_identity_does_not_depend_on_cookie_name(self):
        for pid, host in (("chatgpt", "chatgpt.com"), ("perplexity", "www.perplexity.ai")):
            self.assertEqual(observation(pid, "https://"+host+"/api/auth/session", 200, {"user": {"id": "fixture-user"}}), (True, None))

    def test_email_identity_and_unknown_schema_do_not_report_logout(self):
        url = "https://chatgpt.com/api/auth/session"
        self.assertEqual(observation("chatgpt", url, 200, {"user": {"email": "fixture@example.invalid"}}), (True, None))
        self.assertIsNone(observation("chatgpt", url, 200, {"user": {"new_identity": "unsupported"}}))
        self.assertIsNone(observation("chatgpt", url, 200, {"changed_session_schema": True}))
        self.assertIsNone(observation("chatgpt", "https://chatgpt.com/backend-api/me", 200, {"changed_schema": True}))

    def test_foreign_domains_and_chat_content_are_not_measurements(self):
        payload = {"five_hour": {"utilization": 35}}
        self.assertIsNone(observation("claude", "https://evil.example/api/organizations/fixture/usage", 200, payload))
        self.assertIsNone(observation("claude", "https://claude.ai/api/organizations/fixture/chat_conversations/usage", 200, payload))

    def test_usage_response_and_logout_are_distinct(self):
        url = "https://claude.ai/api/organizations/fixture/usage"
        identity, usage = observation("claude", url, 200, {"five_hour": {"utilization": 75}})
        self.assertTrue(identity)
        self.assertEqual(usage.progress, .25)
        self.assertEqual(observation("claude", url, 401, {}), (False, None))


if __name__ == "__main__":
    unittest.main()
