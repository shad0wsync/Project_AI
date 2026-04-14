import re

EMAIL_REGEX = re.compile(
    r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+"
    r"(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*"
    r"@"
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z]{2,}$"
)


def is_valid_email(email: str) -> bool:
    """Return True when the given string is a valid email address.

    This performs a conservative syntactic validation and does not verify
    whether the mailbox actually exists.
    """
    if not isinstance(email, str):
        return False

    return bool(EMAIL_REGEX.fullmatch(email.strip()))


if __name__ == "__main__":
    examples = [
        "user@example.com",
        "user.name+tag@example.co.uk",
        "invalid-email",
        "user@.example.com",
        "user@localhost",
    ]

    for value in examples:
        print(f"{value}: {is_valid_email(value)}")
