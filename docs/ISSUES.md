# Known limitations

- The KoboldCpp initializer currently supports official Windows builds. Linux and macOS acquisition and startup are not implemented.
- Automatic KoboldCpp acquisition stops when the release API does not provide a verifiable SHA-256 digest.
- GGUF model licenses, hardware requirements, and provider availability vary; users must review them individually.
- Workflow execution currently assumes one active runner per task. Concurrent writes to the same task state are not coordinated.
- Context compression depends on the KoboldCpp tokenizer API being available and returning a valid token count.

## Potential improvements

- Add a mock KoboldCpp API for end-to-end workflow tests.
- Make retry and timeout policies configurable.
- Add explicit locking for task state and workspace changes.
- Add portable acquisition and startup support for other operating systems.
