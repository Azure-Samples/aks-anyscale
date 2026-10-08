import os
import random
import re
from io import BytesIO
from urllib.parse import urlsplit

import numpy as np
import requests
from PIL import Image, UnidentifiedImageError

ALLOWED_IMAGE_HOSTS = frozenset({"doggos-dataset.s3.us-west-2.amazonaws.com"})
MAX_IMAGE_BYTES = 5 * 1024 * 1024
MAX_IMAGE_PIXELS = 16_000_000
IMAGE_REQUEST_TIMEOUT = (3.05, 10)
_IMAGE_CHUNK_SIZE = 64 * 1024


def add_class(row):
    row["class"] = row["path"].rsplit("/", 3)[-2]
    return row


def delete_s3_objects(s3_path):
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError

    s3 = boto3.client("s3")
    match = re.match(r"s3://([^/]+)/(.+)", s3_path)
    if not match:
        raise ValueError(f"Invalid S3 path: {s3_path}")
    bucket_name, prefix = match.groups()
    try:
        response = s3.list_objects_v2(Bucket=bucket_name, Prefix=prefix)
        if "Contents" not in response:  # No objects found
            print(f"No objects found at {s3_path}")
            return
        objects_to_delete = [{"Key": obj["Key"]} for obj in response["Contents"]]
        s3.delete_objects(
            Bucket=bucket_name,
            Delete={"Objects": objects_to_delete},
        )
        print(f"Deleted {len(objects_to_delete)} objects from {s3_path}")
    except s3.exceptions.NoSuchBucket:
        print(f"Bucket '{bucket_name}' does not exist.")
    except (BotoCoreError, ClientError) as e:
        print(f"Error deleting objects from {s3_path}: {e}")


def set_seeds(seed=42):
    """Set seeds for reproducibility."""
    import torch

    np.random.seed(seed)
    random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed(seed)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False
    os.environ["PYTHONHASHSEED"] = str(seed)


def image_bytes_to_array(
    image_data,
    *,
    max_bytes=MAX_IMAGE_BYTES,
    max_pixels=MAX_IMAGE_PIXELS,
):
    """Decode a bounded image payload into an RGB NumPy array."""
    if not isinstance(image_data, (bytes, bytearray, memoryview)):
        raise TypeError("Image payload must be bytes")
    if not image_data:
        raise ValueError("Image payload is empty")
    if len(image_data) > max_bytes:
        raise ValueError("Image is too large")

    try:
        with Image.open(BytesIO(image_data)) as image:
            width, height = image.size
            if width <= 0 or height <= 0 or width * height > max_pixels:
                raise ValueError("Image dimensions are too large")
            return np.array(image.convert("RGB"))
    except ValueError:
        raise
    except (Image.DecompressionBombError, UnidentifiedImageError, OSError) as exc:
        raise ValueError("Image payload is invalid") from exc


def _validate_image_url(url):
    if not isinstance(url, str) or len(url) > 2048:
        raise ValueError("Image URL is invalid")

    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError as exc:
        raise ValueError("Image URL is invalid") from exc

    if (
        parsed.scheme != "https"
        or parsed.hostname not in ALLOWED_IMAGE_HOSTS
        or parsed.username is not None
        or parsed.password is not None
        or port not in (None, 443)
    ):
        raise ValueError("Image URL host is not allowed")


def url_to_array(url):
    """Download a tutorial image with SSRF and resource-exhaustion safeguards."""
    _validate_image_url(url)

    with requests.get(
        url,
        allow_redirects=False,
        stream=True,
        timeout=IMAGE_REQUEST_TIMEOUT,
    ) as response:
        if 300 <= response.status_code < 400:
            raise ValueError("Image URL redirects are not allowed")
        response.raise_for_status()

        content_type = (
            response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        )
        if not content_type.startswith("image/"):
            raise ValueError("Image URL did not return an image")

        content_length = response.headers.get("content-length")
        if content_length is not None:
            try:
                declared_size = int(content_length)
            except ValueError as exc:
                raise ValueError("Image response has an invalid length") from exc
            if declared_size < 0:
                raise ValueError("Image response has an invalid length")
            if declared_size > MAX_IMAGE_BYTES:
                raise ValueError("Image is too large")

        image_data = bytearray()
        for chunk in response.iter_content(chunk_size=_IMAGE_CHUNK_SIZE):
            if len(image_data) + len(chunk) > MAX_IMAGE_BYTES:
                raise ValueError("Image is too large")
            image_data.extend(chunk)

    return image_bytes_to_array(image_data)
