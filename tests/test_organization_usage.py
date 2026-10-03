from datetime import datetime, timezone
import unittest
from unittest.mock import Mock

import requests

from api_clients import check_api
from organization_usage import check_organization_usage
from providers import PROVIDERS


class OrganizationUsageTests(unittest.TestCase):
    def client(self, pages, codes=None):
        codes = codes or [200] * len(pages)
        return Mock(get=Mock(side_effect=[Mock(status_code=code, json=Mock(return_value=page)) for page, code in zip(pages, codes)]))

    def report(self, rows=(), more=False, cursor=None):
        return {"data": [{"results": list(rows)}], "has_more": more, "next_page": cursor}

    def test_openai_cache_is_not_double_counted_and_pages_are_combined(self):
        client = self.client([self.report([{"input_tokens": 100, "input_cached_tokens": 90, "output_tokens": 20}], True, "second"),
                              self.report([{"input_tokens": 300, "output_tokens": 50}])])
        result = check_organization_usage("openai_usage", "fixture", client, now=datetime(2026, 10, 1, 12, tzinfo=timezone.utc))
        self.assertTrue(result.authenticated)
        self.assertEqual(result.value, "470")
        self.assertEqual(result.metrics, [("Input inkl. Cache", "400"), ("Output", "70")])
        first, second = client.get.call_args_list
        self.assertEqual(first.kwargs["headers"]["Authorization"], "Bearer fixture")
        self.assertEqual(first.kwargs["params"]["bucket_width"], "1d")
        self.assertEqual(first.kwargs["params"]["start_time"], int(datetime(2026, 9, 25, tzinfo=timezone.utc).timestamp()))
        self.assertNotIn("page", first.kwargs["params"])
        self.assertEqual(second.kwargs["params"]["page"], "second")
        self.assertEqual(first.args[0], PROVIDERS["openai_usage"].endpoint)
        self.assertFalse(first.kwargs["allow_redirects"])

    def test_anthropic_cache_reads_and_both_write_windows_are_included(self):
        client = self.client([self.report([{"uncached_input_tokens": 100, "cache_read_input_tokens": 200,
                                         "cache_creation": {"ephemeral_5m_input_tokens": 30, "ephemeral_1h_input_tokens": 40},
                                         "output_tokens": 50}])])
        result = check_api("anthropic_usage", "fixture", client)
        self.assertTrue(result.authenticated)
        self.assertEqual(result.value, "420")
        self.assertEqual(result.metrics[0], ("Input inkl. Cache", "370"))
        call = client.get.call_args
        self.assertEqual(call.kwargs["headers"]["x-api-key"], "fixture")
        self.assertIn("starting_at", call.kwargs["params"])
        self.assertNotIn("Authorization", call.kwargs["headers"])

    def test_empty_valid_usage_is_zero_not_missing(self):
        for pid in ("openai_usage", "anthropic_usage"):
            result = check_api(pid, "fixture", self.client([{"data": [], "has_more": False}]))
            self.assertTrue(result.authenticated)
            self.assertEqual(result.value, "0")

    def test_normal_key_permissions_and_expired_access_do_not_connect(self):
        for pid in ("openai_usage", "anthropic_usage"):
            for code, status in ((401, "unauthorized"), (403, "error"), (429, "warning"), (500, "error")):
                result = check_api(pid, "fixture", self.client([{}], [code]))
                self.assertFalse(result.authenticated)
                self.assertEqual(result.status, status)

    def test_incomplete_or_changed_reports_never_show_partial_totals(self):
        row = {"input_tokens": 100, "output_tokens": 50}
        for pages in ([{}], [self.report([{"input_tokens": True, "output_tokens": 50}])],
                      [self.report([{"input_tokens": -1, "output_tokens": 50}])],
                      [self.report([row], True, None)],
                      [self.report([row], True, "again"), self.report([row], True, "again")],
                      [self.report([row], True, "second"), {}]):
            result = check_api("openai_usage", "fixture", self.client(pages))
            self.assertFalse(result.authenticated)
            self.assertEqual(result.status, "error")
            self.assertNotIn("150", result.value)

    def test_connection_failure_keeps_retryable_status(self):
        result = check_api("openai_usage", "fixture", Mock(get=Mock(side_effect=requests.Timeout)))
        self.assertEqual(result.status, "error")


if __name__ == "__main__":
    unittest.main()
