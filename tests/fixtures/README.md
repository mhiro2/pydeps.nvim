# Lockfile fixtures

`generated-fork.uv.lock` was generated offline with uv 0.12.3 using
`uv lock --offline`. The root project depends on `demo[speed]`, with two local
sources selected by `sys_platform == 'linux'` and its complement. The local
projects declare `demo` versions `1.0` and `2.0`, each with an optional
`speed` dependency on the local `child` project. This records uv's actual
fork identity, resolution-marker, source, and conditional edge layout.

`fork.uv.lock` is a focused synthetic extension of that layout covering
registry/Git identities, optional dependencies, and development groups.
