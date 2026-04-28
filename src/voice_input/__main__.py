"""Entry point: ``python -m voice_input``."""
from .app import VoiceApp


def main() -> None:
    VoiceApp().run()


if __name__ == "__main__":
    main()
