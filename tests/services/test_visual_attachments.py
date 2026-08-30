"""Tests for visual attachment preparation in chat turns."""

from services.agent import _user_content_with_visuals


def test_user_content_with_visuals_adds_openai_responses_image_part():
    content = _user_content_with_visuals(
        "Please look at this.",
        [
            {
                "name": "samantha.png",
                "mime_type": "image/png",
                "data_url": "data:image/png;base64,aW1hZ2U=",
                "byte_size": 5,
            }
        ],
    )

    assert content == [
        {"type": "input_text", "text": "Please look at this."},
        {"type": "input_text", "text": "\n[Attached image 1: samantha.png]\n"},
        {
            "type": "input_image",
            "image_url": "data:image/png;base64,aW1hZ2U=",
            "detail": "auto",
        },
    ]

