"""Compatibility helpers for the original module; connections live in manager.py."""
from api_clients import check_api
from browser_sessions import extract_usage


def get_openrouter_stats(api_key):
    result = check_api("openrouter", api_key)
    return {"credits": result.value, "info": result.detail}


def extract_stats_from_text(text, name=""):
    result = extract_usage(text, name.lower())
    return {"credits": result.value, "info": result.detail}
