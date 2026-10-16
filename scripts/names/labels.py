"""Display-name normalization. No chat or transcript discovery."""
MAX_NAME_LENGTH = 80


def clean(value):
    return ''.join(c for c in str(value) if c.isprintable()).strip()[:MAX_NAME_LENGTH] or None
