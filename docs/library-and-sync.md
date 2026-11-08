# Document library and iCloud sync

Prose's library presents document titles, previews, search and a recoverable trash. Typst files remain an implementation detail in normal writing. Import, source export, project export and reveal-in-Finder remain available when a writer needs the source or its assets.

## Storage and identity

The local library lives at `Application Support/Prose/Library`. Each document has a stable UUID directory under `Documents`, a `document.json` metadata file and a source entry point. New documents use `main.typ`. Renaming changes the title in metadata, never the source URL or the UUID. Source modification dates also contribute to the displayed modification time, so edits made by the editor or another application remain visible.

A source-only import copies one UTF-8 file and leaves its original untouched. A project import requires an explicitly selected project directory and main `.typ` file; it copies that directory beneath `Project/` and preserves relative asset paths. Prose never silently copies the source file's entire parent directory. Symbolic links and nonregular files are rejected, and metadata entry points cannot escape the managed document folder. Documents that depend on external paths or dynamically located resources still require the author to bring those resources into the imported project.

Source export creates a UTF-8 `.typ` file. Project export includes the relative resource tree and a short entry-point hint, while excluding internal UUID metadata. Existing export destinations are rejected rather than silently replaced. Trash is a metadata tombstone: it retains the source, assets and identity, and restore removes that tombstone. There is no automatic permanent deletion.

The library is an actor. Its indexing, import, export and migration work runs away from the main actor. `DocumentStorage` also uses `NSFileCoordinator`: baseline comparison and atomic source replacement occur within the same coordinated write accessor. A source changed or deleted elsewhere fails the baseline check and preserves the editor's recovery data. The app's current synchronous save boundary remains available for shutdown and document switching; a coordinated write can wait for other processes. This is not a guarantee that every disk operation has zero UI latency.

## A book is still one document

A project is a storage boundary, not an extra object the writer must create.
The library shows one title for the entry point; local styles, chapters and
images travel together when imported, exported, trashed or migrated to iCloud.
The entry point remains the preview target when following a definition into a
local `.typ` dependency, and the library identity still refers to the whole book.

