# Releasing Musubi

## One-time publication requirements

- Choose and commit an open-source license.
- Create the public GitHub repository and set it as `origin`.
- Confirm the repository name and default branch are `Musubi` and `main`.
- Enable the GitHub Actions workflow and branch protection if desired.

## 0.1 release checklist

1. Confirm the compatibility table and changelog describe the code honestly.
2. Run `swift test` with a full Xcode toolchain.
3. Run `swift build -c release`.
4. Run `swift package dump-package` and review the products, targets, and
   minimum platform.
5. Run `musubi-inspect` over the ignored local reference directory and review
   errors or unexpectedly empty interpretations.
6. Confirm `git status` is clean and no private images or build artifacts are
   tracked.
7. Tag the release with an annotated semantic version:

   ```sh
   git tag -a 0.1.0 -m "Musubi 0.1.0"
   git push origin main 0.1.0
   ```

8. Create a GitHub release from the tag using the matching changelog section.
9. Add the package to a consuming app by its Git URL and verify Xcode resolves
   the `0.1.0` tag and imports the `Musubi` module.

Swift Package Manager derives the package version from Git tags; no version
number belongs in `Package.swift`.

