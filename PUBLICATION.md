# Preparing a public release

This is a local source-release preparation, not an App Store submission. Nothing
is uploaded automatically. A license decision is still required if LICENSE is
absent. Public visibility alone does not grant an open-source license.

## Publish the clean snapshot, not the development repository

The original development Git history contains personal author metadata. Editing
files does not remove it. Preserve that repository privately.

Run `python3 Tools/Release/prepare_public.py` to create `public-release/GalaxySim`
with one neutral initial commit and no remote. The command refuses to overwrite
an existing destination; provide another destination argument for a later export.
It copies a limited set of source, runtime resources, documentation and tools.
It excludes original Git history/config/hooks, historical screenshots (including
embedded image metadata), Blender binaries/backups, build outputs and private
handoffs. The shipped meshes remain necessary runtime resources.

Before exporting, put private names, usernames and email addresses, one per line,
in the ignored `.privacy-terms` file. The exporter checks selected file names and
contents for those terms, common private paths and some credential patterns.
This is a screening tool, not proof of anonymity or a complete secret detector.
Review documentation, asset provenance and any future images manually. Do not
commit `.privacy-terms` or copy private files into the release directory.

In the prepared directory:

```
git log --all --format=fuller
git remote -v
git status --short
swift build -c release
./rebuild-app.sh
```

Only after inspecting that directory, choosing a license and reviewing your
hosting identity should you create an empty GitHub repository and configure its
remote there. Never push the original development history or its tags. GitHub
account names, profile links and activity can identify you independently of file
contents. A neutral commit author does not anonymize the hosting account.
The export has a local neutral Git identity; inspect future commits and avoid
merging the private history back into it.

## Build and asset provenance

Requires macOS 15 or later and a compatible Swift 6 toolchain. No external Swift
packages are required. `rebuild-app.sh` includes the tracked Info.plist template,
so a clean clone can assemble the app. The current `local.galaxysim` identifier
is a local development identifier; choose an identifier you control for release.
Do not distribute locally built binaries without inspecting embedded paths,
debug information, signing metadata and bundled resources separately.

The runtime ship/cabin meshes have procedural authoring scripts in Tools/Blender.
Historical .blend files are deliberately excluded; review asset ownership before
choosing the scope of a software/artwork license. Scientific citations in the
design documents are retained. The audio code references an installed macOS
instrument bank; that system asset is not included in this repository.

For Blender authoring, enable your trusted Blender MCP add-on on localhost port
9876. Create `Assets/Blender` first. Run, for example:

```
mkdir -p Assets/Blender
python3 Tools/Blender/client.py Tools/Blender/build_cityship.py
```

Run refinement/export scripts in the README order. The client supplies the script
location to Blender, so project paths are derived from the checkout rather than
a particular home directory. This assumes Blender runs on the same machine and
can access that checkout. The client executes Python in Blender; keep the service
local and send only trusted scripts. Direct Blender `--python` execution also
uses the script location.

## App Store is a separate release step

Source cleanup does not conceal an Apple developer's identity. Apple states that
an individual developer's displayed developer name is their legal name;
organizations have different registered trade-name options. Review Apple's
[current naming rules](https://developer.apple.com/help/app-store-connect/create-an-app-record/set-your-developer-name)
before choosing enrollment. Other seller/contact disclosures may apply.

This preparation does not configure signing, entitlements, sandboxing or store
submission. Before submission, audit sandbox compatibility, resource access,
privacy disclosures, licensing, app icons, accessibility, and performance on the
minimum supported Mac; test a signed archive. Keep certificates, private keys,
provisioning profiles and account credentials outside the source distribution.
