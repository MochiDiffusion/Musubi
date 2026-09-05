# Contributing

Bug reports should include the producing application, image format, relevant
application version when known, expected fields, and Musubi's actual result.
Attach an image only when you have permission to redistribute it and have
checked its prompt and embedded metadata for private information.

Implementation changes should preserve raw payload ordering, avoid pixel
decoding, and add focused Swift Testing coverage. Run both commands before
opening a pull request:

```sh
swift test
swift build -c release
```

Format conventions change independently of Musubi. New source support should
be based on observed files or an authoritative upstream implementation, and
limitations should be documented rather than hidden behind guessed values.

By contributing, you agree that your contribution will be licensed under the
GNU General Public License v3 used by this repository.
