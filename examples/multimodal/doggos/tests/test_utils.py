import unittest
from io import BytesIO
from unittest.mock import patch

import numpy as np
from doggos.utils import (
    IMAGE_REQUEST_TIMEOUT,
    MAX_IMAGE_BYTES,
    image_bytes_to_array,
    url_to_array,
)
from PIL import Image

ALLOWED_URL = "https://doggos-dataset.s3.us-west-2.amazonaws.com/samara.png"


def make_image_bytes(size=(3, 2), image_format="PNG"):
    output = BytesIO()
    Image.new("RGB", size, color=(10, 20, 30)).save(output, format=image_format)
    return output.getvalue()


class FakeResponse:
    def __init__(
        self,
        chunks,
        *,
        status_code=200,
        content_type="image/png",
        include_content_length=True,
    ):
        self._chunks = chunks
        self.status_code = status_code
        self.headers = {"content-type": content_type}
        if include_content_length:
            self.headers["content-length"] = str(sum(len(chunk) for chunk in chunks))

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def raise_for_status(self):
        return None

    def iter_content(self, chunk_size):
        yield from self._chunks


class ImageBytesToArrayTests(unittest.TestCase):
    def test_decodes_rgb_image(self):
        result = image_bytes_to_array(make_image_bytes())

        self.assertEqual((2, 3, 3), result.shape)
        self.assertEqual(np.uint8, result.dtype)

    def test_rejects_payload_over_byte_limit(self):
        with self.assertRaisesRegex(ValueError, "too large"):
            image_bytes_to_array(b"1234", max_bytes=3)

    def test_rejects_image_over_pixel_limit(self):
        with self.assertRaisesRegex(ValueError, "dimensions"):
            image_bytes_to_array(make_image_bytes(size=(3, 2)), max_pixels=5)

    def test_rejects_invalid_image(self):
        with self.assertRaisesRegex(ValueError, "invalid"):
            image_bytes_to_array(b"not an image")


class UrlToArrayTests(unittest.TestCase):
    @patch("doggos.utils.requests.get")
    def test_rejects_untrusted_host_without_network_request(self, request_get):
        with self.assertRaisesRegex(ValueError, "host is not allowed"):
            url_to_array("http://169.254.169.254/latest/meta-data/")

        request_get.assert_not_called()

    @patch("doggos.utils.requests.get")
    def test_disables_redirects_and_sets_timeout(self, request_get):
        image_data = make_image_bytes()
        request_get.return_value = FakeResponse([image_data])

        result = url_to_array(ALLOWED_URL)

        self.assertEqual((2, 3, 3), result.shape)
        request_get.assert_called_once_with(
            ALLOWED_URL,
            allow_redirects=False,
            stream=True,
            timeout=IMAGE_REQUEST_TIMEOUT,
        )

    @patch("doggos.utils.requests.get")
    def test_rejects_redirect_response(self, request_get):
        request_get.return_value = FakeResponse([], status_code=302)

        with self.assertRaisesRegex(ValueError, "redirects"):
            url_to_array(ALLOWED_URL)

    @patch("doggos.utils.requests.get")
    def test_rejects_stream_over_byte_limit(self, request_get):
        request_get.return_value = FakeResponse(
            [b"x" * MAX_IMAGE_BYTES, b"x"], include_content_length=False
        )

        with self.assertRaisesRegex(ValueError, "too large"):
            url_to_array(ALLOWED_URL)


if __name__ == "__main__":
    unittest.main()
