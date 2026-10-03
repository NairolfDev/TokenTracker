from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from browser_sessions import BrowserSessions
from gemini_usage import reset_at
from subscription_usage import empty_quota, page_usage


class GeminiQuotaTests(unittest.TestCase):
    def test_current_german_usage_page_with_nbsp_and_zero(self):
        result = page_usage('Nutzungslimits\nPRO\nAktuelle Nutzung\n0\u00a0% genutzt\nWird um 14:56 zurückgesetzt\n'
                            'Wöchentliches Limit\nWird am 7. Okt. um 09:56 zurückgesetzt\n6\u00a0% genutzt', 'gemini_chat')
        self.assertEqual([w.remaining_percent for w in result.windows], [100, 94])
        self.assertEqual(result.value, '94%')
        self.assertEqual(result.label, 'Woche übrig')

    def test_english_current_usage_and_unknown_weekly_value(self):
        result = page_usage('Current usage\n25% used\nWeekly limit\nLoading', 'gemini_chat')
        self.assertEqual(result.windows[0].remaining_percent, 75)
        self.assertIsNone(result.windows[1].remaining_percent)

    def test_local_german_reset_times(self):
        now = datetime(2026, 10, 2, 14, 20, tzinfo=timezone(timedelta(hours=2)))
        self.assertEqual(reset_at('Wird um 14:56 zurückgesetzt', 'five_hour', now), '2026-10-02T14:56:00+02:00')
        self.assertEqual(reset_at('Wird am 7. Okt. um 09:56 zurückgesetzt', 'seven_day', now), '2026-10-07T09:56:00+02:00')

    def test_reset_across_midnight_and_new_year(self):
        now = datetime(2026, 12, 31, 23, tzinfo=timezone.utc)
        self.assertEqual(reset_at('Wird um 02:15 zurückgesetzt', 'five_hour', now), '2027-01-01T02:15:00+00:00')
        self.assertEqual(reset_at('Wird am 3. Jan. um 09:56 zurückgesetzt', 'seven_day', now), '2027-01-03T09:56:00+00:00')
        self.assertEqual(reset_at('Resets on Jan 3 at 9:56 AM', 'seven_day', now), '2027-01-03T09:56:00+00:00')

    def test_elapsed_reset_does_not_turn_into_tomorrow_or_grant_capacity(self):
        now = datetime(2026, 10, 2, 14, 57, tzinfo=timezone.utc)
        self.assertEqual(reset_at('Wird um 14:56 zurückgesetzt', 'five_hour', now), '2026-10-02T14:56:00+00:00')
        for text in ('Wird um 25:99 zurückgesetzt', 'Wird am 32. Okt. um 09:56 zurückgesetzt',
                     'Wird am 7. Unknown um 09:56 zurückgesetzt', 'Reset nicht verfügbar'):
            self.assertIsNone(reset_at(text, 'seven_day', now))

    def test_reader_waits_for_both_values_in_the_usage_component(self):
        page = Mock(url='https://gemini.google.com/usage')
        page.is_closed.return_value = False
        components = Mock()
        components.count.return_value = 1
        component = Mock()
        component.is_visible.return_value = True
        component.inner_text.side_effect = ['Aktuelle Nutzung\n0% genutzt',
                                            'Aktuelle Nutzung\n0% genutzt\nWöchentliches Limit\n6% genutzt']
        components.nth.return_value = component
        page.locator.return_value = components
        result = BrowserSessions()._wait_gemini_quota(page, empty_quota('Gemini', authenticated=True), dedicated=True)
        self.assertEqual([w.remaining_percent for w in result.windows], [100, 94])
        self.assertEqual(page.wait_for_timeout.call_count, 2)
        page.locator.assert_called_with('usage-metrics-window')

    def test_usage_redirect_to_chat_never_reads_chat_percentages(self):
        page = Mock(url='https://gemini.google.com/app')
        page.is_closed.return_value = False
        result = BrowserSessions()._wait_gemini_quota(page, empty_quota('Gemini', authenticated=True), dedicated=True)
        self.assertTrue(result.authenticated)
        self.assertTrue(all(w.remaining_percent is None for w in result.windows))
        page.locator.assert_not_called()


if __name__ == '__main__':
    unittest.main()
