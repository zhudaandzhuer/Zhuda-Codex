#!/usr/bin/env python3
"""Patch Codex Desktop's bundled model query to prefer Zhuda adapter models.

The Codex webview normally asks the backend host for model descriptors through
`list-models-for-host`.  For Zhuda-Codex portable builds we want the model menu
to be driven by the local adapter's `/pool/status` endpoint instead, because
runtime CDP injection is timing-sensitive on Windows.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


MARKER = "__zhudaCodexBundleModelPatch"

HELPER = (
    "function __zhudaCodexBundleModelPatchEfforts(){return "
    "[`minimal`,`low`,`medium`,`high`,`xhigh`].map(e=>({reasoningEffort:e,description:e+` effort`}))}"
    "function __zhudaCodexBundleModelPatchDescriptor(e,t,n){let r=__zhudaCodexBundleModelPatchEfforts();"
    "return{id:e,model:e,slug:e,name:e,label:e,title:e,displayName:e,display_name:e,"
    "description:`Zhuda `+(n||`adapter`)+` upstream model`,hidden:!1,disabled:!1,isAvailable:!0,"
    "isDefault:e===t,defaultReasoningEffort:`medium`,default_reasoning_effort:`medium`,"
    "supportedReasoningEfforts:r,supported_reasoning_efforts:r,availabilityNux:null,upgrade:null}}"
    "async function __zhudaCodexBundleModelPatchList(){for(const e of [4400,4000]){try{let t=await "
    "fetch(`http://127.0.0.1:${e}/pool/status`,{cache:`no-store`});if(!t.ok)continue;let n=await t.json(),"
    "r=Array.isArray(n.visibleModels)?n.visibleModels.filter(e=>typeof e===`string`&&e.trim()):[];"
    "if(!r.length)continue;let i=String(n.selectedUpstreamModel||n.selectedCodeModel||n.forceUpstreamModel||"
    "n.defaultUpstreamModel||r[0]||``).trim();if(!r.includes(i))i=r[0];return r.map(e=>"
    "__zhudaCodexBundleModelPatchDescriptor(e,i,n.providerName||n.provider))}catch(e){}}return null}"
)

QUERY_NEEDLE = (
    "queryFn:()=>i(`list-models-for-host`,{hostId:a,includeHidden:!0,cursor:null,limit:s})"
)

QUERY_REPLACEMENT = (
    "queryFn:async()=>{let z=await __zhudaCodexBundleModelPatchList();"
    "return z??await i(`list-models-for-host`,{hostId:a,includeHidden:!0,cursor:null,limit:s})}"
)


def run(command: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(command, cwd=cwd, check=True)


def find_model_query_file(extract_dir: Path) -> Path:
    candidates = sorted((extract_dir / "webview" / "assets").glob("model-queries-*.js"))
    if not candidates:
        raise RuntimeError("Could not find webview/assets/model-queries-*.js in app.asar")
    if len(candidates) > 1:
        raise RuntimeError(
            "Found multiple model query bundles; refusing ambiguous patch: "
            + ", ".join(str(path) for path in candidates)
        )
    return candidates[0]


def patch_model_query(model_query: Path) -> bool:
    text = model_query.read_text(encoding="utf-8")
    if MARKER in text:
        return False
    if QUERY_NEEDLE not in text:
        raise RuntimeError(
            "The Codex model query bundle no longer matches the known shape. "
            "Inspect webview/assets/model-queries-*.js before patching this version."
        )
    text = text.replace("var w=o(c,", HELPER + "var w=o(c,", 1)
    text = text.replace(QUERY_NEEDLE, QUERY_REPLACEMENT, 1)
    model_query.write_text(text, encoding="utf-8")
    return True


def write_patch_marker(asar_path: Path) -> None:
    marker_path = asar_path.with_suffix(".asar.zhuda-models-patched")
    marker_path.write_text(
        "zhuda-model-list-patch=1\n",
        encoding="utf-8",
    )


def patch_asar(asar_path: Path, *, backup: bool) -> bool:
    asar_path = asar_path.resolve()
    if not asar_path.exists():
        raise FileNotFoundError(str(asar_path))
    if asar_path.name != "app.asar":
        raise RuntimeError(f"Expected app.asar, got: {asar_path.name}")

    with tempfile.TemporaryDirectory(prefix="zhuda-codex-asar-") as tmp:
        extract_dir = Path(tmp) / "app"
        run(["npx", "--yes", "asar", "extract", str(asar_path), str(extract_dir)])
        changed = patch_model_query(find_model_query_file(extract_dir))
        if not changed:
            write_patch_marker(asar_path)
            print(f"already_patched={asar_path}")
            return False

        if backup:
            backup_path = asar_path.with_suffix(".asar.before-zhuda-models")
            if not backup_path.exists():
                shutil.copy2(asar_path, backup_path)
                print(f"backup={backup_path}")

        new_asar = Path(tmp) / "app.asar"
        run(["npx", "--yes", "asar", "pack", str(extract_dir), str(new_asar)])
        shutil.copy2(new_asar, asar_path)
        write_patch_marker(asar_path)
        print(f"patched={asar_path}")
        return True


def default_mac_asar() -> Path:
    return (
        Path(__file__).resolve().parents[1]
        / "mac"
        / "dist"
        / "Zhuda-Codex.app"
        / "Contents"
        / "Resources"
        / "app.asar"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--asar",
        action="append",
        dest="asar_paths",
        help="Path to a Codex app.asar. Can be passed more than once.",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="Do not create app.asar.before-zhuda-models.",
    )
    args = parser.parse_args()

    paths = [Path(path) for path in args.asar_paths] if args.asar_paths else [default_mac_asar()]
    changed_any = False
    for path in paths:
        changed_any = patch_asar(path, backup=not args.no_backup) or changed_any
    print(f"changed={str(changed_any).lower()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