For example, the SICP example imports a local `styles/book.typ` function and
applies it with `#show: book`. Typst `#set` and `#show` rules are scoped, so merely
importing a file containing top-level settings would not apply those settings
to the caller. A template function is the explicit, reusable boundary. Authors
can similarly use `#include "chapters/intro.typ"` for chapter content. Paths are
relative to the file where they occur; the root entry point should sit above
its dependencies. See the [Typst module documentation](https://typst.app/docs/reference/scripting/#modules).

There is no hidden global preamble or separate Prose-only formatting language.
The exported folder compiles with standard Typst. A full project file tree,
chapter navigation UI and dependency-aware cross-file library search are future
work; the current library content search indexes the main manuscript. SICP keeps
its full prose in that manuscript so search, outline and large-buffer tests
exercise the complete book today.

## Native change discovery

`LibraryFileMonitor` implements `NSFilePresenter` and sends callbacks on a serial background queue. Owners must call `stop()` before replacing or releasing it. The presenter catches coordinated external changes; it does not claim to observe every uncoordinated POSIX write. The UI refreshes on relevant app/library activity as a second opportunity to discover changes.

`LibraryCloudQuery` uses `NSMetadataQueryUbiquitousDocumentsScope`, filters results to the current Prose library and requests source/metadata downloads. This discovers remote placeholders that a plain directory enumeration may not yet expose. The selected document's folder is requested for download when opened so its resources can become available. Loading a source still waiting for download returns a specific pending state, never an empty document that could overwrite the remote content.

A clean open buffer can adopt incoming source changes while preserving its selection. A dirty buffer must compare against its saved baseline and either merge demonstrably nonoverlapping changes or retain both versions for user review. The library does not automatically select a winner for native `NSFileVersion` conflicts; it exposes the conflict flag and refuses destructive source writes while that flag is set. Native conflict versions are not deleted or marked resolved without a resolution step.

## Explicit iCloud transitions

Sync is off by default. The native resolver checks the running application's signed ubiquity container entitlement, the user's iCloud identity and the actual container URL. A build without capability provisioning, a signed-out account or an unavailable container produces an explicit error and leaves the current library root unchanged.

Enabling sync copies the current library into the app's iCloud container at `Documents/ProseLibrary`. Disabling sync copies the current cloud library back to local storage. Both transitions preserve the originals. Matching UUID folders with identical contents are reused. Different contents under the same UUID produce a separate preserved copy and an ID mapping for the active editor; they never overwrite the destination. The copy records its origin fingerprint, making a repeated interrupted transition reuse that copy instead of multiplying it. If migration fails, the active root remains unchanged; any already completed copies are safe to reuse on retry.

After a successful choice, the app persists its opt-in locally. At the next launch it calls `resumeICloud()`, which activates the existing container **without migrating stale local backups again**. Account changes never cause an implicit switch to the old local backup. The open buffer and recovery snapshot must be preserved, and the app must report the unavailable account. It must not imply that an old local snapshot represents the latest remote library.

Normal offline work uses macOS's locally cached iCloud files. Files that were never downloaded remain pending until the system can retrieve them. Account replacement and sign-out are stronger events than temporarily losing network access; recovery must remain explicit when the old container is unavailable. `LibraryAccountMonitor` reports these events without deciding that a different account owns the previous account's documents.

`LibraryCloudEnvironment.state(of:)` distinguishes local files, pending download, pending upload, uploading, uploaded and unresolved conflict states using native resource values. Activating a container or returning from a write does not mean another device has received the edit.

## Preferences

`LibraryPreferences` persists a validated local snapshot immediately. Its optional `NSUbiquitousKeyValueStore` adapter syncs only language, app appearance, command key, editor font size, dark preview, styled-source, history interval and legacy default-template preferences (retained for compatibility; new documents now use explicit choices in Templates). Document text, file paths, recovery snapshots, logs, tokens and other secrets never enter KVS. The adapter is created only after the user opts in and a signed KVS entitlement/account is available.

Initial reconciliation reads existing cloud preferences before publishing defaults. Changes made while waiting remain local until reconciliation completes. Later updates merge each field against the last observed cloud snapshot, preserving independent edits; an explicit local change wins a simultaneous change to the same field. Local preference changes remain available if the service is unavailable. Quota and account-change notifications are surfaced; an account change stops publishing until sync is explicitly reenabled. `synchronize()` is used at activation, not on every keystroke, and its return value is never presented as proof of cross-device delivery.

## Provisioning and release

`Resources/Prose.iCloud.entitlements.example` documents the required capabilities. The release script derives its final entitlements from a validated profile instead of applying the template directly. The renamed App ID, container association and `ICLOUD_PROVISIONING_PROFILE` GitHub Secret must be configured before the first Prose release; the previous testing profile belongs to the old application identity. A release requires an explicit App ID for `com.tehrandavis.prose`, the registered `iCloud.com.tehrandavis.prose` container, iCloud Documents and Key-value Storage services, and a matching Developer ID provisioning profile embedded in the app. Expand `$(TeamIdentifierPrefix)` to the team's actual prefix when generating the final entitlement file. The signing workflow validates the profile and resulting signed entitlements; adding strings to a plist alone does not grant the capability.

Apple's current macOS capability matrix includes iCloud Documents and KVS for Developer ID distribution. Existing Developer ID signing and notarization by themselves do not configure these services. No developer-portal settings, profiles or production cloud data are changed by the library tests.

## Verification and product limits

Disk integration tests exercise create, read, baseline-safe edit, search, rename, trash/restore, source/project import and export, relative assets, invalid metadata, path traversal, external changes, native presenter callbacks, injected cloud migration, conflict preservation and restart without duplicate migration. Preference integration tests use an isolated UserDefaults suite and an injected cloud store. They exercise initial reconciliation, offline/unavailable states, account changes, quota handling and local persistence. No test writes to a real user's iCloud account.

This backend uses iCloud Drive because Typst documents depend on a real directory of source and assets, and it fits the existing file-based renderer. CloudKit could offer explicit record-level change tokens, custom conflict transactions and a more controlled local database, but it would require a separate asset materialization layer and synchronization engine. Changing transports would not alone provide collaborative text semantics.

The intended experience is immediate local writing, automatic discovery of remote changes and safe conflict handling. This implementation does not claim Apple Notes' latency, collaboration engine or private system integrations. Before enabling iCloud in a public release, verify the correctly provisioned build on two Macs: create/edit/rename/trash/restore; offline edits and reconnection; edits to different and overlapping paragraphs; undownloaded assets; app restart; low quota; and sign-out/account changes. Native upload/download delivery and real two-device conflict behavior remain unverified by isolated tests.

## Apple references

- [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services)
- [Supported capabilities for macOS](https://developer.apple.com/help/account/reference/supported-capabilities-macos)
- [File coordinators and presenters](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html)
- [iCloud file management and metadata queries](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)
- [Downloading ubiquitous items](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:))
- [Key-value synchronization timing](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/synchronize())
- [Native conflict versions](https://developer.apple.com/documentation/foundation/nsfileversion)
