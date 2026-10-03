"""Read Gemini's reported local reset times; never infer remaining capacity."""
from datetime import datetime, timedelta
import re


MONTHS = {
    'jan': 1, 'feb': 2, 'mär': 3, 'märz': 3, 'mar': 3, 'apr': 4,
    'mai': 5, 'may': 5, 'jun': 6, 'juni': 6, 'jul': 7, 'juli': 7,
    'aug': 8, 'sep': 9, 'sept': 9, 'okt': 10, 'oct': 10, 'nov': 11, 'dez': 12, 'dec': 12,
}


def reset_at(text, key, now=None):
    current = now or datetime.now().astimezone()
    horizon = timedelta(hours=5, minutes=1) if key == 'five_hour' else timedelta(days=8)
    patterns = (
        r'Wird\s+(?:am\s+(\d{1,2})\.\s*([A-Za-zÄÖÜäöüß]+)\.?\s+)?um\s+(\d{1,2})[:.](\d{2})\s+zurückgesetzt',
        r'Resets?\s+(?:on\s+([A-Za-z]+)\.?\s+(\d{1,2}),?\s+)?at\s+(\d{1,2}):(\d{2})\s*(AM|PM)?',
    )
    for index, pattern in enumerate(patterns):
        match = re.search(pattern, text, re.I)
        if not match:
            continue
        groups = match.groups()
        day, month = groups[:2] if index == 0 else (groups[1], groups[0])
        hour, minute = int(groups[2]), int(groups[3])
        if index == 1 and groups[4]:
            if not 1 <= hour <= 12:
                return None
            hour = hour % 12 + (12 if groups[4].lower() == 'pm' else 0)
        if hour > 23 or minute > 59:
            return None
        dates = []
        if day and month:
            month_number = MONTHS.get(month.lower())
            if not month_number:
                return None
            for year in (current.year - 1, current.year, current.year + 1):
                try:
                    dates.append(datetime(year, month_number, int(day), hour, minute))
                except ValueError:
                    pass
        else:
            dates = [datetime.combine((current + timedelta(days=offset)).date(), datetime.min.time()).replace(hour=hour, minute=minute)
                     for offset in (0, 1)]
        # astimezone() on a naive local date uses the OS rules for that date,
        # including DST. Injected aware times make tests timezone-independent.
        candidates = [date.replace(tzinfo=current.tzinfo) if now is not None else date.astimezone() for date in dates]
        future = [date for date in candidates if timedelta(0) <= date - current <= horizon]
        if future:
            return min(future).isoformat()
        # Keep a just-elapsed provider reset as elapsed; never grant 100% locally.
        elapsed = [date for date in candidates if timedelta(0) <= current - date <= horizon]
        return max(elapsed).isoformat() if elapsed else None
    return None
