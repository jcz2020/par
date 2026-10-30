"""Content constructors using the SDK's existing tagged-array JSON format."""

import base64
import binascii
from pathlib import Path
from typing import Any, Literal


ContentBlock = list[Any]
ImageDetail = Literal["auto", "low", "high"]

#: Largest image payload PAR carries inline in one block, in decoded bytes.
#: Five mebibytes is the per-image cap Anthropic documents; OpenAI allows more,
#: so this is the conservative default. Pass ``max_bytes=`` to raise it.
MAX_IMAGE_BYTES = 5 * 1024 * 1024

#: The image MIME types PAR's providers can transmit. A type outside this set
#: would be rejected downstream, so the data constructors reject it here.
SUPPORTED_IMAGE_MEDIA_TYPES = frozenset(
    {"image/png", "image/jpeg", "image/gif", "image/webp"}
)

_MEDIA_TYPES_BY_SUFFIX = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
}


class ImageError(ValueError):
    """Raised when input cannot be turned into a valid image block.

    Subclasses :class:`ValueError`, so callers that already catch ``ValueError``
    keep working. A missing or unreadable file still raises :class:`OSError`;
    this is for content that is readable but not valid.
    """


def text(value: str) -> ContentBlock:
    """Build a text block for :meth:`Runtime.invoke_content`."""
    return ["Text_block", {"text": value, "cache_control": None}]


def image_url(
    url: str, *, media_type: str = "image/png", detail: ImageDetail | None = None,
) -> ContentBlock:
    """Reference a remote image; the provider, not PAR, fetches the URL.

    ``media_type`` is a hint forwarded to the provider, which sniffs the bytes
    it downloads, so it is not validated here.
    """
    return ["Image_block", {
        "source": ["Url", url], "media_type": media_type, "data": "",
        "detail": detail, "cache_control": None,
    }]


def _check_media_type(media_type: str, *, what: str) -> str:
    if media_type not in SUPPORTED_IMAGE_MEDIA_TYPES:
        supported = ", ".join(sorted(SUPPORTED_IMAGE_MEDIA_TYPES))
        raise ImageError(
            f"{what}: unsupported image media type {media_type!r} "
            f"(supported: {supported})"
        )
    return media_type


def _check_max_bytes(max_bytes: int, *, what: str) -> int:
    if max_bytes <= 0:
        raise ImageError(f"{what}: max_bytes must be positive")
    return max_bytes


def _decode_base64(data: str, *, max_bytes: int, what: str) -> bytes:
    """Validate a base64 payload and return its decoded bytes.

    The encoded length is checked first: base64 inflates by 4/3, so rejecting
    an oversized string before decoding keeps an untrusted payload from forcing
    a decoded copy of it.
    """
    if len(data) > ((max_bytes + 2) // 3) * 4:
        raise ImageError(
            f"{what}: encoded data is {len(data)} bytes, "
            f"over the {max_bytes}-byte image limit"
        )
    try:
        decoded = base64.b64decode(data, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ImageError(f"{what}: not valid base64: {exc}") from exc
    if not decoded:
        raise ImageError(f"{what}: empty image data")
    if len(decoded) > max_bytes:
        raise ImageError(
            f"{what}: decoded image is {len(decoded)} bytes, "
            f"over the {max_bytes}-byte image limit"
        )
    return decoded


def image_base64(
    data: str, *, media_type: str = "image/png", detail: ImageDetail | None = None,
    max_bytes: int = MAX_IMAGE_BYTES,
) -> ContentBlock:
    """Build an image block from already base64-encoded bytes.

    The payload is checked rather than trusted: it must be valid base64, it
    must not be empty, and its decoded length must not exceed ``max_bytes``.
    The media type must be one of :data:`SUPPORTED_IMAGE_MEDIA_TYPES`.

    Raises :class:`ImageError` with the reason when a check fails.
    """
    _check_max_bytes(max_bytes, what="image_base64")
    _decode_base64(data, max_bytes=max_bytes, what="image_base64")
    _check_media_type(media_type, what="image_base64")
    return ["Image_block", {
        "source": ["Base64", data], "media_type": media_type, "data": "",
        "detail": detail, "cache_control": None,
    }]


def image_file(
    path: str | Path, *, media_type: str | None = None,
    detail: ImageDetail | None = None, max_bytes: int = MAX_IMAGE_BYTES,
) -> ContentBlock:
    """Read an image from disk and build an inline image block.

    The media type is inferred from the file extension when ``media_type`` is
    not given; an extension outside :data:`SUPPORTED_IMAGE_MEDIA_TYPES` raises
    :class:`ImageError` rather than defaulting, so a mislabelled payload cannot
    reach a provider. Files larger than ``max_bytes`` are rejected without
    being loaded whole, and empty files are rejected too.

    Raises :class:`OSError` when the file cannot be read and
    :class:`ImageError` when it fails a content check.
    """
    _check_max_bytes(max_bytes, what="image_file")
    path = Path(path)
    if media_type is None:
        inferred = _MEDIA_TYPES_BY_SUFFIX.get(path.suffix.lower())
        if inferred is None:
            supported = ", ".join(sorted(SUPPORTED_IMAGE_MEDIA_TYPES))
            raise ImageError(
                f"image_file: cannot infer an image media type from {str(path)!r}; "
                f"pass media_type explicitly (supported: {supported})"
            )
        media_type = inferred
    else:
        _check_media_type(media_type, what="image_file")

    # Read one byte past the limit: enough to tell that the file is too large
    # without loading it whole.
    with path.open("rb") as handle:
        raw = handle.read(max_bytes + 1)
    if not raw:
        raise ImageError(f"image_file: {str(path)!r} is empty")
    if len(raw) > max_bytes:
        raise ImageError(
            f"image_file: {str(path)!r} is over the {max_bytes}-byte image limit"
        )

    encoded = base64.b64encode(raw).decode("ascii")
    return image_base64(
        encoded, media_type=media_type, detail=detail, max_bytes=max_bytes,
    )
