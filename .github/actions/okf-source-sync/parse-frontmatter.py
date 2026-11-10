import json
import sys
from pathlib import Path

import yaml


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key ({key})",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    construct_mapping,
)


def parse_frontmatter(path):
    lines = Path(path).read_text(encoding="utf-8-sig").splitlines()
    if len(lines) < 3 or lines[0].strip() != "---":
        return {"resources": [], "diagnostics": []}

    try:
        end = next(index for index in range(1, len(lines)) if lines[index].strip() == "---")
    except StopIteration:
        return {
            "resources": [],
            "diagnostics": [
                {
                    "code": "invalid-frontmatter",
                    "message": "Front matter does not have a closing '---' delimiter.",
                }
            ],
        }

    content = "\n".join(lines[1:end])
    try:
        document = yaml.load(content, Loader=UniqueKeyLoader)
    except yaml.YAMLError as error:
        return {
            "resources": [],
            "diagnostics": [
                {
                    "code": "invalid-frontmatter",
                    "message": f"Unable to parse front matter as YAML: {error}",
                }
            ],
        }

    if document is None:
        return {"resources": [], "diagnostics": []}
    if not isinstance(document, dict):
        return {
            "resources": [],
            "diagnostics": [
                {
                    "code": "invalid-frontmatter",
                    "message": "Front matter must contain a YAML mapping.",
                }
            ],
        }

    if "sources" not in document or document["sources"] is None:
        return {"resources": [], "diagnostics": []}
    sources = document["sources"]
    if not isinstance(sources, list):
        return {
            "resources": [],
            "diagnostics": [
                {
                    "code": "unsupported-source-declaration",
                    "message": "The top-level 'sources' value must be a YAML list.",
                }
            ],
        }

    resources = []
    diagnostics = []
    for index, item in enumerate(sources):
        if not isinstance(item, dict):
            diagnostics.append(
                {
                    "code": "unsupported-source-declaration",
                    "message": f"Source entry {index} must be a YAML mapping.",
                }
            )
            continue
        resource = item.get("resource")
        if not isinstance(resource, str) or not resource.strip():
            diagnostics.append(
                {
                    "code": "unsupported-source-declaration",
                    "message": f"Source entry {index} must contain a non-empty string resource.",
                }
            )
            continue
        resources.append(resource.strip())

    return {"resources": resources, "diagnostics": diagnostics}


if len(sys.argv) != 2:
    raise SystemExit("Usage: parse-frontmatter.py <markdown-file>")

print(json.dumps(parse_frontmatter(sys.argv[1]), ensure_ascii=False))
