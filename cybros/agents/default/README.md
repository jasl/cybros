# Bundled Default Agent

This is the official bundled Cybros programmable agent source tree.

It is intentionally structured like a small Ruby application so it can be:

- launched as the product's default external agent
- tested in isolation
- copied into a user-owned workspace root and forked as a custom agent

It is not a RubyGems package and should not carry RubyGems release semantics.
