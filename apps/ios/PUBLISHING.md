# iPhone/iPad POC gaps and proposed Apple publishing path

Status, 2026-11-16: **unofficial, fork-only proof of concept (POC)**.
Not an official ArtCraft release, an accepted suite architecture, or a store-ready app.
No signing credentials, Apple membership, TestFlight upload or App Store submission
have been configured or verified by this documentation change.

Tracking:

- [storytold/pdfcraft#2085](https://github.com/storytold/pdfcraft/issues/2085):
  canonical mobile request; today's comment records unsupported controls for review.
- [storytold/craft-common-actions#259](https://github.com/storytold/craft-common-actions/issues/259)
  and [draft proposal PR](https://github.com/storytold/craft-common-actions/pull/260):
  shared workflow ownership, credential contract and staged implementation.
- [RFC-0039](https://github.com/storytold/craft-contrib/pull/60),
  [craft-mobile proposal](https://github.com/storytold/craft-libs/pull/632),
  [shared inventory](https://github.com/storytold/craft-libs/issues/115),
  and [different mobile host](https://github.com/storytold/pdfcraft/pull/1119):
  alternatives under review, not adopted dependencies of this POC.

## What this snapshot actually represents

The published POC baseline at `55f13eaf0` covers Rust-backed open, render, zoom,
clockwise page rotation, save-a-copy and native sharing. Both device families are
configured in [project.yml](project.yml); iOS/iPadOS 17 is the compile-time minimum.

The latest **local, not yet committed/pushed** 2026-11-16 work also provides a
desktop-aligned Home, tools/search/pins, appearance preferences and per-page
embedded-text reading/copying. Complete local runs passed 7 Rust tests, 4 hosted
Swift tests and 3 native UI workflows on each of iPhone 18 Pro and iPad Pro 11-inch
(M5), using the iOS/iPadOS 27.0 runtime. This documentation-only branch does not
ship those local enhancements or claim that they are in the published baseline.
No physical-device, signing, TestFlight or App Review result follows from these tests.

## Unsupported controls and intentional differences

This is a mobile-shell exposure inventory, **not** a claim the Rust engine lacks
the corresponding features. Keep unsupported tools hidden, not enabled placeholders.
Future issues/PRs should select one workflow, reuse the engine/automation operation,
and verify it on both device families before exposing its control.

| Desktop control or capability | POC limitation / future review |
| --- | --- |
| Full Edit workspace | No mobile document text/image editing, annotation/comment tools or full edit panels |
| Convert / create / combine / extract | No mobile conversion, PDF creation, merge, split or extraction workflow |
| E-Sign, forms and protection panels | No signature/form editing, signing UI or password/encryption configuration UI |
| Full Organize pages grid | Only page selection and explicit clockwise Rotate; no thumbnails, reorder, insert, delete or multi-page batch editing |
| Undo/redo, save-in-place, multiple documents | No undo/redo UI, original-file overwrite, tabs, multi-document session or crash restoration; keep copy-based saving and dirty-close confirmation |
| Desktop recents and pinned folders | No separate mobile history/bookmark store; native Files provides recents, folders and provider access |
| OCR and read-aloud controls | No scanned-page OCR or custom speech player; local text work exposes embedded text, not a position-aligned selection overlay |
| Desktop-scale accessibility/localization | Native labels/text are present, but complete VoiceOver speech, all Dynamic Type/split-view sizes and localization are not validated |
| Shipping and updates | No production identity/icon/metadata/signing/archive pipeline, TestFlight distribution, App Store listing or physical-device certification |

Keep the desktop's task order, terminology and safe document semantics where they
fit native touch UI. Do not copy unsupported Edit/Convert/E-Sign tabs, trademark
assets or a second PDF implementation merely for visual parity. Selecting Organize
must not edit the document automatically. Maintain this inventory when a tool lands;
a hidden control is not evidence that the underlying feature has been implemented.

## Apple account and credential setup: authorized maintainers only

Simulator testing needs no paid Apple Developer Program membership. A free Personal
Team can provide limited, short-lived personal-device testing, not TestFlight or
App Store distribution.

If Storytold does not already have suitable membership, its authorized legal entity
should join the **Apple Developer Program as an organization**, so that entity is
the seller. Apple normally requires a legal entity, D-U-N-S number, binding authority,
domain-associated work email and public website. The Account Holder handles
agreements/enrollment/payment or a possible fee waiver. No enrollment is performed
here; do not use a contributor's or this fork's seller identity by accident.

1. In Apple Developer **Certificates, Identifiers & Profiles**, register an
   authorized bundle ID/capabilities and matching Apple Distribution identity and
   App Store Connect provisioning profile. Do not repurpose the fork's
   `com.blackoutsecure.pdfcraft.poc` as Storytold's production ID.
2. In **App Store Connect > Apps**, create the matching app record. In **Users and
   Access > Integrations > App Store Connect API**, request access/create a suitably
   role-limited API key through the authorized account roles.
3. Keep the `.p12` certificate **with its private key**, its password, the profile,
   and the API `.p8` in the organization's secret store. A `.cer` alone cannot sign;
   the upload `.p8` is a separate private key, not a signing certificate.
4. After workflow acceptance, add the following under **the app repository >
   Settings > Environments > ios-testflight > Environment secrets**:
   `IOS_DISTRIBUTION_P12_BASE64`, `IOS_DISTRIBUTION_P12_PASSWORD`,
   `IOS_APPSTORE_PROFILE_BASE64`, `ASC_API_PRIVATE_KEY_P8_BASE64`.
   Store `APPLE_TEAM_ID`, `IOS_BUNDLE_ID`, `ASC_APP_ID`, `ASC_API_KEY_ID` and
   `ASC_API_ISSUER_ID` as environment variables. These are proposed names, not an
   existing working CI interface.
5. Restrict deployment refs and required reviewers, and keep production submission
   behind a separate `ios-appstore` environment. Do not grant PR/fork code secrets.
   The reusable job must bind the environment internally and receive explicitly
   mapped secret names; reject empty values. Do not use blanket secret inheritance.

**Do not publish certificates/private keys to GitHub source, issues, releases or
logs.** Base64 is not encryption. No credentials belong in `craft-common-actions`.
Existing desktop `APPLE_CERTIFICATE`/Apple-ID notarization secrets are not the iOS
signing/upload setup. A team API key can cover all apps despite GitHub repo scoping.
Use temporary runner keychains/files with failure cleanup and an approved
least-privilege key/tooling choice as described in the shared proposal.

## Workflow additions and existing workflow integration

The app's [CI](../../.github/workflows/ci.yml) and
[release workflow](../../.github/workflows/release.yml) already delegate to
`storytold/craft-common-actions`. The current release Apple path is macOS
Developer ID signing/notarization, not iOS distribution.

The recommendation in the [shared proposal](https://github.com/storytold/craft-common-actions/pull/260)
is to implement new reusable workflows there first:

1. **Unsigned `ios-gate.yml`:** explicit Xcode/Rust/host toolchains, unsigned app
   builds and sequential iPhone+iPad simulator tests. Start with a manual app
   `ios.yml` caller; no extra default macOS PR runner cost.
2. **Protected `ios-distribute.yml`:** reviewed commit, device Rust release build,
   native archive/export/signature checks and manually approved App Store Connect
   upload. Later add a thin manual `ios-testflight.yml` app caller.
3. **Optional later submission workflow:** separate production approval for an
   already processed build. Start with manual App Store Connect review/release.

These are **suggested future filenames**, not implemented workflows. Do not add a
caller referencing them now. Keep the existing desktop release schedule and `release`
environment untouched. A later opt-in extension may delegate from the release
workflow only after maintainer approval and regression tests; it must default off.
No new workflow is needed merely to review this POC or these documents.

### Release blockers before the signed pilot

- Accept a mobile architecture/host and ownership first. Do not silently turn the
  fork-only SwiftUI exception into a suite requirement.
- [Release.xcconfig](Config/Release.xcconfig) currently includes the Debug config;
  [build-ios-rust.sh](../../scripts/build-ios-rust.sh) builds a development Rust
  archive. Xcode's Release selector alone does **not** fix that. Add and verify a
  real device Rust release profile, correct native library search paths and
  profile-aware generated bindings in a separate implementation change.
- Choose a hosted runner with the required Xcode/SDK; local Xcode 27.2 availability
  is not proof of hosted availability. Check Apple's upload SDK requirements again.
- Replace development bundle/team identity, provide approved app icons/launch
  assets, version/build-number policy, entitlements and matching distribution profile.
  Keep universal device families `1,2`; test actual iPhone/iPad hardware and supported
  OS versions, not only the newest Simulator.
- Validate the signed archive/export, release behavior, memory/fidelity limits,
  privacy/required-reason API manifests where applicable, licensing and export
  compliance. The engine includes cryptography: do not guess an exemption.
- Prepare beta/review contact, support/privacy URLs, age rating, accurate privacy
  disclosures and iPhone/iPad store screenshots using allowed synthetic documents.
  A POC disclaimer does not bypass Apple's completeness/review requirements.

## Private testing to public release

Upload an approved signed build, then wait for Apple's processing and record the
build ID. Upload success alone is not tester availability or store approval.

Use **App Store Connect > app > TestFlight** for private internal groups first
(up to 100 authorized App Store Connect users). Disable automatic distribution on
the pilot group and review existing automatic group assignments before uploading,
so an upload cannot unexpectedly notify/distribute to testers. Invitation-only external groups
are a later option; their first build requires Beta App Review and subsequent builds
may also require review. Public TestFlight links are a separate optional decision.
Apple currently permits up to 10,000 external testers and builds expire after 90 days.
Do not select an internal-only distribution option if the same build must later be
eligible for external testing or App Review.

For a public release, complete the app version metadata in App Store Connect,
select the processed build and explicitly submit it for **production App Review**.
Beta approval is not production approval. Prefer **manual release after approval**
for the first version; later updates may use phased release. Keep upload, tester
invitations, external review, production submission and release as separate approvals.
This proposal performs none of them and does not promise Apple acceptance.

See the shared proposal's official Apple/GitHub references for enrollment, roles,
signing secrets, reusable workflow environments, TestFlight and App Review.
